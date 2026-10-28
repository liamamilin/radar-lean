import SwiftUI
import RadarCore
import GRDB

enum Selection: Hashable { case updates, watch(Int64) }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Selection? = .updates
    @State private var watches: [Watch] = []
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("更新", systemImage: "bell.badge").badge(model.unread).tag(Selection.updates)
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
            default: UpdatesView()
            }
        }
        .toolbar {
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
            func shot(_ name: String) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.frame.width > 600 }),
                      let v = win.contentView?.superview ?? win.contentView else { return }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = v.bounds.size
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
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
        .task(id: model.revision) {
            watches = (try? await model.store.db.read { try Watch.order(Column("createdAt").desc).fetchAll($0) }) ?? []
        }
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
    let event: Event
    var watchTitle: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(event.readAt == nil ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.headline)
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
            }
        }.padding(.vertical, 3)
    }
}

struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    @State private var events: [Event] = []
    @State private var titles: [Int64: String] = [:]
    var body: some View {
        Group {
            if events.isEmpty {
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
        }
    }
}
