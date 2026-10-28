import SwiftUI
import RadarCore

@main
struct RadarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Radar", id: "main") {
            ContentView().environmentObject(model).frame(minWidth: 900, minHeight: 560)
        }
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.unread > 0 ? "dot.radiowaves.left.and.right.circle.fill" : "dot.radiowaves.left.and.right")
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var token = Keychain.get() ?? ""
    @State private var searchKey = Keychain.get(Keychain.searchService) ?? ""
    @State private var saved = false
    var body: some View {
        Form {
            SecureField("GitHub Token（可选）", text: $token)
            Text("提高 GitHub API 限额，保存在系统钥匙串。不需要任何权限范围。").font(.caption).foregroundStyle(.secondary)
            SecureField("Exa API Key", text: $searchKey)
            Text("用于按主题联网搜索信息源（dashboard.exa.ai 申请），保存在系统钥匙串。不填则只用内置目录和 GitHub 搜索。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存") {
                    model.setToken(token); model.setSearchKey(searchKey)
                    saved = true
                    Task { try? await Task.sleep(for: .seconds(2)); saved = false }
                }
                if saved { Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .formStyle(.grouped).frame(width: 480, height: 300)
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("打开 Radar") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("立即检查全部") { Task { await model.checkDue(force: true) } }.disabled(model.checking > 0)
        Toggle("暂停自动检查", isOn: $model.paused)
        SettingsLink { Text("设置…") }
        Divider()
        if model.recent.isEmpty { Text("暂无事件") }
        ForEach(model.recent, id: \.id) { e in
            Button(e.title) { model.open(e) }
        }
        Divider()
        Button("退出 Radar") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
