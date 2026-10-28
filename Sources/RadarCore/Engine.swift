import Foundation
import GRDB
import os

public struct CheckOutcome {
    public var newEntries = 0
    public var events: [Event] = []
    public var notModified = false
    public var error: String?
}

public final class Engine {
    public let store: Store
    public let fetcher: Fetcher
    let log = Logger(subsystem: "app.radar", category: "engine")

    public init(store: Store, fetcher: Fetcher) { self.store = store; self.fetcher = fetcher }

    enum Change { case new, changed(before: String) }

    /// Fetch a source once and serve every linked watch from the result.
    @discardableResult
    public func check(sourceID: Int64) async -> CheckOutcome {
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
                    let type: String; if case .new = change { type = "new" } else { type = "changed" }
                    var mk = mergeKey(entry.canonicalURL)
                    if type == "changed" { mk += "#" + entry.contentHash }
                    let ref = EvidenceRef(name: src.name, url: entry.canonicalURL)
                    // Same content already reported for this watch (another source, same link/repo/title): add evidence, no new event.
                    if var old = try Event.filter(Column("watchID") == w.id! && (Column("mergeKey") == mk || (entry.title.count >= 15 && Column("title") == entry.title))).fetchOne(db) {
                        var ev = old.evidence
                        if !ev.contains(ref) { ev.append(ref); old.evidence = ev }
                        if Self.rank(j.kind) > Self.rank(old.kind) { old.kind = j.kind; old.reason = j.reason }
                        try old.update(db)
                        continue
                    }
                    var ev = Event(id: nil, watchID: w.id!, entryID: entry.id!, dedupeKey: sha256("\(w.id!)|\(mk)|\(type)"), title: entry.title, reason: j.reason,
                                   evidenceURL: entry.canonicalURL, beforeSnippet: j.before, afterSnippet: j.after, createdAt: Date(), readAt: nil,
                                   kind: j.kind, mergeKey: mk)
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
        return (events, changes.count)
    }

    struct Judged { var reason: String; var kind: String; var before: String? = nil; var after: String? = nil }

    static func rank(_ kind: String) -> Int { ["update": 0, "pageChange": 1, "majorUpdate": 2, "newProject": 3][kind] ?? 0 }

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
            guard relevant(hay) else { return nil }
            let stars = Int(entry.meta["stars"] ?? "") ?? 0
            let age = Date().timeIntervalSince(entry.publishedAt ?? entry.firstSeenAt) / 86400
            guard worthAlert(stars: stars, ageDays: age, minStars: plan.minStars) else { return nil }
            // cheap sanity: a real project says what it is, and a pile of stars with zero forks is usually inflated
            let forks = Int(entry.meta["forks"] ?? "") ?? 0
            guard entry.summary.count >= 10, !(stars >= 20 && forks == 0) else { return nil }
            let lang = entry.meta["language"].flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""
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
