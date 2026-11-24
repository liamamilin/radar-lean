import SwiftUI
import RadarCore

@main
struct RadarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Radar", id: "main") {
            ContentView().environmentObject(model).radarLinks().frame(minWidth: 940, minHeight: 560)
        }
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.unread > 0 ? "antenna.radiowaves.left.and.right.circle.fill" : "dot.radiowaves.left.and.right")
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
            Section("AI 模型（AI 简报 / 问 Radar）") {
                LLMSettings(ai: model.ai)
            }
            Section("网络代理") {
                ProxySettings(proxy: model.proxy)
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
        .formStyle(.grouped).frame(width: 560, height: 720)
        .onAppear {   // a scratch database (RADAR_DB) never touches the real Keychain
            guard !model.isolated else { return }
            token = Keychain.get() ?? ""; searchKey = Keychain.get(Keychain.searchService) ?? ""
            model.adopt(token: token, searchKey: searchKey)
            model.loadLLMKey(userInitiated: true)
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

struct LLMSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ai: AssistantModel
    @State private var key = ""
    @State private var preset = AssistantModel.presets.first { $0.url == UserDefaults.standard.string(forKey: "llmBaseURL") }?.name
        ?? (UserDefaults.standard.string(forKey: "llmBaseURL") == nil ? AssistantModel.presets[0].name : "自定义")
    var body: some View {
        Group { content }
            .task { key = ai.apiKey; await ai.refresh() }
    }
    @ViewBuilder var content: some View {
        Picker("来源", selection: $ai.provider) { ForEach(AssistantModel.Provider.allCases) { Text($0.label).tag($0) } }
            .onChange(of: ai.provider) { _, _ in Task { await ai.refresh() } }
        if ai.provider == .openai {
            Picker("服务", selection: $preset) { ForEach(AssistantModel.presets, id: \.name) { Text($0.name).tag($0.name) } }
                .onChange(of: preset) { _, p in
                    if let u = AssistantModel.presets.first(where: { $0.name == p })?.url, !u.isEmpty { ai.baseURLString = u }
                }
                .onChange(of: ai.baseURLString) { _, _ in   // every service keeps its own key (a custom address is handled by 保存并测试)
                    guard preset != "自定义" else { return }
                    model.loadLLMKey(userInitiated: true); key = ai.apiKey
                    ai.models = []; ai.status = .unknown; ai.switchNote = nil
                    Task { await ai.refresh() }
                }
            TextField("接口地址", text: $ai.baseURLString, prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder).disabled(preset != "自定义")
            SecureField("API Key", text: $key)
            Text(ai.baseURLString.contains("deepseek.com")
                 ? "Key 保存在系统钥匙串（每个服务各存各的）。DeepSeek 的 Key 在 platform.deepseek.com 创建，按量计费；Radar 会关闭它的“思考”模式以节省费用。"
                 : "Key 保存在系统钥匙串（每个服务各存各的）。OpenCode Go 的 Key 在 opencode.ai 控制台创建；接口地址以 /v1 结尾，Radar 会请求 /models 和 /chat/completions。").font(.caption).foregroundStyle(.secondary)
            Toggle("模型不可用时自动切换备用模型（优先便宜的）", isOn: $ai.autoSwitch)
            if ai.autoSwitch { Text("所选模型被拒绝、限流、出错或没有返回内容时，改用列表里看起来最便宜的其他模型（名字含 flash / mini / lite 的优先，名字含 free 的排在其后，pro / max 最后），最多试 3 个；已经开始输出的回答不会中途切换。当前模型之后会暂时避开一段时间。").font(.caption).foregroundStyle(.secondary) }
        }
        HStack {
            switch ai.status {
            case .ready: Label("已连接，\(ai.models.count) 个模型", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unknown: Label("检测中…", systemImage: "ellipsis.circle")
            default: Label("未连接", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Spacer()
            if ai.provider == .openai { Button("保存并测试") { model.setLLMKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); Task { await ai.refresh() } } }
            else { Button("重新检测") { Task { await ai.refresh() } } }
        }
        if !ai.models.isEmpty {
            Picker("模型", selection: Binding(get: { ai.selected?.name ?? "" }, set: { ai.selectedName = $0 })) {
                ForEach(ai.models) { Text($0.name).tag($0.name) }
            }
        }
        if let p = ai.problem { Text(p).font(.caption).foregroundStyle(.orange) }
        Text(ai.isLocal ? "只使用本机 Ollama（127.0.0.1:11434），不联网、不需要 Key；云端模型不会出现在列表里。"
                        : "生成总结或提问时，会把检索到的资料片段（标题、摘要、链接）发送给上面这个服务；采集信息源本身不使用 AI。").font(.caption).foregroundStyle(.secondary)
    }
}

struct ProxySettings: View {
    @ObservedObject var proxy: ProxyModel
    var body: some View {
        Picker("模式", selection: Binding(get: { proxy.mode }, set: { proxy.setMode($0) })) {
            ForEach(ProxyMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if proxy.mode != .off {
            HStack {
                Circle().fill(proxy.statusColor).frame(width: 8, height: 8)
                Text(proxy.statusText).font(.callout)
                Spacer()
                if proxy.checking { ProgressView().controlSize(.small) }
                Button("重新检测") { Task { await proxy.refresh(force: true) } }.disabled(proxy.checking)
            }
            switch proxy.verge {
            case .failure(let p): Label(p.errorDescription ?? "", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            case .success(let v):
                if let u = v.updated {
                    Text("订阅更新于 \(u.formatted(date: .abbreviated, time: .omitted))" + (v.expire.map { "，\($0.formatted(date: .abbreviated, time: .omitted)) 到期" } ?? "")
                         + (Date().timeIntervalSince(u) > 7 * 86400 ? "。订阅已超过一周没有更新，节点失效时请打开一次 Clash Verge 刷新。" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("用 Clash Verge 自带的内核和你当前选中的订阅，另起一个只服务 Radar 的代理，不改系统代理，也不需要打开 Clash Verge。“自动”会先测试直连：Clash Verge 已开着（TUN 或系统代理）或本来就能访问时，不会启动。订阅里的规则决定哪些网站走代理。本机 Ollama 不走代理。")
            .font(.caption).foregroundStyle(.secondary)
    }
}
