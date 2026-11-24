import XCTest
@testable import RadarCore

/// A backend whose models each follow a script: answer, refuse with an error, or say nothing.
final class ScriptedChat: ChatClient, @unchecked Sendable {
    enum Step { case say([String]), fail(Error), sayThenFail([String], Error), silent }
    var script: [String: Step]
    nonisolated(unsafe) var asked: [String] = []
    init(_ script: [String: Step]) { self.script = script }
    func models() async throws -> [OllamaModel] { script.keys.sorted().map { OllamaModel(name: $0, thinking: false) } }
    func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        asked.append(model.name)
        let step = script[model.name] ?? .fail(LLMError.http(404, "no such model"))
        return AsyncThrowingStream { c in
            switch step {
            case .say(let p): p.forEach { c.yield($0) }; c.finish()
            case .fail(let e): c.finish(throwing: e)
            case .sayThenFail(let p, let e): p.forEach { c.yield($0) }; c.finish(throwing: e)
            case .silent: c.finish()
            }
        }
    }
}

final class FailoverTests: XCTestCase {
    func m(_ n: String) -> OllamaModel { OllamaModel(name: n, thinking: false) }
    let all = ["beam-free", "kimi-k3", "deepseek-v4.1-flash", "glm-5.3", "minimax-m3", "qwen3.8-max"]
    func run(_ f: FailoverChat, _ model: String = "beam-free") async throws -> String {
        var out = ""
        for try await p in f.chat(model: m(model), messages: []) { out += p }
        return out
    }
    func chat(_ s: [String: ScriptedChat.Step], health: ModelHealth = ModelHealth()) -> (FailoverChat, ScriptedChat) {
        let b = ScriptedChat(s)
        return (FailoverChat(base: b, alternatives: all.map(m), health: health), b)
    }

    func testRankingPutsCheapFirstFreeAfterAndUnreliableLast() {
        let order = ModelRanking.ordered(all.map(m)).map { $0.name }
        XCTAssertEqual(order.first, "deepseek-v4.1-flash")
        XCTAssertLessThan(order.firstIndex(of: "kimi-k3")!, order.firstIndex(of: "qwen3.8-max")!)
        XCTAssertLessThan(order.firstIndex(of: "deepseek-v4.1-flash")!, order.firstIndex(of: "beam-free")!)
        XCTAssertEqual(order.last, "minimax-m3")
        XCTAssertEqual(ModelRanking.best(all.map(m))?.name, "deepseek-v4.1-flash")
        XCTAssertNil(ModelRanking.best([]))
    }

    func testRefusedModelFallsBackToTheCheapestOther() async throws {
        let (f, b) = chat(["beam-free": .fail(LLMError.http(429, "limit")), "deepseek-v4.1-flash": .say(["好", "的"])])
        var switched: [String] = []
        f.onSwitch = { from, to, why in switched.append("\(from)>\(to):\(why)") }
        let out = try await run(f)
        XCTAssertEqual(out, "好的"); XCTAssertEqual(b.asked, ["beam-free", "deepseek-v4.1-flash"])
        XCTAssertEqual(switched, ["beam-free>deepseek-v4.1-flash:HTTP 429"])
    }

    func testUnknownModelAndEmptyReplyAlsoSwitch() async throws {
        var (f, b) = chat(["deepseek-v4.1-flash": .say(["ok"])])   // beam-free is not served at all: 404
        var out = try await run(f)
        XCTAssertEqual(out, "ok"); XCTAssertEqual(b.asked.first, "beam-free")
        (f, b) = chat(["beam-free": .silent, "deepseek-v4.1-flash": .say(["ok"])])
        out = try await run(f)
        XCTAssertEqual(out, "ok")
    }

    func testHalfAnswerIsNeverSwitched() async {
        let (f, b) = chat(["beam-free": .sayThenFail(["半句"], LLMError.http(500, "boom")), "deepseek-v4.1-flash": .say(["不该出现"])])
        do { _ = try await run(f); XCTFail() } catch { XCTAssertEqual(b.asked, ["beam-free"]) }
    }

    func testFailuresEveryModelWouldShareAreNotRetried() async {
        for e in [LLMError.unauthorized, LLMError.noKey, LLMError.unreachable("x")] {
            let (f, b) = chat(["beam-free": .fail(e), "deepseek-v4.1-flash": .say(["ok"])])
            do { _ = try await run(f); XCTFail() } catch { XCTAssertEqual(b.asked, ["beam-free"]) }
        }
    }

    func testAllFailingReportsTheFirstErrorAfterThreeTries() async {
        let (f, b) = chat(["beam-free": .fail(LLMError.http(404, "gone")), "deepseek-v4.1-flash": .fail(LLMError.http(500, "x")), "glm-5.3": .fail(LLMError.http(500, "y")), "kimi-k3": .say(["late"])])
        do { _ = try await run(f); XCTFail() } catch {
            XCTAssertEqual(b.asked.count, 3, "at most three models are tried")
            XCTAssertTrue((error as? LLMError).map { "\($0)".contains("gone") } == true)
        }
    }

    func testFailedModelIsAvoidedNextTimeUntilItRecovers() async throws {
        let health = ModelHealth()
        let (f, b) = chat(["beam-free": .fail(LLMError.http(404, "gone")), "deepseek-v4.1-flash": .say(["ok"])], health: health)
        _ = try await run(f)
        b.asked = []
        _ = try await run(f)
        XCTAssertEqual(b.asked, ["deepseek-v4.1-flash"], "straight to the working model")
        health.ok("beam-free"); b.asked = []
        _ = try await run(f)
        XCTAssertEqual(b.asked.first, "beam-free")
    }

    func testTimeoutsSwitchButOtherNetworkErrorsDoNot() {
        XCTAssertTrue(LLMError.shouldSwitchModel(URLError(.timedOut)))
        XCTAssertFalse(LLMError.shouldSwitchModel(URLError(.notConnectedToInternet)))
        XCTAssertTrue(LLMError.shouldSwitchModel(LLMError.http(503, "")))
        XCTAssertFalse(LLMError.shouldSwitchModel(LLMError.http(401, "")))
    }

    func testDeepSeekBodyDisablesThinkingOnlyWhenAsked() {
        let on = OpenAICompatClient.body(model: "deepseek-flash", messages: [], disableThinking: true)
        XCTAssertEqual((on["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(OpenAICompatClient.body(model: "x", messages: [], disableThinking: false)["thinking"])
    }
}
