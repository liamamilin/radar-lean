import XCTest
import GRDB
@testable import RadarCore

final class Stub: URLProtocol {
    struct Resp { var status = 200; var headers: [String: String] = [:]; var body = Data(); var error: URLError? }
    nonisolated(unsafe) static var routes: [String: Resp] = [:]
    nonisolated(unsafe) static var hits: [String: Int] = [:]
    nonisolated(unsafe) static var dynamic: ((URL) -> Resp?)?
    nonisolated(unsafe) static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        Stub.hits[key, default: 0] += 1
        if Stub.delay > 0 { Thread.sleep(forTimeInterval: Stub.delay) }
        let r = Stub.dynamic?(request.url!) ?? Stub.routes.first { key.hasPrefix($0.key) }?.value ?? Resp(status: 404)
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
        Stub.routes = [:]; Stub.hits = [:]; Stub.dynamic = nil; Stub.delay = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        store = try Store(path: nil)
        let fetcher = Fetcher(session: URLSession(configuration: cfg)); fetcher.searchGap = 0
        engine = Engine(store: store, fetcher: fetcher)
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

final class JudgeTests: Base {
    func ago(_ days: Double) -> String { Fetcher.iso.string(from: Date().addingTimeInterval(-days * 86400)) }
    let searchURL = "https://api.github.com/search/repositories"

    func testAcceptanceSentenceParse() {
        let p = PlanParser.parse("我想关注 AI 开源项目，尤其是 Agent 和本地模型，有真正值得关注的新项目时提醒我")
        XCTAssertEqual(p.type, .topic)
        XCTAssertEqual(p.title, "AI 开源项目")
        XCTAssertEqual(p.include, ["Agent", "本地模型"])       // the alert clause must not become a keyword
        let q = PlanParser.parse("关注 Rust 项目，要创新的，stars 100 以上")
        XCTAssertEqual(q.minStars, 100)
        XCTAssertEqual(q.unsupported?.count, 1)
    }

    func testGitHubDiscoveryFiltersAndClassifies() async throws {
        var plan = WatchPlan(type: .topic, title: "ai"); plan.include = ["agent"]
        let (_, s) = try watch(plan, SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "gh"))
        func item(_ id: Int, _ name: String, _ stars: Int, _ age: Double, _ desc: String, fork: Bool = false) -> String {
            #"{"id":\#(id),"full_name":"\#(name)","html_url":"https://github.com/\#(name)","description":"\#(desc)","stargazers_count":\#(stars),"forks_count":30,"language":"Python","topics":[],"created_at":"\#(ago(age))","pushed_at":"\#(ago(1))","fork":\#(fork),"archived":false}"#
        }
        Stub.routes[searchURL] = .init(body: Data(#"{"items":[]}"#.utf8))
        var o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0)
        let items = [item(1, "a/solid", 200, 40, "An agent framework"), item(2, "b/small", 12, 40, "An agent toy"),
                     item(3, "c/fresh", 12, 3, "Fresh agent runtime"), item(4, "d/forked", 500, 40, "agent fork", fork: true),
                     item(5, "e/offtopic", 900, 40, "A database")]
        Stub.routes[searchURL] = .init(body: Data(#"{"items":[\#(items.joined(separator: ","))]}"#.utf8))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.map { $0.title }.sorted(), ["a/solid", "c/fresh"])   // small old, fork and off-topic dropped
        XCTAssertTrue(o.events.allSatisfy { $0.kind == "newProject" })
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0)
    }

    func testListPageItems() throws {
        let posts = (1...6).map { #"<li><a href="/blog/post-number-\#($0)">Post number \#($0) about agents</a> <time datetime="2026-10-0\#($0)">d</time><p>Summary \#($0)</p></li>"# }
        let html = "<html><head><title>Blog</title></head><body><nav><a href=\"/about-us-page\">About us and more</a></nav><ul>\(posts.joined())</ul></body></html>"
        let r = try engine.fetcher.extractList(html: html, url: URL(string: "https://x.test/blog")!)
        XCTAssertEqual(r.entries.count, 6)
        XCTAssertEqual(r.entries[0].url, "https://x.test/blog/post-number-1")
        XCTAssertNotNil(r.entries[0].publishedAt)
        XCTAssertThrowsError(try engine.fetcher.extractList(html: "<html><body><p>one <a href=\"/a/b/c\">single article link here</a></p></body></html>", url: URL(string: "https://x.test/p")!))
    }

    func testListSourceIncrementalAndMerge() async throws {
        func page(_ n: Int) -> Data {
            let li = (1...n).map { #"<li><a href="/blog/post-number-\#($0)">Post number \#($0) about agents</a></li>"# }.joined()
            return Data("<html><body><ul>\(li)</ul></body></html>".utf8)
        }
        func feed(_ n: Int) -> Data {
            let it = (1...n).map { "<item><title>Post number \($0) about agents</title><link>https://x.test/blog/post-number-\($0)/?utm_source=rss</link></item>" }.joined()
            return Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>\(it)</channel></rss>".utf8)
        }
        let plan = WatchPlan(type: .topic, title: "x")
        let (w, list) = try watch(plan, SourceSpec(kind: .list, endpoint: "https://x.test/blog", name: "list"))
        let rss = try store.attach(watchID: w.id!, spec: SourceSpec(kind: .rss, endpoint: "https://x.test/feed", name: "feed"))
        Stub.routes["https://x.test/blog"] = .init(body: page(6)); Stub.routes["https://x.test/feed"] = .init(body: feed(6))
        _ = await engine.check(sourceID: list.id!); _ = await engine.check(sourceID: rss.id!)
        Stub.routes["https://x.test/blog"] = .init(body: page(7)); Stub.routes["https://x.test/feed"] = .init(body: feed(7))
        let a = await engine.check(sourceID: list.id!)
        XCTAssertEqual(a.events.count, 1)
        let b = await engine.check(sourceID: rss.id!)
        XCTAssertEqual(b.events.count, 0)                                            // same post via the feed: merged, not repeated
        let ev = try events()
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(Set(ev[0].evidence.map { $0.name }), ["list", "feed"])        // both sources kept as evidence
    }

    func testMajorVersusPatchRelease() async throws {
        let plan = WatchPlan(type: .githubRelease, title: "x")
        let (_, s) = try watch(plan, Self.relSpec)
        func rel(_ id: Int, _ tag: String) -> String { #"{"id":\#(id),"tag_name":"\#(tag)","name":"\#(tag)","html_url":"https://github.com/example/radar-fixture/releases/tag/\#(tag)","draft":false,"prerelease":false,"body":""}"# }
        Stub.routes[Self.relURL] = .init(body: Data("[\(rel(1, "v1.2.0"))]".utf8))
        _ = await engine.check(sourceID: s.id!)
        Stub.routes[Self.relURL] = .init(body: Data("[\(rel(3, "v1.2.1")),\(rel(2, "v1.3.0")),\(rel(1, "v1.2.0"))]".utf8))
        let o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: o.events.map { ($0.title, $0.kind) }), ["v1.2.1": "update", "v1.3.0": "majorUpdate"])
    }

    func testPausedWatchGetsNoEventsAndResumes() async throws {
        let plan = WatchPlan(type: .githubRelease, title: "x")
        let (w, s) = try watch(plan, Self.relSpec)
        func rel(_ id: Int) -> String { #"{"id":\#(id),"tag_name":"v1.\#(id).0","name":"v1.\#(id).0","html_url":"https://github.com/example/radar-fixture/releases/tag/v1.\#(id).0","draft":false,"prerelease":false,"body":""}"# }
        Stub.routes[Self.relURL] = .init(body: Data("[\(rel(1))]".utf8))
        _ = await engine.check(sourceID: s.id!)
        try await store.db.write { try $0.execute(sql: "UPDATE watch SET status = 'paused' WHERE id = ?", arguments: [w.id]) }
        Stub.routes[Self.relURL] = .init(body: Data("[\(rel(2)),\(rel(1))]".utf8))
        var o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0)                      // paused: nothing reported
        try await store.db.write { try $0.execute(sql: "UPDATE watch SET status = 'active' WHERE id = ?", arguments: [w.id]) }
        Stub.routes[Self.relURL] = .init(body: Data("[\(rel(3)),\(rel(2)),\(rel(1))]".utf8))
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.map { $0.title }, ["v1.3.0"])  // resumed: only what is new since, not the paused backlog
    }
}

final class RegressionTests: Base {
    let searchURL = "https://api.github.com/search/repositories"
    func ago(_ days: Double) -> String { Fetcher.iso.string(from: Date().addingTimeInterval(-days * 86400)) }
    func repo(_ id: Int, _ name: String, stars: Int, age: Double = 20, desc: String = "An agent framework for tools", forks: Int? = nil) -> String {
        #"{"id":\#(id),"full_name":"\#(name)","html_url":"https://github.com/\#(name)","description":"\#(desc)","stargazers_count":\#(stars),"forks_count":\#(forks ?? max(1, stars / 10)),"language":"Go","topics":[],"created_at":"\#(ago(age))","pushed_at":"\#(ago(0))","fork":false,"archived":false}"#
    }
    func serve(_ repos: [String]) { Stub.routes[searchURL] = .init(body: Data(#"{"items":[\#(repos.joined(separator: ","))]}"#.utf8)) }
    let ghSpec = SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "gh")

    // same page title, new content each time: every real change is an event, a repeat check is not
    func testSameTitlePageChangesAllReported() async throws {
        func page(_ body: String) -> Data { Data("<html><head><title>Pricing</title></head><body><article>\(body) plan details for everyone</article></body></html>".utf8) }
        let (_, s) = try watch(WatchPlan(type: .webpage, title: "p"), SourceSpec(kind: .web, endpoint: "https://p.test/page", name: "page"))
        Stub.routes["https://p.test/page"] = .init(body: page("Starter costs 10 dollars"))
        _ = await engine.check(sourceID: s.id!)
        Stub.routes["https://p.test/page"] = .init(body: page("Starter costs 12 dollars"))
        var o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 1)
        Stub.routes["https://p.test/page"] = .init(body: page("Starter costs 15 dollars"))
        o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 1)          // same title as the first event, still new
        o = await engine.check(sourceID: s.id!); XCTAssertEqual(o.events.count, 0)
        XCTAssertEqual(try events().count, 2)
        XCTAssertEqual(Set(try events().map { $0.afterSnippet ?? "" }).count, 2)
    }

    func testSameTitleSameSourceNotMerged_OtherSourceMerged() async throws {
        func feed(_ items: [(String, String)]) -> Data {
            Data(("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>" + items.map { "<item><title>\($0.0)</title><link>\($0.1)</link></item>" }.joined() + "</channel></rss>").utf8)
        }
        let t = "Big agent runtime launch today"
        let (w, a) = try watch(WatchPlan(type: .topic, title: "x"), SourceSpec(kind: .rss, endpoint: "https://a.test/feed", name: "A"))
        let b = try store.attach(watchID: w.id!, spec: SourceSpec(kind: .rss, endpoint: "https://b.test/feed", name: "B"))
        Stub.routes["https://a.test/feed"] = .init(body: feed([("old a", "https://a.test/0")])); Stub.routes["https://b.test/feed"] = .init(body: feed([("old b", "https://b.test/0")]))
        _ = await engine.check(sourceID: a.id!); _ = await engine.check(sourceID: b.id!)
        Stub.routes["https://a.test/feed"] = .init(body: feed([(t, "https://a.test/1"), ("old a", "https://a.test/0")]))
        Stub.routes["https://b.test/feed"] = .init(body: feed([(t, "https://b.test/9"), ("old b", "https://b.test/0")]))
        do { let c = await engine.check(sourceID: a.id!).events.count; XCTAssertEqual(c, 1) }
        do { let c = await engine.check(sourceID: b.id!).events.count; XCTAssertEqual(c, 0) }               // other source, same story: merged
        XCTAssertEqual(try events()[0].evidence.count, 2)
        // the same source reusing a title for a different link is a different item
        Stub.routes["https://a.test/feed"] = .init(body: feed([(t, "https://a.test/2"), (t, "https://a.test/1"), ("old a", "https://a.test/0")]))
        do { let c = await engine.check(sourceID: a.id!).events.count; XCTAssertEqual(c, 1) }
    }

    // 12 → 300 stars: found once; further growth and unchanged checks stay quiet; each watch uses its own bar
    func testStarThresholdCrossing() async throws {
        var p1 = WatchPlan(type: .topic, title: "low"); p1.minStars = 100; p1.include = ["agent"]
        var p2 = WatchPlan(type: .topic, title: "high"); p2.minStars = 500; p2.include = ["agent"]
        let (w1, s) = try watch(p1, ghSpec)
        let w2 = try store.createWatch(plan: p2, text: "t", sources: [])
        _ = try store.attach(watchID: w2.id!, spec: ghSpec)
        serve([repo(1, "o/rocket", stars: 12), repo(2, "o/steady", stars: 40), repo(3, "o/already", stars: 400)])
        var o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.count, 0)                                                   // baseline: nothing, even o/already
        serve([repo(1, "o/rocket", stars: 300), repo(2, "o/steady", stars: 60), repo(3, "o/already", stars: 450)])
        o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.map { "\($0.watchID):\($0.title)" }, ["\(w1.id!):o/rocket"])  // 300 ≥ 100 yes, ≥ 500 no; steady 60 < 100; already was above before
        XCTAssertTrue(o.events[0].reason.contains("★12 → ★300"))
        serve([repo(1, "o/rocket", stars: 320), repo(2, "o/steady", stars: 60), repo(3, "o/already", stars: 450)])
        do { let c = await engine.check(sourceID: s.id!).events.count; XCTAssertEqual(c, 0) }               // no repeat for the same bar
        serve([repo(1, "o/rocket", stars: 700), repo(2, "o/steady", stars: 60), repo(3, "o/already", stars: 450)])
        let hi = await engine.check(sourceID: s.id!)
        XCTAssertEqual(hi.events.map { $0.watchID }, [w2.id!])                              // crosses the high watch's bar once
        XCTAssertEqual(try store.sync { try Entry.fetchOne($0, sql: "SELECT * FROM entry WHERE title = 'o/rocket'")?.meta["stars"] }, "700")   // metrics kept current
    }

    func testNotificationRule() {
        var topic = WatchPlan(type: .topic, title: "t")
        for k in ["newProject", "majorUpdate"] { XCTAssertTrue(Engine.shouldNotify(plan: topic, kind: k)) }
        for k in ["update", "pageChange"] { XCTAssertFalse(Engine.shouldNotify(plan: topic, kind: k)) }
        XCTAssertTrue(Engine.shouldNotify(plan: WatchPlan(type: .feed, title: "f"), kind: "update"))   // single-feed watch: its articles are the point
        topic.notify = false
        XCTAssertFalse(Engine.shouldNotify(plan: topic, kind: "newProject"))                           // user's switch wins
    }

    // "排除 RAG" typed after the fact must filter what arrives next
    func testNaturalLanguageExcludeTakesEffect() async throws {
        var plan = WatchPlan(type: .topic, title: "t"); plan.include = ["agent"]; plan.minStars = 10
        let (w, s) = try watch(plan, ghSpec)
        serve([])
        _ = await engine.check(sourceID: s.id!)
        let edited = try XCTUnwrap(PlanParser.applyEdit("也关注 MCP，排除 RAG", to: plan))
        try await store.db.write { var x = try Watch.fetchOne($0, key: w.id!)!; x.plan = edited; try x.update($0) }
        serve([repo(1, "o/ragbot", stars: 80, desc: "Agent with RAG pipeline over docs"), repo(2, "o/mcpkit", stars: 80, desc: "MCP server toolkit"),
               repo(3, "o/runner", stars: 80, desc: "Agent runtime for tools"), repo(4, "o/mgmt", stars: 80, desc: "Project management dashboard")])
        let o = await engine.check(sourceID: s.id!)
        XCTAssertEqual(o.events.map { $0.title }.sorted(), ["o/mcpkit", "o/runner"])         // RAG out, MCP in, "management" is not "agent"
    }

    func testKeywordMatching() {
        XCTAssertTrue(Keywords.matches("Agentic workflows", any: ["agent"]))
        XCTAssertFalse(Keywords.matches("Project management suite", any: ["agent"]))
        XCTAssertFalse(Keywords.matches("a paint tool", any: ["ai"]))
        XCTAssertTrue(Keywords.matches("topics: local-llm ollama", any: ["本地模型"]))
        XCTAssertFalse(Keywords.matches("Local news and weather", any: ["本地模型"]))
    }

    // an article linking a project we already reported adds evidence, not a second alert
    func testArticleAboutKnownRepoMerges() async throws {
        var plan = WatchPlan(type: .topic, title: "t"); plan.include = ["agent"]; plan.minStars = 10
        let (w, g) = try watch(plan, ghSpec)
        let blog = try store.attach(watchID: w.id!, spec: SourceSpec(kind: .rss, endpoint: "https://blog.test/feed", name: "blog"))
        serve([]); Stub.routes["https://blog.test/feed"] = .init(body: Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title></channel></rss>".utf8))
        _ = await engine.check(sourceID: g.id!); _ = await engine.check(sourceID: blog.id!)
        serve([repo(1, "o/newagent", stars: 80)])
        do { let c = await engine.check(sourceID: g.id!).events.count; XCTAssertEqual(c, 1) }
        Stub.routes["https://blog.test/feed"] = .init(body: Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title><item><title>Meet newagent, a fresh agent runtime</title><link>https://blog.test/p1</link><description>Code at https://github.com/o/newagent today</description></item></channel></rss>".utf8))
        do { let c = await engine.check(sourceID: blog.id!).events.count; XCTAssertEqual(c, 0) }
        XCTAssertEqual(try events().count, 1); XCTAssertEqual(try events()[0].evidence.count, 2)
    }

    // project-quality rules on real-looking metadata: tag-only matches, inflated stars
    func testGitHubQualityRules() {
        var plan = WatchPlan(type: .topic, title: "t"); plan.include = ["MCP"]
        func verdict(_ title: String, _ desc: String, topics: String, stars: Int, forks: Int) -> Bool {
            let e = Entry(id: 1, sourceID: 1, externalKey: "1", canonicalURL: "https://github.com/\(title)", title: title, summary: desc, text: "", contentHash: "",
                          firstSeenAt: Date(), publishedAt: Date().addingTimeInterval(-20 * 86400),
                          meta: ["stars": "\(stars)", "forks": "\(forks)", "topics": topics])
            return Engine.evaluate(plan: plan, kind: .githubSearch, entry: e, change: .new) != nil
        }
        XCTAssertTrue(verdict("a/srv", "MCP server for GitHub issues", topics: "mcp", stars: 300, forks: 30))
        XCTAssertTrue(verdict("a/agentkit", "Toolkit for LLM agents", topics: "mcp,agents", stars: 300, forks: 30))   // tag + reads as AI work
        XCTAssertFalse(verdict("a/cad", "Parametric 3D CAD in Rust", topics: "mcp,cad", stars: 5000, forks: 400))     // tag only, not AI
        XCTAssertFalse(verdict("a/farm", "MCP server for everything", topics: "mcp", stars: 1200, forks: 5))          // 1200 stars, 5 forks
        XCTAssertFalse(verdict("a/empty", "", topics: "mcp", stars: 300, forks: 30))
    }
}

final class StabilityTests: Base {
    let searchURL = "https://api.github.com/search/repositories"
    func ago(_ d: Double) -> String { Fetcher.iso.string(from: Date().addingTimeInterval(-d * 86400)) }
    func repoJSON(_ stars: Int, age: Double) -> String {
        #"{"items":[{"id":7,"full_name":"o/proj","html_url":"https://github.com/o/proj","description":"A small agent runtime","stargazers_count":\#(stars),"forks_count":3,"language":"Go","topics":[],"created_at":"\#(ago(age))","pushed_at":"\#(ago(0))","fork":false,"archived":false}]}"#
    }
    func rel(_ id: Int, _ tag: String) -> String { #"{"id":\#(id),"tag_name":"\#(tag)","name":"\#(tag)","html_url":"https://github.com/o/proj/releases/tag/\#(tag)","draft":false,"prerelease":false,"body":"Agent runtime notes. Full changelog https://github.com/o/proj/compare/a...b"}"# }
    func feed(_ items: [(String, String)]) -> Data {
        Data(("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>" + items.map { "<item><title>\($0.0)</title><link>https://blog.test/\($0.1)</link><description>see https://github.com/o/proj</description></item>" }.joined() + "</channel></rss>").utf8)
    }

    // one project, several things happening to it over days: each is its own event; coverage of the same thing joins it
    func testSameProjectDifferentHappeningsStaySeparate() async throws {
        var plan = WatchPlan(type: .topic, title: "t"); plan.include = ["agent"]; plan.minStars = 50
        let (w, g) = try watch(plan, SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "search"))
        let r = try store.attach(watchID: w.id!, spec: SourceSpec(kind: .githubReleases, endpoint: "o/proj", name: "releases"))
        let b = try store.attach(watchID: w.id!, spec: SourceSpec(kind: .rss, endpoint: "https://blog.test/feed", name: "blog"))
        let relURL = "https://api.github.com/repos/o/proj/releases"
        Stub.routes[searchURL] = .init(body: Data(#"{"items":[]}"#.utf8)); Stub.routes[relURL] = .init(body: Data("[\(rel(1, "v0.9.0"))]".utf8))
        Stub.routes["https://blog.test/feed"] = .init(body: feed([("old news", "old")]))
        for id in [g.id!, r.id!, b.id!] { _ = await engine.check(sourceID: id) }

        // day 1: discovered, and a blog post covers it
        Stub.routes[searchURL] = .init(body: Data(repoJSON(80, age: 3).utf8))
        var evs = await engine.check(sourceID: g.id!); XCTAssertEqual(evs.events.map { $0.kind }, ["newProject"])
        Stub.routes["https://blog.test/feed"] = .init(body: feed([("Meet proj, a small runtime for agents", "meet"), ("old news", "old")]))
        evs = await engine.check(sourceID: b.id!); XCTAssertEqual(evs.events.count, 0)                       // coverage of the discovery: merged
        // day 2: v1.0.0 is released, and an announcement post
        Stub.routes[relURL] = .init(body: Data("[\(rel(2, "v1.0.0")),\(rel(1, "v0.9.0"))]".utf8))
        evs = await engine.check(sourceID: r.id!); XCTAssertEqual(evs.events.count, 1)                       // not swallowed by the discovery event
        Stub.routes["https://blog.test/feed"] = .init(body: feed([("Announcing proj v1.0 for agent builders", "v1"), ("Meet proj, a small runtime for agents", "meet"), ("old news", "old")]))
        evs = await engine.check(sourceID: b.id!); XCTAssertEqual(evs.events.count, 0)                       // same happening: merged
        // day 3: a new minor release and a launch post about a feature (no version in it)
        Stub.routes[relURL] = .init(body: Data("[\(rel(3, "v1.1.0")),\(rel(2, "v1.0.0")),\(rel(1, "v0.9.0"))]".utf8))
        evs = await engine.check(sourceID: r.id!); XCTAssertEqual(evs.events.count, 1)
        Stub.routes["https://blog.test/feed"] = .init(body: feed([("proj launch: agent memory is here", "mem"), ("Announcing proj v1.0 for agent builders", "v1"), ("Meet proj, a small runtime for agents", "meet"), ("old news", "old")]))
        evs = await engine.check(sourceID: b.id!); XCTAssertEqual(evs.events.count, 1)                       // a different happening of the same project
        // re-reading everything changes nothing
        for id in [g.id!, r.id!, b.id!] { let o = await engine.check(sourceID: id); XCTAssertEqual(o.events.count, 0) }
        let all = try events()
        XCTAssertEqual(all.count, 4)                                                                         // discovery, v1.0.0, v1.1.0, feature post
        XCTAssertEqual(all.map { $0.evidence.count }, [2, 2, 1, 1])                                         // discovery+blog, v1.0.0+announcement
    }

    // timer tick, wake-up and a click arriving while a source is being read: one request
    func testOverlappingChecksFetchOnce() async throws {
        let (_, s) = try watch(WatchPlan(type: .feed, title: "f"), SourceSpec(kind: .rss, endpoint: "https://slow.test/feed", name: "slow"))
        Stub.routes["https://slow.test/feed"] = .init(body: feed([("a", "a")])); Stub.delay = 0.6
        async let a = engine.check(sourceID: s.id!), b = engine.check(sourceID: s.id!), c = engine.check(sourceID: s.id!)
        let outs = await [a, b, c]
        XCTAssertEqual(outs.filter { $0.alreadyRunning }.count, 2)
        XCTAssertEqual(Stub.hits["https://slow.test/feed"], 1)
        XCTAssertFalse(engine.isChecking(s.id!))                                                             // finished: free for the next run
        Stub.delay = 0
        let again = await engine.check(sourceID: s.id!); XCTAssertFalse(again.alreadyRunning)
        let due = try store.sync { try Source.fetchOne($0, key: s.id!)!.nextDueAt }
        XCTAssertGreaterThan(due, Date())                                                                    // next run scheduled
    }

    // a topic whose only project is 5 days old with 8 stars is still a working source; the normal case costs one request
    func testSampleSearchFallsBackToFreshWindow() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        let f = Fetcher(session: URLSession(configuration: cfg)); f.searchGap = 0
        let disc = Discovery(fetcher: f, store: store)
        Stub.dynamic = { url in
            let q = url.absoluteString.removingPercentEncoding ?? ""
            return .init(body: Data((q.contains("30..400") ? #"{"items":[]}"# : self.repoJSON(8, age: 5)).utf8))
        }
        let spec = SourceSpec(kind: .githubSearch, endpoint: "topic:tiny", name: "tiny")
        let c = await disc.probe(spec)
        XCTAssertTrue(c.ok); XCTAssertEqual(c.samples, ["• o/proj"].map { String($0.dropFirst(2)) })
        XCTAssertEqual(Stub.hits.values.reduce(0, +), 2)                                                     // the cheap query, then the fresh window
        Stub.hits = [:]; Stub.dynamic = { _ in .init(body: Data(self.repoJSON(100, age: 30).utf8)) }
        _ = await disc.probe(spec)
        XCTAssertEqual(Stub.hits.values.reduce(0, +), 1)                                                     // no fallback when the first query finds something
    }

    // scheduled checks read the sources directly; the web search API is for discovery only
    func testScheduledChecksDoNotCallSearch() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        let f = Fetcher(session: URLSession(configuration: cfg), searchKey: { "k" }); f.searchGap = 0
        let eng = Engine(store: store, fetcher: f)
        _ = try watch(WatchPlan(type: .feed, title: "f"), SourceSpec(kind: .rss, endpoint: "https://a.test/feed", name: "a"))
        Stub.routes["https://a.test/feed"] = .init(body: feed([("x", "x")]))
        _ = await eng.checkDue(force: true); _ = await eng.checkDue(force: true)
        XCTAssertTrue(Stub.hits.keys.allSatisfy { !$0.contains("exa.ai") })
        XCTAssertEqual(Stub.hits["https://a.test/feed"], 2)
    }
}
