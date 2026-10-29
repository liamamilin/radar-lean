import Foundation

public struct OllamaModel: Hashable, Identifiable {
    public var name: String
    public var thinking: Bool
    public var id: String { name }
}

public struct ChatMessage: Codable, Hashable {
    public var role: String   // system / user / assistant
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public enum OllamaError: LocalizedError {
    case unreachable, noModels, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unreachable: return "连不上本机 Ollama（127.0.0.1:11434）。请打开 Ollama 应用，或在终端运行 ollama serve。"
        case .noModels: return "Ollama 里没有可用的本地模型。可在终端运行 ollama pull <模型名> 安装一个（Radar 不会自动下载）。"
        case .failed(let m): return "Ollama 返回错误：\(m)"
        }
    }
}

/// Talks to the local Ollama server only. Nothing here leaves the machine.
public final class OllamaClient: @unchecked Sendable {
    public var baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
    }

    /// Installed models that can chat. Cloud-hosted entries and embedding-only models are not offered.
    public func models() async throws -> [OllamaModel] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags")); req.timeoutInterval = 4
        let data: Data
        do { data = try await session.data(for: req).0 } catch { throw OllamaError.unreachable }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["models"] as? [[String: Any]] else {
            throw OllamaError.failed("无法解析模型列表")
        }
        return list.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let caps = m["capabilities"] as? [String]
            if name.hasSuffix("cloud") || m["remote_host"] != nil || m["remote_model"] != nil { return nil }
            if let caps, !caps.contains("completion") { return nil }
            return OllamaModel(name: name, thinking: caps?.contains("thinking") ?? false)
        }
    }

    /// Streams the reply text piece by piece; cancelling the consuming task stops the generation.
    public func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"; req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = ["model": model.name, "stream": true,
                                               "messages": messages.map { ["role": $0.role, "content": $0.content] },
                                               "options": ["num_ctx": 10240, "temperature": 0.3]]
                    if model.thinking { body["think"] = false }   // thinking models would spend minutes before the first visible word
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, resp) = try await session.bytes(for: req) } catch is CancellationError { throw CancellationError() } catch { throw OllamaError.unreachable }
                    if let status = (resp as? HTTPURLResponse)?.statusCode, status != 200 {
                        var raw = ""
                        for try await l in bytes.lines { raw += l }
                        let msg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["error"] as? String
                        throw OllamaError.failed(msg ?? "HTTP \(status)")
                    }
                    for try await line in bytes.lines {
                        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        if let e = o["error"] as? String { throw OllamaError.failed(e) }
                        if let c = (o["message"] as? [String: Any])?["content"] as? String, !c.isEmpty { cont.yield(c) }
                        if o["done"] as? Bool == true { break }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
