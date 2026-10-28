import XCTest
import GRDB
@testable import RadarCore

/// Real HTTP against a local server whose files really change between checks (no stub, no database edits).
final class LocalServerTests: XCTestCase {
    var dir: URL!, server: Process!
    let port = 18765

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("radar-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("search"), withIntermediateDirectories: true)
        server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", dir.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try? server.run()
        try XCTSkipUnless(server.isRunning, "python3 not available")
    }
    override func tearDown() { server?.terminate() }

    func put(_ name: String, _ text: String) throws {
        Thread.sleep(forTimeInterval: 1.1)    // Last-Modified has 1 s resolution; a real site would also change later than the last read
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func repos(_ items: [(Int, String, Int)]) -> String {
        let now = Fetcher.iso.string(from: Date().addingTimeInterval(-20 * 86400))
        return #"{"items":["# + items.map { #"{"id":\#($0.0),"full_name":"\#($0.1)","html_url":"https://github.com/\#($0.1)","description":"An agent framework for tools","stargazers_count":\#($0.2),"forks_count":\#(max(1, $0.2 / 10)),"language":"Go","topics":[],"created_at":"\#(now)","pushed_at":"\#(now)","fork":false,"archived":false}"# }.joined(separator: ",") + "]}"
    }
    func page(_ body: String) -> String { "<html><head><title>Changelog</title></head><body><article>\(body) — details for every user of the tool</article></body></html>" }
    func list(_ n: Int) -> String {
        "<html><body><ul>" + (1...n).map { #"<li><a href="/post-\#($0)">Agent post number \#($0) is out</a></li>"# }.joined() + "</ul></body></html>"
    }
    func feed(_ n: Int) -> String {
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>t</title>" + (1...n).map { "<item><title>Agent post number \($0) is out</title><link>http://127.0.0.1:\(port)/post-\($0)</link></item>" }.joined() + "</channel></rss>"
    }

    func testRealContentChangesEndToEnd() async throws {
        let base = "http://127.0.0.1:\(port)"
        let store = try Store(path: nil)
        let fetcher = Fetcher(); fetcher.githubBase = base
        let engine = Engine(store: store, fetcher: fetcher)
        try put("search/repositories", repos([(1, "o/rocket", 12), (2, "o/steady", 40)]))
        try put("feed.xml", feed(5)); try put("list.html", list(5)); try put("page.html", page("Version 1 notes"))

        var topic = WatchPlan(type: .topic, title: "agents"); topic.include = ["agent"]; topic.minStars = 100
        let w = try store.createWatch(plan: topic, text: "t", sources: [
            SourceSpec(kind: .githubSearch, endpoint: "topic:ai-agents", name: "gh"),
            SourceSpec(kind: .rss, endpoint: "\(base)/feed.xml", name: "feed"),
            SourceSpec(kind: .list, endpoint: "\(base)/list.html", name: "list")])
        let pw = try store.createWatch(plan: WatchPlan(type: .webpage, title: "page"), text: "t", sources: [SourceSpec(kind: .web, endpoint: "\(base)/page.html", name: "page")])

        var evs = await engine.check(watchID: w.id!) + (await engine.check(watchID: pw.id!))
        XCTAssertEqual(evs.count, 0)                                                       // baseline
        func all() throws -> [Event] { try store.sync { try Event.order(Column("id")).fetchAll($0) } }

        // round 1: the page is edited, post 6 appears in both the feed and the list, a project jumps 12 → 300 and another appears
        try put("page.html", page("Version 2 notes")); try put("feed.xml", feed(6)); try put("list.html", list(6))
        try put("search/repositories", repos([(1, "o/rocket", 300), (2, "o/steady", 60), (3, "o/newcomer", 150)]))
        evs = await engine.check(watchID: w.id!) + (await engine.check(watchID: pw.id!))
        let byTitle = Dictionary(uniqueKeysWithValues: try all().map { ($0.title, $0) })
        XCTAssertEqual(Set(byTitle.keys), ["Changelog", "Agent post number 6 is out", "o/rocket", "o/newcomer"])   // steady (60 < 100) stays quiet
        XCTAssertEqual(byTitle["Agent post number 6 is out"]?.evidence.count, 2)            // feed + list, one event
        XCTAssertTrue(byTitle["o/rocket"]!.reason.contains("★12 → ★300"))
        XCTAssertEqual(byTitle["o/rocket"]?.kind, "newProject")
        XCTAssertEqual(evs.count, 4)

        // nothing changed → nothing new
        evs = await engine.check(watchID: w.id!) + (await engine.check(watchID: pw.id!))
        XCTAssertEqual(evs.count, 0)

        // round 2: the same page (same title) changes again, the project keeps growing
        try put("page.html", page("Version 3 notes")); try put("search/repositories", repos([(1, "o/rocket", 340), (2, "o/steady", 130), (3, "o/newcomer", 170)]))
        evs = await engine.check(watchID: w.id!) + (await engine.check(watchID: pw.id!))
        XCTAssertEqual(evs.map { $0.title }.sorted(), ["Changelog", "o/steady"])             // page change is not swallowed; steady crosses 100 now; rocket/newcomer do not repeat
        XCTAssertEqual(try all().count, 6)
        XCTAssertTrue(evs.contains { $0.kind == "pageChange" && ($0.beforeSnippet ?? "").contains("2") && ($0.afterSnippet ?? "").contains("3") })
    }
}
