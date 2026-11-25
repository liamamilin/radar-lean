import Foundation
import WebKit
import Network

/// Renders a page the way a browser would (JavaScript runs), then hands back the resulting HTML. Used by web / list sources whose
/// selector starts with "js:". Uses an ephemeral store (no cookies or logins) and does not try to get past human-verification pages.
@MainActor
enum PageRenderer {
    static let challengeMarkers = ["just a moment", "verify you are human", "checking your browser", "attention required", "are you a robot", "captcha", "人机验证", "安全验证"]

    static func render(_ url: URL, timeout: TimeInterval = 25) async throws -> String {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        if let p = NetworkRoute.shared.proxyPort, let port = NWEndpoint.Port(rawValue: UInt16(p)) {   // the same route as every other request
            cfg.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))]
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 2000), configuration: cfg)
        let loader = Loader(); web.navigationDelegate = loader
        defer { web.stopLoading(); web.navigationDelegate = nil }
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        try await loader.waitForLoad(until: deadline)
        // JS pages keep filling in after "load": wait until the visible text stops growing
        var last = -1, stable = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 600_000_000)
            let n = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.length : 0")) as? Int ?? 0
            if n == last && n > 0 { stable += 1 } else { stable = 0 }
            last = n
            if stable >= 3 { break }
        }
        guard let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String else { throw RadarError.parse("页面渲染没有返回内容") }
        let probe = html.prefix(6000).lowercased()
        if challengeMarkers.contains(where: { probe.contains($0) }) && last < 2000 { throw RadarError.unsupported("网站要求人机验证，Radar 不会绕过") }
        return html
    }

    @MainActor
    private final class Loader: NSObject, WKNavigationDelegate {
        private var cont: CheckedContinuation<Void, Error>?
        private var done = false
        private var resultError: Error?

        func waitForLoad(until deadline: Date) async throws {
            try await withThrowingTaskGroup(of: Void.self) { g in
                g.addTask { @MainActor in
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                            if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                            if self.done {
                                if let e = self.resultError { c.resume(throwing: e) } else { c.resume() }
                                return
                            }
                            self.cont = c
                        }
                    } onCancel: {
                        Task { @MainActor in self.finish(CancellationError()) }
                    }
                }
                g.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(1, deadline.timeIntervalSinceNow) * 1e9))
                    throw RadarError.unsupported("页面渲染超时")
                }
                do {
                    _ = try await g.next()
                    g.cancelAll()
                } catch {
                    g.cancelAll()
                    throw error
                }
            }
        }

        private func finish(_ e: Error?) {
            if !done { done = true; resultError = e }
            if let c = cont {
                cont = nil
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(nil) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(RadarError.parse("页面加载失败：" + e.localizedDescription)) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(RadarError.parse("页面加载失败：" + e.localizedDescription)) }
    }
}
