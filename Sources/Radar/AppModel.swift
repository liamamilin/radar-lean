import SwiftUI
import RadarCore
import GRDB
import UserNotifications
import Security
import os

enum Keychain {
    /// The keychain only prompts for an app whose code hash it has not seen, and every rebuild has a new one. So it is read at launch
    /// only when the user saved something there (remembered here); everyone else never meets the dialog.
    static func holds(_ service: String) -> Bool { UserDefaults.standard.bool(forKey: "keychain." + service) }
    static func remember(_ service: String, _ has: Bool) { UserDefaults.standard.set(has, forKey: "keychain." + service) }
    static let service = "app.radar.github-token"
    static let searchService = "app.radar.search-key"
    static let llmService = "app.radar.llm-key"
    static func get(_ service: String = Keychain.service) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ v: String, _ service: String = Keychain.service) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !v.isEmpty else { return }
        SecItemAdd(base.merging([kSecValueData as String: Data(v.utf8)]) { $1 } as CFDictionary, nil)
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let store: Store
    let engine: Engine
    let discovery: Discovery
    let ai: AssistantModel
    let isolated = ProcessInfo.processInfo.environment["RADAR_DB"] != nil
    var token: String?
    @Published var revision = 0
    @Published var checking = 0
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published var unread = 0
    let fetcher: Fetcher
    @Published var askRequest: String?   // a question for 问 Radar from elsewhere in the app (e.g. "read this source")
    @Published var wantsBriefing = false   // a "briefing ready" notification was clicked
    @Published var storageWarning: String?
    var openMainWindow: (() -> Void)?
    let briefing: BriefingModel
    let proxy = ProxyModel()
    @Published var notifyStatus = UNAuthorizationStatus.notDetermined   // what macOS currently allows us to show
    private let notifyLog = Logger(subsystem: "app.radar", category: "notify")
    @Published var busySources = Set<Int64>()   // sources being read right now (shown in the source rows)
    private var sweeping = false
    @Published var driveNL: String?   // dev aid (RADAR_DRIVE_*): a natural-language edit to apply to the open watch
    @Published var recent: [Event] = []
    private var observer: AnyDatabaseCancellable?
    private var timer: Timer?

    override init() {
        let isolated = ProcessInfo.processInfo.environment["RADAR_DB"] != nil   // a scratch database never touches the real Keychain
        let path = ProcessInfo.processInfo.environment["RADAR_DB"] ?? ((try? Store.defaultPath()) ?? ":memory:")
        var warning: String?
        do {
            let opened = try Store.openSafely(path: path)
            store = opened.store
            if let backup = opened.recoveredFrom {
                warning = "原数据库无法读取，已自动备份到 \(URL(fileURLWithPath: backup).lastPathComponent) 并创建新库。"
            }
        } catch {
            store = try! Store(path: nil)
            warning = "无法打开本地数据库（\(error.localizedDescription)），当前已临时切换为内存模式，重启后改动不会保存。"
        }
        storageWarning = warning
        let tokenBox = TokenBox()
        let searchBox = TokenBox()
        let fetcher = Fetcher(githubToken: { tokenBox.value }, searchKey: { searchBox.value })
        self.fetcher = fetcher
        engine = Engine(store: store, fetcher: fetcher)
        discovery = Discovery(fetcher: fetcher, store: store)
        ai = AssistantModel(store: store)
        briefing = BriefingModel(ai: ai, store: store)
        super.init()
        briefing.onAutoDone = { [weak self] b in self?.notifyBriefing(b) }
        tokenBox.value = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? (isolated || !Keychain.holds(Keychain.service) ? nil : Keychain.get())
        engine.onChecking = { [weak self] id, on in
            DispatchQueue.main.async { if on { self?.busySources.insert(id) } else { self?.busySources.remove(id) } }
        }
        self.tokenBox = tokenBox
        searchBox.value = ProcessInfo.processInfo.environment["EXA_API_KEY"] ?? (isolated || !Keychain.holds(Keychain.searchService) ? nil : Keychain.get(Keychain.searchService))
        self.searchBox = searchBox
        loadLLMKey()
        observer = DatabaseRegionObservation(tracking: Watch.all(), Source.all(), Event.all(), Entry.all(), WatchSource.all())
            .start(in: store.db, onError: { _ in }, onChange: { [weak self] _ in
                DispatchQueue.main.async { self?.changed() }
            })
        refresh()
        UNUserNotificationCenter.current().delegate = self
        // ask once the app is up and active: an early request (inside init) is refused with "not allowed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                self?.notifyLog.notice("authorization granted=\(granted) error=\(String(describing: error), privacy: .public)")
                Task { @MainActor in await self?.refreshNotifyStatus() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshNotifyStatus() }   // the user may have changed it in System Settings
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkDue() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.proxy.refresh(force: true); await self?.checkDue() }
        }
        Task {
            await checkDue()
            pruneIfNeeded()
        }
    }

    /// Runs once per calendar day to drop stale unreferenced entries so the SQLite file stays bounded.
    private func pruneIfNeeded() {
        guard !isolated else { return }
        let today = Briefer.dayKey(Date())
        guard UserDefaults.standard.string(forKey: "lastPruneDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "lastPruneDay")
        let s = store
        Task.detached(priority: .background) { _ = try? s.pruneOldEntries() }
    }
    private var tokenBox: TokenBox!
    private var searchBox: TokenBox!
    var searchEnabled: Bool { !(searchBox.value ?? "").isEmpty }
    func setSearchKey(_ t: String) { Keychain.set(t, Keychain.searchService); Keychain.remember(Keychain.searchService, !t.isEmpty); searchBox.value = t.isEmpty ? nil : t }
    func setLLMKey(_ k: String) { Keychain.set(k, ai.keyService); Keychain.remember(ai.keyService, !k.isEmpty); ai.apiKey = k }
    /// The key of the service the settings point at (each service keeps its own); only read when the user saved one, so no keychain prompt at launch.
    func loadLLMKey(userInitiated: Bool = false) {
        guard ProcessInfo.processInfo.environment["RADAR_LLM_KEY"] == nil, !isolated else { return }
        let s = ai.keyService
        guard userInitiated || Keychain.holds(s) else { ai.apiKey = ""; return }
        ai.apiKey = Keychain.get(s) ?? ""
        if !ai.apiKey.isEmpty { Keychain.remember(s, true) }
    }
    func setToken(_ t: String) { Keychain.set(t); Keychain.remember(Keychain.service, !t.isEmpty); tokenBox.value = t.isEmpty ? nil : t }
    /// Settings was opened (the user's own action, so a keychain prompt is fine): pick up what is stored there.
    func adopt(token t: String, searchKey k: String) {
        if !t.isEmpty { Keychain.remember(Keychain.service, true); tokenBox.value = t }
        if !k.isEmpty { Keychain.remember(Keychain.searchService, true); searchBox.value = k }
    }

    /// The database changed. A sweep writes dozens of times in a second; every view re-reads on `revision`, so bursts are folded into one refresh.
    private var refreshQueued = false
    func changed() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshQueued = false; self?.refresh() }
    }

    private func refresh() {
        Task {
            let r = try? await store.db.read { db in
                (try Event.filter(Column("readAt") == nil).fetchCount(db), try Event.order(Column("createdAt").desc).limit(5).fetchAll(db))
            }
            if let r { unread = r.0; recent = r.1 }
            revision += 1
        }
    }

    func checkDue(force: Bool = false) async {
        briefing.runIfDue()
        if paused && !force { return }
        guard !sweeping else { return }            // the previous sweep (timer / wake-up / menu) is still running
        sweeping = true; defer { sweeping = false }
        await proxy.refresh()                      // decide direct or proxied before anything is fetched
        checking += 1; defer { checking -= 1 }
        notify(await engine.checkDue(force: force))
    }

    func check(watchID: Int64) async {
        checking += 1; defer { checking -= 1 }
        notify(await engine.check(watchID: watchID))
    }

    func check(sourceID: Int64) async {
        checking += 1; defer { checking -= 1 }
        notify(await engine.check(sourceID: sourceID).events)
    }

    func refreshNotifyStatus() async {
        notifyStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func notify(_ events: [Event]) {
        let watches = (try? store.db.read { try Watch.fetchAll($0) }) ?? []
        for e in events {
            guard let plan = watches.first(where: { $0.id == e.watchID })?.plan, Engine.shouldNotify(plan: plan, kind: e.kind) else { continue }
            let c = UNMutableNotificationContent()
            let kind = e.kind, title = e.title
            c.title = title; c.body = e.reason; c.userInfo = ["url": e.evidenceURL]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.dedupeKey, content: c, trigger: nil)) { [notifyLog] error in
                notifyLog.notice("submitted \(kind) '\(title)' error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// "Read this with Radar": opens 问 Radar and sends the link in a fresh conversation.
    func readWithRadar(_ url: String) { askRequest = "帮我读一下这篇，整理要点：" + url }

    func notifyBriefing(_ b: Briefing) {
        let c = UNMutableNotificationContent()
        c.title = "今日 AI 简报已生成"
        c.body = "\(b.activeSections.count) 个关注类有更新，共 \(b.updateCount) 条。点击查看。"
        c.userInfo = ["briefing": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "briefing-" + b.day, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["briefing"] as? Bool == true {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                if let win = NSApp.windows.first(where: { $0.title == "Radar" && $0.canBecomeMain }) {
                    win.makeKeyAndOrderFront(nil)
                } else {
                    openMainWindow?()
                }
                wantsBriefing = true
            }
            return
        }
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            await MainActor.run { LinkOpener.open(u) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func open(_ e: Event) {
        if let u = URL(string: e.evidenceURL) { LinkOpener.open(u) }
        markRead(e)
    }
    func markRead(_ e: Event) {
        try? store.db.write { db in try db.execute(sql: "UPDATE event SET readAt = ? WHERE id = ? AND readAt IS NULL", arguments: [Date(), e.id]) }
    }
    func markAllRead() {
        try? store.db.write { try $0.execute(sql: "UPDATE event SET readAt = ? WHERE readAt IS NULL", arguments: [Date()]) }
    }
    func setStatus(_ w: Watch, active: Bool) {
        try? store.db.write { try $0.execute(sql: "UPDATE watch SET status = ? WHERE id = ?", arguments: [active ? "active" : "paused", w.id]) }
    }
    func savePlan(_ w: Watch, _ plan: WatchPlan) {
        var w = w; w.plan = plan; w.title = plan.title
        try? store.db.write { try w.update($0) }
    }
    func delete(_ w: Watch) { try? store.deleteWatch(w.id!) }
}

final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
