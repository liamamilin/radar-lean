import SwiftUI
import RadarCore

/// Writes the daily briefing. One briefing per day, made of one section per watch plus an overview; each part can be
/// generated on its own. The schedule fills in whatever today's briefing still lacks once the chosen hour has passed;
/// a day missed (Radar closed, Mac asleep, model unreachable) is caught up as soon as a later tick finds the app able to.
@MainActor
final class BriefingModel: ObservableObject {
    enum Job: Equatable { case all(force: Bool), watch(Int64), overview }

    let ai: AssistantModel
    let briefer: Briefer
    @Published var days: [Briefing] = []          // newest first, one per day
    @Published var watches: [Watch] = []          // the tabs: active watches
    @Published var job: Job?
    @Published var progress = ""
    @Published var error: String?
    @Published var autoEnabled = UserDefaults.standard.object(forKey: "briefAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: "briefAuto") }
    }
    @Published var hour = UserDefaults.standard.object(forKey: "briefHour") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(hour, forKey: "briefHour") }
    }
    var onAutoDone: ((Briefing) -> Void)?
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?
    static let retryAfter: TimeInterval = 15 * 60

    var running: Bool { job != nil }
    var today: String { Briefer.dayKey(Date()) }

    init(ai: AssistantModel, store: Store) {
        self.ai = ai; briefer = Briefer(store: store)
        reload()
    }

    func reload() {
        days = (try? briefer.days()) ?? []
        watches = (try? briefer.watches()) ?? []
    }
    func briefing(_ day: String) -> Briefing? { days.first { $0.day == day } }

    func cancel() { task?.cancel() }

    /// Starts a job and returns at once. Each finished part is saved straight away, so tabs fill in while it runs
    /// and a stop or a failure keeps what was already written.
    func start(_ job: Job, auto: Bool = false) {
        guard !running else { return }
        self.job = job; error = nil; progress = "准备中…"
        task = Task {
            defer { self.job = nil; progress = "" }
            do {
                if ai.selected == nil { await ai.refresh() }
                guard let m = ai.selected else { throw LLMError.failed(ai.problem ?? "没有可用的模型，请先在设置里配置") }
                try await run(job, model: m, auto: auto)
            } catch is CancellationError {} catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func run(_ job: Job, model m: OllamaModel, auto: Bool) async throws {
        let now = Date(), key = Briefer.dayKey(now), client = ai.client
        var b = briefer.briefing(day: key) ?? Briefing(day: key, createdAt: now, model: m.name, auto: auto, overview: "", sections: [])
        ai.lastUsedModel = nil
        func commit() throws { b.model = ai.lastUsedModel ?? m.name; try briefer.save(b); reload() }
        switch job {
        case .watch(let id):
            guard let w = watches.first(where: { $0.id == id }) else { return }
            progress = "正在整理：\(w.title)"
            b.put(try await briefer.makeSection(watch: w, client: client, model: m, now: now)); try commit()
        case .overview:
            progress = "正在写总览"
            b.overview = try await briefer.makeOverview(b.sections, client: client, model: m); b.overviewAt = Date(); try commit()
        case .all(let force):
            let todo = watches.filter { w in force || !(b.section(w.id!)?.isGenerated ?? false) }
            for (i, w) in todo.enumerated() {
                try Task.checkCancellation()
                progress = "正在整理 \(i + 1)/\(todo.count)：\(w.title)"
                b.put(try await briefer.makeSection(watch: w, client: client, model: m, now: now)); try commit()
            }
            try Task.checkCancellation()
            progress = "正在写总览"
            b.overview = try await briefer.makeOverview(b.sections, client: client, model: m); b.overviewAt = Date(); b.auto = auto; try commit()
            if auto && b.updateCount > 0 { onAutoDone?(b) }
        }
    }

    /// Today's briefing still has no overview, so the schedule has not done its job for today.
    func dueNow(_ now: Date = Date()) -> Bool {
        guard autoEnabled, !running else { return false }
        guard Calendar.current.component(.hour, from: now) >= hour, !(briefing(Briefer.dayKey(now))?.hasOverview ?? false) else { return false }
        if let l = lastAttempt, now.timeIntervalSince(l) < Self.retryAfter { return false }
        return true
    }

    /// Called every minute, at launch and after wake.
    func runIfDue(_ now: Date = Date()) {
        guard dueNow(now) else { return }
        lastAttempt = now
        start(.all(force: false), auto: true)
    }
}
