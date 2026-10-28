import XCTest
import GRDB
@testable import RadarCore

/// Real-network checks. Run with RADAR_LIVE=1 swift test --filter LiveTests
final class LiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RADAR_LIVE"] == "1")
    }

    func testTopicDiscoveryAndReleases() async throws {
        let store = try Store(path: nil)
        let fetcher = Fetcher(githubToken: { ProcessInfo.processInfo.environment["GITHUB_TOKEN"] })
        let engine = Engine(store: store, fetcher: fetcher)
        let disc = Discovery(fetcher: fetcher, store: store)
        let text = "关注 AI 开源项目，尤其是 Agent 和本地模型，排除 AI 绘画"
        let plan = PlanParser.parse(text)
        let cands = await disc.findSources(plan: plan, text: text)
        print("LIVE candidates:", cands.map { ($0.spec.endpoint, $0.ok, $0.samples.prefix(3), $0.error ?? "") })
        XCTAssertFalse(cands.isEmpty); XCTAssertTrue(cands.allSatisfy { $0.ok }, "\(cands.compactMap { $0.error })")
        let w = try store.createWatch(plan: plan, text: text, sources: cands.map { $0.spec })
        var evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(evs.count, 0)
        let n = try store.sync { try Entry.fetchCount($0) }
        print("LIVE discovered repos:", n)
        XCTAssertGreaterThan(n, 0)
        evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(evs.count, 0)
        XCTAssertEqual(try store.sync { try Entry.fetchCount($0) }, n)

        // Releases of a real repo
        var rp = WatchPlan(type: .githubRelease, title: "ollama"); rp.stableOnly = true
        let rw = try store.createWatch(plan: rp, text: "t", sources: [SourceSpec(kind: .githubReleases, endpoint: "ollama/ollama", name: "r")])
        evs = await engine.check(watchID: rw.id!)
        let relCount = try store.sync { try Entry.filter(Column("externalKey") != "").filter(sql: "sourceID = (SELECT id FROM source WHERE kind='githubReleases')").fetchCount($0) }
        print("LIVE ollama releases baseline:", relCount, "events:", evs.count)
        XCTAssertGreaterThan(relCount, 0); XCTAssertEqual(evs.count, 0)
    }

    func testRSSAndHTML() async throws {
        let store = try Store(path: nil)
        let fetcher = Fetcher()
        let engine = Engine(store: store, fetcher: fetcher)
        let disc = Discovery(fetcher: fetcher, store: store)
        // site URL -> feed autodiscovery
        var p = WatchPlan(type: .feed, title: "swift blog"); p.targetURL = "https://www.swift.org/blog/"
        let cands = await disc.findSources(plan: p, text: "")
        print("LIVE swift.org candidates:", cands.map { ($0.spec.kind, $0.spec.endpoint, $0.ok, $0.samples.prefix(2), $0.error ?? "") })
        XCTAssertTrue(cands.contains { $0.spec.kind == .rss && $0.ok })
        let feed = cands.first { $0.spec.kind == .rss && $0.ok }!.spec
        let w = try store.createWatch(plan: p, text: "t", sources: [feed])
        let evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(evs.count, 0)
        XCTAssertGreaterThan(try store.sync { try Entry.fetchCount($0) }, 0)
        // static page
        let page = SourceSpec(kind: .web, endpoint: "https://www.swift.org/install/macos/", name: "install")
        let pc = await disc.probe(page)
        print("LIVE page probe:", pc.ok, pc.samples, pc.error ?? "")
        XCTAssertTrue(pc.ok)
    }
}
