import XCTest
@testable import RadarCore

final class OpenAICompatTests: XCTestCase {
    func client(key: String = "k") -> OpenAICompatClient {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Stub.self]
        return OpenAICompatClient(baseURL: URL(string: "https://llm.example/zen/go/v1/")!, apiKey: key, session: URLSession(configuration: c))
    }
    override func setUp() { Stub.routes = [:]; Stub.dynamic = nil; Stub.delay = 0 }

    func testModelsAreListedSortedWithoutEmbeddings() async throws {
        Stub.routes["https://llm.example/zen/go/v1/models"] = .init(body: Data(#"{"data":[{"id":"glm-5.2"},{"id":"text-embedding-3"},{"id":"kimi-k2.6"}]}"#.utf8))
        let m = try await client().models()
        XCTAssertEqual(m.map { $0.name }, ["glm-5.2", "kimi-k2.6"])
    }

    func testStreamedReplyIsAssembledAndReasoningIsSkipped() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}

        data: {"choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: [DONE]

        """
        Stub.routes["https://llm.example/zen/go/v1/chat/completions"] = .init(body: Data(sse.utf8))
        var out = ""
        for try await p in client().chat(model: OllamaModel(name: "glm-5.2", thinking: false), messages: [ChatMessage(role: "user", content: "hi")]) { out += p }
        XCTAssertEqual(out, "你好")
    }

    func testBadKeyAndMissingKeyAreReportedClearly() async {
        Stub.routes["https://llm.example/zen/go/v1/models"] = .init(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        do { _ = try await client().models(); XCTFail() } catch { XCTAssertEqual(error as? LLMError == nil, false); XCTAssertTrue("\(error)".contains("unauthorized")) }
        do { _ = try await client(key: "").models(); XCTFail() } catch { XCTAssertTrue("\(error)".contains("noKey")) }
    }

    func testServerErrorMessageIsSurfaced() async {
        Stub.routes["https://llm.example/zen/go/v1/chat/completions"] = .init(status: 400, body: Data(#"{"error":{"message":"model not supported"}}"#.utf8))
        do { for try await _ in client().chat(model: OllamaModel(name: "x", thinking: false), messages: []) {}; XCTFail() }
        catch { XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("model not supported") == true) }
    }

    func testInvalidBaseURLFailsCleanlyWithoutCrashing() async {
        let bad = OpenAICompatClient(baseURL: URL(fileURLWithPath: "/not-http"), apiKey: "k")
        do { _ = try await bad.models(); XCTFail() }
        catch { XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("接口地址格式无效") == true) }
        do { for try await _ in bad.chat(model: OllamaModel(name: "x", thinking: false), messages: []) {}; XCTFail() }
        catch { XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("接口地址格式无效") == true) }
    }
}
