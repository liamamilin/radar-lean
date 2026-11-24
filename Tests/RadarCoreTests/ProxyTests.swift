import XCTest
@testable import RadarCore

final class ProxyTests: XCTestCase {
    static let profile = """
    # Profile
    allow-lan: true
    mixed-port: 9981
    mode: global
    tun:
      enable: true
    dns:
      enable: true
      enhanced-mode: fake-ip
    proxies:
    - name: "a b"
      type: ss
      server: 1.2.3.4
    proxy-groups:
    - name: Ghelper
      type: select
      proxies:
      - a b
    rules:
    - DOMAIN-SUFFIX,ip138.com,DIRECT
    - GEOIP,CN,DIRECT
    - MATCH, Ghelper
    """

    func testRenderKeepsOnlyNodesGroupsRulesAndOwnsTheRest() {
        let out = ClashConfig.render(profile: Self.profile, port: 5555)
        XCTAssertTrue(out.hasPrefix("mixed-port: 5555"))
        XCTAssertTrue(out.contains("allow-lan: false") && !out.contains("allow-lan: true"))
        XCTAssertFalse(out.contains("tun:"), "no TUN, no system-level changes")
        XCTAssertFalse(out.contains("fake-ip"))
        XCTAssertFalse(out.contains("mixed-port: 9981") || out.contains("mode: global"))
        XCTAssertTrue(out.contains("mode: rule"))
        XCTAssertTrue(out.contains("- name: \"a b\"") && out.contains("- MATCH, Ghelper") && out.contains("- GEOIP,CN,DIRECT"))
        XCTAssertFalse(out.contains("external-controller"))
    }

    func testHasContent() {
        XCTAssertTrue(ClashConfig.hasContent(Self.profile))
        XCTAssertFalse(ClashConfig.hasContent("mixed-port: 1\nrules:\n- MATCH,DIRECT\n"))
        XCTAssertFalse(ClashConfig.hasContent("proxies:\n- name: x\n"))
    }

    func testParseProfilesAndLocate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verge-\(UUID().uuidString)")
        let home = root.appendingPathComponent(VergeLocator.dataFolder)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        try """
        current: abc
        items:
        - uid: Merge
          type: merge
          file: Merge.yaml
        - uid: abc
          type: remote
          name: null
          file: abc.yaml
          selected:
          - name: Ghelper
            now: x
          extra:
            upload: 10
            download: 90
            total: 1000
            expire: 1814117375
          updated: 1793475592
        """.write(to: home.appendingPathComponent("profiles.yaml"), atomically: true, encoding: .utf8)
        try Self.profile.write(to: home.appendingPathComponent("profiles/abc.yaml"), atomically: true, encoding: .utf8)
        let app = root.appendingPathComponent("Clash Verge.app/Contents/MacOS"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let core = app.appendingPathComponent("verge-mihomo"); try "#!/bin/sh".write(to: core, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core.path)

        guard case .success(let v) = VergeLocator.locate(applicationSupport: root, appPaths: [root.appendingPathComponent("Clash Verge.app").path]) else { return XCTFail("not located") }
        XCTAssertEqual(v.profile.lastPathComponent, "abc.yaml")
        XCTAssertEqual(v.used, 100); XCTAssertEqual(v.total, 1000)
        XCTAssertEqual(v.updated, Date(timeIntervalSince1970: 1793475592)); XCTAssertNotNil(v.expire)
        XCTAssertEqual(VergeLocator.locate(applicationSupport: root, appPaths: ["/nonexistent"]), .failure(.notInstalled))
        try FileManager.default.removeItem(at: home.appendingPathComponent("profiles/abc.yaml"))
        XCTAssertEqual(VergeLocator.locate(applicationSupport: root, appPaths: [root.appendingPathComponent("Clash Verge.app").path]), .failure(.noProfile))
    }

    func testFreePortAndAccepts() throws {
        let p = try XCTUnwrap(ProxyCore.freePort())
        XCTAssertGreaterThan(p, 1024)
        XCTAssertFalse(ProxyCore.accepts(p))
    }

    // MARK: route decisions

    final class Counter: @unchecked Sendable { var starts = 0, stops = 0; var direct = false }
    static let fakeVerge = VergeProfile(core: URL(fileURLWithPath: "/x"), profile: URL(fileURLWithPath: "/y"), home: URL(fileURLWithPath: "/z"))

    func route(_ c: Counter, locate: Result<VergeProfile, ProxyProblem> = .success(fakeVerge), fail: Bool = false) -> NetworkRoute {
        let d = UserDefaults(suiteName: "proxytest-\(UUID().uuidString)")!
        return NetworkRoute(defaults: d, probe: { c.direct }, locate: { locate },
                            starter: { _ in c.starts += 1; if fail { throw ProxyProblem.failed("boom") }; return 4321 }, stopper: { c.stops += 1 })
    }

    func testOffByDefaultDoesNothing() async {
        let c = Counter(), r = route(c)
        XCTAssertEqual(r.mode, .off)
        await r.evaluate(force: true)
        XCTAssertEqual(r.state, .off); XCTAssertEqual(c.starts, 0); XCTAssertNil(r.proxyPort)
    }

    func testAutoLeavesAloneWhenDirectWorks() async {
        let c = Counter(); c.direct = true
        let r = route(c); r.mode = .auto
        await r.evaluate(force: true)
        guard case .direct = r.state else { return XCTFail("\(r.state)") }
        XCTAssertEqual(c.starts, 0)
    }

    func testAutoStartsCoreWhenDirectFailsAndStopsWhenItWorksAgain() async {
        let c = Counter()
        let r = route(c); r.mode = .auto
        await r.evaluate(force: true)
        XCTAssertEqual(r.state, .proxied(4321)); XCTAssertEqual(r.proxyPort, 4321); XCTAssertEqual(c.starts, 1)
        c.direct = true   // Clash Verge was turned on (TUN)
        await r.evaluate(force: true)
        guard case .direct = r.state else { return XCTFail("\(r.state)") }
        XCTAssertGreaterThanOrEqual(c.stops, 1); XCTAssertNil(r.proxyPort)
    }

    func testAlwaysSkipsProbe() async {
        let c = Counter(); c.direct = true
        let r = route(c); r.mode = .always
        await r.evaluate(force: true)
        XCTAssertEqual(r.state, .proxied(4321))
    }

    func testProblemsBecomeUnavailableNotCrashes() async {
        var c = Counter(), r = route(c, locate: .failure(.notInstalled)); r.mode = .always
        await r.evaluate(force: true)
        guard case .unavailable(let m) = r.state else { return XCTFail() }
        XCTAssertTrue(m.contains("Clash Verge")); XCTAssertNotNil(r.errorHint)
        c = Counter(); r = route(c, fail: true); r.mode = .always
        await r.evaluate(force: true)
        XCTAssertEqual(r.state, .unavailable("boom"))
    }

    func testRecentResultIsReusedUnlessForced() async {
        let c = Counter(), r = route(c); r.mode = .always
        await r.evaluate(force: true); await r.evaluate(); await r.evaluate()
        XCTAssertEqual(c.starts, 1)
    }

    func testSessionFollowsRoute() async {
        let c = Counter(), r = route(c)
        XCTAssertNil(r.session(request: 5, resource: 5).configuration.connectionProxyDictionary)
        r.mode = .always; await r.evaluate(force: true)
        let d = r.session(request: 5, resource: 5).configuration.connectionProxyDictionary
        XCTAssertEqual(d?["HTTPSPort"] as? Int, 4321); XCTAssertEqual(d?["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertTrue((d?["ExceptionsList"] as? [String])?.contains("localhost") == true)
    }
}
