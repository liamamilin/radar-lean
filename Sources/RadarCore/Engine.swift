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
                    guard let (reason, before, after) = Self.evaluate(plan: w.plan, kind: src.kind, entry: entry, change: change) else { continue }
                    let type: String; if case .new = change { type = "new" } else { type = "changed" }
                    let key = sha256("\(w.id!)|\(sourceID)|\(entry.externalKey)|\(entry.contentHash)|\(type)")
                    var ev = Event(id: nil, watchID: w.id!, entryID: entry.id!, dedupeKey: key, title: entry.title, reason: reason,
                                   evidenceURL: entry.canonicalURL, beforeSnippet: before, afterSnippet: after, createdAt: Date(), readAt: nil)
                    if try Event.filter(Column("dedupeKey") == key).isEmpty(db) {
                        try ev.insert(db)
                        events.append(ev)
                    }
                }
            }
        }
        src.lastCheckedAt = Date(); src.lastSuccessAt = Date(); src.lastError = nil
        src.nextDueAt = Date().addingTimeInterval(src.intervalSeconds)
        if let e = result.etag { src.etag = e }; if let m = result.lastModified { src.lastModified = m }
        try src.update(db)
        return (events, changes.count)
    }

    static func evaluate(plan: WatchPlan, kind: SourceKind, entry: Entry, change: Change) -> (String, String?, String?)? {
        let hay = entry.title + " " + entry.summary + " " + (kind == .web ? "" : entry.text)
        switch kind {
        case .githubReleases:
            if entry.meta["draft"] == "1" { return nil }
            if plan.stableOnly && entry.meta["prerelease"] == "1" { return nil }
            let tag = entry.meta["tag"] ?? entry.title
            if let minV = plan.minimumVersion {
                guard let need = Version(minV), let have = Version(tag), have >= need else { return nil }
            }
            if !plan.exclude.isEmpty && Keywords.matches(hay, any: plan.exclude) { return nil }
            if !plan.include.isEmpty && !Keywords.matches(hay, any: plan.include) { return nil }
            let pre = entry.meta["prerelease"] == "1" ? "预发布" : "正式版"
            return ("新\(pre)：\(tag)", nil, nil)
        case .githubSearch:
            if !plan.exclude.isEmpty && Keywords.matches(hay, any: plan.exclude) { return nil }
            if !plan.include.isEmpty && !Keywords.matches(hay, any: plan.include) { return nil }
            return ("此来源新发现的项目（★\(entry.meta["stars"] ?? "?")）", nil, nil)
        case .rss:
            if !plan.exclude.isEmpty && Keywords.matches(hay, any: plan.exclude) { return nil }
            if !plan.include.isEmpty && !Keywords.matches(hay, any: plan.include) { return nil }
            return ("新文章", nil, nil)
        case .web:
            guard case .changed(let before) = change else { return nil }
            if !plan.exclude.isEmpty && Keywords.matches(entry.text, any: plan.exclude) { return nil }
            if !plan.include.isEmpty && !Keywords.matches(entry.text, any: plan.include) { return nil }
            let (b, a) = diffSnippets(before, entry.text)
            return ("页面正文发生变化", b, a)
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
