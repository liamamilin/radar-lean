import SwiftUI
import RadarCore
import GRDB
import UserNotifications
import Security

enum Keychain {
    static let service = "app.radar.github-token"
    static let searchService = "app.radar.search-key"
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
    var token: String?
    @Published var revision = 0
    @Published var checking = 0
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published var unread = 0
    @Published var driveNL: String?   // dev aid (RADAR_DRIVE_*): a natural-language edit to apply to the open watch
    @Published var recent: [Event] = []
    private var observer: AnyDatabaseCancellable?
    private var timer: Timer?

    override init() {
        let path = ProcessInfo.processInfo.environment["RADAR_DB"] ?? ((try? Store.defaultPath()) ?? ":memory:")
        store = try! Store(path: path)
        let tokenBox = TokenBox()
        let searchBox = TokenBox()
        let fetcher = Fetcher(githubToken: { tokenBox.value }, searchKey: { searchBox.value })
        engine = Engine(store: store, fetcher: fetcher)
        discovery = Discovery(fetcher: fetcher, store: store)
        super.init()
        tokenBox.value = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? Keychain.get()
        self.tokenBox = tokenBox
        searchBox.value = ProcessInfo.processInfo.environment["EXA_API_KEY"] ?? Keychain.get(Keychain.searchService)
        self.searchBox = searchBox
        observer = DatabaseRegionObservation(tracking: Watch.all(), Source.all(), Event.all(), Entry.all(), WatchSource.all())
            .start(in: store.db, onError: { _ in }, onChange: { [weak self] _ in
                DispatchQueue.main.async { self?.changed() }
            })
        changed()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkDue() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkDue() }
        }
        Task { await checkDue() }
    }
    private var tokenBox: TokenBox!
    private var searchBox: TokenBox!
    var searchEnabled: Bool { !(searchBox.value ?? "").isEmpty }
    func setSearchKey(_ t: String) { Keychain.set(t, Keychain.searchService); searchBox.value = t.isEmpty ? nil : t }
    func setToken(_ t: String) { Keychain.set(t); tokenBox.value = t.isEmpty ? nil : t }

    func changed() {
        revision += 1
        unread = (try? store.db.read { try Event.filter(Column("readAt") == nil).fetchCount($0) }) ?? 0
        recent = (try? store.db.read { try Event.order(Column("createdAt").desc).limit(5).fetchAll($0) }) ?? []
    }

    func checkDue(force: Bool = false) async {
        if paused && !force { return }
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

    func notify(_ events: [Event]) {
        let watches = (try? store.db.read { try Watch.fetchAll($0) }) ?? []
        for e in events {
            guard let plan = watches.first(where: { $0.id == e.watchID })?.plan, plan.notify else { continue }
            // topic watches only interrupt for new projects / major updates; ordinary posts stay in the list
            if plan.type == .topic && e.kind == "update" { continue }
            let c = UNMutableNotificationContent()
            c.title = e.title; c.body = e.reason; c.userInfo = ["url": e.evidenceURL]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.dedupeKey, content: c, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func open(_ e: Event) {
        if let u = URL(string: e.evidenceURL) { NSWorkspace.shared.open(u) }
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

final class TokenBox { var value: String? }
