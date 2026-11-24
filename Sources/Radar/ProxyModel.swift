import SwiftUI
import Network
import RadarCore

/// The "network proxy" setting and what it is doing right now. The decisions live in `NetworkRoute`; this keeps the UI current
/// and re-checks when the network changes (Wi-Fi switch, wake, Clash Verge turned on or off).
@MainActor
final class ProxyModel: ObservableObject {
    private let route = NetworkRoute.shared
    @Published var mode: ProxyMode
    @Published var state: NetworkRoute.State
    @Published var checking = false
    @Published var verge: Result<VergeProfile, ProxyProblem>
    private let monitor = NWPathMonitor()
    private var settled = false
    private var debounce: Task<Void, Never>?

    init() {
        mode = route.mode; state = route.state; verge = VergeLocator.locate()
        route.onChange = { [weak self] s in Task { @MainActor in self?.state = s } }
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.settled else { self.settled = true; return }   // the first callback only reports the starting state
                self.debounce?.cancel()
                self.debounce = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { await self.refresh(force: true) } }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in NetworkRoute.shared.shutdown() }
    }

    func setMode(_ m: ProxyMode) {
        mode = m; route.mode = m
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard mode != .off || state != .off else { return }   // nothing to do and nothing to undo
        if force { checking = true }
        await route.evaluate(force: force)
        checking = false
        state = route.state
        verge = VergeLocator.locate()
    }

    var statusText: String {
        switch state {
        case .off: return "未启用"
        case .direct(let why): return why
        case .proxied: return "已通过内置代理访问"
        case .unavailable(let why): return "不可用：\(why)"
        }
    }
    var statusColor: Color {
        switch state { case .off: return .secondary; case .direct, .proxied: return .green; case .unavailable: return .red }
    }
}
