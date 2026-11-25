import SwiftUI
import RadarCore

struct BriefingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { BriefingBody(b: model.briefing, ai: model.ai).navigationTitle("AI 简报") }
}

/// One briefing per day. A tab bar picks the overview or one watch; each watch is generated on its own.
struct BriefingBody: View {
    @ObservedObject var b: BriefingModel
    @ObservedObject var ai: AssistantModel
    @State private var day = Briefer.dayKey(Date())
    @State private var tab: Int64?          // nil = overview
    @State private var confirmAll = false

    var isToday: Bool { day == b.today }
    var current: Briefing? { b.briefing(day) }
    /// Today: every active watch (generated or not). A past day: the sections that were written then.
    var tabs: [(id: Int64, title: String)] {
        if isToday { return b.watches.map { ($0.id!, $0.title) } }
        return (current?.sections ?? []).map { ($0.watchID, $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        OllamaNotice(ai: ai)
                        if let e = b.error { Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                        if let t = tab, tabs.contains(where: { $0.id == t }) { watchPage(t) } else { overviewPage }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { b.reload(); if ai.status == .unknown { await ai.refresh() } }
        .onChange(of: b.today) { oldToday, newToday in
            if day == oldToday { day = newToday }
        }
        .onChange(of: day) { _, newDay in b.loadDay(newDay) }
        .confirmationDialog("重新生成今天所有雷达的简报？", isPresented: $confirmAll) {
            Button("全部重新生成") { b.start(.all(force: true)) }
        } message: { Text("会对每个有更新的雷达各调用一次模型。只补齐还没生成的，请用“补齐未生成的”。") }
    }

    // MARK: header and tabs

    var header: some View {
        HStack(spacing: 10) {
            let older = b.headers.filter { $0.day < day }.first?.day, newer = b.headers.last { $0.day > day }?.day
            Button { if let o = older { day = o } } label: { Image(systemName: "chevron.left") }.disabled(older == nil).help("前一天的简报")
            Menu {
                Button("今天（\(b.today)）") { day = b.today }
                Divider()
                ForEach(b.headers.prefix(60).filter { $0.day != b.today }) { d in Button((d.day == day ? "✓ " : "") + d.day + (d.auto ? " · 自动" : "")) { day = d.day } }
            } label: { Text(isToday ? "今天 · \(day)" : day).font(.headline) }.fixedSize()
            Button { if let n = newer { day = n } else { day = b.today } } label: { Image(systemName: "chevron.right") }.disabled(isToday).help("后一天的简报")
            if !isToday { Button("回到今天") { day = b.today }.controlSize(.small) }
            Spacer()
            ModelMenu(ai: ai)
            Toggle("每天自动生成", isOn: $b.autoEnabled).toggleStyle(.switch).controlSize(.small)
            if b.autoEnabled { Picker("", selection: $b.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }.labelsHidden().frame(width: 80) }
        }
    }

    /// A vertical list: it grows with the number of radars and scrolls with an ordinary mouse wheel.
    var rail: some View {
        ScrollView {
            VStack(spacing: 2) {
                railRow("总览", icon: "square.grid.2x2", selected: tab == nil || !tabs.contains { $0.id == tab },
                        busy: b.job == .overview || b.job == .all(force: true) || b.job == .all(force: false)) { tab = nil }
                if !tabs.isEmpty { Divider().padding(.vertical, 4) }
                ForEach(tabs, id: \.id) { t in
                    let s = current?.section(t.id)
                    railRow(t.title, badge: s.flatMap { $0.isGenerated ? ($0.isEmpty ? nil : $0.evidence.count) : nil },
                            dim: !(s?.isGenerated ?? false) || (s?.isEmpty ?? true), selected: tab == t.id, busy: b.job == .watch(t.id)) { tab = t.id }
                }
            }.padding(8)
        }.frame(width: 210).background(.quinary)
    }

    func railRow(_ title: String, icon: String? = nil, badge: Int? = nil, dim: Bool = false, selected: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) } else if let icon { Image(systemName: icon).font(.caption).frame(width: 14) }
                Text(title).lineLimit(2).multilineTextAlignment(.leading).font(.callout)
                Spacer(minLength: 4)
                if let badge { Text("\(badge)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? Color.accentColor : (dim ? Color.secondary : Color.primary))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: overview

    @ViewBuilder var overviewPage: some View {
        if let c = current, c.hasOverview {
            Text("总览").font(.title2.bold())
            Text(stamp(c.overviewAt) + " · " + c.model + (c.auto ? " · 自动生成" : "")).font(.caption).foregroundStyle(.secondary)
            if c.overviewIsStale && isToday {
                HStack {
                    Label("有雷达的内容比这份总览新", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.blue)
                    Button("更新总览") { b.start(.overview) }.controlSize(.small).disabled(b.running)
                }
            }
            MarkdownText(text: c.overview)
            CopyButton(text: c.overview)
        } else if isToday {
            Text(current == nil ? "今天还没有简报。" : "今天还没有总览。").foregroundStyle(.secondary)
            Text("“生成全部”会把每个有更新的雷达各整理一遍，再写总览；也可以在下面只生成某一个雷达，或切到对应的标签页单独生成。每天到设定时间也会自动生成。").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("这一天没有生成总览。").foregroundStyle(.secondary)
        }
        Divider()
        HStack {
            Text("各雷达").font(.headline)
            Spacer()
            if b.running {
                ProgressView().controlSize(.small); Text(b.progress).font(.caption).foregroundStyle(.secondary)
                Button("停止") { b.cancel() }.controlSize(.small)
            } else if isToday {
                let missing = b.watches.filter { !(current?.section($0.id!)?.isGenerated ?? false) }.count
                if missing > 0 { Button(current?.hasOverview == true ? "补齐未生成的（\(missing)）" : "生成全部") { b.start(.all(force: false)) }.controlSize(.small).disabled(ai.selected == nil && ai.status == .ready) }
                if missing < b.watches.count { Button("全部重新生成") { confirmAll = true }.controlSize(.small) }
            }
        }
        ForEach(tabs, id: \.id) { t in
            let s = current?.section(t.id)
            HStack(spacing: 8) {
                Button { tab = t.id } label: { Text(t.title).foregroundStyle(.primary) }.buttonStyle(.plain)
                Text(status(s)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isToday && !b.running { Button((s?.isGenerated ?? false) ? "重新整理" : "生成") { b.start(.watch(t.id)) }.controlSize(.small) }
            }
        }
        if tabs.isEmpty { Text("还没有关注事项。").font(.caption).foregroundStyle(.secondary) }
    }

    func status(_ s: BriefingSection?) -> String {
        guard let s, s.isGenerated else { return "未生成" }
        return s.isEmpty ? "没有新内容" : "\(s.events) 条事件 · \(s.entries) 条内容"
    }
    func stamp(_ d: Date?) -> String { d.map { $0.formatted(date: .omitted, time: .shortened) } ?? "" }

    // MARK: one watch

    @ViewBuilder func watchPage(_ id: Int64) -> some View {
        let s = current?.section(id), title = tabs.first { $0.id == id }?.title ?? ""
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            if b.job == .watch(id) {
                ProgressView().controlSize(.small); Text(b.progress).font(.caption).foregroundStyle(.secondary); Button("停止") { b.cancel() }.controlSize(.small)
            } else if isToday {
                Button((s?.isGenerated ?? false) ? "重新整理" : "生成这个雷达的简报") { b.start(.watch(id)) }.disabled(b.running)
            }
        }
        if let s, s.isGenerated {
            Text("生成于 \(stamp(s.generatedAt)) · " + status(s)).font(.caption).foregroundStyle(.secondary)
            if s.isEmpty { Text("过去 24 小时没有新内容。").foregroundStyle(.secondary) } else {
                let cited = RadarAssistant.cited(s.text, s.evidence)
                let copyable = RadarAssistant.textWithLinks(s.text, s.evidence)
                MarkdownText(text: RadarAssistant.linkCitations(s.text, s.evidence), evidence: s.evidence)
                CopyButton(text: copyable, label: copyable == s.text ? "复制" : "复制（含链接）")
                SourceList(items: cited)
            }
        } else {
            Text(isToday ? "今天还没有生成这个雷达的简报。点右上角的按钮只整理它，不会动其他雷达。" : "这一天没有生成这个雷达的简报。").foregroundStyle(.secondary)
        }
    }
}
