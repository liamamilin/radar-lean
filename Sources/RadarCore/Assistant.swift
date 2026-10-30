import Foundation
import GRDB

public enum TimeRange: String, CaseIterable, Identifiable {
    case day, week, month, all
    public var id: String { rawValue }
    public var label: String {
        switch self { case .day: return "最近 24 小时"; case .week: return "最近 7 天"; case .month: return "最近 30 天"; case .all: return "已发现的全部内容" }
    }
    public var days: Double? { switch self { case .day: return 1; case .week: return 7; case .month: return 30; case .all: return nil } }
    public func since(_ now: Date = Date()) -> Date? { days.map { now.addingTimeInterval(-$0 * 86400) } }
}

/// One numbered piece of stored material handed to the model. The URL always comes from the database.
public struct Evidence: Identifiable, Hashable, Codable {
    public var id: String            // S1, S2 …
    public var title: String
    public var url: String
    public var origin: String        // watch / source it came from
    public var date: Date?
    public var text: String
    public var meta: String
    public var isEvent: Bool         // a change Radar detected (Event) as opposed to content it has found (Entry)
    public var kind: String
}

public struct SummaryContext {
    public var evidence: [Evidence]
    public var events: Int, entries: Int
    public var signature: String     // changes when the underlying data changes (cache invalidation)
    public var scopeTitle: String
}

public final class RadarAssistant {
    let store: Store
    public init(store: Store) { self.store = store }

    static let kindLabel = ["newProject": "新项目", "majorUpdate": "重大更新", "pageChange": "页面变化", "update": "更新"]

    // MARK: rows

    struct Row { var entry: Entry; var source: String; var watch: String; var watchID: Int64 }

    func rows(_ db: Database, watchID: Int64?) throws -> [Row] {
        let sql = """
            SELECT entry.*, source.name AS sourceName, watch.title AS watchTitle, ws.watchID AS wid FROM entry
            JOIN source ON source.id = entry.sourceID JOIN watchSource ws ON ws.sourceID = source.id JOIN watch ON watch.id = ws.watchID
            \(watchID == nil ? "" : "WHERE ws.watchID = ?") ORDER BY entry.id DESC
            """
        return try GRDB.Row.fetchAll(db, sql: sql, arguments: watchID.map { [$0] } ?? []).map {
            Row(entry: try Entry(row: $0), source: $0["sourceName"], watch: $0["watchTitle"], watchID: $0["wid"])
        }
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
    static func stars(_ e: Entry) -> Int { Int(e.meta["stars"] ?? "") ?? 0 }
    static func meta(_ e: Entry) -> String {
        [Self.stars(e) > 0 ? "★\(Self.stars(e))" : nil, e.meta["language"].flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " ")
    }
    static func date(_ e: Entry) -> Date { e.publishedAt ?? e.firstSeenAt }

    func evidence(_ r: Row, id: String) -> Evidence {
        let body = r.entry.summary.isEmpty ? r.entry.text : r.entry.summary
        return Evidence(id: id, title: r.entry.title, url: r.entry.canonicalURL, origin: r.source, date: Self.date(r.entry),
                        text: Self.clip(body, 600), meta: Self.meta(r.entry), isEvent: false, kind: "entry")
    }

    func evidence(_ e: Event, entry: Entry?, watch: String, id: String) -> Evidence {
        let extra = entry.map { $0.summary.isEmpty ? $0.text : $0.summary } ?? ""
        return Evidence(id: id, title: e.title, url: e.evidenceURL, origin: watch, date: e.createdAt,
                        text: Self.clip(e.reason + "。" + extra, 600), meta: entry.map { Self.meta($0) } ?? "", isEvent: true, kind: e.kind)
    }

    func watchTitles(_ db: Database) throws -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: try Watch.fetchAll(db).map { ($0.id!, $0.title) })
    }

    // MARK: summary

    /// Real new events in the range, plus the content found in the range (which includes the first-read baseline, and is labelled so).
    public func summaryContext(watchID: Int64?, range: TimeRange, now: Date = Date(), maxEvents: Int = 20, maxEntries: Int = 24) throws -> SummaryContext {
        try store.db.read { db in
            let titles = try watchTitles(db)
            let since = range.since(now)
            var evq = Event.order(Column("createdAt").desc)
            if let w = watchID { evq = evq.filter(Column("watchID") == w) }
            if let s = since { evq = evq.filter(Column("createdAt") >= s) }
            let evs = try evq.limit(maxEvents).fetchAll(db)
            var ev: [Evidence] = [], seen = Set<String>()
            for e in evs where seen.insert(e.evidenceURL).inserted {
                ev.append(evidence(e, entry: try Entry.fetchOne(db, key: e.entryID), watch: titles[e.watchID] ?? "", id: "S\(ev.count + 1)"))
            }
            var rs = try rows(db, watchID: watchID).filter { r in since.map { Self.date(r.entry) >= $0 } ?? true && seen.insert(r.entry.canonicalURL).inserted }
            let total = rs.count
            // worth-a-look first: popular projects and fresh items
            let span = range.days ?? 90
            func score(_ r: Row) -> Double {
                let age = max(0, now.timeIntervalSince(Self.date(r.entry)) / 86400)
                return log10(1 + Double(Self.stars(r.entry))) + max(0, 1 - age / span)
            }
            rs.sort { score($0) > score($1) }
            let shown = rs.prefix(maxEntries)
            var all = ev
            for r in shown { all.append(evidence(r, id: "S\(all.count + 1)")) }
            let maxEntry = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM entry") ?? 0, maxEvent = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM event") ?? 0
            let title = watchID.flatMap { titles[$0] } ?? "全部关注事项"
            return SummaryContext(evidence: all, events: ev.count, entries: total, signature: "\(watchID ?? 0)-\(range.rawValue)-\(maxEntry)-\(maxEvent)", scopeTitle: title)
        }
    }

    // MARK: ask

    static let stop: Set<String> = ["最近", "哪些", "什么", "值得", "关注", "一周", "本周", "今天", "这些", "其中", "比较", "有没有", "发现", "新的", "一下", "怎么", "如何", "项目", "请问",
                                    "the", "and", "what", "which", "recent", "new", "are", "for", "any", "about", "compare"]
    static let followMarkers = ["其中", "这些", "它", "他们", "前两个", "前三个", "第一个", "第二个", "第三个", "上面", "刚才", "你提到", "这几个", "那个", "这个"]

    public static func detectRange(_ q: String) -> TimeRange? {
        if q.contains("24小时") || q.contains("24 小时") || q.contains("今天") || q.contains("昨天") { return .day }
        if q.contains("一周") || q.contains("7天") || q.contains("7 天") || q.contains("本周") || q.contains("这周") || q.contains("上周") || q.lowercased().contains("past week") { return .week }
        if q.contains("一个月") || q.contains("30天") || q.contains("30 天") || q.contains("本月") { return .month }
        return nil
    }

    static func tokens(_ q: String) -> [String] {
        var out: [String] = [], word = "", cjk = ""
        func flushCJK() {
            let c = Array(cjk)
            if c.count >= 2 { for i in 0..<(c.count - 1) { out.append(String(c[i...i + 1])) } }
            cjk = ""
        }
        for ch in q.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-") { flushCJK(); word.append(ch) }
            else {
                if word.count >= 2 { out.append(word) }; word = ""
                if ch.isLetter { cjk.append(ch) } else { flushCJK() }
            }
        }
        if word.count >= 2 { out.append(word) }; flushCJK()
        var seen = Set<String>()
        return out.filter { !stop.contains($0) && !genericTerms.contains($0) && seen.insert($0).inserted }
    }

    public struct Retrieval {
        public var evidence: [Evidence]
        public var matched: Bool       // false: the question named something and nothing stored mentions it (the evidence is only what was carried over)
    }

    public func askContext(question: String, watchID: Int64?, range: TimeRange?, previous: [Evidence], now: Date = Date(), maxNew: Int = 10) throws -> [Evidence] {
        try retrieve(question: question, extraTerms: [], watchID: watchID, range: range, previous: previous, now: now, maxNew: maxNew).evidence
    }

    // MARK: query expansion (the stored content is mostly English, the questions are often Chinese)

    /// Only worth a model call when the question has CJK text and so cannot match English titles directly.
    public static func needsExpansion(_ q: String) -> Bool { !isAboutRadar(q) && q.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    public static func expandMessages(_ q: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: "你把用户的问题改写成用于检索英文科技资讯标题的关键词。输出 6 到 12 个英文关键词或短语（含常见同义词和产品名），用英文逗号分隔，只输出关键词，不要解释。例如问题“OpenAI 额度有什么变化”输出：openai, usage limit, quota, pricing, credits, plan, codex, chatgpt"),
         ChatMessage(role: "user", content: q)]
    }

    /// Words a model adds for coverage that match almost any tech headline; they would make "nothing found" impossible.
    static let genericTerms: Set<String> = ["development", "progress", "latest news", "news", "update", "updates", "research", "research update", "breakthroughs", "breakthrough", "policy change", "api update", "policy", "technology", "tech", "ai", "software", "open source", "open-source", "tools", "tool", "release", "new", "announcement", "model", "models"]

    /// Model output -> search terms. Defensive: models add numbering, quotes or a lead-in sentence.
    public static func parseTerms(_ raw: String) -> [String] {
        let line = raw.split(separator: "\n").map(String.init).max { a, b in a.filter { ",，".contains($0) }.count < b.filter { ",，".contains($0) }.count } ?? raw   // the list line, not a lead-in sentence
        var seen = Set<String>()
        return line.split(whereSeparator: { ",，;；\n".contains($0) }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”`*-•0123456789.、)）(（")).lowercased()
        }.filter { $0.count >= 2 && $0.count <= 40 && !stop.contains($0) && seen.insert($0).inserted }.prefix(14).map { $0 }
    }

    // MARK: Radar's own state ("which sources fail?")

    static let statusMarkers = ["读取失败", "读不了", "读不到", "抓不到", "报错", "出错", "失败", "来源", "信息源", "关注了什么", "关注了哪些", "有哪些关注", "覆盖", "为什么没", "没提醒", "没有提醒", "漏", "健康", "状态", "还在工作", "正常吗"]
    public static func isAboutRadar(_ q: String) -> Bool { statusMarkers.contains { q.contains($0) } }

    func statusEvidence(_ db: Database, watchID: Int64?, now: Date) throws -> [Evidence] {
        let watches = try Watch.fetchAll(db).filter { watchID == nil || $0.id == watchID }
        var out: [Evidence] = []
        func item(_ title: String, _ text: String, url: String = "", date: Date? = nil) {
            out.append(Evidence(id: "", title: title, url: url, origin: "Radar 状态", date: date, text: text, meta: "", isEvent: false, kind: "status"))
        }
        var bad = 0, stale = 0, total = 0
        var lines: [String] = []
        for w in watches {
            let srcs = try Source.fetchAll(db, sql: "SELECT source.* FROM source JOIN watchSource ws ON ws.sourceID = source.id WHERE ws.watchID = ? ORDER BY source.name", arguments: [w.id!])
            total += srcs.count
            lines.append("关注“\(w.title)”（\(w.status == "active" ? "进行中" : "已暂停")）：\(srcs.count) 个来源")
            for s in srcs {
                let link = URL(string: s.endpoint)?.scheme?.hasPrefix("http") == true ? s.endpoint : ""
                if let e = s.lastError {
                    bad += 1
                    if out.count < 7 { item("来源读取失败：\(s.name)", "属于关注“\(w.title)”。最近一次读取失败：\(e)。上次成功：\(s.lastSuccessAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "从未成功")。", url: link, date: s.lastCheckedAt) }
                } else if s.initialized, let ok = s.lastSuccessAt, now.timeIntervalSince(ok) > s.intervalSeconds * 4 + 3600 {
                    stale += 1
                    if out.count < 7 { item("来源很久没有更新检查：\(s.name)", "属于关注“\(w.title)”。上次成功读取在 \(ok.formatted(date: .abbreviated, time: .shortened))，已超过检查间隔的 4 倍。", url: link, date: ok) }
                }
            }
        }
        let head = Evidence(id: "", title: "Radar 当前运行概况", url: "", origin: "Radar 状态", date: now,
                            text: "共 \(watches.count) 个关注、\(total) 个来源；读取失败 \(bad) 个，长期未更新 \(stale) 个。" + lines.prefix(12).joined(separator: "；"),
                            meta: "", isEvent: false, kind: "status")
        return [head] + out
    }

    /// Lexical retrieval over what Radar already stored. `previous` keeps earlier numbering so follow-ups can refer to it.
    public func retrieve(question: String, extraTerms: [String], watchID: Int64?, range: TimeRange?, previous: [Evidence], now: Date = Date(), maxNew: Int = 10) throws -> Retrieval {
        let follow = !previous.isEmpty && Self.followMarkers.contains { question.contains($0) }
        var toks = Self.tokens(question)
        let named = !toks.isEmpty
        for t in extraTerms where !toks.contains(t) { toks.append(t) }
        let about = Self.isAboutRadar(question)
        let since = (range ?? Self.detectRange(question) ?? .all).since(now)
        return try store.db.read { db -> Retrieval in
            let titles = try watchTitles(db)
            var out = previous, seen = Set(previous.map { $0.url })
            func take(_ e: Evidence) { var e = e; e.id = "S\(out.count + 1)"; out.append(e); seen.insert(e.url) }
            func hits(_ hay: String) -> Int { let h = hay.lowercased(); return toks.reduce(0) { $0 + (h.contains($1) ? 1 : 0) } }
            if about && !previous.contains(where: { $0.kind == "status" }) { for e in try statusEvidence(db, watchID: watchID, now: now) { take(e) } }
            // recent events that match
            var evq = Event.order(Column("createdAt").desc)
            if let w = watchID { evq = evq.filter(Column("watchID") == w) }
            if let s = since { evq = evq.filter(Column("createdAt") >= s) }
            let evs = try evq.limit(200).fetchAll(db).map { ($0, try Entry.fetchOne(db, key: $0.entryID)) }
                .map { (e: ($0.0), en: $0.1, s: hits($0.0.title + " " + $0.0.reason + " " + ($0.1?.summary ?? ""))) }
                .filter { toks.isEmpty || $0.s > 0 }.prefix(follow ? 1 : max(3, maxNew / 3))
            for x in evs where !seen.contains(x.e.evidenceURL) { take(evidence(x.e, entry: x.en, watch: titles[x.e.watchID] ?? "", id: "")) }
            // matching entries, best first
            let candidates = try rows(db, watchID: watchID).filter { r in since.map { Self.date(r.entry) >= $0 } ?? true }
            let scored = candidates.map { r -> (Row, Double, Int) in
                let e = r.entry
                let lex = hits(e.title) * 3 + hits(e.summary) * 2 + hits(String(e.text.prefix(2000)))
                let age = max(0, now.timeIntervalSince(Self.date(e)) / 86400)
                return (r, Double(lex) + 0.6 * log10(1 + Double(Self.stars(e))) + max(0, 1 - age / 60), lex)
            }.sorted { $0.1 > $1.1 }
            // when anything matches the question, unrelated items are noise; with no match at all fall back to freshness
            let anyMatch = scored.contains { $0.2 > 0 }
            // a question that names something nothing mentions gets no filler: unrelated items only invite a made-up answer
            let eventHit = out.count > previous.count && out.contains { $0.isEvent }
            let matched = follow || about || anyMatch || eventHit || !named
            let ranked = scored.filter { !follow && !anyMatch && matched || $0.2 > 0 }
            var added = 0
            for (r, _, _) in ranked where added < (follow ? 3 : maxNew) && out.count < 18 {
                if seen.contains(r.entry.canonicalURL) { continue }
                take(evidence(r, id: "")); added += 1
            }
            return Retrieval(evidence: out, matched: matched)
        }
    }

    // MARK: prompts

    static let rules = """
        你是 Radar 的本地信息助手。只能依据下面“资料”作答，资料里没有的内容不要编造，也不要使用你自己的记忆补充项目或事实。\
        每条结论后面用 [S编号] 标注来源，只能使用资料中出现的编号，不要自己写链接。\
        资料分三类：“Radar 自身状态”描述 Radar 本身的运行情况（来源是否读取失败等），回答关于 Radar 的问题时使用；“事件”是 Radar 检测到的真实新变化；“已发现内容”是已采集的信息，包含首次采集建立的基线，不等于近期新增，不要把它们说成“新增”或“新发布”。\
        不要根据简短描述推断兼容性、性能或功能是否完整；资料没写的就说“资料中未说明”。\
        不要补充资料里没有的评价（例如文档是否完善、社区是否活跃、生态是否开放、是否适合某场景），需要判断时只说资料能支持的部分。\
        如果资料不足以回答，直接说明现有资料掌握了什么、缺什么。回答要简洁：通常不超过 8 条，每条一两句话，不要重复提问，不要附加统计信息。用中文回答，使用 Markdown。
        """

    static func block(_ evidence: [Evidence], budget: Int = 12000) -> String {
        let cap = max(120, min(500, budget / max(1, evidence.count) - 140))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return evidence.map { e in
            let head = [e.isEvent ? "事件·\(kindLabel[e.kind] ?? "更新")" : (e.kind == "status" ? "Radar 自身状态" : "已发现内容"), e.date.map { "时间 " + f.string(from: $0) }, "来源 " + e.origin,
                        e.meta.isEmpty ? nil : e.meta].compactMap { $0 }.joined(separator: " | ")
            return "[\(e.id)] (\(head))\n标题：\(e.title)\n内容：\(clip(e.text, cap))"
        }.joined(separator: "\n\n")
    }

    public static func summaryMessages(_ ctx: SummaryContext, range: TimeRange) -> [ChatMessage] {
        let stats = "统计：这段时间 Radar 检测到 \(ctx.events) 条真实事件；时间范围内已发现内容共 \(ctx.entries) 条，下面只给出其中 \(ctx.evidence.count - ctx.events) 条。"
        let ask = """
            请为「\(ctx.scopeTitle)」生成“\(range.label)”的简报，按这个结构：
            ## 总览（2–3 句）
            ## 新发生的变化（只依据“事件”；没有事件就明确写“这段时间没有检测到新事件”）
            ## 值得关注的内容（最多 8 条，合并重复，每条一句说明为什么值得关注）
            ## 值得继续了解（最多 4 条，只列资料里能看到的线索）
            \(stats)
            """
        return [ChatMessage(role: "system", content: rules + "\n\n资料：\n" + block(ctx.evidence)), ChatMessage(role: "user", content: ask)]
    }

    public static func askMessages(history: [ChatMessage], question: String, evidence: [Evidence], scope: String) -> [ChatMessage] {
        let sys = rules + "\n当前检索范围：\(scope)。\n\n资料：\n" + (evidence.isEmpty ? "（没有检索到相关资料）" : block(evidence))
        return [ChatMessage(role: "system", content: sys)] + history.suffix(8) + [ChatMessage(role: "user", content: question)]
    }

    // MARK: citations

    /// Turns [S1] / [S1, S2] into markdown links whose URLs come from the database; unknown numbers stay plain text.
    public static func linkCitations(_ text: String, _ evidence: [Evidence]) -> String {
        let byID = Dictionary(evidence.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        guard let group = try? NSRegularExpression(pattern: #"[\[【]\s*((?:S\d+[\s,，、;；]*)+)[\]】]"#) else { return text }
        var out = text
        for m in group.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: out), let inner = Range(m.range(at: 1), in: out) else { continue }
            let ids = out[inner].split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            let links = ids.map { id in byID[id].flatMap { URL(string: $0) != nil ? "[\(id)](\($0))" : nil } ?? "\(id)" }
            out.replaceSubrange(whole, with: links.joined(separator: "、"))
        }
        return out.replacingOccurrences(of: #"\)\s*\[S(\d+)\]\("#, with: ")、[S$1](", options: .regularExpression)   // [S1][S6] written as separate brackets
    }

    public static func cited(_ text: String, _ evidence: [Evidence]) -> [Evidence] {
        guard let re = try? NSRegularExpression(pattern: #"S(\d+)"#) else { return [] }
        let ids = Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { "S" + String(text[$0].dropFirst()) } })
        return evidence.filter { ids.contains($0.id) }
    }
}

extension RadarAssistant: @unchecked Sendable {}
