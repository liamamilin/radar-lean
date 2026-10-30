import SwiftUI
import RadarCore

struct NewWatchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Int64) -> Void

    @State private var text = ""
    @State private var plan: WatchPlan?
    @State private var includeText = ""
    @State private var excludeText = ""
    @State private var candidates: [Candidate] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?
    @State private var manualURL = ""
    @State private var selector = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("你想关注什么？") {
                    TextEditor(text: $text).frame(height: 70).font(.body)
                    Text("例如：关注 AI 开源项目，尤其是 Agent 和本地模型，排除 AI 绘画\n或：关注 https://github.com/owner/repo 的稳定版，1.0 以上提醒\n或：这个博客有关于本地 AI 的新文章就告诉我 https://…").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("分析并查找来源") { Task { await analyze() } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                        if busy { ProgressView().controlSize(.small); Text("正在分析并试读来源（联网搜索可能需要十几秒）…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if var p = plan {
                    Section("计划（可编辑）") {
                        TextField("名称", text: Binding(get: { plan?.title ?? "" }, set: { plan?.title = $0 }))
                        TextField("包含关键词（逗号分隔）", text: $includeText)
                        TextField("排除关键词", text: $excludeText)
                        if let u = p.unsupported, !u.isEmpty {
                            ForEach(u, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }
                        if p.type == .topic {
                            TextField("GitHub 新项目最低 Stars（默认 50）", text: Binding(get: { plan?.minStars.map(String.init) ?? "" }, set: { plan?.minStars = Int($0) }))
                            Text("“值得关注”的判定：近 90 天创建、非 fork/归档、Stars 达标（创建 14 天内的新项目门槛降为 1/5，至少 10）。其余只列在更新里，不弹通知。").font(.caption).foregroundStyle(.secondary)
                        }
                        if p.type == .githubRelease {
                            Toggle("仅稳定版", isOn: Binding(get: { plan?.stableOnly ?? false }, set: { plan?.stableOnly = $0 }))
                            TextField("最低版本", text: Binding(get: { plan?.minimumVersion ?? "" }, set: { plan?.minimumVersion = $0.isEmpty ? nil : $0 }))
                        }
                    }
                    Section("信息源（已实际试读）") {
                        if candidates.isEmpty && !busy {
                            Text("没有匹配的内置来源。请在下方粘贴一个 GitHub 仓库、RSS 或网页 URL。").foregroundStyle(.secondary)
                        }
                        ForEach(candidates) { c in
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(get: { selected.contains(c.id) }, set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } }))
                                    .labelsHidden().disabled(!c.ok)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(c.spec.name).font(.headline)
                                        if c.official { Text("官方").font(.caption2.bold()).padding(.horizontal, 5).background(Color.green.opacity(0.2), in: Capsule()).foregroundStyle(.green) }
                                    }
                                    Text("\(c.spec.kind.label) · \(c.spec.endpoint)").font(.caption).foregroundStyle(.secondary)
                                    if c.ok, c.latest != nil || c.matched != nil {
                                        Text([c.latest.map { "最近更新 " + $0.formatted(.relative(presentation: .named)) },
                                              c.matched.map { "近 \(c.total) 条中 \($0) 条含关键词" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle((c.matched ?? 1) == 0 ? .orange : .secondary)
                                    }
                                    if c.existing { Text("已有来源，将复用（不会补报历史内容）").font(.caption).foregroundStyle(.blue) }
                                    if c.ok {
                                        ForEach(c.samples, id: \.self) { s in Text("• " + s).font(.caption).lineLimit(3) }
                                    } else {
                                        Label(c.error ?? "无法读取", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        HStack {
                            TextField("手动添加来源 URL", text: $manualURL).onSubmit { Task { await addManual() } }
                            Button("试读") { Task { await addManual() } }.disabled(manualURL.isEmpty || busy)
                        }
                        if candidates.contains(where: { $0.spec.kind == .web }) {
                            HStack {
                                TextField("网页正文 CSS 选择器（可选，默认 article/main）", text: $selector)
                                Button("按选择器重新试读") { Task { await reprobeWeb() } }
                            }
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(.orange) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始关注") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(plan == nil || selected.isEmpty)
            }.padding(12)
        }.frame(width: 640, height: 640)
        .task {
            if let t = ProcessInfo.processInfo.environment["RADAR_DRIVE_TEXT"] { text = t; await analyze(); create() }   // dev aid, see ContentView.drive
        }
    }

    func analyze() async {
        busy = true; message = nil; defer { busy = false }
        var p = PlanParser.parse(text)
        if p.type != .githubRelease, let refined = await AIPlanner.refine(p, text: text) { p.include = refined.include; p.exclude = refined.exclude; if p.type == .topic { p.title = refined.title } }
        includeText = p.include.joined(separator: ", "); excludeText = p.exclude.joined(separator: ", ")
        plan = p
        candidates = await model.discovery.findSources(plan: p, text: text)
        if p.type == .topic {
            // GitHub sources are always relevant by construction; web-found sources must actually mention the keywords
            let gh = candidates.filter { $0.ok && $0.matched == nil }, web = candidates.filter { $0.ok && ($0.matched ?? 0) > 0 }.prefix(4)
            selected = Set((gh + web + candidates.filter { $0.ok && $0.official }).map { $0.id })
        } else { selected = Set(candidates.filter { $0.ok }.prefix(1).map { $0.id }) }
        let noSearch = p.type == .topic && !model.searchEnabled
        if p.type == .topic && candidates.isEmpty { message = "内置目录没有匹配这个主题的来源。请提供 GitHub 仓库、RSS 或网页 URL。" }
        else if !candidates.contains(where: { $0.ok }) { message = "没有可用来源，不会创建空任务。" }
        else if noSearch { message = "未配置联网搜索（设置里填 Exa API Key），只用了内置目录和 GitHub 搜索。" }
        p.include = []; _ = p
    }

    func addManual() async {
        let u = manualURL.trimmingCharacters(in: .whitespaces)
        busy = true; defer { busy = false }
        var p = PlanParser.parse(u); p.targetURL = PlanParser.url(in: u) ?? u
        let found = await model.discovery.findSources(plan: p, text: u)
        if found.isEmpty { message = "无法识别这个地址"; return }
        for c in found where !candidates.contains(where: { $0.id == c.id }) { candidates.append(c) }
        if let ok = found.first(where: { $0.ok }) { selected.insert(ok.id) }
        manualURL = ""
        if plan == nil { plan = WatchPlan(type: p.type == .topic ? .feed : p.type, title: p.title) }
    }

    func reprobeWeb() async {
        busy = true; defer { busy = false }
        for i in candidates.indices where candidates[i].spec.kind == .web {
            var s = candidates[i].spec; s.selector = selector.isEmpty ? nil : selector
            let c = await model.discovery.probe(s)
            selected.remove(candidates[i].id)
            candidates[i] = c
            if c.ok { selected.insert(c.id) }
        }
    }

    func create() {
        guard var p = plan else { return }
        p.include = includeText.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.exclude = excludeText.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let chosen = candidates.filter { selected.contains($0.id) && $0.ok }.map { $0.spec }
        guard !chosen.isEmpty else { return }
        if p.type == .feed || p.type == .webpage { p.type = chosen.contains { $0.kind == .rss } ? .feed : .webpage }
        guard let w = try? model.store.createWatch(plan: p, text: text, sources: chosen) else { message = "保存失败"; return }
        Task { await model.check(watchID: w.id!) }
        onCreated(w.id!)
        dismiss()
    }
}
