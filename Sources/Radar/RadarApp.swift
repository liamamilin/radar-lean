import SwiftUI
import RadarCore

@main
struct RadarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Radar", id: "main") {
            ContentView().environmentObject(model).radarLinks().frame(minWidth: 900, minHeight: 560)
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
    @State private var token = ""
    @State private var searchKey = ""
    @State private var saved = false
    var body: some View {
        Form {
            SecureField("GitHub Token（可选）", text: $token)
            Text("提高 GitHub API 限额，保存在系统钥匙串。不需要任何权限范围。").font(.caption).foregroundStyle(.secondary)
            SecureField("Exa API Key", text: $searchKey)
            Text("用于按主题联网搜索信息源（dashboard.exa.ai 申请），保存在系统钥匙串。不填则只用内置目录和 GitHub 搜索。").font(.caption).foregroundStyle(.secondary)
            Section("本机 Ollama（AI 总结 / 问 Radar）") {
                OllamaSettings(ai: model.ai)
            }
            HStack {
                Button("保存") {
                    model.setToken(token); model.setSearchKey(searchKey)
                    saved = true
                    Task { try? await Task.sleep(for: .seconds(2)); saved = false }
                }
                if saved { Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 470)
        .onAppear {   // a scratch database (RADAR_DB) never touches the real Keychain
            guard !model.isolated else { return }
            token = Keychain.get() ?? ""; searchKey = Keychain.get(Keychain.searchService) ?? ""
            model.adopt(token: token, searchKey: searchKey)
        }
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
        if model.notifyStatus == .denied {
            Button("系统通知已关闭 — 打开系统设置") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
        Divider()
        if model.recent.isEmpty { Text("暂无事件") }
        ForEach(model.recent, id: \.id) { e in
            Button(e.title) { model.open(e) }
        }
        Divider()
        Button("退出 Radar") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct OllamaSettings: View {
    @ObservedObject var ai: AssistantModel
    var body: some View {
        Group { content }.task { await ai.refresh() }
    }
    @ViewBuilder var content: some View {
        HStack {
            switch ai.status {
            case .ready: Label("已连接，\(ai.models.count) 个本地模型", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unknown: Label("检测中…", systemImage: "ellipsis.circle")
            default: Label("未连接", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Spacer()
            Button("重新检测") { Task { await ai.refresh() } }
        }
        if !ai.models.isEmpty {
            Picker("模型", selection: Binding(get: { ai.selected?.name ?? "" }, set: { ai.selectedName = $0 })) {
                ForEach(ai.models) { Text($0.name).tag($0.name) }
            }
        }
        if let p = ai.problem { Text(p).font(.caption).foregroundStyle(.orange) }
        Text("只使用本机 Ollama（127.0.0.1:11434），不联网、不需要 Key；云端模型不会出现在列表里。").font(.caption).foregroundStyle(.secondary)
    }
}
