import SwiftUI
import RadarCore
import GRDB

/// Model backend (local Ollama or an OpenAI-compatible service) + the user's choice of model + cached summaries. Nothing here runs unless the user asks for it.
@MainActor
final class AssistantModel: ObservableObject {
    enum Status: Equatable { case unknown, ready, unreachable, noModels, failed }
    enum Provider: String, CaseIterable, Identifiable {
        case ollama, openai
        var id: String { rawValue }
        var label: String { self == .ollama ? "本机 Ollama" : "OpenAI 兼容服务" }
    }
    /// Presets for `.openai`; picking one fills the address, "自定义" leaves it to the user.
    static let presets: [(name: String, url: String)] = [("OpenCode Go", "https://opencode.ai/zen/go/v1"), ("DeepSeek 官方", "https://api.deepseek.com"), ("自定义", "")]
    let ollama = OllamaClient(baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST_URL"] ?? "http://127.0.0.1:11434")!)   // env override is a dev aid for testing the unreachable state
    let assistant: RadarAssistant
    @Published var status = Status.unknown
    @Published var models: [OllamaModel] = []
    @Published var lastError: String?
    @Published var provider = Provider(rawValue: UserDefaults.standard.string(forKey: "llmProvider") ?? "") ?? .ollama {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider"); models = []; status = .unknown; lastError = nil }
    }
    @Published var baseURLString = UserDefaults.standard.string(forKey: "llmBaseURL") ?? AssistantModel.presets[0].url {
        didSet { UserDefaults.standard.set(baseURLString, forKey: "llmBaseURL") }
    }
    /// Lives in the Keychain (see AppModel.setLLMKey); kept in memory for requests.
    @Published var apiKey = ProcessInfo.processInfo.environment["RADAR_LLM_KEY"] ?? ""
    /// Which Keychain item holds the key for the current address: each service has its own key. (OpenCode keeps the original item.)
    var keyService: String {
        let host = URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host == "opencode.ai" || host.isEmpty ? Keychain.llmService : Keychain.llmService + "." + host
    }
    /// When the chosen model cannot answer, a cheaper available one is tried (see FailoverChat).
    @Published var autoSwitch = UserDefaults.standard.object(forKey: "llmAutoSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "llmAutoSwitch") }
    }
    @Published var switchNote: String?      // "X was unavailable, Y answered instead": shown until the next refresh
    var lastUsedModel: String?              // the model that actually answered the latest request
    let health = ModelHealth()
    /// The chosen model is remembered per service (a model name from one service means nothing at another).
    private var modelKey: String {
        guard provider == .openai else { return "llmModel." + provider.rawValue }
        let host = URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host == "opencode.ai" || host.isEmpty ? "llmModel.openai" : "llmModel.openai." + host
    }
    var selectedName: String? {
        get { UserDefaults.standard.string(forKey: modelKey) ?? (provider == .ollama ? UserDefaults.standard.string(forKey: "ollamaModel") : nil) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey); objectWillChange.send() }
    }
    /// What the current settings talk to.
    var client: ChatClient {
        switch provider {
        case .ollama: return ollama
        case .openai:
            let url = URL(string: baseURLString.trimmingCharacters(in: .whitespaces)) ?? URL(string: "https://invalid.local")!
            let base = OpenAICompatClient(baseURL: url, apiKey: apiKey, disableThinking: url.host == "api.deepseek.com")
            guard autoSwitch else { return base }
            let f = FailoverChat(base: base, alternatives: models, health: health)
            f.onSwitch = { [weak self] from, to, why in
                DispatchQueue.main.async { self?.switchNote = "「\(from)」\(why)，已自动改用「\(to)」。" }
            }
            f.onUsed = { [weak self] name in DispatchQueue.main.async { self?.lastUsedModel = name } }
            return f
        }
    }
    struct Cached: Codable { var text: String; var evidence: [Evidence]; var signature: String; var model: String; var date: Date }
    private let store: Store
    static let keepPerKey = 20
    /// Every generated summary per "<watch>|<range>", newest first. The first one is the cache.
    private(set) var history: [String: [Cached]] = [:]
    func latest(_ key: String) -> Cached? { history[key]?.first }

    init(store: Store) {
        self.store = store; assistant = RadarAssistant(store: store)
        let rows = (try? store.db.read { try Row.fetchAll($0, sql: "SELECT key, json FROM summaryHistory ORDER BY id") }) ?? []
        for r in rows { if let k: String = r["key"], let d: Data = r["json"], let c = try? JSONDecoder().decode(Cached.self, from: d) { history[k, default: []].insert(c, at: 0) } }
    }

    func save(_ key: String, _ c: Cached) {
        history[key, default: []].insert(c, at: 0)
        if history[key]!.count > Self.keepPerKey { history[key]!.removeLast(history[key]!.count - Self.keepPerKey) }
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? store.db.write { db in
            try db.execute(sql: "INSERT INTO summaryHistory (key, json) VALUES (?, ?)", arguments: [key, d])
            try db.execute(sql: "DELETE FROM summaryHistory WHERE key = ? AND id NOT IN (SELECT id FROM summaryHistory WHERE key = ? ORDER BY id DESC LIMIT ?)", arguments: [key, key, Self.keepPerKey])
        }
    }

    /// The chosen model; when none was chosen (or it is no longer offered) the cheapest-looking one, not just the first alphabetically.
    var selected: OllamaModel? {
        models.first { $0.name == selectedName } ?? (provider == .openai ? ModelRanking.best(models) : (models.first { !$0.thinking } ?? models.first))
    }

    func refresh() async {
        let p = provider
        do {
            let list = try await client.models()
            guard p == provider else { return }   // the user switched backend while this was loading
            models = list; lastError = nil; switchNote = nil
            status = models.isEmpty ? .noModels : .ready
        } catch {
            guard p == provider else { return }
            models = []; status = p == .ollama ? .unreachable : .failed
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    var problem: String? {
        switch provider {
        case .ollama:
            switch status { case .unreachable: return OllamaError.unreachable.errorDescription; case .noModels: return OllamaError.noModels.errorDescription; default: return nil }
        case .openai:
            if status == .failed || status == .noModels { return lastError ?? LLMError.noModels.errorDescription }
            return apiKey.isEmpty ? LLMError.noKey.errorDescription : nil
        }
    }
    /// For wording that has to say whether data leaves the machine.
    var isLocal: Bool { provider == .ollama }
}

/// The current model, switchable in place (the same choice as in Settings).
struct ModelMenu: View {
    @ObservedObject var ai: AssistantModel
    var body: some View {
        if let m = ai.selected {
            Menu(m.name) {
                ForEach(ai.models) { x in Button((x.name == m.name ? "✓ " : "") + x.name) { ai.selectedName = x.name } }
                Divider()
                Button("重新检测") { Task { await ai.refresh() } }
            }.menuStyle(.borderlessButton).fixedSize().font(.caption)
        }
    }
}

struct OllamaNotice: View {
    @ObservedObject var ai: AssistantModel
    var body: some View {
        if let p = ai.problem {
            Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if let n = ai.switchNote {
            Label(n, systemImage: "arrow.triangle.swap").font(.caption).foregroundStyle(.blue)
        }
    }
}

