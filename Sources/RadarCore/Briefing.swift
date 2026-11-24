import Foundation
import GRDB

/// One watch's part of a day's briefing. `generatedAt == nil` means it was never generated; generated with empty
/// `evidence` means the watch had nothing new in the window.
public struct BriefingSection: Codable, Hashable, Identifiable {
    public var watchID: Int64
    public var title: String
    public var text: String
    public var evidence: [Evidence]
    public var events: Int
    public var entries: Int
    public var generatedAt: Date? = nil
    public var id: Int64 { watchID }
    public var isEmpty: Bool { evidence.isEmpty }
    public var isGenerated: Bool { generatedAt != nil }
    public init(watchID: Int64, title: String, text: String, evidence: [Evidence], events: Int, entries: Int, generatedAt: Date? = nil) {
        self.watchID = watchID; self.title = title; self.text = text; self.evidence = evidence; self.events = events; self.entries = entries; self.generatedAt = generatedAt
    }
}

/// The report for one day: an overview across watches, then one section per watch. Sections are generated
/// independently, so a single watch can be (re)done without touching the others.
public struct Briefing: Codable, Hashable, Identifiable {
    public var day: String            // yyyy-MM-dd
    public var createdAt: Date
    public var model: String          // the model that wrote the most recent part
    public var auto: Bool             // the schedule wrote it (rather than a click)
    public var overview: String
    public var overviewAt: Date? = nil
    public var sections: [BriefingSection]
    public var id: String { day }
    public init(day: String, createdAt: Date, model: String, auto: Bool, overview: String, overviewAt: Date? = nil, sections: [BriefingSection]) {
        self.day = day; self.createdAt = createdAt; self.model = model; self.auto = auto; self.overview = overview; self.overviewAt = overviewAt; self.sections = sections
    }

    public var updateCount: Int { sections.reduce(0) { $0 + $1.evidence.count } }
    public var activeSections: [BriefingSection] { sections.filter { !$0.isEmpty } }
    public func section(_ watchID: Int64) -> BriefingSection? { sections.first { $0.watchID == watchID } }
    public var hasOverview: Bool { overviewAt != nil }
    /// Some section was written after the overview, so the overview no longer reflects it.
    public var overviewIsStale: Bool {
        guard let o = overviewAt else { return false }
        return sections.contains { ($0.generatedAt ?? .distantPast) > o }
    }

    /// Replaces the section of the same watch (keeping its place) or appends it.
    public mutating func put(_ s: BriefingSection) {
        if let i = sections.firstIndex(where: { $0.watchID == s.watchID }) { sections[i] = s } else { sections.append(s) }
    }
}

/// Builds and stores briefings. Only organises what Radar already collected; it never searches.
public final class Briefer {
    let store: Store
    let assistant: RadarAssistant
    public init(store: Store) { self.store = store; assistant = RadarAssistant(store: store) }

    public static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: storage — one briefing per day (the newest row for a day wins; older rows from before this rule are ignored)

    /// One per day, newest day first.
    public func days() throws -> [Briefing] {
        try store.db.read { db in
            var seen = Set<String>()
            return try Row.fetchAll(db, sql: "SELECT json FROM briefing ORDER BY day DESC, createdAt DESC, id DESC LIMIT 400").compactMap { r in
                guard let d: Data = r["json"], let b = try? Self.decoder.decode(Briefing.self, from: d), seen.insert(b.day).inserted else { return nil }
                return Self.upgraded(b)
            }
        }
    }
    /// Reads the saved briefings straight from the database file without migrating, writing or moving anything — for tools running beside the app.
    public static func readOnlyDays(path: String) throws -> [Briefing] {
        var cfg = Configuration()
        cfg.readonly = true
        cfg.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: cfg)
        return try pool.read { db in
            var seen = Set<String>()
            return try Row.fetchAll(db, sql: "SELECT json FROM briefing ORDER BY day DESC, createdAt DESC, id DESC LIMIT 400").compactMap { r in
                guard let d: Data = r["json"], let b = try? decoder.decode(Briefing.self, from: d), seen.insert(b.day).inserted else { return nil }
                return upgraded(b)
            }
        }
    }

    public func briefing(day: String) -> Briefing? { (try? days())?.first { $0.day == day } }
    public func has(day: String) -> Bool { briefing(day: day) != nil }

    /// Inserts the day's briefing, or replaces it in place.
    public func save(_ b: Briefing) throws {
        let data = try Self.encoder.encode(b)
        try store.db.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM briefing WHERE day = ? ORDER BY createdAt DESC, id DESC LIMIT 1", arguments: [b.day]) {
                try db.execute(sql: "UPDATE briefing SET json = ?, createdAt = ? WHERE id = ?", arguments: [data, b.createdAt, id])
            } else {
                try db.execute(sql: "INSERT INTO briefing (day, createdAt, json) VALUES (?, ?, ?)", arguments: [b.day, b.createdAt, data])
            }
        }
    }
    /// Briefings saved before sections and the overview carried their own times: everything in them was written when they were.
    static func upgraded(_ b: Briefing) -> Briefing {
        var b = b
        if b.overviewAt == nil, !b.overview.isEmpty { b.overviewAt = b.createdAt }
        for i in b.sections.indices where b.sections[i].generatedAt == nil && (b.overviewAt != nil || !b.sections[i].isEmpty) { b.sections[i].generatedAt = b.createdAt }
        return b
    }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// The watches that get a section, in the order they were created.
    public func watches() throws -> [Watch] {
        try store.db.read { try Watch.filter(Column("status") == "active").order(Column("id")).fetchAll($0) }
    }

    // MARK: generation

    /// One watch's section: a single model call, or none at all when it had nothing new.
    public func makeSection(watch w: Watch, client: ChatClient, model: OllamaModel, now: Date = Date(), range: TimeRange = .day) async throws -> BriefingSection {
        let a = assistant, wid = w.id!
        let ctx = try await Task.detached { try a.summaryContext(watchID: wid, range: range, now: now) }.value
        guard !ctx.evidence.isEmpty else { return BriefingSection(watchID: wid, title: w.title, text: "", evidence: [], events: 0, entries: 0, generatedAt: now) }
        var text = ""
        for try await piece in client.chat(model: model, messages: Self.sectionMessages(ctx, title: w.title, range: range)) { text += piece }
        return BriefingSection(watchID: wid, title: w.title, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               evidence: ctx.evidence, events: ctx.events, entries: ctx.entries, generatedAt: now)
    }

    /// The overview across the sections that have content; no model call when there are none.
    public func makeOverview(_ sections: [BriefingSection], client: ChatClient, model: OllamaModel, range: TimeRange = .day) async throws -> String {
        let active = sections.filter { !$0.isEmpty }
        guard !active.isEmpty else { return "\(range.label)内，所有关注事项都没有新内容。" }
        var raw = ""
        for try await piece in client.chat(model: model, messages: Self.overviewMessages(active, range: range)) { raw += piece }
        return Self.cleanOverview(raw)
    }

    /// Every watch, then the overview. Used by the tests and for a plain "do everything"; the app saves between steps instead.
    public func generate(client: ChatClient, model: OllamaModel, now: Date = Date(), auto: Bool, range: TimeRange = .day,
                         progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Briefing {
        let ws = try watches()
        var b = Briefing(day: Self.dayKey(now), createdAt: now, model: model.name, auto: auto, overview: "", sections: [])
        for (i, w) in ws.enumerated() {
            try Task.checkCancellation()
            progress("正在整理 \(i + 1)/\(ws.count)：\(w.title)")
            b.put(try await makeSection(watch: w, client: client, model: model, now: now, range: range))
        }
        try Task.checkCancellation()
        progress("正在写总览")
        b.overview = try await makeOverview(b.sections, client: client, model: model, range: range); b.overviewAt = now
        return b
    }

    // MARK: prompts

    public static func sectionMessages(_ ctx: SummaryContext, title: String, range: TimeRange) -> [ChatMessage] {
        let stats = "统计：这段时间 Radar 检测到 \(ctx.events) 条真实事件；时间范围内已发现内容共 \(ctx.entries) 条，下面给出其中 \(ctx.evidence.count - ctx.events) 条。"
        let ask = """
            请整理「\(title)」在“\(range.label)”内的更新。只做梳理，不做评价、预测或建议：
            1. 第一行用一句话概括（不超过 40 字）。
            2. 然后按重要程度列出要点，最多 8 条，每条一行，格式：- **名称或标题**：发生了什么（一句话）[S编号]
            3. 合并重复内容；“事件”优先于“已发现内容”；资料没写的细节不要补。
            4. 不要写标题行（如“总览”“简报”），直接从概括开始。
            \(stats)
            """
        return [ChatMessage(role: "system", content: RadarAssistant.rules + "\n\n资料：\n" + RadarAssistant.block(ctx.evidence)), ChatMessage(role: "user", content: ask)]
    }

    public static func overviewMessages(_ sections: [BriefingSection], range: TimeRange) -> [ChatMessage] {
        let body = sections.map { "### \($0.title)（\($0.events) 条事件，\($0.entries) 条内容）\n" + RadarAssistant.clip($0.text, 1500) }.joined(separator: "\n\n")
        let sys = "你是 Radar 的简报编辑。下面是各个关注类在“\(range.label)”内的更新整理。只依据这些内容写总览，不要编造，不要使用其中没有的信息，不要写 [S编号] 之类的引用。用中文，使用 Markdown。\n\n" + body
        let ask = "请写今天的总览：第一行一句话说明整体情况（哪些关注类有动静、哪些没有）；然后用 3 到 6 条列出跨关注类最值得看的变化，每条一句话，以【关注类名称】开头。没有重要变化就直说，不要凑数。不要写标题行（如“总览”）。"
        return [ChatMessage(role: "system", content: sys), ChatMessage(role: "user", content: ask)]
    }

    static func stripCitations(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[\[【]\s*S\d+(?:[\s,，、;；]*S\d+)*\s*[\]】]"#, with: "", options: .regularExpression)
    }

    /// Citations out, and the "总览" heading some models write on their own (the page already has one) dropped.
    static func cleanOverview(_ s: String) -> String {
        var lines = stripCitations(s).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: CharacterSet(charactersIn: "#*：: \t")) == "总览" { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
