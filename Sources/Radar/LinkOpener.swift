import AppKit
import SwiftUI

/// Opens web links in the default browser, and if that browser shows no window shortly after (a windowless or headless
/// instance of it swallowed the request), opens the link in Safari instead so a click always shows the page.
enum LinkOpener {
    static func open(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https",
              let browser = NSWorkspace.shared.urlForApplication(toOpen: url) else { NSWorkspace.shared.open(url); return }
        let name = FileManager.default.displayName(atPath: browser.path).replacingOccurrences(of: ".app", with: "")
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if !hasWindow(named: name), let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    static func hasWindow(named name: String) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }
}

extension View {
    func radarLinks() -> some View { environment(\.openURL, OpenURLAction { LinkOpener.open($0); return .handled }) }
}
