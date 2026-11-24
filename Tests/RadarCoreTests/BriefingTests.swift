import XCTest
@testable import RadarCore

/// Answers from the prompt itself, and records how many calls were made.
final class FakeChat: ChatClient, @unchecked Sendable {
    nonisolated(unsafe) var calls: [[ChatMessage]] = []
    func models() async throws -> [OllamaModel] { [OllamaModel(name: "fake", thinking: false)] }
    func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        calls.append(messages)
        let isOverview = messages[0].content.contains("简报编辑")
        return AsyncThrowingStream { c in
            c.yield(isOverview ? "整体有动静 [S1]\n- 【活跃】有新项目" : "概括一句\n- **agent-kit**：新项目 [S1]")
            c.finish()
        }
    }
}

final class BriefingTests: Base {
    var activeID: Int64 = 0, quietID: Int64 = 0

    override func setUp() async throws {
        try await super.setUp()
        let (a, s) = try watch(WatchPlan(type: .topic, title: "活跃"), SourceSpec(kind: .githubSearch, endpoint: "topic:a", name: "GitHub · A"))
        let (q, _) = try watch(WatchPlan(type: .topic, title: "安静"), SourceSpec(kind: .githubSearch, endpoint: "topic:q", name: "GitHub · Q"))
        activeID = a.id!; quietID = q.id!
        try await store.db.write { db in
            var e = Entry(id: nil, sourceID: s.id!, externalKey: "agent-kit", canonicalURL: "https://github.com/x/agent-kit", title: "agent-kit", summary: "An agent toolkit", text: "An agent toolkit",
                          contentHash: "h", firstSeenAt: Date(), publishedAt: Date().addingTimeInterval(-3600), meta: ["stars": "50"])
            try e.insert(db)
        }
    }

    func testOnlyWatchesWithNewContentCostAModelCall() async throws {
        let chat = FakeChat()
        let b = try await Briefer(store: store).generate(client: chat, model: OllamaModel(name: "fake", thinking: false), auto: true)
        XCTAssertEqual(chat.calls.count, 2)                       // one section + the overview; the quiet watch is free
        XCTAssertEqual(b.sections.map { $0.title }, ["活跃", "安静"])
        XCTAssertFalse(b.sections[0].isEmpty); XCTAssertTrue(b.sections[1].isEmpty)
        XCTAssertTrue(b.sections[0].text.contains("agent-kit"))
        XCTAssertFalse(b.overview.contains("[S1]"))               // the overview has no citations to resolve
        XCTAssertTrue(b.auto); XCTAssertEqual(b.updateCount, 1)
    }

    func testNothingNewMeansNoModelCallAtAll() async throws {
        try await store.db.write { try $0.execute(sql: "DELETE FROM entry") }
        let chat = FakeChat()
        let b = try await Briefer(store: store).generate(client: chat, model: OllamaModel(name: "fake", thinking: false), auto: false)
        XCTAssertEqual(chat.calls.count, 0)
        XCTAssertTrue(b.overview.contains("没有新内容")); XCTAssertEqual(b.updateCount, 0)
    }

    func testThereIsOneBriefingPerDayAndSavingReplacesIt() async throws {
        let br = Briefer(store: store)
        let m = OllamaModel(name: "fake", thinking: false)
        let yesterday = Date().addingTimeInterval(-86400 * 2)
        try br.save(try await br.generate(client: FakeChat(), model: m, now: yesterday, auto: true))
        var today = try await br.generate(client: FakeChat(), model: m, auto: false)
        try br.save(today)
        today.overview = "改过的总览"; try br.save(today)                        // the same day again: replaced, not added
        let days = try br.days()
        XCTAssertEqual(days.count, 2); XCTAssertEqual(days[0].day, Briefer.dayKey(Date())); XCTAssertEqual(days[0].overview, "改过的总览")
        XCTAssertTrue(br.has(day: Briefer.dayKey(Date()))); XCTAssertFalse(br.has(day: "1999-01-01"))
        XCTAssertEqual(days[0].sections.count, 2)                                 // round-trips through JSON
    }

    func testOneWatchCanBeGeneratedWithoutTouchingTheOthers() async throws {
        let br = Briefer(store: store), chat = FakeChat()
        let m = OllamaModel(name: "fake", thinking: false)
        let w = try br.watches().first { $0.id == activeID }!
        let s = try await br.makeSection(watch: w, client: chat, model: m)
        XCTAssertEqual(chat.calls.count, 1)                                        // exactly this watch, no overview, no other watch
        XCTAssertTrue(s.isGenerated); XCTAssertFalse(s.isEmpty)
        let quiet = try await br.makeSection(watch: try br.watches().first { $0.id == quietID }!, client: chat, model: m)
        XCTAssertEqual(chat.calls.count, 1)                                        // nothing new: no call, but it counts as generated
        XCTAssertTrue(quiet.isGenerated); XCTAssertTrue(quiet.isEmpty)

        var b = Briefing(day: Briefer.dayKey(Date()), createdAt: Date(), model: "fake", auto: false, overview: "", sections: [])
        b.put(quiet); b.put(s)
        XCTAssertEqual(b.sections.map { $0.title }, ["安静", "活跃"])
        var redo = s; redo.text = "重新整理后"; b.put(redo)
        XCTAssertEqual(b.sections.count, 2); XCTAssertEqual(b.section(activeID)?.text, "重新整理后")   // replaced in place
    }

    func testOverviewGoesStaleWhenASectionIsWrittenAfterIt() {
        var b = Briefing(day: "2026-10-31", createdAt: Date(), model: "m", auto: false, overview: "o", overviewAt: Date(), sections: [])
        XCTAssertTrue(b.hasOverview); XCTAssertFalse(b.overviewIsStale)
        b.put(BriefingSection(watchID: 1, title: "a", text: "t", evidence: [], events: 0, entries: 0, generatedAt: Date().addingTimeInterval(60)))
        XCTAssertTrue(b.overviewIsStale)
        XCTAssertFalse(Briefing(day: "d", createdAt: Date(), model: "m", auto: false, overview: "", sections: []).hasOverview)
    }

    func testABriefingFromBeforeSectionTimesIsNotTreatedAsMissing() {
        let t = Date().addingTimeInterval(-3600)
        let old = Briefing(day: "2026-10-31", createdAt: t, model: "m", auto: true, overview: "旧总览",
                           sections: [BriefingSection(watchID: 1, title: "a", text: "x", evidence: [], events: 0, entries: 0)])
        let up = Briefer.upgraded(old)
        XCTAssertTrue(up.hasOverview); XCTAssertTrue(up.sections[0].isGenerated); XCTAssertFalse(up.overviewIsStale)   // so the schedule does not redo it
    }

    func testOverviewKeepsNoHeadingOfItsOwn() {
        XCTAssertEqual(Briefer.cleanOverview("**总览**\n整体有动静 [S1]\n- 【A】新项目"), "整体有动静\n- 【A】新项目")
        XCTAssertEqual(Briefer.cleanOverview("## 总览：\n正文"), "正文")
        XCTAssertEqual(Briefer.cleanOverview("总览显示今天很忙"), "总览显示今天很忙")   // a sentence that merely starts with the word stays
    }

    func testStripCitationsHandlesGroupsAndFullWidthBrackets() {
        XCTAssertEqual(Briefer.stripCitations("好 [S1] 和 [S2, S3] 以及【S4】。"), "好 和 以及。")
    }
}
