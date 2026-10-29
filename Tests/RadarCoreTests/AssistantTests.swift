import XCTest
import GRDB
@testable import RadarCore

final class OllamaTests: XCTestCase {
    func client() -> OllamaClient {
        Stub.routes = [:]; Stub.hits = [:]; Stub.dynamic = nil; Stub.delay = 0
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        return OllamaClient(session: URLSession(configuration: cfg))
    }

    func testModelListSkipsCloudAndEmbeddingOnly() async throws {
        let c = client()
        let json = #"{"models":[{"name":"qwen3:8b","capabilities":["completion"]},{"name":"think:9b","capabilities":["completion","thinking"]},{"name":"bge-m3:latest","capabilities":["embedding"]},{"name":"gpt-oss:120b-cloud","capabilities":["completion"]},{"name":"old:1b"}]}"#
        Stub.routes["http://127.0.0.1:11434/api/tags"] = .init(body: Data(json.utf8))
        let m = try await c.models()
        XCTAssertEqual(m.map { $0.name }, ["qwen3:8b", "think:9b", "old:1b"])
        XCTAssertEqual(m.map { $0.thinking }, [false, true, false])
    }

    func testUnreachableAndNoModels() async throws {
        let c = client()
        Stub.routes["http://127.0.0.1:11434/api/tags"] = .init(error: URLError(.cannotConnectToHost))
        do { _ = try await c.models(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("连不上")) }
        Stub.routes["http://127.0.0.1:11434/api/tags"] = .init(body: Data(#"{"models":[]}"#.utf8))
        let none = try await c.models(); XCTAssertTrue(none.isEmpty)
    }

    func testChatStreamsPiecesAndReportsErrors() async throws {
        let c = client()
        let ndjson = [#"{"message":{"role":"assistant","content":"你"},"done":false}"#, #"{"message":{"role":"assistant","content":"好"},"done":false}"#,
                      #"{"message":{"role":"assistant","content":""},"done":true}"#].joined(separator: "\n") + "\n"
        Stub.routes["http://127.0.0.1:11434/api/chat"] = .init(body: Data(ndjson.utf8))
        var got: [String] = []
        for try await p in c.chat(model: OllamaModel(name: "m", thinking: true), messages: [ChatMessage(role: "user", content: "hi")]) { got.append(p) }
        XCTAssertEqual(got, ["你", "好"])
        Stub.routes["http://127.0.0.1:11434/api/chat"] = .init(status: 404, body: Data(#"{"error":"model 'm' not found"}"#.utf8))
        do { for try await _ in c.chat(model: OllamaModel(name: "m", thinking: false), messages: []) {}; XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not found")) }
    }
}

final class AssistantTests: Base {
    var wid: Int64 = 0, sid: Int64 = 0
    override func setUp() async throws {
        try await super.setUp()
        let (w, s) = try watch(WatchPlan(type: .topic, title: "AI 开源"), SourceSpec(kind: .githubSearch, endpoint: "topic:x", name: "GitHub · X"))
        wid = w.id!; sid = s.id!
    }
    @discardableResult
    func entry(_ title: String, _ summary: String, stars: Int = 0, days: Double = 1, url: String? = nil) throws -> Entry {
        try store.db.write { db in
            var e = Entry(id: nil, sourceID: sid, externalKey: title, canonicalURL: url ?? "https://github.com/x/\(title.replacingOccurrences(of: " ", with: "-"))", title: title, summary: summary,
                          text: summary, contentHash: title, firstSeenAt: Date(), publishedAt: Date().addingTimeInterval(-days * 86400), meta: ["stars": String(stars)])
            try e.insert(db); return e
        }
    }
    func event(_ e: Entry, kind: String = "newProject") throws {
        try store.db.write { db in
            var ev = Event(id: nil, watchID: wid, entryID: e.id!, dedupeKey: e.title, title: e.title, reason: "新项目：\(e.title)", evidenceURL: e.canonicalURL, beforeSnippet: nil, afterSnippet: nil,
                           createdAt: Date(), readAt: nil, kind: kind, mergeKey: e.canonicalURL, repoKey: "", facet: "discover", evidenceJSON: nil)
            try ev.insert(db)
        }
    }

    func testBaselineIsNotPresentedAsNewEvents() throws {
        try entry("agent-kit", "An agent toolkit", stars: 120)
        try entry("old-thing", "something from long ago", days: 200)
        let a = RadarAssistant(store: store)
        let c = try a.summaryContext(watchID: wid, range: .week)
        XCTAssertEqual(c.events, 0)                                   // nothing happened since the baseline
        XCTAssertEqual(c.evidence.map { $0.title }, ["agent-kit"])    // and the 200-day-old item is outside the range
        XCTAssertTrue(c.evidence.allSatisfy { !$0.isEvent })
        let msgs = RadarAssistant.summaryMessages(c, range: .week)
        XCTAssertTrue(msgs[1].content.contains("检测到 0 条真实事件"))
        XCTAssertTrue(msgs[0].content.contains("不等于近期新增"))
    }

    func testEventsComeFirstAndUrlsAreFromTheDatabase() throws {
        let hot = try entry("hot-agent", "fast agent runtime", stars: 900)
        try entry("quiet-lib", "tiny library", stars: 3)
        try event(hot)
        let a = RadarAssistant(store: store)
        let c = try a.summaryContext(watchID: wid, range: .week)
        XCTAssertEqual(c.events, 1)
        XCTAssertEqual(c.evidence[0].isEvent, true); XCTAssertEqual(c.evidence[0].id, "S1")
        XCTAssertEqual(c.evidence.filter { $0.url == hot.canonicalURL }.count, 1)    // the entry behind the event is not listed twice
        let sig = c.signature
        try entry("another", "new", stars: 1)
        XCTAssertNotEqual(try a.summaryContext(watchID: wid, range: .week).signature, sig)   // cache invalidation
    }

    func testAskRanksByKeywordAndFollowUpKeepsNumbering() throws {
        try entry("mcp-gateway", "MCP server gateway for agents", stars: 40)
        try entry("llama-runner", "run local models quickly", stars: 400)
        try entry("cooking-app", "recipes", stars: 2000)
        let a = RadarAssistant(store: store)
        let first = try a.askContext(question: "最近有哪些 MCP 项目？", watchID: nil, range: nil, previous: [])
        XCTAssertEqual(first.first?.title, "mcp-gateway")
        let second = try a.askContext(question: "其中哪些适合本地运行？", watchID: nil, range: nil, previous: first)
        XCTAssertEqual(Array(second.prefix(first.count)), first)                      // earlier numbers keep their meaning
        XCTAssertTrue(Set(second.map { $0.id }).count == second.count)
        XCTAssertEqual(RadarAssistant.detectRange("最近一周发现了什么"), .week)
        let none = try a.askContext(question: "mcp", watchID: nil, range: .day, previous: [])
        XCTAssertTrue(none.allSatisfy { $0.date! > Date().addingTimeInterval(-86400) })
    }

    func testAskCanBeScopedToOneWatch() throws {
        try entry("in-scope", "agent runtime")
        let (w2, s2) = try watch(WatchPlan(type: .topic, title: "other"), SourceSpec(kind: .githubSearch, endpoint: "topic:y", name: "GitHub · Y"))
        try store.db.write { db in
            var e = Entry(id: nil, sourceID: s2.id!, externalKey: "o", canonicalURL: "https://github.com/y/other-agent", title: "other-agent", summary: "agent", text: "agent", contentHash: "o",
                          firstSeenAt: Date(), publishedAt: Date(), meta: [:])
            try e.insert(db)
        }
        let r = try RadarAssistant(store: store).askContext(question: "agent", watchID: w2.id!, range: nil, previous: [])
        XCTAssertEqual(r.map { $0.title }, ["other-agent"])
    }

    func testCitationsAreLinkedFromEvidenceOnly() {
        let ev = [Evidence(id: "S1", title: "a", url: "https://a.test/1", origin: "o", date: nil, text: "", meta: "", isEvent: false, kind: "entry"),
                  Evidence(id: "S2", title: "b", url: "https://b.test/2", origin: "o", date: nil, text: "", meta: "", isEvent: false, kind: "entry")]
        let out = RadarAssistant.linkCitations("好 [S1]，也有 [S1, S2]，编造的 [S9]。", ev)
        XCTAssertTrue(out.contains("[S1](https://a.test/1)"))
        XCTAssertTrue(out.contains("[S2](https://b.test/2)"))
        XCTAssertFalse(out.contains("S9]("))                                          // a number the database does not know gets no link
        XCTAssertEqual(RadarAssistant.cited("见 [S2] 和 [S9]", ev).map { $0.id }, ["S2"])
    }

    func testExportSourcesListsEverySourceWithItsWatches() throws {
        let data = try store.exportSources()
        let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let list = o["sources"] as! [[String: Any]]
        XCTAssertEqual(o["count"] as? Int, list.count)
        XCTAssertEqual(list.count, try store.db.read { try Source.fetchCount($0) })
        XCTAssertTrue(list.allSatisfy { ($0["endpoint"] as? String)?.isEmpty == false && $0["kind"] != nil })
        XCTAssertTrue(list.contains { ($0["watches"] as? [String])?.isEmpty == false })
    }
}
