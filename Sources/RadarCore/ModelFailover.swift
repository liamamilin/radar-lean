import Foundation

/// Which model to prefer when the chosen one cannot answer: cheap first. Only the model's name is known, so this is a heuristic.
public enum ModelRanking {
    static let cheap = ["flash", "mini", "lite", "haiku", "small", "nano", "turbo", "air", "instant"]
    static let costly = ["opus", "pro", "max", "ultra", "large", "gpt-5", "gpt-6", "sonnet", "thinking", "reason"]
    /// Families that speak their own protocol on some gateways (OpenCode Go routes them outside chat/completions): last resort.
    static let unreliable = ["minimax", "gemini"]

    /// Lower is better: cheap models, then unknown ones, then costly ones. A model marked free goes after the cheap paid ones
    /// (free tiers are the ones that disappear or run dry), and the unreliable families go last.
    public static func rank(_ name: String) -> Int {
        let n = name.lowercased()
        var r = cheap.contains { n.contains($0) } ? 0 : (costly.contains { n.contains($0) } ? 4 : 2)
        if n.contains("free") { r += 1 }
        if unreliable.contains(where: { n.contains($0) }) { r += 10 }
        return r
    }

    public static func ordered(_ models: [OllamaModel]) -> [OllamaModel] {
        models.filter { !$0.name.lowercased().contains("embed") }
            .sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
    }

    /// The model to use when nothing was chosen (or the chosen one is gone from the list).
    public static func best(_ models: [OllamaModel]) -> OllamaModel? { ordered(models).first ?? models.first }
}

/// Models that just failed, so the next request does not queue behind the same failure.
public final class ModelHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var until: [String: Date] = [:]
    public init() {}
    public func isBlocked(_ name: String, now: Date = Date()) -> Bool { lock.withLock { (until[name] ?? .distantPast) > now } }
    public func block(_ name: String, for seconds: TimeInterval, now: Date = Date()) { lock.withLock { until[name] = now.addingTimeInterval(seconds) } }
    public func ok(_ name: String) { lock.withLock { _ = until.removeValue(forKey: name) } }
}

/// Asks the requested model; if the service refuses it before saying anything (gone, rate-limited, erroring, empty), the next
/// cheapest available model is tried, up to `attempts` models in all. Once text has started flowing, nothing is switched:
/// a half answer is never glued to another model's answer. A failure that every model would share (key, network) is passed on.
public final class FailoverChat: ChatClient, @unchecked Sendable {
    let base: ChatClient
    let alternatives: [OllamaModel]
    let health: ModelHealth
    let attempts: Int
    public var onSwitch: (@Sendable (_ from: String, _ to: String, _ reason: String) -> Void)?
    public var onUsed: (@Sendable (String) -> Void)?

    public init(base: ChatClient, alternatives: [OllamaModel], health: ModelHealth, attempts: Int = 3) {
        self.base = base; self.alternatives = alternatives; self.health = health; self.attempts = max(1, attempts)
    }

    public func models() async throws -> [OllamaModel] { try await base.models() }

    func plan(for model: OllamaModel) -> [OllamaModel] {
        let others = ModelRanking.ordered(alternatives).filter { $0.name != model.name && !health.isBlocked($0.name) }
        if health.isBlocked(model.name), !others.isEmpty { return Array(others.prefix(attempts)) }   // known bad for now: go straight to the next
        return Array(([model] + others).prefix(attempts))
    }

    public func chat(model: OllamaModel, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                let order = plan(for: model)
                if order.first?.name != model.name, let to = order.first { onSwitch?(model.name, to.name, "近期不可用，暂时避开") }
                var first: Error?
                for (i, m) in order.enumerated() {
                    var yielded = false
                    do {
                        for try await piece in base.chat(model: m, messages: messages) { yielded = true; cont.yield(piece) }
                        guard yielded else { throw LLMError.failed("模型没有返回内容") }
                        health.ok(m.name); onUsed?(m.name)
                        cont.finish(); return
                    } catch {
                        if Task.isCancelled || error is CancellationError { cont.finish(throwing: CancellationError()); return }
                        if yielded || !LLMError.shouldSwitchModel(error) { cont.finish(throwing: error); return }
                        first = first ?? error
                        health.block(m.name, for: LLMError.cooldown(error))
                        if i + 1 < order.count { onSwitch?(m.name, order[i + 1].name, (error as? LLMError)?.short ?? "出错") }
                    }
                }
                cont.finish(throwing: first ?? LLMError.noModels)
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
