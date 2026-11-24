import Foundation

/// What the assistant needs from a model backend: a list of usable models and a streamed reply.
public protocol ChatClient: Sendable {
    func models() async throws -> [OllamaModel]
    func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

extension OllamaClient: ChatClient {}

public enum LLMError: LocalizedError {
    case noKey, unreachable(String), unauthorized, failed(String), noModels
    case http(Int, String)      // the service answered, but refused this request (model unavailable, rate limit, server trouble …)
    public var errorDescription: String? {
        switch self {
        case .http(_, let m): return "模型服务返回错误：\(m)"
        case .noKey: return "还没有填写 API Key。请在“设置 → AI 模型”里填写。"
        case .unreachable(let host): return "连不上 \(host)，请检查网络和接口地址。"
        case .unauthorized: return "API Key 无效或已过期（HTTP 401）。"
        case .failed(let m): return "模型服务返回错误：\(m)"
        case .noModels: return "这个服务没有返回可用的模型。"
        }
    }
}

extension LLMError {
    /// Would another model plausibly succeed where this one failed? A bad key, no key or no network would fail the same way for every model.
    public static func shouldSwitchModel(_ error: Error) -> Bool {
        if let u = error as? URLError { return u.code == .timedOut }
        guard let e = error as? LLMError else { return false }
        switch e {
        case .http(let s, _): return [400, 402, 403, 404, 408, 409, 422, 425, 429].contains(s) || s >= 500
        case .failed: return true
        case .noKey, .unreachable, .unauthorized, .noModels: return false
        }
    }
    /// How long a model that failed this way is left alone.
    static func cooldown(_ error: Error) -> TimeInterval {
        if case .http(let s, _) = error as? LLMError { return s == 429 ? 300 : (s >= 500 ? 600 : 3600) }
        return 600
    }
    var short: String {
        switch self {
        case .http(let s, _): return "HTTP \(s)"
        case .failed(let m): return String(m.prefix(40))
        default: return errorDescription ?? ""
        }
    }
}

/// Any server speaking the OpenAI chat-completions protocol (OpenCode Go, OpenRouter, a self-hosted gateway, …).
/// `baseURL` is the API root that ends in `/v1`. Unlike `OllamaClient`, what is asked here leaves the machine.
public final class OpenAICompatClient: ChatClient, @unchecked Sendable {
    public let baseURL: URL
    let apiKey: String
    private let injected: URLSession?
    var session: URLSession { injected ?? NetworkRoute.shared.session(request: 60, resource: 3600) }

    /// Some gateways (OpenCode Go) route and cache by a stable per-conversation id and ask clients to name themselves.
    public let sessionID: String
    /// DeepSeek answers in "thinking" mode unless told otherwise, and the thinking is billed as output; a briefing does not need it.
    public let disableThinking: Bool
    public static let launchSession = UUID().uuidString

    public init(baseURL: URL, apiKey: String, session: URLSession? = nil, sessionID: String = OpenAICompatClient.launchSession, disableThinking: Bool = false) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.injected = session; self.sessionID = sessionID; self.disableThinking = disableThinking
    }

    func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!)
        req.timeoutInterval = timeout
        req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("radar-macos/0.3", forHTTPHeaderField: "User-Agent")
        req.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        return req
    }

    static func errorMessage(_ data: Data, status: Int) -> LLMError {
        if status == 401 { return .unauthorized }
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = ((o?["error"] as? [String: Any])?["message"] as? String) ?? (o?["error"] as? String) ?? (o?["message"] as? String)
        return .http(status, msg ?? "HTTP \(status)")
    }

    public func models() async throws -> [OllamaModel] {
        guard !apiKey.isEmpty else { throw LLMError.noKey }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: request("models", timeout: 15)) } catch { throw LLMError.unreachable(baseURL.host ?? baseURL.absoluteString) }
        if let s = (resp as? HTTPURLResponse)?.statusCode, s != 200 { throw Self.errorMessage(data, status: s) }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["data"] as? [[String: Any]] else { throw LLMError.failed("无法解析模型列表") }
        let ids = list.compactMap { $0["id"] as? String }.filter { !$0.lowercased().contains("embed") }.sorted()
        guard !ids.isEmpty else { throw LLMError.noModels }
        return ids.map { OllamaModel(name: $0, thinking: false) }
    }

    static func body(model: String, messages: [ChatMessage], disableThinking: Bool) -> [String: Any] {
        var o: [String: Any] = ["model": model, "stream": true, "temperature": 0.3, "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        if disableThinking { o["thinking"] = ["type": "disabled"] }
        return o
    }

    /// Server-sent events: `data: {"choices":[{"delta":{"content":"…"}}]}` lines until `data: [DONE]`. Reasoning tokens are skipped.
    public func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.noKey }
                    var req = request("chat/completions", timeout: 600)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model.name, messages: messages, disableThinking: disableThinking))
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, resp) = try await session.bytes(for: req) } catch is CancellationError { throw CancellationError() }
                    catch let e as URLError where e.code == .timedOut { throw LLMError.failed("模型响应超时") }
                    catch { throw LLMError.unreachable(baseURL.host ?? baseURL.absoluteString) }
                    if let s = (resp as? HTTPURLResponse)?.statusCode, s != 200 {
                        var raw = ""
                        for try await l in bytes.lines { raw += l }
                        throw Self.errorMessage(Data(raw.utf8), status: s)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let o = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { throw LLMError.failed(m) }
                        if let c = ((o["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String, !c.isEmpty { cont.yield(c) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
