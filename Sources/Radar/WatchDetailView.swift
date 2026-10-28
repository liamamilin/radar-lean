import SwiftUI
import RadarCore
import GRDB

struct WatchDetailView: View {
    let watchID: Int64
    @Binding var selection: Selection?
    @EnvironmentObject var model: AppModel
    @State private var watch: Watch?
    @State private var plan = WatchPlan(type: .topic, title: "")
    @State private var sources: [Source] = []
    @State private var entries: [(Entry, Source)] = []
    @State private var events: [Event] = []
    @State private var includeText = ""
    @State private var excludeText = ""
    @State private var nl = ""
    @State private var nlMessage: String?
    @State private var addURL = ""
    @State private var addMessage: String?
    @State private var tracking: Set<String> = []

    var body: some View {
        Form {
            if let watch {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(watch.title).font(.title2.bold())
                            Text(watch.originalText).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("立即检查") { Task { await model.check(watchID: watchID) } }.disabled(model.checking > 0)
                        Button(watch.isActive ? "暂停" : "继续") { model.setStatus(watch, active: !watch.isActive) }
                        Button("删除", role: .destructive) { selection = .updates; model.delete(watch) }
                    }
                }
                Section("关注条件") {
                    TextField("包含关键词（逗号分隔，空 = 不限）", text: $includeText)
                    TextField("排除关键词", text: $excludeText)
                    if plan.type == .githubRelease {
                        Toggle("仅稳定版（排除预发布）", isOn: $plan.stableOnly)
                        TextField("最低版本（如 1.0.0）", text: Binding(get: { plan.minimumVersion ?? "" }, set: { plan.minimumVersion = $0.isEmpty ? nil : $0 }))
                    }
                    if let u = plan.unsupported, !u.isEmpty {
                        ForEach(u, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    if plan.type == .topic {
                        TextField("GitHub 新项目最低 Stars（默认 50）", text: Binding(get: { plan.minStars.map(String.init) ?? "" }, set: { plan.minStars = Int($0) }))
                    }
                    Toggle(plan.type == .topic ? "系统通知（仅新项目 / 重大更新）" : "系统通知", isOn: $plan.notify)
                    HStack {
                        TextField("用一句话调整，例如：排除 AI 绘画 / 不要预发布", text: $nl).onSubmit(applyNL)
                        Button("应用", action: applyNL).disabled(nl.isEmpty)
                    }
                    if let nlMessage { Text(nlMessage).font(.caption).foregroundStyle(.orange) }
                    Button("保存条件") { save() }
                }
                Section("信息源") {
                    ForEach(sources) { s in sourceRow(s) }
                    HStack {
                        TextField("添加来源 URL（GitHub 仓库 / RSS / 网页）", text: $addURL).onSubmit(addSource)
                        Button("添加", action: addSource).disabled(addURL.isEmpty)
                    }
                    if let addMessage { Text(addMessage).font(.caption).foregroundStyle(.orange) }
                }
                Section("已发现内容（\(entries.count)）") {
                    if entries.isEmpty { Text("来源尚未成功读取").foregroundStyle(.secondary) }
                    ForEach(entries, id: \.0.id) { e, s in entryRow(e, s) }
                }
                Section("事件（\(events.count)）") {
                    if events.isEmpty { Text("尚无事件。首次读取只建立基线，之后的新内容才会产生事件。").foregroundStyle(.secondary) }
                    ForEach(events) { e in EventRow(event: e).onTapGesture { model.open(e) } }
                }
            } else { ProgressView() }
        }
        .formStyle(.grouped)
        .navigationTitle(watch?.title ?? "")
        .task(id: model.revision) { await load() }
        .onChange(of: model.driveNL) { _, v in if let v { nl = v; model.driveNL = nil; applyNL() } }
    }

    func sourceRow(_ s: Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.name).font(.headline)
                Text(s.kind.label).font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule())
                Spacer()
                intervalPicker(s)
                Button("检查") { Task { await model.check(sourceID: s.id!) } }.disabled(model.checking > 0)
                Button { try? model.store.detach(watchID: watchID, sourceID: s.id!) } label: { Image(systemName: "minus.circle") }.help("从这个关注里移除此来源")
            }
            Text(s.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !s.initialized && s.lastError == nil { Text("等待首次读取…").font(.caption) }
            HStack(spacing: 12) {
                Text("最近检查：" + (s.lastCheckedAt?.formatted(.relative(presentation: .named)) ?? "—"))
                Text("最近成功：" + (s.lastSuccessAt?.formatted(.relative(presentation: .named)) ?? "—"))
                Text("下次：" + s.nextDueAt.formatted(date: .omitted, time: .shortened))
            }.font(.caption).foregroundStyle(.secondary)
            if let err = s.lastError {
                Label("读取失败：\(err)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }.padding(.vertical, 2)
    }

    static let intervals: [Double] = [900, 3600, 7200, 14400, 21600, 43200, 86400]

    func intervalPicker(_ s: Source) -> some View {
        let binding = Binding<Double>(get: { s.intervalSeconds }, set: { v in
            try? model.store.db.write { try $0.execute(sql: "UPDATE source SET intervalSeconds = ? WHERE id = ?", arguments: [v, s.id]) }
        })
        return Picker("", selection: binding) {
            ForEach(Self.intervals, id: \.self) { v in
                Text(v < 3600 ? "\(Int(v / 60)) 分钟" : "\(Int(v / 3600)) 小时").tag(v)
            }
        }.labelsHidden().frame(width: 100)
    }

    func entryRow(_ e: Entry, _ s: Source) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Link(e.title, destination: URL(string: e.canonicalURL) ?? URL(string: "about:blank")!).font(.headline)
                if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 8) {
                    if let st = e.meta["stars"] { Text("★ \(st)") }
                    if let l = e.meta["language"], !l.isEmpty { Text(l) }
                    Text("发现于 " + e.firstSeenAt.formatted(.relative(presentation: .named)))
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if s.kind == .githubSearch, let full = e.meta["fullName"] {
                Button(tracking.contains(full) ? "已追踪" : "追踪版本") { trackReleases(full) }.disabled(tracking.contains(full))
            }
        }
    }

    func load() async {
        let r = try? await model.store.db.read { db -> (Watch?, [Source], [(Entry, Source)], [Event]) in
            let w = try Watch.fetchOne(db, key: watchID)
            let srcs = try Source.fetchAll(db, sql: "SELECT source.* FROM source JOIN watchSource ws ON ws.sourceID = source.id WHERE ws.watchID = ?", arguments: [watchID])
            var ents: [(Entry, Source)] = []
            for s in srcs {
                let es = try Entry.filter(Column("sourceID") == s.id!).order(Column("firstSeenAt").desc, Column("id").desc).limit(60).fetchAll(db)
                ents += es.map { ($0, s) }
            }
            let evs = try Event.filter(Column("watchID") == watchID).order(Column("createdAt").desc).limit(100).fetchAll(db)
            return (w, srcs, ents, evs)
        }
        guard let r else { return }
        let first = watch == nil
        watch = r.0; sources = r.1; entries = r.2; events = r.3
        if first, let w = r.0 { plan = w.plan; includeText = plan.include.joined(separator: ", "); excludeText = plan.exclude.joined(separator: ", ") }
        let tracked = (try? await model.store.db.read { try String.fetchAll($0, sql: "SELECT endpoint FROM source WHERE kind = 'githubReleases'") }) ?? []
        tracking = Set(tracked.map { $0 })
    }

    func list(_ s: String) -> [String] {
        s.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func save() {
        guard let watch else { return }
        let oldInclude = watch.plan.include
        plan.include = list(includeText); plan.exclude = list(excludeText)
        model.savePlan(watch, plan)
        if plan.type == .topic && plan.include != oldInclude { Task { await rediscover() } }
    }

    /// The topic changed: look for sources for the new keywords, attach the good ones (no backfill), and flag the ones that no longer fit.
    func rediscover() async {
        model.checking += 1; defer { model.checking -= 1 }
        nlMessage = "关注目标变了，正在重新发现来源…"
        let (fresh, stale) = await model.discovery.rediscover(watchID: watchID, plan: plan, text: watch?.originalText ?? "")
        var parts: [String] = []
        parts.append(fresh.isEmpty ? "没有找到新的合适来源" : "新增来源：" + fresh.map { $0.spec.name }.joined(separator: "、") + "（只记录基线，不补报历史）")
        if !stale.isEmpty { parts.append("这些来源近期没有含新关键词的内容，可用来源右侧的 − 移除：" + stale.joined(separator: "、")) }
        nlMessage = parts.joined(separator: "。")
        await model.check(watchID: watchID)
    }
    func applyNL() {
        Task {
            var edited = PlanParser.applyEdit(nl, to: plan)
            if edited == nil { edited = await AIPlanner.refine(plan, text: nl, followUp: true) }
            await MainActor.run { finishNL(edited) }
        }
    }
    func finishNL(_ edited: WatchPlan?) {
        if let p = edited {
            plan = p; includeText = p.include.joined(separator: ", "); excludeText = p.exclude.joined(separator: ", ")
            nlMessage = nil; nl = ""; save()
        } else {
            nlMessage = "没能可靠理解这句话，请直接修改上面的条件字段。"
        }
    }
    func trackReleases(_ full: String) {
        var p = WatchPlan(type: .githubRelease, title: "\(full) 新版本")
        p.targetURL = "https://github.com/\(full)"; p.stableOnly = true
        let spec = SourceSpec(kind: .githubReleases, endpoint: full, name: "\(full) Releases")
        if let w = try? model.store.createWatch(plan: p, text: "追踪 \(full) 的稳定版", sources: [spec]) {
            tracking.insert(full)
            Task { await model.check(watchID: w.id!) }
            selection = .watch(w.id!)
        }
    }
    func addSource() {
        let u = addURL.trimmingCharacters(in: .whitespaces)
        addMessage = "试读中…"
        Task {
            var p = PlanParser.parse(u); p.targetURL = PlanParser.url(in: u) ?? u
            let cands = await model.discovery.findSources(plan: p, text: u)
            if let c = cands.first(where: { $0.ok }) {
                _ = try? model.store.attach(watchID: watchID, spec: c.spec)
                addMessage = nil; addURL = ""
                await model.check(watchID: watchID)
            } else {
                addMessage = cands.first?.error ?? "没有找到可用来源"
            }
        }
    }
}
