import SwiftUI
import RadarCore
import GRDB
import UniformTypeIdentifiers

enum Selection: Hashable { case updates, briefing, ask(Int64?), watch(Int64) }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Selection? = .updates
    @State private var watches: [Watch] = []
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("更新", systemImage: "bell.badge").badge(model.unread).tag(Selection.updates)
                Label("AI 简报", systemImage: "sparkles").tag(Selection.briefing)
                Label("问 Radar", systemImage: "bubble.left.and.text.bubble.right").tag(Selection.ask(nil))
                Section("关注") {
                    ForEach(watches) { w in
                        Label(w.title, systemImage: icon(w)).tag(Selection.watch(w.id!))
                            .foregroundStyle(w.isActive ? .primary : .secondary)
                    }
                    if watches.isEmpty { Text("还没有关注事项").foregroundStyle(.secondary) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                Button { showNew = true } label: { Label("新建关注", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).padding(10)
            }
        } detail: {
            switch selection {
            case .watch(let id): WatchDetailView(watchID: id, selection: $selection).id(id)
            case .briefing: BriefingView()
            case .ask(let scope): AskRadarView(scope: scope).id(scope)
            default: UpdatesView(onNew: { showNew = true })
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Self.exportSources(model.store) } label: { Label("导出信息源", systemImage: "square.and.arrow.up") }.help("把所有信息源导出为 JSON 文件")
            }
            ToolbarItem {
                Button { Task { await model.checkDue(force: true) } } label: {
                    if model.checking > 0 { ProgressView().controlSize(.small) } else { Label("立即检查全部", systemImage: "arrow.clockwise") }
                }.help("立即检查全部来源")
            }
        }
        .sheet(isPresented: $showNew) { NewWatchView { id in selection = .watch(id) }.environmentObject(model) }
        .task {
            // Dev aid: RADAR_SNAPSHOT=<dir> writes PNGs of the window (updates view, then first watch) and quits.
            guard let dir = ProcessInfo.processInfo.environment["RADAR_SNAPSHOT"] else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            func shot(_ name: String) { Self.snapshot(dir + "/" + name) }
            try? NSApp.windows.map { "\($0.title) \($0.frame) vis=\($0.isVisible) sheet=\($0.isSheet) \(type(of: $0))" }.joined(separator: "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
            shot("updates.png")
            if let w = watches.first?.id { selection = .watch(w); try? await Task.sleep(nanoseconds: 2_000_000_000); shot("watch.png") }
            showNew = true; try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let sheet = NSApp.windows.first(where: { $0.isSheet })?.contentView, let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                sheet.cacheDisplay(in: sheet.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/new.png"))
            }
            NSApp.terminate(nil)
        }
        .task { await drive() }
        .task(id: model.revision) {
            watches = (try? await model.store.db.read { try Watch.order(Column("createdAt").desc).fetchAll($0) }) ?? []
        }
    }

    static func exportSources(_ store: Store) {
        guard let data = try? store.exportSources() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Radar-信息源-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    static func snapshot(_ path: String) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.frame.width > 600 }),
              let v = win.contentView?.superview ?? win.contentView else { return }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Dev aid: RADAR_DRIVE_DIR + RADAR_DRIVE_TEXT (+ RADAR_DRIVE_NL) runs the real flow in the running app —
    /// create a watch from the sentence, check, pause/resume, fake an incremental update, edit by natural language — with a PNG at each stage.
    func drive() async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["RADAR_DRIVE_DIR"], let text = env["RADAR_DRIVE_TEXT"] else { return }
        func log(_ s: String) { print("DRIVE", s); FileHandle.standardError.write(Data(("DRIVE " + s + "\n").utf8)) }
        func settle(_ max: Double = 240) async {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var t = 0.0
            while model.checking > 0 && t < max { try? await Task.sleep(nanoseconds: 1_000_000_000); t += 1 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        showNew = true
        var t = 0
        while watches.isEmpty && t < 240 { try? await Task.sleep(nanoseconds: 1_000_000_000); t += 1 }      // NewWatchView analyses and creates by itself
        log("watch created after \(t)s")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await settle(); Self.snapshot(dir + "/1-created.png")
        let wid = watches[0].id!
        let w0 = watches[0]; model.setStatus(w0, active: false); try? await Task.sleep(nanoseconds: 1_500_000_000); Self.snapshot(dir + "/2-paused.png")
        model.setStatus(w0, active: true); try? await Task.sleep(nanoseconds: 1_000_000_000)
        // real incremental: wait, then re-read the real sources and compare what GitHub now says
        func stars() async -> [String: Int] {
            let es = (try? await model.store.db.read { try Entry.fetchAll($0) }) ?? []
            return Dictionary(es.map { ($0.canonicalURL, Int($0.meta["stars"] ?? "") ?? 0) }, uniquingKeysWith: { a, _ in a })
        }
        var guardT = 0
        while ((try? await model.store.db.read { try Entry.fetchCount($0) }) ?? 0) == 0 && guardT < 120 { try? await Task.sleep(nanoseconds: 1_000_000_000); guardT += 1 }
        await settle()
        let s0 = await stars(); let e0 = (try? await model.store.db.read { try Event.fetchCount($0) }) ?? 0
        let wait = Double(env["RADAR_DRIVE_WAIT"] ?? "180") ?? 180
        log("waiting \(Int(wait))s for the real sources to move")
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        await model.checkDue(force: true); await settle()
        let s1 = await stars(); let e1 = (try? await model.store.db.read { try Event.fetchCount($0) }) ?? 0
        log("repos \(s0.count) -> \(s1.count), stars changed on \(s1.filter { s0[$0.key] != nil && s0[$0.key]! != $0.value }.count), events \(e0) -> \(e1)")
        selection = .updates; try? await Task.sleep(nanoseconds: 2_000_000_000); Self.snapshot(dir + "/3-updates.png")
        selection = .watch(wid); try? await Task.sleep(nanoseconds: 1_500_000_000)
        let before = (try? await model.store.db.read { try Source.fetchCount($0) }) ?? 0
        if let nl = env["RADAR_DRIVE_NL"] { model.driveNL = nl }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await settle(300)
        let after = (try? await model.store.db.read { try Source.fetchCount($0) }) ?? 0
        log("sources \(before) -> \(after) after natural-language edit")
        Self.snapshot(dir + "/4-after-edit.png")
        let evs = (try? await model.store.db.read { try Event.fetchCount($0) }) ?? 0
        log("events \(evs)")
        exit(0)
    }

    func icon(_ w: Watch) -> String {
        if !w.isActive { return "pause.circle" }
        switch w.plan.type {
        case .githubRelease: return "tag"
        case .topic: return "sparkle.magnifyingglass"
        case .feed: return "dot.radiowaves.up.forward"
        case .webpage: return "doc.text.magnifyingglass"
        }
    }
}

struct EventRow: View {
    static func badge(_ kind: String) -> (String, Color)? {
        switch kind { case "newProject": return ("新项目", .green); case "majorUpdate": return ("重大更新", .orange); case "pageChange": return ("页面变化", .blue); default: return nil }
    }
    let event: Event
    var watchTitle: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(event.readAt == nil ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let b = Self.badge(event.kind) { Text(b.0).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(b.1.opacity(0.2), in: Capsule()).foregroundStyle(b.1) }
                    Text(event.title).font(.headline)
                }
                Text(event.reason).foregroundStyle(.secondary)
                if let b = event.beforeSnippet, let a = event.afterSnippet {
                    Text("前：\(b)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text("后：\(a)").font(.caption).lineLimit(3)
                }
                HStack(spacing: 8) {
                    if let watchTitle { Text(watchTitle) }
                    Text(event.createdAt.formatted(.relative(presentation: .named)))
                    Link(event.evidenceURL, destination: URL(string: event.evidenceURL) ?? URL(string: "about:blank")!).lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
                if event.evidence.count > 1 {
                    Text("同一内容的 \(event.evidence.count) 个来源：" + event.evidence.map { $0.name }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }
}

struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    @State private var events: [Event] = []
    @State private var titles: [Int64: String] = [:]
    @State private var loaded = false
    var onNew: () -> Void = {}
    var body: some View {
        Group {
            if loaded && titles.isEmpty && events.isEmpty {
                WelcomeView(ai: model.ai, onNew: onNew)
            } else if events.isEmpty {
                ContentUnavailableView("暂无更新", systemImage: "bell", description: Text("首次读取只建立基线，之后出现的新内容会显示在这里。"))
            } else {
                List(events) { e in
                    EventRow(event: e, watchTitle: titles[e.watchID])
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(e) }
                        .contextMenu { Button("标为已读") { model.markRead(e) } }
                }
            }
        }
        .navigationTitle("更新")
        .toolbar { Button("全部已读") { model.markAllRead() }.disabled(model.unread == 0) }
        .task(id: model.revision) {
            let r = try? await model.store.db.read { db in (try Event.order(Column("createdAt").desc).limit(300).fetchAll(db), try Watch.fetchAll(db)) }
            events = r?.0 ?? []
            titles = Dictionary(uniqueKeysWithValues: (r?.1 ?? []).map { ($0.id!, $0.title) })
            loaded = r != nil
        }
    }
}

/// Shown until the first watch exists: the three things a new user has to do, with live status.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ai: AssistantModel
    var onNew: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("欢迎使用 Radar").font(.largeTitle.bold())
            Text("用一句话说出你关心什么，Radar 持续盯着，只在有新东西时告诉你。").foregroundStyle(.secondary)
            step("1", "建立第一个关注", "例如：关注 chatgpt、claude、codex 的最新动态", done: false) {
                Button("新建关注", action: onNew).buttonStyle(.borderedProminent)
            }
            step("2", "允许系统通知", "新项目和重大更新会弹通知；其余留在“更新”列表", done: model.notifyStatus == .authorized) {
                if model.notifyStatus != .authorized {
                    Button("打开系统通知设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                }
            }
            step("3", "连接本机 Ollama（可选）", "用于 AI 简报和“问 Radar”，只用本机模型。没有它其余功能照常使用", done: ai.status == .ready) {
                if ai.status != .ready { Link("下载 Ollama", destination: URL(string: "https://ollama.com")!) }
            }
            Spacer()
            Text("Radar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · 数据只保存在本机").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(32).frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading).frame(maxWidth: .infinity)
        .task { await ai.refresh() }
    }
    func step<A: View>(_ n: String, _ title: String, _ detail: String, done: Bool, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").font(.title2).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                action().padding(.top, 2)
            }
        }
    }
}
