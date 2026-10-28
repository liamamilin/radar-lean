import XCTest
import GRDB
@testable import RadarCore

final class Stub: URLProtocol {
    struct Resp { var status = 200; var headers: [String: String] = [:]; var body = Data(); var error: URLError? }
    nonisolated(unsafe) static var routes: [String: Resp] = [:]
    nonisolated(unsafe) static var hits: [String: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        Stub.hits[key, default: 0] += 1
        let r = Stub.routes.first { key.hasPrefix($0.key) }?.value ?? Resp(status: 404)
        if let e = r.error { client?.urlProtocol(self, didFailWithError: e); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func fixture(_ name: String) -> Data {
    try! Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("fixtures/\(name)"))
}

class Base: XCTestCase {
    var store: Store!, engine: Engine!
    override func setUp() async throws {
        Stub.routes = [:]; Stub.hits = [:]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        store = try Store(path: nil)
        engine = Engine(store: store, fetcher: Fetcher(session: URLSession(configuration: cfg)))
    }
    func events() throws -> [Event] { try store.sync { try Event.fetchAll($0) } }
    func watch(_ plan: WatchPlan, _ spec: SourceSpec) throws -> (Watch, Source) {
        let w = try store.createWatch(plan: plan, text: "t", sources: [])
        let s = try store.attach(watchID: w.id!, spec: spec)
        return (w, s)
    }
    static let relURL = "https://api.github.com/repos/example/radar-fixture/releases"
    static let relSpec = SourceSpec(kind: .githubReleases, endpoint: "example/radar-fixture", name: "r")
}

// A: GitHub baseline, new stable, repeat, prerelease
final class GitHubTests: Base {
    func testBaselineNewStableRepeatPrerelease() async throws {
        var plan = WatchPlan(type: .githubRelease, title: "x"); plan.stableOnly = true; plan.minimumVersion = "1.0.0"
        let (_, s) = try watch(plan, Self.relSpec)
        Stub.routes[Self.relURL] = .init(body: fixture("github_releases_baseline.json"))
        var o = await engine.check(sourceID: s.id!)
        XCTAssertNil(o.error); XCTAssertEqual(o.events.count, 0)
        XCTAssertEqual(try store.sync { try Entry.fetchCount($0) }, 2)           // baseline visible, no event
        Stub.routes[Self.relURL] = .init(body: fixture("github_releases_new.json"))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 1)
        XCTAssertEqual(o.events[0].evidenceURL, "https://github.com/example/radar-fixture/releases/tag/v1.0.0")
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0); XCTAssertEqual(try events().count, 1)
    }
    func testPrereleaseIgnoredWhenStableOnly() async throws {
        var plan = WatchPlan(type: .githubRelease, title: "x"); plan.stableOnly = true
        let (_, s) = try watch(plan, Self.relSpec)
        Stub.routes[Self.relURL] = .init(body: Data("[]".utf8))
        _ = await engine.check(sourceID: s.id!)
        let rc = #"[{"id":102,"tag_name":"v1.0.0-rc.1","name":"RC1","html_url":"https://github.com/example/radar-fixture/releases/tag/v1.0.0-rc.1","draft":false,"prerelease":true,"body":""}]"#
        Stub.routes[Self.relURL] = .init(body: Data(rc.utf8))   // adds only the prerelease
        let o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0)
    }
    func testVersionCompare() {
        XCTAssertTrue(Version("v1.0.0-rc.1")! < Version("1.0.0")!)
        XCTAssertTrue(Version("0.9.0")! < Version("1.0")!)
        XCTAssertNil(Version("nightly"))
    }
}

// B: shared sources / late-joining watch
final class SharingTests: Base {
    func testSharedSourceOneFetchNoBackfill() async throws {
        let spec = SourceSpec(kind: .rss, endpoint: "https://example.com/feed.xml", name: "f")
        var p1 = WatchPlan(type: .feed, title: "a"); p1.include = ["agent"]
        var p2 = WatchPlan(type: .feed, title: "b"); p2.include = ["swift"]
        let (_, s) = try watch(p1, spec)
        Stub.routes["https://example.com/feed.xml"] = .init(body: fixture("feed_initial.xml"))
        _ = await engine.check(sourceID: s.id!)
        // Watch 2 joins the initialized source: baseline already ready, old entries must not be reported.
        let w2 = try store.createWatch(plan: p2, text: "t", sources: [spec])
        XCTAssertEqual(try store.sync { try WatchSource.filter(Column("watchID") == w2.id!).fetchOne($0)?.baselineReady }, true)
        XCTAssertEqual(try store.sync { try Source.fetchCount($0) }, 1)
        Stub.hits = [:]
        Stub.routes["https://example.com/feed.xml"] = .init(body: fixture("feed_new.xml"))
        let o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(Stub.hits["https://example.com/feed.xml"], 1)
        XCTAssertEqual(o.events.count, 1)                       // only the "agent" watch matches the new post
        XCTAssertEqual(o.events[0].watchID, 1)
    }
}

// C: RSS
final class FeedTests: Base {
    func testReorderAndNewArticle() async throws {
        let spec = SourceSpec(kind: .rss, endpoint: "https://example.com/feed.xml", name: "f")
        var p = WatchPlan(type: .feed, title: "a"); p.include = ["agent"]
        let (_, s) = try watch(p, spec)
        Stub.routes["https://example.com/feed.xml"] = .init(body: fixture("feed_initial.xml"))
        var o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 0)
        let reordered = String(decoding: fixture("feed_new.xml"), as: UTF8.self)
        // new feed but with items reversed -> same two entries, one new
        Stub.routes["https://example.com/feed.xml"] = .init(body: fixture("feed_new.xml"))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 1); XCTAssertEqual(o.events[0].evidenceURL, "https://example.com/blog/101")
        _ = reordered
        let swapped = String(decoding: fixture("feed_new.xml"), as: UTF8.self)
            .replacingOccurrences(of: "<item>", with: "<ITEMX>").components(separatedBy: "<ITEMX>")
        let flipped = ([swapped[0]] + swapped[1...].reversed().map { "<item>" + $0 }).joined()
            .replacingOccurrences(of: "</channel></rss></channel></rss>", with: "</channel></rss>")
        Stub.routes["https://example.com/feed.xml"] = .init(body: Data(flipped.utf8))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0); XCTAssertNil(o.error)
        XCTAssertEqual(try events().count, 1)
    }
}

// D: HTML
final class HTMLTests: Base {
    func testNavIgnoredContentDetected() async throws {
        let url = "https://example.com/changelog"
        let spec = SourceSpec(kind: .web, endpoint: url, name: "w")
        let (_, s) = try watch(WatchPlan(type: .webpage, title: "w"), spec)
        Stub.routes[url] = .init(body: fixture("page_initial.html"))
        var o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 0)
        Stub.routes[url] = .init(body: fixture("page_nav_only.html"))
        o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 0)
        Stub.routes[url] = .init(body: fixture("page_content_change.html"))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 1)
        XCTAssertTrue(o.events[0].afterSnippet?.contains("1.0 stable") ?? false)
        XCTAssertTrue(o.events[0].beforeSnippet?.contains("0.9") ?? false)
        o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 0)
    }
}

// E: 304 / 429 / offline
final class ErrorTests: Base {
    func testStatuses() async throws {
        let (_, s) = try watch(WatchPlan(type: .githubRelease, title: "x"), Self.relSpec)
        Stub.routes[Self.relURL] = .init(headers: ["ETag": "\"abc\""], body: fixture("github_releases_baseline.json"))
        _ = await engine.check(sourceID: s.id!)
        Stub.routes[Self.relURL] = .init(status: 304)
        var o = await engine.check(sourceID: s.id!)
        XCTAssertTrue(o.notModified); XCTAssertNil(o.error)
        Stub.routes[Self.relURL] = .init(status: 429, headers: ["Retry-After": "600"])
        o = await engine.check(sourceID: s.id!)
        XCTAssertNotNil(o.error)
        var src = try store.sync { try Source.fetchOne($0, key: s.id!)! }
        XCTAssertNotNil(src.lastError); XCTAssertTrue(src.initialized)
        XCTAssertGreaterThan(src.nextDueAt.timeIntervalSinceNow, 500)
        Stub.routes[Self.relURL] = .init(error: URLError(.notConnectedToInternet))
        o = await engine.check(sourceID: s.id!)
        XCTAssertNotNil(o.error)
        src = try store.sync { try Source.fetchOne($0, key: s.id!)! }
        XCTAssertNotNil(src.lastError)
    }
    func testFirstFailureKeepsUninitialized() async throws {
        let (_, s) = try watch(WatchPlan(type: .githubRelease, title: "x"), Self.relSpec)
        Stub.routes[Self.relURL] = .init(status: 500)
        _ = await engine.check(sourceID: s.id!)
        let src = try store.sync { try Source.fetchOne($0, key: s.id!)! }
        XCTAssertFalse(src.initialized)
        XCTAssertEqual(try store.sync { try WatchSource.fetchOne($0)?.baselineReady }, false)
    }
}

// F: restart + pause
final class PersistenceTests: Base {
    func testRestartAndPause() async throws {
        let path = NSTemporaryDirectory() + "radar-\(UUID().uuidString).sqlite"
        var st = try Store(path: path)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        var eng = Engine(store: st, fetcher: Fetcher(session: URLSession(configuration: cfg)))
        let w = try st.createWatch(plan: WatchPlan(type: .githubRelease, title: "x"), text: "t", sources: [Self.relSpec])
        Stub.routes[Self.relURL] = .init(body: fixture("github_releases_baseline.json"))
        _ = await eng.checkDue(force: true)
        try await st.db.write { try $0.execute(sql: "UPDATE watch SET status='paused' WHERE id=?", arguments: [w.id]) }
        Stub.routes[Self.relURL] = .init(body: fixture("github_releases_new.json"))
        let none = await eng.checkDue(force: true); XCTAssertEqual(none.count, 0)     // paused: source not even fetched
        try await st.db.write { try $0.execute(sql: "UPDATE watch SET status='active' WHERE id=?", arguments: [w.id]) }
        // reopen DB
        st = try Store(path: path); eng = Engine(store: st, fetcher: Fetcher(session: URLSession(configuration: cfg)))
        XCTAssertEqual(try st.sync { try Entry.fetchCount($0) }, 2)
        XCTAssertTrue(try st.sync { try Source.fetchOne($0)!.initialized })
        let evs = await eng.checkDue(force: true)
        XCTAssertEqual(evs.count, 1)
        st = try Store(path: path)
        XCTAssertEqual(try st.sync { try Event.fetchCount($0) }, 1)
    }
}

final class PlanTests: XCTestCase {
    func testTopic() {
        let p = PlanParser.parse("关注 AI 开源项目，尤其是 Agent 和本地模型，排除 AI 绘画")
        XCTAssertEqual(p.type, .topic); XCTAssertEqual(p.include, ["Agent", "本地模型"]); XCTAssertEqual(p.exclude, ["AI 绘画"])
    }
    func testRelease() {
        let p = PlanParser.parse("关注 https://github.com/ollama/ollama 的稳定版，1.0 以上提醒")
        XCTAssertEqual(p.type, .githubRelease); XCTAssertTrue(p.stableOnly); XCTAssertEqual(p.minimumVersion, "1.0")
        XCTAssertEqual(PlanParser.githubRepo(p.targetURL!), "ollama/ollama")
    }
    func testEdit() {
        var p = WatchPlan(type: .topic, title: "t")
        p = PlanParser.applyEdit("排除 AI 绘画", to: p)!; XCTAssertEqual(p.exclude, ["AI 绘画"])
        p = PlanParser.applyEdit("改成只关注 Agent", to: p)!; XCTAssertEqual(p.include, ["Agent"])
        XCTAssertTrue(PlanParser.applyEdit("不要预发布", to: p)!.stableOnly)
        XCTAssertNil(PlanParser.applyEdit("你好呀今天天气不错", to: p))
    }
}

final class DiscoveryTests: Base {
    func testTopicMatching() async throws {
        let d = Discovery(fetcher: engine.fetcher, store: store)
        let ai = await d.specs(for: PlanParser.parse("关注 AI 开源项目，尤其是 Agent"), text: "关注 AI 开源项目，尤其是 Agent")
        XCTAssertEqual(ai.map { $0.endpoint }, ["topic:ai-agents"])
        // not AI: "detail"/"email" must not match "ai"; Chinese-only unknown topic gets nothing
        let t1 = "关注 Rust 开源项目"
        let none = await d.specs(for: PlanParser.parse(t1), text: t1)
        XCTAssertTrue(none.isEmpty)
        let t2 = "关注 detail email，尤其是 rust, wasm"
        let kw = await d.specs(for: PlanParser.parse(t2), text: t2)
        XCTAssertEqual(kw.first?.kind, .githubSearch)
        XCTAssertTrue(kw.first?.endpoint.contains("rust") ?? false)
    }
}

final class SearchTests: Base {
    func testSearchFindsFeeds() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        let f = Fetcher(session: URLSession(configuration: cfg), searchKey: { "k" })
        let json = #"{"results":[{"title":"A","url":"https://blog.a.test/post/1"},{"title":"G","url":"https://github.com/x/y"},{"title":"B","url":"https://b.test/news"},{"title":"A2","url":"https://blog.a.test/post/2"}]}"#
        Stub.routes["https://api.exa.ai/"] = .init(body: Data(json.utf8))
        Stub.routes["https://blog.a.test/post/1"] = .init(body: Data(#"<html><head><title>A</title><link rel="alternate" type="application/rss+xml" href="https://blog.a.test/feed.xml"></head></html>"#.utf8))
        Stub.routes["https://b.test/"] = .init(body: Data("<html><head><title>B</title></head><body>no feed</body></html>".utf8))
        let d = Discovery(fetcher: f, store: store)
        var plan = WatchPlan(type: .topic, title: "x"); plan.include = ["rust"]
        let specs = await d.searchSpecs(plan: plan, text: "rust")
        XCTAssertEqual(specs.map { $0.endpoint }, ["https://blog.a.test/feed.xml"])   // github skipped, host deduped, no-feed site dropped
        let none = try await Fetcher(session: URLSession(configuration: cfg)).webSearch("x")
        XCTAssertTrue(none.isEmpty)                                                   // no key → no search
    }
}

final class RankTests: Base {
    func rss(_ items: [(String, String)]) -> Data {
        let body = items.map { "<item><title>\($0.0)</title><link>https://x.test/\($0.0.hashValue)</link><pubDate>\($0.1)</pubDate></item>" }.joined()
        return Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>\(body)</channel></rss>".utf8)
    }
    func testStaleDroppedAndRankedByHits() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        let f = Fetcher(session: URLSession(configuration: cfg), searchKey: { "k" })
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let now = df.string(from: Date()), old = df.string(from: Date().addingTimeInterval(-800 * 86400))
        let json = #"{"results":[{"url":"https://stale.test/a"},{"url":"https://off.test/a"},{"url":"https://on.test/a"}]}"#
        Stub.routes["https://api.exa.ai/"] = .init(body: Data(json.utf8))
        for h in ["stale", "off", "on"] {
            Stub.routes["https://\(h).test/a"] = .init(body: Data(#"<html><head><link rel="alternate" type="application/rss+xml" href="https://\#(h).test/feed"></head></html>"#.utf8))
        }
        Stub.routes["https://stale.test/feed"] = .init(body: rss([("rust news", old)]))
        Stub.routes["https://off.test/feed"] = .init(body: rss([("cooking", now)]))
        Stub.routes["https://on.test/feed"] = .init(body: rss([("rust 1.90 released", now)]))
        var plan = WatchPlan(type: .topic, title: "x"); plan.include = ["rust"]
        let c = await Discovery(fetcher: f, store: store).findSources(plan: plan, text: "rust")
        XCTAssertEqual(c.map { $0.spec.name.replacingOccurrences(of: " Feed", with: "") }.filter { $0.hasSuffix(".test") }, ["on.test", "off.test"])
        XCTAssertEqual(c.first { $0.spec.name.hasPrefix("on.test") }?.matched, 1)
        XCTAssertEqual(c.first { $0.spec.name.hasPrefix("off.test") }?.matched, 0)
    }
}
