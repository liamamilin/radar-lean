import Foundation
import GRDB
import os

public struct CheckOutcome {
    public var newEntries = 0
    public var events: [Event] = []
    public var notModified = false
    public var error: String?
    public var alreadyRunning = false   // another check of this source was in progress; nothing was fetched
}

public final class Engine {
    public let store: Store
    public let fetcher: Fetcher
    let log = Logger(subsystem: "app.radar", category: "engine")

    public init(store: Store, fetcher: Fetcher) { self.store = store; self.fetcher = fetcher }

    /// Sources being read right now: a second request for the same source (timer tick, wake-up, a click) joins nothing and fetches nothing.
    private let lock = NSLock()
    private var inFlight = Set<Int64>()
    public var onChecking: (@Sendable (Int64, Bool) -> Void)?   // UI hook: a source started / finished being read
    public func isChecking(_ id: Int64) -> Bool { lock.withLock { inFlight.contains(id) } }

    enum Change { case new, changed(before: String), metrics(previous: [String: String]) }

    /// Fetch a source once and serve every linked watch from the result.
    @discardableResult
    public func check(sourceID: Int64) async -> CheckOutcome {
        guard lock.withLock({ inFlight.insert(sourceID).inserted }) else { return CheckOutcome(alreadyRunning: true) }
        onChecking?(sourceID, true)
        defer { lock.withLock { _ = inFlight.remove(sourceID) }; onChecking?(sourceID, false) }
        guard let src = try? await store.db.read({ try Source.fetchOne($0, key: sourceID) }) else { return CheckOutcome(error: "来源不存在") }
        let spec = SourceSpec(kind: src.kind, endpoint: src.endpoint, name: src.name, selector: src.selector, interval: src.intervalSeconds)
        do {
            let result = try await fetcher.fetch(spec, etag: src.initialized ? src.etag : nil, lastModified: src.initialized ? src.lastModified : nil)
            if result.notModified && src.initialized {
                try await store.db.write { db in
                    var s = try Source.fetchOne(db, key: sourceID)!
                    s.lastCheckedAt = Date(); s.lastSuccessAt = Date(); s.lastError = nil
                    s.nextDueAt = Date().addingTimeInterval(s.intervalSeconds)
                    try s.update(db)
                }
                return CheckOutcome(notModified: true)
            }
            let (events, added) = try await store.db.write { db in try self.apply(result, sourceID: sourceID, db: db) }
            return CheckOutcome(newEntries: added, events: events)
        } catch {
            let msg = error.localizedDescription
            let urlErr = (error as? URLError).map { "网络错误：\($0.localizedDescription)" }
            log.error("check failed \(src.uniqueKey): \(msg)")
            var due = Date().addingTimeInterval(min(src.intervalSeconds, 30 * 60))
            if case RadarError.rateLimited(let until) = error { due = until }
            try? await store.db.write { db in
                var s = try Source.fetchOne(db, key: sourceID)!
                s.lastCheckedAt = Date(); s.lastError = urlErr ?? msg; s.nextDueAt = due
                try s.update(db)
            }
            return CheckOutcome(error: urlErr ?? msg)
        }
    }

    func apply(_ result: FetchResult, sourceID: Int64, db: Database) throws -> ([Event], Int) {
        var src = try Source.fetchOne(db, key: sourceID)!
        let wasInitialized = src.initialized
        var changes: [(Entry, Change)] = []
        var prevVersion: Version?
        if src.kind == .githubReleases {
            let seen = try Entry.filter(Column("sourceID") == sourceID).fetchAll(db)
            prevVersion = seen.filter { $0.meta["prerelease"] != "1" && $0.meta["draft"] != "1" }.compactMap { Version($0.meta["tag"] ?? $0.title) }.max()
        }
        for fe in result.entries {
            if var e = try Entry.filter(Column("sourceID") == sourceID && Column("externalKey") == fe.externalKey).fetchOne(db) {
                let h = fe.contentHash
                if src.kind == .web && e.contentHash != h {
                    let before = e.text
                    e.contentHash = h; e.text = fe.text; e.summary = fe.summary; e.title = fe.title
                    try e.update(db)
                    changes.append((e, .changed(before: before)))
                } else if src.kind == .githubSearch {
                    // an already-known project: keep its stars/forks current, and let rules see the move
                    let prev = e.meta
                    e.meta = fe.meta; e.summary = fe.summary; e.title = fe.title
                    try e.update(db)
                    if prev["stars"] != fe.meta["stars"] { changes.append((e, .metrics(previous: prev))) }
                }
            } else {
                var e = Entry(id: nil, sourceID: sourceID, externalKey: fe.externalKey, canonicalURL: fe.url, title: fe.title,
                              summary: fe.summary, text: fe.text, contentHash: fe.contentHash, firstSeenAt: Date(),
                              publishedAt: fe.publishedAt, meta: fe.meta)
                try e.insert(db)
                changes.append((e, .new))
            }
        }
        var events: [Event] = []
        if !wasInitialized {
            src.initialized = true
            try db.execute(sql: "UPDATE watchSource SET baselineReady = 1 WHERE sourceID = ?", arguments: [sourceID])
        } else {
            let links = try WatchSource.filter(Column("sourceID") == sourceID && Column("baselineReady") == true).fetchAll(db)
            for link in links {
                guard let w = try Watch.fetchOne(db, key: link.watchID), w.isActive else { continue }
                for (entry, change) in changes {
                    guard let j = Self.evaluate(plan: w.plan, kind: src.kind, entry: entry, change: change, previous: prevVersion) else { continue }
                    let type: String
                    switch change { case .new: type = "new"; case .changed: type = "changed"; case .metrics: type = "metrics" }
                    var mk = mergeKey(entry.canonicalURL)
                    if type == "changed" { mk += "#" + entry.contentHash }
                    let rk = Self.repoKey(entry, kind: src.kind, endpoint: src.endpoint)
                    let facet = Self.facet(kind: src.kind, entry: entry, judged: j, mergeKey: mk)
                    let ref = EvidenceRef(name: src.name, url: entry.canonicalURL)
                    // Already reported for this watch? Same link: yes. Same GitHub project AND same happening (discovery, one specific
                    // release): yes, another source covering it. A different release or a new feature of that project is its own event,
                    // as is another version of a page. Or the same title from another source within 3 days.
                    let wid = w.id!
                    var old = try Event.filter(Column("watchID") == wid && Column("mergeKey") == mk).fetchOne(db)
                    if old == nil && !rk.isEmpty && (facet == "discover" || facet.hasPrefix("release:")) {
                        old = try Event.filter(Column("watchID") == wid && Column("repoKey") == rk && Column("facet") == facet
                                               && Column("createdAt") > Date().addingTimeInterval(-7 * 86400)).fetchOne(db)
                    }
                    if old == nil && type == "new" && entry.title.count >= 15 {
                        old = try Event.filter(Column("watchID") == wid && Column("title") == entry.title && Column("kind") != "pageChange"
                                               && Column("createdAt") > Date().addingTimeInterval(-3 * 86400)).fetchAll(db)
                            .first { !$0.evidence.contains { $0.name == src.name } }
                    }
                    if var old {
                        var ev = old.evidence
                        if !ev.contains(ref) { ev.append(ref); old.evidence = ev }
                        // an ordinary article that turns out to be about a new project / major update: promote it, and alert once
                        let promoted = Self.rank(j.kind) > Self.rank(old.kind)
                        let alertNow = promoted && Self.shouldNotify(plan: w.plan, kind: j.kind) && !Self.shouldNotify(plan: w.plan, kind: old.kind)
                        if promoted { old.kind = j.kind; old.reason = j.reason }
                        try old.update(db)
                        if alertNow { events.append(old) }
                        continue
                    }
                    var ev = Event(id: nil, watchID: w.id!, entryID: entry.id!, dedupeKey: sha256("\(w.id!)|\(mk)|\(type)"), title: entry.title, reason: j.reason,
                                   evidenceURL: entry.canonicalURL, beforeSnippet: j.before, afterSnippet: j.after, createdAt: Date(), readAt: nil,
                                   kind: j.kind, mergeKey: mk, repoKey: rk, facet: facet)
                    ev.evidence = [ref]
                    try ev.insert(db)
                    events.append(ev)
                }
            }
        }
        src.lastCheckedAt = Date(); src.lastSuccessAt = Date(); src.lastError = nil
        src.nextDueAt = Date().addingTimeInterval(src.intervalSeconds)
        if let e = result.etag { src.etag = e }; if let m = result.lastModified { src.lastModified = m }
        try src.update(db)
        return (events, changes.filter { if case .new = $0.1 { return true }; return false }.count)
    }

    struct Judged { var reason: String; var kind: String; var before: String? = nil; var after: String? = nil }

    /// Topic watches interrupt only for new projects and major updates; everything else waits in the list.
    public static func shouldNotify(plan: WatchPlan, kind: String) -> Bool {
        plan.notify && (plan.type != .topic || kind == "newProject" || kind == "majorUpdate")
    }

    static let ghReserved: Set<String> = ["topics", "orgs", "sponsors", "features", "marketplace", "about", "login", "settings", "collections", "explore", "trending", "apps", "enterprise", "pricing", "readme"]
    /// The GitHub project an entry is (a repo page) or links to (first repo URL in its text).
    static func repoKey(_ e: Entry, kind: SourceKind, endpoint: String) -> String {
        if kind == .githubReleases { return "gh:" + endpoint.lowercased() }
        let k = mergeKey(e.canonicalURL)
        if k.hasPrefix("gh:") { return k }
        guard kind == .rss || kind == .list else { return "" }
        let hay = String((e.summary + " " + e.text).prefix(3000))   // not the URL itself: a release page must not collapse into its repo
        guard let r = hay.range(of: #"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"#, options: .regularExpression) else { return "" }
        let parts = hay[r].dropFirst("github.com/".count).split(separator: "/")
        guard parts.count == 2, !ghReserved.contains(parts[0].lowercased()) else { return "" }
        var repo = String(parts[1]); while repo.hasSuffix(".") { repo.removeLast() }; if repo.hasSuffix(".git") { repo.removeLast(4) }
        return "gh:" + (parts[0] + "/" + repo).lowercased()
    }

    /// What happened, as opposed to which project it happened to.
    static func facet(kind: SourceKind, entry: Entry, judged j: Judged, mergeKey mk: String) -> String {
        func ver(_ t: String) -> String? {
            guard let r = t.range(of: #"\bv?\d+\.\d+(\.\d+)?(-[A-Za-z0-9.]+)?"#, options: .regularExpression), let v = Version(String(t[r])) else { return nil }
            return v.nums.map(String.init).joined(separator: ".") + (v.pre.map { "-" + $0 } ?? "")
        }
        switch kind {
        case .githubSearch: return "discover"
        case .githubReleases: return "release:" + (ver(entry.meta["tag"] ?? entry.title) ?? entry.title.lowercased())
        case .web: return "page"
        case .rss, .list:
            if j.kind == "majorUpdate", let v = ver(entry.title) { return "release:" + v }   // "Announcing v1.0" covers the v1.0 release
            return j.kind == "update" ? "discover" : "article:" + mk                         // an ordinary post about a project is coverage of its discovery
        }
    }

    static func rank(_ kind: String) -> Int { ["update": 0, "pageChange": 1, "majorUpdate": 2, "newProject": 3][kind] ?? 0 }

    static let aiHints = ["ai", "llm", "llms", "gpt", "model", "models", "inference", "agent", "agents", "mcp", "claude", "codex", "qwen", "deepseek", "ollama", "gpu",
                          "模型", "大模型", "智能体", "人工智能"]
    static let majorWords = ["release", "released", "launch", "introducing", "announcing", "announce", "open source", "open-source", "v1", "1.0", "2.0",
                             "发布", "上线", "重磅", "全新", "正式版", "major"]

    /// Is a freshly discovered GitHub repo worth an alert? Young repos need fewer stars; the threshold is the plan's (default 50).
    static func worthAlert(stars: Int, ageDays: Double, minStars: Int?) -> Bool {
        let need = minStars ?? 50
        return ageDays <= 14 ? stars >= max(10, need / 5) : stars >= need
    }

    static func evaluate(plan: WatchPlan, kind: SourceKind, entry: Entry, change: Change, previous: Version? = nil) -> Judged? {
        let hay = entry.title + " " + entry.summary + " " + (kind == .web ? "" : entry.text)
        func relevant(_ text: String) -> Bool {
            (plan.exclude.isEmpty || !Keywords.matches(text, any: plan.exclude)) && (plan.include.isEmpty || Keywords.matches(text, any: plan.include))
        }
        switch kind {
        case .githubReleases:
            if entry.meta["draft"] == "1" { return nil }
            if plan.stableOnly && entry.meta["prerelease"] == "1" { return nil }
            let tag = entry.meta["tag"] ?? entry.title
            let have = Version(tag)
            if let minV = plan.minimumVersion {
                guard let need = Version(minV), let have, have >= need else { return nil }
            }
            guard relevant(hay) else { return nil }
            let pre = entry.meta["prerelease"] == "1"
            // stable release that bumps major or minor over the previous stable one = major update; patch/prerelease = ordinary
            var major = false
            if !pre, let have, let previous { major = have.nums[0] > previous.nums[0] || (have.nums[0] == previous.nums[0] && have.nums[1] > previous.nums[1]) }
            return Judged(reason: "新\(pre ? "预发布" : "正式版")：\(tag)" + (major ? "（主要/次要版本升级）" : ""), kind: major ? "majorUpdate" : "update")
        case .githubSearch:
            // Relevance rests on what the project says about itself (name + description). A topic tag alone is easy to add
            // (CAD apps and UI kits tagged "mcp"), so a tag-only match must at least read as AI work.
            let said = entry.title + " " + entry.summary, topics = (entry.meta["topics"] ?? "").replacingOccurrences(of: ",", with: " ")
            let wanted = plan.include.isEmpty || Keywords.matches(said, any: plan.include)
                || (Keywords.matches(topics, any: plan.include) && Keywords.matches(said, any: aiHints))
            guard wanted, plan.exclude.isEmpty || !Keywords.matches(said + " " + topics, any: plan.exclude) else { return nil }
            let stars = Int(entry.meta["stars"] ?? "") ?? 0
            let age = Date().timeIntervalSince(entry.publishedAt ?? entry.firstSeenAt) / 86400
            guard worthAlert(stars: stars, ageDays: age, minStars: plan.minStars) else { return nil }
            // a known project only alerts when it crosses this watch's bar now (it was below it before)
            var rising: Int?
            if case .metrics(let prev) = change {
                let was = Int(prev["stars"] ?? "") ?? 0
                guard !worthAlert(stars: was, ageDays: age, minStars: plan.minStars) else { return nil }
                rising = was
            } else if case .changed = change { return nil }
            // cheap sanity: a real project says what it is, and a pile of stars with zero forks is usually inflated
            let forks = Int(entry.meta["forks"] ?? "") ?? 0
            guard entry.summary.count >= 10, !(stars >= 200 && forks * 100 < stars), !(stars >= 20 && forks == 0) else { return nil }
            let lang = entry.meta["language"].flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""
            if let was = rising { return Judged(reason: "项目升温 · ★\(was) → ★\(stars) · 创建 \(Int(age)) 天\(lang)", kind: "newProject") }
            return Judged(reason: "新项目 · 创建 \(Int(age)) 天 · ★\(stars)\(lang)", kind: "newProject")
        case .rss, .list:
            guard relevant(hay) else { return nil }
            let t = entry.title.lowercased()
            let major = majorWords.contains { t.contains($0) }
            return Judged(reason: kind == .list ? "列表页新条目" : "新文章", kind: major ? "majorUpdate" : "update")
        case .web:
            guard case .changed(let before) = change else { return nil }
            guard relevant(entry.text) else { return nil }
            let (b, a) = diffSnippets(before, entry.text)
            return Judged(reason: "页面正文发生变化", kind: "pageChange", before: b, after: a)
        }
    }

    /// Short before/after excerpts around the first differing region.
    static func diffSnippets(_ a: String, _ b: String) -> (String, String) {
        let x = Array(a), y = Array(b)
        var p = 0
        while p < x.count && p < y.count && x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p && s < y.count - p && x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        func cut(_ c: [Character]) -> String {
            let lo = max(0, p - 30), hi = min(c.count, c.count - s + 30)
            return (lo > 0 ? "…" : "") + String(c[lo..<max(lo, hi)]) + (hi < c.count ? "…" : "")
        }
        return (cut(x), cut(y))
    }

    /// Check every due source that has at least one active watch (serial).
    public func checkDue(force: Bool = false) async -> [Event] {
        let ids: [Int64] = (try? await store.db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM source WHERE (? OR nextDueAt <= ?) AND EXISTS
                (SELECT 1 FROM watchSource ws JOIN watch w ON w.id = ws.watchID WHERE ws.sourceID = source.id AND w.status = 'active')
                ORDER BY nextDueAt
                """, arguments: [force, Date()])
        }) ?? []
        var all: [Event] = []
        for id in ids { all += await check(sourceID: id).events }
        return all
    }

    public func check(watchID: Int64) async -> [Event] {
        let ids = (try? await store.db.read { try Int64.fetchAll($0, sql: "SELECT sourceID FROM watchSource WHERE watchID = ?", arguments: [watchID]) }) ?? []
        var all: [Event] = []
        for id in ids { all += await check(sourceID: id).events }
        return all
    }
}
