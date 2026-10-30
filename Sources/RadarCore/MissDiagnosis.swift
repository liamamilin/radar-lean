import Foundation
import GRDB

/// "Why didn't Radar tell me about this?" Given a link the user saw elsewhere, reads the stored records of one watch and says which
/// step the link did not pass. Read-only. It reports what the records show; where they cannot show the past, it says so.
public struct MissDiagnosis {
    public enum Action {
        case addSource(SourceSpec)       // a verified official channel that would cover the link
        case linkSource(SourceSpec)      // another watch already reads it; this one does not
        case addInclude(String)          // a keyword from the item's title
        case enableNotify
        case resume
    }
    public struct Finding {
        public var ok: Bool
        public var text: String
        public var action: (label: String, action: Action)?
    }
    public var findings: [Finding] = []

    public static func diagnose(url: String, watchID: Int64, store: Store, fetcher: Fetcher, now: Date = Date()) async -> MissDiagnosis {
        var d = MissDiagnosis()
        func add(_ ok: Bool, _ t: String, _ a: (String, Action)? = nil) { d.findings.append(Finding(ok: ok, text: t, action: a.map { (label: $0.0, action: $0.1) })) }
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host?.lowercased() else {
            add(false, "这不是一个有效的网址"); return d
        }
        let key = mergeKey(u.absoluteString)
        struct Facts {
            var watch: Watch?
            var linked: [(Source, Bool)] = []          // source, baselineReady
            var entries: [(Entry, Source)] = []        // every stored entry with this link, from any source
            var events: [Event] = []
            var counts: [Int64: Int] = [:]
            var firstSeen: [Int64: Date] = [:]
        }
        let facts: Facts = (try? await store.db.read { db in
            var f = Facts()
            f.watch = try Watch.fetchOne(db, key: watchID)
            let links = try WatchSource.filter(Column("watchID") == watchID).fetchAll(db)
            for l in links { if let s = try Source.fetchOne(db, key: l.sourceID) { f.linked.append((s, l.baselineReady)) } }
            let sources = try Source.fetchAll(db)
            for s in sources {
                f.counts[s.id!] = try Entry.filter(Column("sourceID") == s.id!).fetchCount(db)
                f.firstSeen[s.id!] = try Date.fetchOne(db, sql: "SELECT MIN(firstSeenAt) FROM entry WHERE sourceID = ?", arguments: [s.id!])
                // the whole table, not the few entries a screen shows
                for e in try Entry.filter(Column("sourceID") == s.id!).fetchAll(db) where mergeKey(e.canonicalURL) == key { f.entries.append((e, s)) }
            }
            f.events = try Event.filter(Column("watchID") == watchID && Column("mergeKey") == key).fetchAll(db)
            return f
        }) ?? Facts()
        guard let watch = facts.watch else { add(false, "找不到这个关注事项"); return d }
        let plan = watch.plan
        let linkedIDs = Set(facts.linked.map { $0.0.id! })
        let official = OfficialCatalog.entities(in: watch.title + " " + watch.originalText)

        func conditionText() -> String {
            (plan.include.isEmpty ? "没有设置关注词" : "关注词：\(plan.include.joined(separator: "、"))") + (plan.exclude.isEmpty ? "" : "；排除词：\(plan.exclude.joined(separator: "、"))")
        }
        func keywordWhy(_ e: Entry) -> String {
            let hay = e.title + " " + e.summary + " " + e.text
            if let hit = plan.exclude.first(where: { Keywords.matches(hay, any: [$0]) }) { return "内容命中了排除词“\(hit)”" }
            if !plan.include.isEmpty && !Keywords.matches(hay, any: plan.include) { return "标题和摘要没有命中任何关注词（\(conditionText())）" }
            return ""
        }
        func titleWords(_ t: String) -> [String] {
            let skip: Set<String> = ["with", "that", "this", "from", "your", "have", "will", "into", "more", "about", "their", "what", "when"]
            return t.split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 4 && $0.allSatisfy(\.isASCII) && !skip.contains($0.lowercased()) }.prefix(2).map { $0 }
        }

        // 1. an event exists for this link
        if let ev = facts.events.first {
            add(true, "Radar 为这个链接产生过事件（\(ev.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Engine.kindName(ev.kind))）：\(ev.reason)")
            if !watch.isActive { add(false, "这个关注事项当时/现在是暂停状态，暂停期间不会提醒。", ("恢复关注", .resume)) }
            else if !plan.notify { add(false, "这个关注事项的系统通知是关闭的，事件只会出现在列表里。", ("打开通知", .enableNotify)) }
            else if !Engine.shouldNotify(plan: plan, kind: ev.kind) { add(false, "事件类型是“\(Engine.kindName(ev.kind))”，主题类关注只会通知“新项目”和“重大更新”，所以它只出现在列表里、没有弹通知。") }
            else { add(true, "按它的类型应当发出过系统通知。Radar 没有保存通知的发送记录，是否显示还取决于系统通知权限和专注模式，这一点无法从记录里确认。") }
            return d
        }

        // 2. stored, but no event
        if let (entry, src) = facts.entries.first(where: { linkedIDs.contains($0.1.id!) }) ?? facts.entries.first {
            add(true, "Radar 读到过它（\(entry.firstSeenAt.formatted(date: .abbreviated, time: .shortened)) · 来源“\(src.name)”）：\(entry.title)")
            if !linkedIDs.contains(src.id!) {
                add(false, "但这个来源只被其他关注事项使用，没有关联到本关注。", ("关联到本关注", .linkSource(SourceSpec(kind: src.kind, endpoint: src.endpoint, name: src.name, selector: src.selector, interval: src.intervalSeconds))))
                return d
            }
            let baseline = !(facts.linked.first { $0.0.id == src.id }?.1 ?? true) || (facts.firstSeen[src.id!].map { entry.firstSeenAt.timeIntervalSince($0) < 120 } ?? false)
            if baseline {
                add(false, "它是这个来源第一次读取时就存在的内容。首次读取只建立基线、不产生事件，这是设计如此；之后新出现的内容才会提醒。")
                return d
            }
            let isOfficial = official.first { $0.channels.contains { $0.spec.uniqueKey == src.uniqueKey } }?.aliases
            if let j = Engine.evaluate(plan: plan, kind: src.kind, entry: entry, change: .new, official: isOfficial) {
                add(false, "按现在的规则它会被判为“\(Engine.kindName(j.kind))”（\(j.reason)），但库里没有对应事件。当时的规则或来源关联可能不同，已有记录无法确定原因。")
            } else {
                let why = keywordWhy(entry)
                add(false, "被当前条件过滤掉了：" + (why.isEmpty ? "来源类型的规则认为它不是新增内容（\(src.kind.label)）" : why) + "。",
                    why.contains("没有命中") ? titleWords(entry.title).first.map { ("把“\($0)”加入关注词", .addInclude($0)) } : nil)
            }
            return d
        }
        add(false, "Radar 没有读到过这个链接（已检查本关注所有来源的全部 \(facts.linked.reduce(0) { $0 + (facts.counts[$1.0.id!] ?? 0) }) 条记录）")

        // 3. never stored: coverage
        func bare(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let sameSite = facts.linked.map { $0.0 }.filter { s in
            guard s.kind != .githubSearch, s.kind != .hackerNews, let h = URL(string: s.endpoint)?.host?.lowercased() else { return false }
            return bare(h) == bare(host) || bare(h).hasSuffix("." + bare(host)) || bare(host).hasSuffix("." + bare(h))
        }
        if sameSite.isEmpty {
            add(false, "没有任何来源覆盖 \(host)——这是来源缺口，不是规则问题。")
            let channel = OfficialCatalog.entities.flatMap { $0.channels }.first { c in
                guard let h = URL(string: c.spec.endpoint)?.host?.lowercased() else { return false }
                return bare(h) == bare(host) && c.auto
            }
            if let c = channel, !facts.linked.contains(where: { $0.0.uniqueKey == c.spec.uniqueKey }) {
                add(false, "官方目录里有已验证的渠道：\(c.spec.name)。", ("添加“\(c.spec.name)”", .addSource(c.spec)))
            }
        } else {
            for s in sameSite {
                if s.kind == .web { add(true, "“\(s.name)”是整页变化监测，只比较整页内容，不收录单篇链接；链接指向的内容如果在那一页里，变化会产生“页面变化”事件。"); continue }
                if let e = s.lastError { add(false, "来源“\(s.name)”最近一次读取失败：\(e)") }
                else if !s.initialized { add(false, "来源“\(s.name)”还没完成首次读取") }
                else { add(true, "来源“\(s.name)”读取正常（上次成功 \(s.lastSuccessAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")，共 \(facts.counts[s.id!] ?? 0) 条记录），但里面没有这个链接——它可能在该来源的列表之外（别的栏目或二级页面），或还没出现在列表里。") }
            }
        }

        // 4. can Radar read the page, and would it have passed the conditions?
        do {
            let r = try await fetcher.fetch(SourceSpec(kind: .web, endpoint: u.absoluteString, name: "diagnose"))
            if let fe = r.entries.first {
                add(true, "页面本身能读到：\(fe.title)")
                let probe = Entry(id: nil, sourceID: 0, externalKey: "", canonicalURL: fe.url, title: fe.title, summary: String(fe.text.prefix(300)), text: "", contentHash: "", firstSeenAt: now, publishedAt: nil, meta: [:])
                if let j = Engine.evaluate(plan: plan, kind: .rss, entry: probe, change: .new) {
                    add(true, "如果它出现在被覆盖的来源里，按现在的条件会判为“\(Engine.kindName(j.kind))”（\(j.reason)）。")
                } else if !keywordWhy(probe).isEmpty {
                    add(false, "即使来源覆盖了它，也会被过滤：\(keywordWhy(probe))。", titleWords(fe.title).first.map { ("把“\($0)”加入关注词", .addInclude($0)) })
                }
            } else { add(true, "页面本身能读到") }
        } catch {
            add(false, "Radar 读不到这个页面：\(error.localizedDescription)。需要 JavaScript 的页面可以用 js: 选择器；被拦截的页面 Radar 不会绕过。")
        }
        return d
    }
}

extension Engine {
    public static func kindName(_ k: String) -> String { ["newProject": "新项目", "majorUpdate": "重大更新", "pageChange": "页面变化", "update": "普通更新"][k] ?? k }
}
