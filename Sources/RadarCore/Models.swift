import Foundation
import GRDB
import CryptoKit

public enum SourceKind: String, Codable, CaseIterable {
    case githubReleases, githubSearch, rss, web, list
    public var label: String {
        switch self {
        case .githubReleases: return "GitHub Releases"
        case .githubSearch: return "GitHub 仓库发现"
        case .rss: return "RSS / Atom"
        case .web: return "静态网页"
        case .list: return "文章/项目列表页"
        }
    }
    public var defaultInterval: Double {
        switch self {
        case .githubReleases: return 2 * 3600
        case .rss: return 4 * 3600
        case .githubSearch: return 12 * 3600
        case .web, .list: return 6 * 3600
        }
    }
}

public enum PlanType: String, Codable { case topic, githubRelease, feed, webpage }

public struct WatchPlan: Codable, Equatable {
    public var type: PlanType
    public var title: String
    public var include: [String] = []
    public var exclude: [String] = []
    public var targetURL: String?
    public var stableOnly = false
    public var minimumVersion: String?
    public var notify = true
    public var minStars: Int?          // GitHub 新项目的 Stars 门槛（空 = 默认 50）
    public var unsupported: [String]?  // 听懂但无法自动判断的条件，原样展示给用户
    public init(type: PlanType, title: String) { self.type = type; self.title = title }
}

public struct Watch: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    public var id: Int64?
    public var title: String
    public var originalText: String
    public var planJSON: String
    public var status: String   // active / paused
    public var createdAt: Date
    public static let databaseTableName = "watch"
    public var isActive: Bool { status == "active" }
    public var plan: WatchPlan {
        get { (try? JSONDecoder().decode(WatchPlan.self, from: Data(planJSON.utf8))) ?? WatchPlan(type: .topic, title: title) }
        set { planJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public init(plan: WatchPlan, originalText: String) {
        self.title = plan.title; self.originalText = originalText; self.planJSON = ""
        self.status = "active"; self.createdAt = Date()
        self.plan = plan
    }
}

public struct Source: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    public var id: Int64?
    public var uniqueKey: String
    public var kind: SourceKind
    public var name: String
    public var endpoint: String      // URL, or GitHub search query
    public var selector: String?
    public var intervalSeconds: Double
    public var initialized: Bool
    public var lastCheckedAt: Date?
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var nextDueAt: Date
    public var etag: String?
    public var lastModified: String?
    public static let databaseTableName = "source"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct WatchSource: Codable, FetchableRecord, PersistableRecord, Hashable {
    public var watchID: Int64
    public var sourceID: Int64
    public var baselineReady: Bool
    public var createdAt: Date
    public static let databaseTableName = "watchSource"
}

public struct Entry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    public var id: Int64?
    public var sourceID: Int64
    public var externalKey: String
    public var canonicalURL: String
    public var title: String
    public var summary: String
    public var text: String
    public var contentHash: String
    public var firstSeenAt: Date
    public var publishedAt: Date?
    public var meta: [String: String]
    public static let databaseTableName = "entry"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Event: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    public var id: Int64?
    public var watchID: Int64
    public var entryID: Int64
    public var dedupeKey: String
    public var title: String
    public var reason: String
    public var evidenceURL: String
    public var beforeSnippet: String?
    public var afterSnippet: String?
    public var createdAt: Date
    public var readAt: Date?
    public var kind = "update"          // newProject / majorUpdate / update / pageChange
    public var mergeKey = ""
    public var repoKey = ""             // gh:owner/repo when the event is about (or links to) a GitHub project: the project, not the event
    public var facet = ""               // what happened to it: discover / release:<version> / article:<url> / page
    public var evidenceJSON: String?    // [EvidenceRef]：同一内容的各来源出处
    public var evidence: [EvidenceRef] {
        get { evidenceJSON.flatMap { try? JSONDecoder().decode([EvidenceRef].self, from: Data($0.utf8)) } ?? [] }
        set { evidenceJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }
    public static let databaseTableName = "event"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct EvidenceRef: Codable, Hashable { public var name: String; public var url: String }

public func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

public final class Store {
    public let db: DatabaseQueue

    public init(path: String?) throws {
        db = path == nil ? try DatabaseQueue() : try DatabaseQueue(path: path!)
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "watch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("originalText", .text).notNull()
                t.column("planJSON", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uniqueKey", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("endpoint", .text).notNull()
                t.column("selector", .text)
                t.column("intervalSeconds", .double).notNull()
                t.column("initialized", .boolean).notNull().defaults(to: false)
                t.column("lastCheckedAt", .datetime)
                t.column("lastSuccessAt", .datetime)
                t.column("lastError", .text)
                t.column("nextDueAt", .datetime).notNull()
                t.column("etag", .text)
                t.column("lastModified", .text)
            }
            try db.create(table: "watchSource") { t in
                t.column("watchID", .integer).notNull().references("watch", onDelete: .cascade)
                t.column("sourceID", .integer).notNull().references("source", onDelete: .cascade)
                t.column("baselineReady", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["watchID", "sourceID"])
            }
            try db.create(table: "entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .integer).notNull().references("source", onDelete: .cascade)
                t.column("externalKey", .text).notNull()
                t.column("canonicalURL", .text).notNull()
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("text", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("firstSeenAt", .datetime).notNull()
                t.column("publishedAt", .datetime)
                t.column("meta", .text).notNull()
                t.uniqueKey(["sourceID", "externalKey"])
            }
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("watchID", .integer).notNull().references("watch", onDelete: .cascade)
                t.column("entryID", .integer).notNull().references("entry", onDelete: .cascade)
                t.column("dedupeKey", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("evidenceURL", .text).notNull()
                t.column("beforeSnippet", .text)
                t.column("afterSnippet", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("readAt", .datetime)
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "event") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "update")
                t.add(column: "mergeKey", .text).notNull().defaults(to: "")
                t.add(column: "evidenceJSON", .text)
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "event") { t in t.add(column: "repoKey", .text).notNull().defaults(to: "") }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "event") { t in t.add(column: "facet", .text).notNull().defaults(to: "") }
        }
        try m.migrate(db)
    }

    /// Synchronous read (for non-async callers and tests).
    public func sync<T>(_ f: (Database) throws -> T) throws -> T { try db.read(f) }

    public static func defaultPath() throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Radar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("radar.sqlite").path
    }

    /// Reuses an existing Source with the same uniqueKey; links it to the watch.
    /// A watch joining an already-initialized source starts with its baseline ready (no backfill).
    @discardableResult
    public func attach(watchID: Int64, spec: SourceSpec) throws -> Source {
        try db.write { db in
            var src: Source
            if let existing = try Source.filter(Column("uniqueKey") == spec.uniqueKey).fetchOne(db) {
                src = existing
            } else {
                src = Source(id: nil, uniqueKey: spec.uniqueKey, kind: spec.kind, name: spec.name, endpoint: spec.endpoint,
                             selector: spec.selector, intervalSeconds: spec.interval ?? spec.kind.defaultInterval,
                             initialized: false, lastCheckedAt: nil, lastSuccessAt: nil, lastError: nil,
                             nextDueAt: Date(), etag: nil, lastModified: nil)
                try src.insert(db)
            }
            if try WatchSource.fetchOne(db, key: ["watchID": watchID, "sourceID": src.id!]) == nil {
                try WatchSource(watchID: watchID, sourceID: src.id!, baselineReady: src.initialized, createdAt: Date()).insert(db)
            }
            return src
        }
    }

    public func createWatch(plan: WatchPlan, text: String, sources: [SourceSpec]) throws -> Watch {
        var w = Watch(plan: plan, originalText: text)
        try db.write { try w.insert($0) }
        for s in sources { try attach(watchID: w.id!, spec: s) }
        return w
    }

    public func detach(watchID: Int64, sourceID: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM watchSource WHERE watchID = ? AND sourceID = ?", arguments: [watchID, sourceID])
            try db.execute(sql: "DELETE FROM source WHERE id NOT IN (SELECT sourceID FROM watchSource)")
        }
    }

    public func deleteWatch(_ id: Int64) throws {
        try db.write { db in
            _ = try Watch.deleteOne(db, key: id)
            // drop sources nobody uses
            try db.execute(sql: "DELETE FROM source WHERE id NOT IN (SELECT sourceID FROM watchSource)")
        }
    }
}

public struct SourceSpec: Hashable, Codable {
    public var kind: SourceKind
    public var endpoint: String
    public var name: String
    public var selector: String?
    public var interval: Double?
    public init(kind: SourceKind, endpoint: String, name: String, selector: String? = nil, interval: Double? = nil) {
        self.kind = kind; self.endpoint = endpoint; self.name = name; self.selector = selector; self.interval = interval
    }
    public var uniqueKey: String {
        switch kind {
        case .githubReleases: return "github-releases:" + endpoint.lowercased()
        case .githubSearch: return "github-search:" + endpoint.lowercased().split(separator: " ").joined(separator: " ")
        case .rss: return "rss:" + normalizeURL(endpoint)
        case .list: return "list:" + normalizeURL(endpoint)
        case .web: return "web:" + normalizeURL(endpoint) + "#" + (selector ?? "default")
        }
    }
}

public func normalizeURL(_ s: String) -> String {
    guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return s }
    c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.fragment = nil
    if c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
    return c.string ?? s
}

/// Identity of a piece of content across sources: a GitHub repo, or a URL without scheme/www/tracking.
public func mergeKey(_ s: String) -> String {
    // a repo home page is the repo itself; deeper GitHub links (a release, an issue) are distinct content
    if let repo = PlanParser.githubRepo(s), URL(string: s)?.pathComponents.filter({ $0 != "/" }).count == 2 { return "gh:" + repo.lowercased() }
    guard var c = URLComponents(string: s) else { return s }
    c.queryItems = c.queryItems?.filter { !($0.name.hasPrefix("utm_") || ["ref", "source", "fbclid"].contains($0.name)) }
    if c.queryItems?.isEmpty == true { c.queryItems = nil }
    c.fragment = nil
    var host = (c.host ?? "").lowercased(); if host.hasPrefix("www.") { host.removeFirst(4) }
    var path = c.path; if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return "u:" + host + path + (c.query.map { "?" + $0 } ?? "")
}
