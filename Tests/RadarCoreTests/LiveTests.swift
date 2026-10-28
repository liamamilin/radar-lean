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
        print("SCENARIO post-edit events:", post.count)
    }
}

/// Real GitHub twice, minutes apart: metrics of known projects must follow reality, and a repo that really crosses the bar alerts once.
final class RecheckTests: XCTestCase {
    func testRealMetricsMoveAndCrossingAlerts() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RADAR_RECHECK"] == "1")
        let store = try Store(path: nil)
        let fetcher = Fetcher(githubToken: { env["GITHUB_TOKEN"] })
        let engine = Engine(store: store, fetcher: fetcher)
        let first = try await fetcher.fetchSearch("topic:ai-agents", cond: [:]).entries
        let stars = first.compactMap { Int($0.meta["stars"] ?? "") }.filter { $0 >= 60 }
        // bar chosen where the most repos sit just below it, so real growth has something to cross
        let bar = (stars.min()!...stars.max()!).max { a, b in stars.filter { $0 < a && $0 >= a - 15 }.count < stars.filter { $0 < b && $0 >= b - 15 }.count }!
        print("RECHECK bar", bar, "repos just below:", stars.filter { $0 < bar && $0 >= bar - 15 }.count)
        var plan = WatchPlan(type: .topic, title: "t"); plan.minStars = bar
        let w = try store.createWatch(plan: plan, text: "t", sources: [SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "gh")])
        var evs = await engine.check(watchID: w.id!)
        XCTAssertEqual(evs.count, 0)
        let before = Dictionary(uniqueKeysWithValues: try store.sync { try Entry.fetchAll($0) }.map { ($0.title, Int($0.meta["stars"] ?? "") ?? 0) })
        try await Task.sleep(nanoseconds: UInt64((Double(env["RADAR_RECHECK_WAIT"] ?? "300") ?? 300) * 1e9))
        try await store.db.write { try $0.execute(sql: "UPDATE source SET nextDueAt = ?", arguments: [Date()]) }
        evs = await engine.check(watchID: w.id!)
        let after = Dictionary(uniqueKeysWithValues: try store.sync { try Entry.fetchAll($0) }.map { ($0.title, Int($0.meta["stars"] ?? "") ?? 0) })
        let moved = after.filter { before[$0.key] != nil && before[$0.key]! != $0.value }
        print("RECHECK tracked", before.count, "→", after.count, "| stars changed on", moved.count, "| new repos", after.count - before.count)
        for (k, v) in moved.sorted(by: { $0.value - before[$0.key]! > $1.value - before[$1.key]! }).prefix(8) { print("RECHECK  \(k): ★\(before[k]!) → ★\(v)") }
        for e in evs { print("RECHECK event [\(e.kind)] \(e.title) — \(e.reason) — \(e.evidenceURL)") }
        XCTAssertGreaterThan(moved.count, 0, "no star count moved in the wait")                 // metrics really are refreshed
        again: do { let r = await engine.check(watchID: w.id!); XCTAssertEqual(r.count, 0) }    // and an immediate re-check stays quiet
    }
}
