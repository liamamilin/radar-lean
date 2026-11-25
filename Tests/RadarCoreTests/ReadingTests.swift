import XCTest
import CoreGraphics
import CoreText
@testable import RadarCore

final class ReadingTests: Base {
    func fetcher() -> Fetcher { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Stub.self]; return Fetcher(session: URLSession(configuration: c)) }
    override func setUp() async throws { try await super.setUp(); Stub.routes = [:]; Stub.dynamic = nil; Stub.delay = 0 }

    private func makePDF(text: String, title: String) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 40, y: 40, width: 532, height: 700), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func testLinksAreFoundWithoutTrailingPunctuationAndCapped() {
        XCTAssertEqual(RadarAssistant.urls(in: "帮我读读 https://example.com/a?x=1。还有 (https://github.com/o/r), 以及 https://example.com/a?x=1"),
                       ["https://example.com/a?x=1", "https://github.com/o/r"])
        XCTAssertEqual(RadarAssistant.urls(in: "1 https://a.io 2 https://b.io 3 https://c.io 4 https://d.io").count, 3)
        XCTAssertTrue(RadarAssistant.urls(in: "没有链接的问题").isEmpty)
    }

    func testAPageIsReadFromItsArticleBody() async throws {
        let html = "<html><head><title>Speculative decoding</title></head><body><nav>menu</nav><article>" + String(repeating: "Draft models propose tokens and the target model verifies them. ", count: 5) + "</article></body></html>"
        Stub.routes["https://blog.example/post"] = .init(headers: ["Content-Type": "text/html"], body: Data(html.utf8))
        let a = try await fetcher().readArticle("https://blog.example/post")
        XCTAssertEqual(a.title, "Speculative decoding")
        XCTAssertTrue(a.text.contains("Draft models propose"))
        XCTAssertFalse(a.text.contains("menu"))
    }

    func testAGithubRepoLinkReadsDescriptionAndReadme() async throws {
        Stub.dynamic = { url in   // exact paths: the stub's prefix routes would let /repos/o/r also answer /repos/o/r/readme
            switch url.absoluteString {
            case "https://api.github.com/repos/o/r/readme": return .init(body: Data("# r\nRuns models locally.".utf8))
            case "https://api.github.com/repos/o/r": return .init(body: Data(#"{"description":"Local runner","stargazers_count":120,"language":"Rust","html_url":"https://github.com/o/r","topics":["llm"]}"#.utf8))
            default: return nil
            }
        }
        let a = try await fetcher().readArticle("https://github.com/o/r")
        XCTAssertEqual(a.title, "o/r")
        XCTAssertTrue(a.text.contains("描述：Local runner")); XCTAssertTrue(a.text.contains("★120")); XCTAssertTrue(a.text.contains("Runs models locally."))
    }

    func testPdfAndFailuresAreReportedNotInvented() async throws {
        let validPDF = makePDF(text: "International AI Safety Report 2026 summarizes capability progress and systemic risk mitigation across frontier models.", title: "AI Safety Report 2026")
        Stub.routes["https://x.example/report.pdf"] = .init(headers: ["Content-Type": "application/pdf"], body: validPDF)
        let pdfArt = try await fetcher().readArticle("https://x.example/report.pdf")
        XCTAssertEqual(pdfArt.title, "AI Safety Report 2026")
        XCTAssertTrue(pdfArt.text.contains("International AI Safety Report 2026"))

        Stub.routes["https://x.example/paper.pdf"] = .init(headers: ["Content-Type": "application/pdf"], body: Data("%PDF".utf8))
        do { _ = try await fetcher().readArticle("https://x.example/paper.pdf"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("PDF")) }
        Stub.routes["https://x.example/gone"] = .init(status: 404)
        do { _ = try await fetcher().readArticle("https://x.example/gone"); XCTFail() } catch {}
    }

    func testJsRenderedFallbackInReadArticle() async throws {
        Stub.routes["https://spa.example/post"] = .init(headers: ["Content-Type": "text/html"], body: Data("<html><body><div id='root'></div></body></html>".utf8))
        let f = fetcher()
        f.jsRenderer = { _ in "<html><head><title>SPA Post</title></head><body><article>Rendered dynamically with JavaScript and contains full article text for Radar.</article></body></html>" }
        let a = try await f.readArticle("https://spa.example/post")
        XCTAssertEqual(a.title, "SPA Post")
        XCTAssertTrue(a.text.contains("Rendered dynamically with JavaScript"))
    }

    func testAPageIsReadInFullAndPutsTheModelInReadingMode() {
        let page = RadarAssistant.pageEvidence(Fetcher.Article(title: "T", url: "https://x.io/a", text: String(repeating: "正文。", count: 1500)), id: "S1")
        let other = Evidence(id: "S2", title: "o", url: "https://x.io/o", origin: "w", date: nil, text: String(repeating: "x", count: 900), meta: "", isEvent: false, kind: "entry")
        let block = RadarAssistant.block([page, other])
        XCTAssertTrue(block.contains("网页正文（用户提供的链接）"))
        XCTAssertGreaterThan(block.count, 4000)                                   // not skimmed to the 500-char excerpt other items get
        let m = RadarAssistant.askMessages(history: [], question: "帮我读一下 https://x.io/a", evidence: [page], scope: "全部关注事项")
        XCTAssertTrue(m[0].content.contains("一句话结论")); XCTAssertTrue(m[0].content.contains("值得追问的问题"))
        XCTAssertFalse(RadarAssistant.askMessages(history: [], question: "q", evidence: [other], scope: "s")[0].content.contains("一句话结论"))
    }

    func testFollowUpsAboutAPageAreNotAnsweredWithNothingFound() throws {
        let page = RadarAssistant.pageEvidence(Fetcher.Article(title: "T", url: "https://x.io/a", text: "文章内容"), id: "S1")
        let r = try RadarAssistant(store: store).retrieve(question: "这篇文章讲了什么实验", extraTerms: [], watchID: nil, range: nil, previous: [page])
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.evidence.map { $0.id }, ["S1"])                          // no unrelated stored items mixed in
    }

    func testConversationsAreSavedListedReopenedAndDeleted() throws {
        let cs = ConversationStore(store: store)
        var t = AskTurn(question: "最近一周发现了哪些 AI Agent 项目？这是一个很长很长很长很长很长的问题标题"); t.answer = "答 [S1]"; t.done = true
        t.evidence = [Evidence(id: "S1", title: "a", url: "https://a.io", origin: "o", date: Date(), text: "x", meta: "", isEvent: false, kind: "entry")]
        var interrupted = AskTurn(question: "第二个问题"); interrupted.answer = "半截"
        let id = try XCTUnwrap(try cs.save(id: nil, turns: [t, interrupted], scope: 7))
        XCTAssertEqual(try cs.save(id: id, turns: [t, interrupted], scope: 7), id)   // updates in place
        let hs = try cs.headers()
        XCTAssertEqual(hs.count, 1); XCTAssertTrue(hs[0].title.hasSuffix("…")); XCTAssertLessThanOrEqual(hs[0].title.count, 29)
        let loaded = try XCTUnwrap(try cs.load(id))
        XCTAssertEqual(loaded.scope, 7); XCTAssertEqual(loaded.turns.count, 2)
        XCTAssertEqual(loaded.turns[0].evidence.first?.url, "https://a.io")
        XCTAssertTrue(loaded.turns[1].done)                                       // an interrupted answer is shown as finished, with what it had
        XCTAssertNil(try cs.save(id: nil, turns: [], scope: nil))                  // an empty conversation is never stored
        try cs.delete(id); XCTAssertTrue(try cs.headers().isEmpty)
    }
}
