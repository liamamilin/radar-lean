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

    func testExpansionTermsFindEnglishItemsForAChineseQuestion() throws {
        try entry("pricing-change", "Codex usage limit doubled for Pro plan", stars: 0)
        try entry("other", "unrelated cooking thing", stars: 0)
        let a = RadarAssistant(store: store)
        XCTAssertTrue(RadarAssistant.needsExpansion("额度有什么变化"))
        XCTAssertFalse(RadarAssistant.needsExpansion("usage limit"))
        XCTAssertFalse(RadarAssistant.needsExpansion("哪些来源读取失败了"))     // about Radar itself: no search terms needed
        XCTAssertEqual(RadarAssistant.parseTerms("quantum computing, development, progress, qubit"), ["quantum computing", "qubit"])
        let plain = try a.retrieve(question: "额度有什么变化", extraTerms: [], watchID: nil, range: nil, previous: [])
        XCTAssertFalse(plain.matched)                                   // nothing matches, and no filler is offered
        let terms = RadarAssistant.parseTerms("好的，关键词如下：\n1. usage limit, quota, \"pricing\", Codex")
        XCTAssertEqual(terms, ["usage limit", "quota", "pricing", "codex"])
        let r = try a.retrieve(question: "额度有什么变化", extraTerms: terms, watchID: nil, range: nil, previous: [])
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.evidence.first?.title, "pricing-change")
    }

    func testQuestionsAboutRadarItselfGetSourceStatus() throws {
        try entry("x", "something")
        try store.db.write { try $0.execute(sql: "UPDATE source SET lastError = 'HTTP 403', initialized = 1") }
        let a = RadarAssistant(store: store)
        XCTAssertTrue(RadarAssistant.isAboutRadar("哪些来源读取失败了？"))
        let r = try a.retrieve(question: "哪些来源读取失败了？", extraTerms: [], watchID: nil, range: nil, previous: [])
        XCTAssertTrue(r.matched)
        XCTAssertTrue(r.evidence.contains { $0.kind == "status" && $0.text.contains("HTTP 403") })
        XCTAssertTrue(r.evidence.first?.text.contains("读取失败 1 个") == true)
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

final class HackerNewsTests: Base {
    func hits(_ items: [(String, String, String?, Int)]) -> Data {
        let list = items.map { #"{"objectID":"\#($0.0)","title":"\#($0.1)","url":\#($0.2.map { "\"\($0)\"" } ?? "null"),"points":\#($0.3),"num_comments":7,"created_at":"2026-10-29T10:00:00Z"}"# }
        return Data(#"{"hits":[\#(list.joined(separator: ","))]}"#.utf8)
    }

    func testHackerNewsSourceBaselineThenNewStory() async throws {
        let url = "https://hn.algolia.com/api/v1/search_by_date"
        Stub.routes[url] = .init(body: hits([("1", "Show HN: local agent runner", "https://example.com/a", 120), ("2", "Ask HN: which coding agent?", nil, 80)]))
        var p = WatchPlan(type: .feed, title: "hn"); p.include = ["agent"]
        let (w, _) = try watch(p, SourceSpec(kind: .hackerNews, endpoint: "ai agent|40", name: "HN"))
        let first = await engine.check(watchID: w.id!)
        XCTAssertEqual(first.count, 0)                                            // first read is only a baseline
        let entries = try store.sync { try Entry.fetchAll($0) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.canonicalURL == "https://news.ycombinator.com/item?id=2" })   // no external URL → the discussion page
        XCTAssertTrue(entries.contains { $0.canonicalURL == "https://example.com/a" })
        Stub.routes[url] = .init(body: hits([("3", "A new agent framework for local models", "https://example.com/c", 200), ("1", "Show HN: local agent runner", "https://example.com/a", 130)]))
        let second = await engine.check(watchID: w.id!)
        XCTAssertEqual(second.map { $0.title }, ["A new agent framework for local models"])
        XCTAssertTrue(Stub.hits.keys.contains { $0.contains("numericFilters=points%3E%3D40") || $0.contains("points>=40") })
    }

    func testHackerNewsServerErrorIsReportedOnTheSource() async throws {
        Stub.routes["https://hn.algolia.com/api/v1/search_by_date"] = .init(status: 502)
        let (w, s) = try watch(WatchPlan(type: .feed, title: "hn"), SourceSpec(kind: .hackerNews, endpoint: "ollama|20", name: "HN"))
        _ = await engine.check(watchID: w.id!)
        let src = try store.sync { try Source.fetchOne($0, key: s.id!) }
        XCTAssertNotNil(src?.lastError)
        XCTAssertFalse(src!.initialized)
    }
}

final class PricingNewsTests: Base {
    func testPricingAndAllowanceNewsIsImportant() async throws {
        for t in ["Codex and Work usage doubles for Pro 100 subscribers", "ChatGPT Pro 200 allowance change", "Claude 套餐额度翻倍", "Cursor pricing update: new plans"] {
            XCTAssertTrue(Engine.isPricingNews(t), t)
        }
        for t in ["How Oracle turns days of work into minutes", "Show HN: A local agent runner", "Weekly digest: Node.js 26 ships"] {
            XCTAssertFalse(Engine.isPricingNews(t), t)
        }
    }

    func testPricingPostBecomesMajorUpdateAndNotifiesTopicWatch() async throws {
        let feed = { (items: String) in Data(#"<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>\#(items)</channel></rss>"#.utf8) }
        let item = { (t: String, id: String) in "<item><title>\(t)</title><link>https://example.com/\(id)</link><guid>\(id)</guid><description>d</description></item>" }
        Stub.routes["https://example.com/feed.xml"] = .init(body: feed(item("old post", "1")))
        var p = WatchPlan(type: .topic, title: "t"); p.include = ["chatgpt"]
        let (w, _) = try watch(p, SourceSpec(kind: .rss, endpoint: "https://example.com/feed.xml", name: "f"))
        _ = await engine.check(watchID: w.id!)
        Stub.routes["https://example.com/feed.xml"] = .init(body: feed(item("ChatGPT Pro 100 usage doubled", "2") + item("old post", "1")))
        let evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(evs.map { $0.kind }, ["majorUpdate"])
        XCTAssertTrue(Engine.shouldNotify(plan: p, kind: evs[0].kind))
    }
}

final class JSONSourceTests: Base {
    let mapping = "items=vulnerabilities;id=cveID;title={cveID} · {vendorProject} {product};url=https://nvd.nist.gov/vuln/detail/{cveID};summary=shortDescription;date=dateAdded"
    func body(_ ids: [String]) -> Data {
        let v = ids.map { #"{"cveID":"\#($0)","vendorProject":"Acme","product":"Router","shortDescription":"RCE in Router","dateAdded":"2026-10-29"}"# }
        return Data(#"{"title":"kev","vulnerabilities":[\#(v.joined(separator: ","))]}"#.utf8)
    }

    func testJSONSourceMapsFieldsAndReportsOnlyNewItems() async throws {
        Stub.routes["https://example.gov/kev.json"] = .init(body: body(["CVE-2026-0001"]))
        let (w, _) = try watch(WatchPlan(type: .feed, title: "kev"), SourceSpec(kind: .json, endpoint: "https://example.gov/kev.json", name: "KEV", selector: mapping))
        let base = await engine.check(watchID: w.id!)
        XCTAssertEqual(base.count, 0)                                                        // baseline
        let e = try store.sync { try Entry.fetchAll($0) }
        XCTAssertEqual(e.first?.title, "CVE-2026-0001 · Acme Router")
        XCTAssertEqual(e.first?.canonicalURL, "https://nvd.nist.gov/vuln/detail/CVE-2026-0001")
        Stub.routes["https://example.gov/kev.json"] = .init(body: body(["CVE-2026-0002", "CVE-2026-0001"]))
        let next = await engine.check(watchID: w.id!)
        XCTAssertEqual(next.map { $0.title }, ["CVE-2026-0002 · Acme Router"])
    }

    func testJSONSourceWithWrongMappingFailsClearly() async throws {
        Stub.routes["https://example.gov/kev.json"] = .init(body: body(["CVE-1"]))
        let (w, s) = try watch(WatchPlan(type: .feed, title: "kev"), SourceSpec(kind: .json, endpoint: "https://example.gov/kev.json", name: "KEV", selector: "items=nothing;id=cveID;title=cveID"))
        _ = await engine.check(watchID: w.id!)
        let src = try store.sync { try Source.fetchOne($0, key: s.id!) }
        XCTAssertTrue(src?.lastError?.contains("条目列表") == true)
        XCTAssertFalse(src!.initialized)
    }
}

final class OfficialCatalogTests: Base {
    func testEntitiesAreMatchedByNameInASentence() {
        let names = OfficialCatalog.entities(in: "关注 Ollama、Claude Code 和 Codex 的重要更新").map { $0.name }
        XCTAssertTrue(names.contains("Ollama")); XCTAssertTrue(names.contains("OpenAI / ChatGPT / Codex")); XCTAssertTrue(names.contains("Anthropic / Claude"))
        XCTAssertTrue(OfficialCatalog.entities(in: "关注 R 语言的最新动态").isEmpty)
    }

    func testCatalogChannelsAreUniqueAndKnownGapsAreRecorded() {
        let keys = OfficialCatalog.entities.flatMap { $0.channels }.map { $0.spec.uniqueKey }
        XCTAssertEqual(keys.count, Set(keys).count)
        let openai = OfficialCatalog.entities.first { $0.aliases.contains("openai") }!
        XCTAssertTrue(openai.unreadable.contains { $0.url.contains("help.openai.com") })   // the help-center release notes are a known blind spot
    }

    func testDiscoveryOffersOfficialChannelsForANamedProduct() async throws {
        Stub.dynamic = { url in
            if url.absoluteString.contains("ollama.com/blog/rss.xml") { return .init(body: Data(#"<?xml version="1.0"?><rss version="2.0"><channel><title>Ollama</title><item><title>New model</title><link>https://ollama.com/blog/x</link><guid>x</guid></item></channel></rss>"#.utf8)) }
            if url.absoluteString.contains("api.github.com/repos/ollama/ollama/releases") { return .init(body: Data("[]".utf8)) }
            return nil
        }
        let disc = Discovery(fetcher: Fetcher(session: engineSession()), store: store)
        var plan = WatchPlan(type: .topic, title: "ollama"); plan.include = ["ollama"]
        let cands = await disc.findSources(plan: plan, text: "关注 Ollama 的更新")
        let official = cands.filter { $0.official }
        XCTAssertTrue(official.contains { $0.spec.endpoint.contains("ollama.com/blog/rss.xml") && $0.ok })
    }

    func engineSession() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Stub.self]; return URLSession(configuration: c) }
}


final class MissDiagnosisTests: Base {
    func entry(_ url: String, _ title: String, source: Int64 = 1) -> Entry {
        Entry(id: 1, sourceID: source, externalKey: url, canonicalURL: url, title: title, summary: "", text: "", contentHash: "h", firstSeenAt: Date(), publishedAt: nil, meta: [:])
    }
    func src(_ endpoint: String, error: String? = nil) -> Source {
        Source(id: 1, uniqueKey: "rss:" + endpoint, kind: .rss, name: "S", endpoint: endpoint, selector: nil, intervalSeconds: 3600, initialized: true, lastCheckedAt: nil, lastSuccessAt: nil, lastError: error, nextDueAt: Date(), etag: nil, lastModified: nil)
    }
    func testUncoveredSiteIsASourceGapWithOfficialSuggestion() async {
        let d = await MissDiagnosis.diagnose(url: "https://openai.com/index/x/", plan: WatchPlan(type: .topic, title: "t"), sources: [], entries: [], fetcher: Fetcher())
        XCTAssertTrue(d.findings.contains { $0.text.contains("没有任何来源覆盖") })
        XCTAssertNotNil(d.suggestion)
    }
    func testKnownEntryFilteredByKeywords() async {
        var plan = WatchPlan(type: .topic, title: "t"); plan.include = ["agent"]
        let d = await MissDiagnosis.diagnose(url: "https://a.com/p", plan: plan, sources: [src("https://a.com/feed")], entries: [entry("https://a.com/p", "Cooking tips")], fetcher: Fetcher())
        XCTAssertTrue(d.findings.contains { $0.text.contains("关键词过滤") })
    }
    func testKnownEntryOnlyOrdinaryUpdate() async {
        let d = await MissDiagnosis.diagnose(url: "https://a.com/p", plan: WatchPlan(type: .topic, title: "t"), sources: [src("https://a.com/feed")], entries: [entry("https://a.com/p", "Some note")], fetcher: Fetcher())
        XCTAssertTrue(d.findings.contains { $0.text.contains("普通更新") })
    }
    func testFailingSameSiteSourceIsNamed() async {
        let d = await MissDiagnosis.diagnose(url: "https://a.com/missing", plan: WatchPlan(type: .topic, title: "t"), sources: [src("https://a.com/feed", error: "HTTP 403")], entries: [], fetcher: Fetcher())
        XCTAssertTrue(d.findings.contains { $0.text.contains("HTTP 403") })
    }
}
