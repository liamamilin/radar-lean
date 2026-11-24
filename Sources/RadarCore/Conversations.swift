import Foundation
import GRDB

/// One question and its answer in "问 Radar". `evidence` is everything the answer could cite, so a reopened conversation still resolves [S1].
public struct AskTurn: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var question: String
    public var answer = ""
    public var evidence: [Evidence] = []
    public var done = false
    public var failed: String?
    public var searched: [String] = []
    public var notes: [String] = []        // e.g. a link that could not be read
    public var canned = false              // answered with a fixed "nothing found" text, not by the model
    public init(question: String) { self.question = question }
}

public struct ConversationHeader: Identifiable, Hashable {
    public var id: Int64
    public var title: String
    public var updatedAt: Date
}

/// Saved "问 Radar" conversations, newest first.
public final class ConversationStore {
    let store: Store
    public init(store: Store) { self.store = store }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public static func title(for question: String) -> String {
        let t = question.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? question
        return t.count > 28 ? String(t.prefix(28)) + "…" : t
    }

    public func headers() throws -> [ConversationHeader] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title, updatedAt FROM conversation ORDER BY updatedAt DESC, id DESC").map {
                ConversationHeader(id: $0["id"], title: $0["title"], updatedAt: $0["updatedAt"])
            }
        }
    }

    public func load(_ id: Int64) throws -> (turns: [AskTurn], scope: Int64?)? {
        try store.db.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT scope, json FROM conversation WHERE id = ?", arguments: [id]), let d: Data = r["json"] else { return nil }
            var turns = (try? Self.decoder.decode([AskTurn].self, from: d)) ?? []
            for i in turns.indices where !turns[i].done { turns[i].done = true }   // generation was interrupted (app quit, switched away)
            return (turns, r["scope"])
        }
    }

    /// Inserts when `id` is nil. Returns the conversation's id.
    @discardableResult
    public func save(id: Int64?, turns: [AskTurn], scope: Int64?, now: Date = Date()) throws -> Int64? {
        guard let first = turns.first else { return id }
        let data = try Self.encoder.encode(turns)
        return try store.db.write { db in
            if let id {
                try db.execute(sql: "UPDATE conversation SET json = ?, scope = ?, updatedAt = ? WHERE id = ?", arguments: [data, scope, now, id])
                return id
            }
            try db.execute(sql: "INSERT INTO conversation (title, scope, createdAt, updatedAt, json) VALUES (?, ?, ?, ?, ?)",
                           arguments: [Self.title(for: first.question), scope, now, now, data])
            return db.lastInsertedRowID
        }
    }

    public func delete(_ id: Int64) throws { try store.db.write { try $0.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id]) } }
}
