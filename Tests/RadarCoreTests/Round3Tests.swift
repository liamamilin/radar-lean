import XCTest
import GRDB
@testable import RadarCore

/// Regression tests for the event judgement of real source kinds, natural-language subjects, and the miss diagnosis.
final class PlanSubjectTests: XCTestCase {
    func testAllThreeProductsAreKeptAndConditionsAreSeparate() {
        for text in ["关注 ChatGPT、Claude、Codex 的最新动态，包括价格、额度、套餐和重要功能。", "ChatGPT、Claude、Codex 的最新动态，包括价格、额度、套餐和重要功能"] {
            let p = PlanParser.parse(text)
            XCTAssertEqual(p.include, ["ChatGPT", "Claude", "Codex"], text)
            XCTAssertEqual(p.focus ?? [], ["价格", "额度", "套餐", "重要功能"], text)
        }
    }
    func testOldSavedPlansStillDecode() throws {
        let old = #"{"title":"t","type":"topic","notify":true,"exclude":[],"include":["a"],"stableOnly":false}"#
        XCTAssertEqual(try JSONDecoder().decode(WatchPlan.self, from: Data(old.utf8)).include, ["a"])
    }
    func testListSourceKeyIncludesSelector() {
        let a = SourceSpec(kind: .list, endpoint: "https://x.dev/changelog", name: "a"), b = SourceSpec(kind: .list, endpoint: "https://x.dev/changelog", name: "b", selector: "js:")
        XCTAssertNotEqual(a.uniqueKey, b.uniqueKey)
        XCTAssertEqual(a.uniqueKey, "list:https://x.dev/changelog")        // saved static lists keep their key
    }
}

final class JudgingTests: XCTestCase {
    func entry(_ title: String, summary: String = "", url: String = "https://example.com/p", meta: [String: String] = [:], created: Date? = nil) -> Entry {
        Entry(id: 1, sourceID: 1, externalKey: title, canonicalURL: url, title: title, summary: summary, text: "", contentHash: "h", firstSeenAt: Date(), publishedAt: created, meta: meta)
    }
    func model(days: Double, likes: Int, tags: String = "", pipe: String = "text-generation") -> Entry {
        entry("org/Model-7B", url: "https://huggingface.co/org/Model-7B", meta: ["likes": String(likes), "downloads": "5000", "createdAt": "x", "pipeline_tag": pipe, "tags": tags], created: Date().addingTimeInterval(-days * 86400))
    }
    var topic: WatchPlan { var p = WatchPlan(type: .topic, title: "t"); p.include = ["chatgpt", "claude", "codex"]; return p }

    func testOfficialPostWithoutProductNameIsRecordedButOnlyPricingNotifies() {
        let aliases = ["openai", "chatgpt", "codex"]
        let pricing = Engine.evaluate(plan: topic, kind: .rss, entry: entry("Updated API pricing for developers"), change: .new, official: aliases)
        XCTAssertEqual(pricing?.kind, "majorUpdate")
        let partner = Engine.evaluate(plan: topic, kind: .rss, entry: entry("Introducing our partnership with a bank"), change: .new, official: aliases)
        XCTAssertEqual(partner?.kind, "update")                           // recorded, no notification
        let story = Engine.evaluate(plan: topic, kind: .rss, entry: entry("Stampli cuts launch hours by 68% using ChatGPT"), change: .new, official: aliases)
        XCTAssertEqual(story?.kind, "update")                             // a customer story, not an announcement
        XCTAssertEqual(Engine.evaluate(plan: topic, kind: .rss, entry: entry("Introducing ChatGPT Images 2.5"), change: .new, official: aliases)?.kind, "majorUpdate")
        XCTAssertNil(Engine.evaluate(plan: topic, kind: .rss, entry: entry("Updated API pricing for developers"), change: .new))   // a non-official source still needs the names
    }

    func testTrendingOldModelIsNotAnnouncedAsNewRelease() {
        let p = WatchPlan(type: .topic, title: "open models")
        let fresh = Engine.evaluate(plan: p, kind: .json, entry: model(days: 3, likes: 80, tags: "gguf,llama"), change: .new)
        XCTAssertEqual(fresh?.kind, "newProject"); XCTAssertTrue(fresh!.reason.contains("本地部署：有"))
        XCTAssertTrue(Engine.evaluate(plan: p, kind: .json, entry: model(days: 3, likes: 80), change: .new)!.reason.contains("本地部署：未确认"))
        let trending = Engine.evaluate(plan: p, kind: .json, entry: model(days: 40, likes: 900), change: .new)
        XCTAssertEqual(trending?.kind, "update"); XCTAssertTrue(trending!.reason.contains("不是新发布"))
        XCTAssertNil(Engine.evaluate(plan: p, kind: .json, entry: model(days: 200, likes: 9000), change: .new))
        XCTAssertNil(Engine.evaluate(plan: p, kind: .json, entry: model(days: 3, likes: 80, pipe: "text-to-image"), change: .new))   // not a language model
        let warm = Engine.evaluate(plan: p, kind: .json, entry: model(days: 10, likes: 60), change: .metrics(previous: ["likes": "20"]))
        XCTAssertEqual(warm?.kind, "newProject")
        XCTAssertNil(Engine.evaluate(plan: p, kind: .json, entry: model(days: 10, likes: 70), change: .metrics(previous: ["likes": "60"])))   // a plain figure move
    }

    func testHackerNewsLaunchNeedsShowHNAndVotes() {
        func hn(_ t: String, _ pts: Int, _ u: String = "https://github.com/a/tool") -> Entry { entry(t, url: u, meta: ["points": String(pts), "comments": "3"]) }
        XCTAssertEqual(Engine.judgeHackerNews(hn("Show HN: Tiny agent runner", 55)).kind, "newProject")
        XCTAssertEqual(Engine.judgeHackerNews(hn("Show HN: Tiny agent runner", 5)).kind, "update")
        XCTAssertEqual(Engine.judgeHackerNews(hn("Why open source release notes matter", 40, "https://blog.example.com/x")).kind, "update")
        XCTAssertEqual(Engine.judgeHackerNews(hn("Show HN: self post", 80, "https://news.ycombinator.com/item?id=1")).kind, "update")
        XCTAssertEqual(Engine.judgeHackerNews(hn("Big lab launches new model", 300, "https://lab.example/x")).kind, "majorUpdate")
    }
}

final class ModelListFlowTests: Base {
    func list(_ items: [(String, Int, Double, String)]) -> Data {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = items.map { #"{"id":"\#($0.0)","likes":\#($0.1),"downloads":4000,"pipeline_tag":"text-generation","tags":[\#($0.3)],"createdAt":"\#(f.string(from: Date().addingTimeInterval(-$0.2 * 86400)))"}"# }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }
    func testNewModelNotifiesOnceAndKnownModelFiguresStayCurrent() async throws {
        let url = "https://hf.test/api/models"
        Stub.routes[url] = .init(body: list([("a/old", 900, 300, ""), ("a/rising", 20, 10, "")]))
        let (w, s) = try watch(WatchPlan(type: .topic, title: "open models"), SourceSpec(kind: .json, endpoint: url, name: "HF", selector: OfficialCatalog.hfModels))
        var evs = await engine.check(watchID: w.id!); XCTAssertEqual(evs.count, 0)                     // baseline
        Stub.routes[url] = .init(body: list([("a/old", 950, 300, ""), ("a/rising", 60, 10, ""), ("b/fresh", 120, 2, #""gguf""#), ("c/ancient", 5000, 400, "")]))
        evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(Set(evs.map { $0.title }), ["a/rising", "b/fresh"])                             // trending-old / ancient models make no event
        XCTAssertTrue(evs.allSatisfy { Engine.shouldNotify(plan: WatchPlan(type: .topic, title: ""), kind: $0.kind) })
        let rising = try store.sync { try Entry.filter(Column("externalKey") == "json:a/rising").fetchOne($0) }
        XCTAssertEqual(rising?.meta["likes"], "60")                                                    // figures are kept current
        evs = await engine.check(watchID: w.id!); XCTAssertEqual(evs.count, 0)                         // nothing repeats
        _ = s
    }
}

final class MissCaseTests: Base {
    var wid: Int64 = 0, sid: Int64 = 0, fetcher: Fetcher!
    override func setUp() async throws {
        try await super.setUp()
        var plan = WatchPlan(type: .topic, title: "agents"); plan.include = ["agent"]
        let (w, s) = try watch(plan, SourceSpec(kind: .rss, endpoint: "https://a.test/feed.xml", name: "A Feed"))
        wid = w.id!; sid = s.id!
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        fetcher = Fetcher(session: URLSession(configuration: cfg))
        try await store.db.write { db in
            try db.execute(sql: "UPDATE source SET initialized = 1, lastSuccessAt = ? WHERE id = ?", arguments: [Date(), sid])
            try db.execute(sql: "UPDATE watchSource SET baselineReady = 1")
        }
    }
    @discardableResult func add(_ i: Int, _ title: String, ago: Double = 0) throws -> Entry {
        try store.db.write { db in
            var e = Entry(id: nil, sourceID: sid, externalKey: "k\(i)", canonicalURL: "https://a.test/p/\(i)", title: title, summary: "", text: "", contentHash: "h\(i)",
                          firstSeenAt: Date().addingTimeInterval(-ago), publishedAt: nil, meta: [:])
            try e.insert(db); return e
        }
    }
    func run(_ i: Int) async -> [String] { await MissDiagnosis.diagnose(url: "https://a.test/p/\(i)", watchID: wid, store: store, fetcher: fetcher).findings.map { $0.text } }

    func testReadButFilteredByKeywordsNamesTheCondition() async throws {
        try add(0, "Old note", ago: 9000); try add(1, "Cooking tips", ago: 100)
        let d = await MissDiagnosis.diagnose(url: "https://a.test/p/1", watchID: wid, store: store, fetcher: fetcher)
        XCTAssertTrue(d.findings.contains { $0.text.contains("没有命中任何关注词") && $0.text.contains("agent") })
        XCTAssertTrue(d.findings.contains { if case .addInclude? = $0.action?.action { return true }; return false })
    }
    func testHealthySourceWithoutTheLinkIsNotBlamedOnRules() async throws {
        for i in 0..<100 { try add(i + 10, "Agent note \(i)", ago: Double(9000 - i)) }
        let t = await run(1)
        XCTAssertTrue(t.contains { $0.contains("读取正常") && $0.contains("共 100 条记录") && $0.contains("没有这个链接") })
    }
    func testOldEntryBeyondTheScreenWindowIsStillFound() async throws {
        for i in 0..<100 { try add(i + 10, "Agent note \(i)", ago: Double(9000 - i)) }   // 100 entries; the oldest is far past a 60-row screen
        let t = await run(10)
        XCTAssertTrue(t.contains { $0.contains("读到过它") && $0.contains("Agent note 0") })
        XCTAssertFalse(t.contains { $0.contains("没有读到过") })
    }
    func testBaselineContentIsExplained() async throws {
        try add(1, "Agent first read", ago: 0); try add(2, "Agent second", ago: 0)
        try await store.db.write { try $0.execute(sql: "UPDATE watchSource SET baselineReady = 0") }
        let t = await run(1)
        XCTAssertTrue(t.contains { $0.contains("基线") })
    }
    func testEventThatDidNotNotifyIsDistinguished() async throws {
        let e = try add(1, "Agent minor note", ago: 100)
        try await store.db.write { db in
            var ev = Event(id: nil, watchID: wid, entryID: e.id!, dedupeKey: "d", title: e.title, reason: "新文章", evidenceURL: e.canonicalURL, beforeSnippet: nil, afterSnippet: nil,
                           createdAt: Date(), readAt: nil, kind: "update", mergeKey: mergeKey(e.canonicalURL), repoKey: "", facet: "article", evidenceJSON: nil)
            try ev.insert(db)
        }
        let t = await run(1)
        XCTAssertTrue(t.contains { $0.contains("只会通知“新项目”和“重大更新”") })
    }
}
