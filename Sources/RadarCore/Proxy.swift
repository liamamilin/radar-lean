import Foundation
import Darwin

// MARK: settings and what Clash Verge left on this machine

public enum ProxyMode: String, CaseIterable, Sendable {
    case off, auto, always
    public var label: String {
        switch self {
        case .off: return "关闭"
        case .auto: return "自动（直连不通时才启用）"
        case .always: return "始终使用内置代理"
        }
    }
}

public enum ProxyProblem: LocalizedError, Equatable {
    case notInstalled, noProfile, badProfile, unsigned(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "没有找到 Clash Verge（/Applications/Clash Verge.app）"
        case .noProfile: return "没有找到 Clash Verge 当前使用的订阅，请先在 Clash Verge 里添加并选中一个订阅"
        case .badProfile: return "订阅里没有可用的节点或规则"
        case .unsigned(let m): return "代理内核的签名校验没有通过：\(m)"
        case .failed(let m): return m
        }
    }
}

/// Clash Verge's core and the subscription it currently uses. Radar only reads them; nothing in Verge's folders is changed.
public struct VergeProfile: Equatable {
    public var core: URL
    public var profile: URL
    public var home: URL            // Verge's data folder (geo databases live here)
    public var updated: Date?
    public var expire: Date?
    public var used: Int64?
    public var total: Int64?
}

public enum VergeLocator {
    static let appPaths = ["/Applications/Clash Verge.app", NSHomeDirectory() + "/Applications/Clash Verge.app"]
    static let dataFolder = "io.github.clash-verge-rev.clash-verge-rev"

    public static func locate(applicationSupport: URL? = nil, appPaths: [String]? = nil) -> Result<VergeProfile, ProxyProblem> {
        let fm = FileManager.default
        guard let app = (appPaths ?? Self.appPaths).first(where: { fm.isExecutableFile(atPath: $0 + "/Contents/MacOS/verge-mihomo") }) else { return .failure(.notInstalled) }
        let support = applicationSupport ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent(dataFolder, isDirectory: true)
        guard let text = try? String(contentsOf: home.appendingPathComponent("profiles.yaml"), encoding: .utf8) else { return .failure(.noProfile) }
        let (current, items) = parseProfiles(text)
        guard let uid = current, let item = items[uid] else { return .failure(.noProfile) }
        let file = home.appendingPathComponent("profiles").appendingPathComponent(item["file"] ?? uid + ".yaml")
        guard fm.fileExists(atPath: file.path) else { return .failure(.noProfile) }
        func date(_ k: String) -> Date? { Double(item[k] ?? "").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        return .success(VergeProfile(core: URL(fileURLWithPath: app + "/Contents/MacOS/verge-mihomo"), profile: file, home: home,
                                     updated: date("updated"), expire: date("expire"),
                                     used: Int64(item["download"] ?? "").map { $0 + (Int64(item["upload"] ?? "") ?? 0) }, total: Int64(item["total"] ?? "")))
    }

    /// `profiles.yaml` is a simple list; only the current uid and a few scalar fields of each item are needed.
    static func parseProfiles(_ text: String) -> (current: String?, items: [String: [String: String]]) {
        func value(_ s: Substring) -> String {
            let v = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return v == "null" || v == "~" ? "" : v
        }
        var current: String?, uid: String?
        var items: [String: [String: String]] = [:]
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("current:") { current = value(line.dropFirst(8)); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- uid:") { let u = value(t.dropFirst(6)); uid = u; items[u] = [:]; continue }
            guard let u = uid, !t.hasPrefix("-"), !t.hasPrefix("#"), let c = t.firstIndex(of: ":") else { continue }
            let v = value(t[t.index(after: c)...])
            if !v.isEmpty { items[u]?[String(t[..<c])] = v }
        }
        return (current?.isEmpty == false ? current : nil, items)
    }
}

// MARK: the configuration Radar runs the core with

public enum ClashConfig {
    /// Only nodes, groups and rules come from the subscription; ports, mode, DNS and everything that touches the system
    /// (TUN, system proxy, LAN access, a control port) are Radar's own.
    static let kept: Set<String> = ["proxies", "proxy-groups", "proxy-providers", "rule-providers", "rules", "sub-rules"]

    /// Top-level blocks of a Clash YAML file, in order. Lines before the first key (comments, `---`) are dropped.
    static func blocks(_ text: String) -> [(key: String, text: String)] {
        var out: [(String, [String])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if let f = l.first, f.isLetter || f == "_", let c = l.firstIndex(of: ":"), !l[..<c].contains(" ") {
                out.append((String(l[..<c]), [l]))
            } else if !out.isEmpty { out[out.count - 1].1.append(l) }
        }
        return out.map { ($0.0, $0.1.joined(separator: "\n")) }
    }

    public static func hasContent(_ profile: String) -> Bool {
        let keys = Set(blocks(profile).map { $0.key })
        return (keys.contains("proxies") || keys.contains("proxy-providers")) && keys.contains("rules")
    }

    public static func render(profile: String, port: Int) -> String {
        let head = """
        mixed-port: \(port)
        bind-address: 127.0.0.1
        allow-lan: false
        mode: rule
        log-level: warning
        ipv6: false
        tcp-concurrent: true
        find-process-mode: "off"
        dns:
          enable: true
          ipv6: false
          nameserver:
          - 223.5.5.5
          - 119.29.29.29
        """
        return head + "\n" + blocks(profile).filter { kept.contains($0.key) }.map { $0.text }.joined(separator: "\n") + "\n"
    }
}

// MARK: the core process

public final class ProxyCore: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()
    private var process: Process?
    private var stopping = false
    public private(set) var port: Int?
    public var onExit: (@Sendable () -> Void)?

    public init(dir: URL? = nil) {
        self.dir = dir ?? ((FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent("Radar/proxy", isDirectory: true))
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true && port != nil } }

    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return got == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    static func accepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A core left over from a Radar that was killed: stop it (only if the pid still belongs to a mihomo).
    func stopStale() {
        let pidFile = dir.appendingPathComponent("core.pid")
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if Self.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="]).output.contains("mihomo") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Starts the core with the subscription's nodes and rules on a free local port, and returns that port.
    public func start(_ verge: VergeProfile) async throws -> Int {
        if let p = lock.withLock({ process?.isRunning == true ? port : nil }) { return p }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stopStale()
        let sig = Self.run("/usr/bin/codesign", ["--verify", verge.core.path])
        guard sig.status == 0 else { throw ProxyProblem.unsigned(String(sig.output.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        for name in ["Country.mmdb", "geoip.dat", "geosite.dat", "ASN.mmdb"] {   // so the core never has to download them
            let from = verge.home.appendingPathComponent(name), to = dir.appendingPathComponent(name)
            let size = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil }
            if fm.fileExists(atPath: from.path), size(from) != size(to) { try? fm.removeItem(at: to); try? fm.copyItem(at: from, to: to) }
        }
        guard let text = try? String(contentsOf: verge.profile, encoding: .utf8), ClashConfig.hasContent(text) else { throw ProxyProblem.badProfile }
        guard let port = Self.freePort() else { throw ProxyProblem.failed("没有可用的本地端口") }
        let config = dir.appendingPathComponent("config.yaml")
        try? fm.removeItem(at: config)
        guard fm.createFile(atPath: config.path, contents: Data(ClashConfig.render(profile: text, port: port).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProxyProblem.failed("无法写入代理配置")
        }
        let logURL = dir.appendingPathComponent("core.log")
        if let n = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? nil, n > 1_000_000 { try? fm.removeItem(at: logURL) }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try? FileHandle(forWritingTo: logURL); _ = try? log?.seekToEnd()

        let p = Process()
        p.executableURL = verge.core
        p.arguments = ["-d", dir.path, "-f", config.path]
        p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in self?.exited(proc) }
        lock.withLock { stopping = false }
        do { try p.run() } catch { throw ProxyProblem.failed("代理内核无法启动：\(error.localizedDescription)") }
        lock.withLock { process = p }
        try? "\(p.processIdentifier)".write(to: dir.appendingPathComponent("core.pid"), atomically: true, encoding: .utf8)
        watch(child: p.processIdentifier)

        for _ in 0..<80 {   // up to 8 s
            if !p.isRunning { throw ProxyProblem.failed("代理内核启动后立即退出：" + lastLog()) }
            if Self.accepts(port) { lock.withLock { self.port = port }; return port }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        throw ProxyProblem.failed("代理内核启动超时")
    }

    /// If Radar dies without a chance to clean up, this small watcher ends the core with it.
    private func watch(child: Int32) {
        let w = Process()
        w.executableURL = URL(fileURLWithPath: "/bin/sh")
        w.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null && kill -0 \(child) 2>/dev/null; do sleep 2; done; kill \(child) 2>/dev/null"]
        w.standardInput = FileHandle.nullDevice; w.standardOutput = FileHandle.nullDevice; w.standardError = FileHandle.nullDevice
        try? w.run()
    }

    func lastLog() -> String {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("core.log"), encoding: .utf8) else { return "" }
        return String((s.split(separator: "\n").last ?? "").prefix(160))
    }

    private func exited(_ proc: Process) {
        let intended: Bool = lock.withLock {
            guard process === proc else { return true }
            process = nil; port = nil
            let s = stopping; stopping = false; return s
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("core.pid"))
        if !intended { onExit?() }
    }

    public func stop() {
        let p: Process? = lock.withLock { stopping = true; let p = process; process = nil; port = nil; return p }
        p?.terminate()
    }
}

// MARK: deciding whether to use it

/// Where Radar's network traffic goes: straight out, or through the local proxy core.
public final class NetworkRoute: @unchecked Sendable {
    public static let shared = NetworkRoute()

    public enum State: Equatable {
        case off
        case direct(String)        // why no proxy is needed
        case proxied(Int)          // local port of the running core
        case unavailable(String)   // a proxy was wanted but could not be started
    }

    public typealias Probe = @Sendable () async -> Bool
    public typealias Starter = @Sendable (VergeProfile) async throws -> Int

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let core: ProxyCore
    private let probe: Probe
    private let locate: @Sendable () -> Result<VergeProfile, ProxyProblem>
    private let starter: Starter?
    private let stopper: (@Sendable () -> Void)?
    private var _state = State.off
    private var generation = 0
    private var inflight: Task<Void, Never>?
    private var lastEval: Date?
    private var sessions: [String: URLSession] = [:]
    private var restarts: [Date] = []
    public var onChange: (@Sendable (State) -> Void)?

    public init(defaults: UserDefaults = .standard, core: ProxyCore = ProxyCore(), probe: Probe? = nil,
                locate: @escaping @Sendable () -> Result<VergeProfile, ProxyProblem> = { VergeLocator.locate() },
                starter: Starter? = nil, stopper: (@Sendable () -> Void)? = nil) {
        self.defaults = defaults; self.core = core; self.locate = locate; self.starter = starter; self.stopper = stopper
        self.probe = probe ?? Self.directProbe
        core.onExit = { [weak self] in self?.coreDied() }
    }

    /// Can this machine reach a site the core exists for? Through the system's own settings, so a running Clash Verge
    /// (TUN or system proxy) counts as "yes" and Radar leaves it alone.
    static let directProbe: Probe = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6; cfg.timeoutIntervalForResource = 8
        let s = URLSession(configuration: cfg)
        defer { s.finishTasksAndInvalidate() }
        guard let (_, resp) = try? await s.data(from: URL(string: "https://www.google.com/generate_204")!), let h = resp as? HTTPURLResponse else { return false }
        return (200..<400).contains(h.statusCode)
    }

    public var mode: ProxyMode {
        get { ProxyMode(rawValue: defaults.string(forKey: "proxyMode") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "proxyMode"); lock.withLock { lastEval = nil } }
    }
    public var state: State { lock.withLock { _state } }
    public var proxyPort: Int? { if case .proxied(let p) = state { return p } else { return nil } }

    /// Appended to network errors so "the source is down" and "the proxy is down" can be told apart.
    public var errorHint: String? {
        switch state {
        case .unavailable(let m): return "（代理不可用：\(m)）"
        case .proxied: return "（已走内置代理）"
        default: return nil
        }
    }

    private func set(_ s: State) {
        let changed: Bool = lock.withLock {
            guard _state != s else { return false }
            _state = s; generation += 1; return true
        }
        if changed { onChange?(s) }
    }

    private func ttl(_ s: State) -> TimeInterval {
        switch s { case .off: return 3600; case .direct: return 180; case .proxied: return 60; case .unavailable: return 30 }
    }

    /// Looks at the current mode and the network, and starts or stops the core to match. Calls made while one is running join it;
    /// a recent result is reused unless `force`.
    public func evaluate(force: Bool = false) async {
        let task: Task<Void, Never> = lock.withLock {
            if let t = inflight { return t }
            if !force, let at = lastEval, Date().timeIntervalSince(at) < ttl(_state) { return Task {} }
            let t = Task { [self] in
                await run()
                lock.withLock { inflight = nil; lastEval = Date() }
            }
            inflight = t
            return t
        }
        await task.value
    }

    private func run() async {
        switch mode {
        case .off: stopCore(); set(.off)
        case .always: await ensureCore()
        case .auto:
            if await probe() { stopCore(); set(.direct("不需要：直连已可用")) } else { await ensureCore() }
        }
    }

    private func stopCore() { if let stopper { stopper() } else { core.stop() } }

    private func ensureCore() async {
        switch locate() {
        case .failure(let p): set(.unavailable(p.errorDescription ?? "未知原因"))
        case .success(let v):
            do { set(.proxied(try await (starter ?? { try await self.core.start($0) })(v))) }
            catch { set(.unavailable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) }
        }
    }

    /// The core quit by itself: say so, and try again a few times (not in a loop).
    private func coreDied() {
        set(.unavailable("代理内核意外退出"))
        let again: Bool = lock.withLock {
            restarts = restarts.filter { Date().timeIntervalSince($0) < 600 } + [Date()]
            return restarts.count <= 3 && mode != .off
        }
        guard again else { return }
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await evaluate(force: true) }
    }

    /// Radar is quitting.
    public func shutdown() { stopCore() }

    /// A session for outgoing requests: through the local core while it is in use. Rebuilt whenever the route changes.
    public func session(request: TimeInterval, resource: TimeInterval) -> URLSession {
        lock.withLock {
            let key = "\(generation)|\(request)|\(resource)"
            if let s = sessions[key] { return s }
            for (k, s) in sessions where !k.hasPrefix("\(generation)|") { s.finishTasksAndInvalidate() }
            sessions = sessions.filter { $0.key.hasPrefix("\(generation)|") }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = request; cfg.timeoutIntervalForResource = resource
            if case .proxied(let p) = _state { cfg.connectionProxyDictionary = Self.proxyDictionary(port: p) }
            let s = URLSession(configuration: cfg)
            sessions[key] = s
            return s
        }
    }

    static func proxyDictionary(port: Int) -> [AnyHashable: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
         "ExceptionsList": ["localhost", "127.0.0.1", "::1", "*.local"]]
    }
}
