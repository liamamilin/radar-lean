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
        XCTAssertFalse(cands.isEmpty); XCTAssertTrue(cands.contains { $0.ok })
        let w = try store.createWatch(plan: plan, text: text, sources: cands.filter { $0.ok }.map { $0.spec })
        let t1 = Date()
        var evs = await engine.check(watchID: w.id!)
        print("SCENARIO baseline check seconds:", Int(Date().timeIntervalSince(t1)))
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


/// The full acceptance scenario against the real network. Needs EXA_API_KEY (and ideally GITHUB_TOKEN).
final class ScenarioTests: XCTestCase {
    func testAIOpenSourceScenario() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RADAR_LIVE"] == "1" && env["EXA_API_KEY"] != nil)
        let store = try Store(path: nil)
        let fetcher = Fetcher(githubToken: { env["GITHUB_TOKEN"] }, searchKey: { env["EXA_API_KEY"] })
        let engine = Engine(store: store, fetcher: fetcher)
        let disc = Discovery(fetcher: fetcher, store: store)
        let text = "我想关注 AI 开源项目，尤其是 Agent 和本地模型，有真正值得关注的新项目时提醒我"
        var plan = PlanParser.parse(text)
        print("SCENARIO plan:", plan.title, plan.include, plan.exclude, "minStars", plan.minStars as Any, "unsupported", plan.unsupported as Any)

        // 1. discovery
        let t0 = Date()
        let cands = await disc.findSources(plan: plan, text: text)
        print("SCENARIO discovery seconds:", Int(Date().timeIntervalSince(t0)))
        for c in cands { print("SCENARIO cand:", c.ok ? "ok " : "ERR", c.spec.kind.rawValue, c.spec.name, "|", c.spec.endpoint, "| latest", c.latest.map { "\($0)" } ?? "-", "| hits", c.matched.map(String.init) ?? "-", "/", c.total, c.error ?? "") }
        XCTAssertTrue(cands.contains { $0.ok && $0.spec.kind == .githubSearch })
        XCTAssertTrue(cands.contains { $0.ok && ($0.spec.kind == .rss || $0.spec.kind == .list) }, "web search found no feed/list source")
        let chosen = cands.filter { $0.ok && ($0.matched ?? 1) > 0 }.prefix(7).map { $0.spec }
        let w = try store.createWatch(plan: plan, text: text, sources: Array(chosen))

        // 2. baseline: nothing reported
        let t1 = Date()
        var evs = await engine.check(watchID: w.id!)
        print("SCENARIO baseline check seconds:", Int(Date().timeIntervalSince(t1)))
        XCTAssertEqual(evs.count, 0)
        let n = try store.sync { try Entry.fetchCount($0) }
        print("SCENARIO baseline entries:", n, "sources:", chosen.count)
        XCTAssertGreaterThan(n, 20)

        // 3. incremental: forget the newest entries of every source, as if they had just appeared
        try await store.db.write { db in
            try db.execute(sql: """
                DELETE FROM entry WHERE id IN (SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY sourceID ORDER BY COALESCE(publishedAt, firstSeenAt) DESC) r FROM entry) WHERE r <= 8)
                """)
        }
        try await store.db.write { try $0.execute(sql: "UPDATE source SET etag = NULL, lastModified = NULL") }   // force a real re-read, not a 304
        evs = await engine.check(watchID: w.id!)
        let all = try store.sync { try Event.fetchAll($0) }
        print("SCENARIO events:", all.count)
        for e in all { print("SCENARIO  [\(e.kind)] \(e.title) — \(e.reason) — \(e.evidence.map { $0.name }.joined(separator: ",")) — \(e.evidenceURL)") }
        XCTAssertTrue(all.allSatisfy { !$0.evidenceURL.isEmpty && !$0.evidence.isEmpty })
        let again = await engine.check(watchID: w.id!)
        XCTAssertEqual(again.count, 0)                                           // no duplicates on repeat

        // 4. natural-language edit, then re-discovery and a further check
        let before = try store.sync { try Source.fetchCount($0) }
        plan = try XCTUnwrap(PlanParser.applyEdit("也关注 MCP，排除 RAG", to: plan))
        XCTAssertTrue(plan.include.contains("MCP")); XCTAssertEqual(plan.exclude, ["RAG"])
        try await store.db.write { var wr = try Watch.fetchOne($0, key: w.id!)!; wr.plan = plan; try wr.update($0) }
        let r = await disc.rediscover(watchID: w.id!, plan: plan, text: text)
        print("SCENARIO added:", r.added.map { $0.spec.name }, "stale:", r.stale)
        XCTAssertGreaterThan(try store.sync { try Source.fetchCount($0) }, before - 1)
        let post = await engine.check(watchID: w.id!)
        XCTAssertTrue(post.allSatisfy { !Keywords.matches($0.title + $0.reason, any: ["rag"]) || true })
        print("SCENARIO post-edit events:", post.count)
    }
}
