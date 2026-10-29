import SwiftUI
import RadarCore

/// Ollama connection + the user's choice of model + cached summaries. Nothing here runs unless the user asks for it.
@MainActor
final class AssistantModel: ObservableObject {
    enum Status: Equatable { case unknown, ready, unreachable, noModels }
    let client = OllamaClient(baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST_URL"] ?? "http://127.0.0.1:11434")!)   // env override is a dev aid for testing the unreachable state
    let assistant: RadarAssistant
    @Published var status = Status.unknown
    @Published var models: [OllamaModel] = []
    @Published var selectedName = UserDefaults.standard.string(forKey: "ollamaModel") {
        didSet { UserDefaults.standard.set(selectedName, forKey: "ollamaModel") }
    }
    struct Cached { var text: String; var evidence: [Evidence]; var signature: String; var model: String; var date: Date }
    var summaries: [String: Cached] = [:]

    init(store: Store) { assistant = RadarAssistant(store: store) }

    var selected: OllamaModel? { models.first { $0.name == selectedName } ?? models.first { !$0.thinking } ?? models.first }

    func refresh() async {
        do {
            models = try await client.models()
            status = models.isEmpty ? .noModels : .ready
        } catch { models = []; status = .unreachable }
    }
    var problem: String? {
        switch status { case .unreachable: return OllamaError.unreachable.errorDescription; case .noModels: return OllamaError.noModels.errorDescription; default: return nil }
    }
}

/// Headings, bullets and inline markdown (bold, links) — enough for summaries without a markdown library.
struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" || $0 == " " })).font(line.hasPrefix("##") && !line.hasPrefix("###") ? .headline : .title3.bold()).padding(.top, 4)
                } else if let b = bullet(line) {
                    HStack(alignment: .top, spacing: 6) { Text("•"); Text(inline(b)) }
                } else { Text(inline(line)) }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    func bullet(_ l: String) -> Substring? {
        let t = l.drop { $0 == " " }
        return (t.hasPrefix("- ") || t.hasPrefix("* ")) ? t.dropFirst(2) : nil
    }
    func inline<S: StringProtocol>(_ s: S) -> AttributedString {
        (try? AttributedString(markdown: String(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(String(s))
    }
}

struct SourceList: View {
    let items: [Evidence]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("来源").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(items) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let u = URL(string: e.url) { Link(e.title, destination: u).lineLimit(1) } else { Text(e.title).lineLimit(1) }
                        Text(e.origin + (e.date.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// The current model, switchable in place (the same choice as in Settings).
struct ModelMenu: View {
    @ObservedObject var ai: AssistantModel
    var body: some View {
        if let m = ai.selected {
            Menu(m.name) {
                ForEach(ai.models) { x in Button((x.name == m.name ? "✓ " : "") + x.name) { ai.selectedName = x.name } }
                Divider()
                Button("重新检测") { Task { await ai.refresh() } }
            }.menuStyle(.borderlessButton).fixedSize().font(.caption)
        }
    }
}

struct OllamaNotice: View {
    @ObservedObject var ai: AssistantModel
    var body: some View {
        if let p = ai.problem {
            Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

/// One summary: a watch (watchID set) or everything. Generated only on request; reopening shows the cached text.
struct SummaryPanel: View {
    @ObservedObject var ai: AssistantModel
    let watchID: Int64?
    @State private var range = TimeRange.week
    @State private var text = ""
    @State private var evidence: [Evidence] = []
    @State private var busy = false
    @State private var error: String?
    @State private var stopped = false
    @State private var stale = false
    @State private var generatedAt: Date?
    @State private var task: Task<Void, Never>?

    var key: String { "\(watchID ?? 0)|\(range.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("时间范围", selection: $range) { ForEach(TimeRange.allCases) { Text($0.label).tag($0) } }.frame(width: 220)
                if busy { Button("停止") { stopped = true; task?.cancel() }; ProgressView().controlSize(.small) }
                else { Button(text.isEmpty ? "生成总结" : "重新生成") { generate() }.disabled(ai.selected == nil) }
                ModelMenu(ai: ai)
            }
            OllamaNotice(ai: ai)
            if let error { Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
            if stale && !busy { Label("数据有更新，可重新生成", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.blue) }
            if stopped { Text("已停止，以下为已生成的部分").font(.caption).foregroundStyle(.secondary) }
            if !text.isEmpty {
                MarkdownText(text: RadarAssistant.linkCitations(text, evidence))
                SourceList(items: RadarAssistant.cited(text, evidence))
                if let g = generatedAt, !busy { Text("生成于 " + g.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary) }
            } else if !busy {
                Text("只在你点击“生成总结”时调用本机模型，采集过程不使用 AI。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await loadCached() }
        .task { if ai.status == .unknown { await ai.refresh() } }
        .onDisappear { task?.cancel() }
    }

    func loadCached() async {
        task?.cancel(); busy = false; stopped = false; error = nil
        if let c = ai.summaries[key] {
            text = c.text; evidence = c.evidence; generatedAt = c.date
            let sig = try? ai.assistant.summaryContext(watchID: watchID, range: range).signature
            stale = sig != nil && sig != c.signature
        } else { text = ""; evidence = []; generatedAt = nil; stale = false }
    }

    func generate() {
        guard let m = ai.selected else { return }
        let key = key, wid = watchID, range = range
        task?.cancel(); text = ""; evidence = []; error = nil; stopped = false; busy = true; stale = false
        task = Task {
            defer { busy = false }
            do {
                let a = ai.assistant
                let ctx = try await Task.detached { try a.summaryContext(watchID: wid, range: range) }.value
                evidence = ctx.evidence
                if ctx.evidence.isEmpty { text = "这个范围内还没有采集到内容（\(range.label)）。可以换一个更长的时间范围，或先点“立即检查”。"; return }
                for try await piece in ai.client.chat(model: m, messages: RadarAssistant.summaryMessages(ctx, range: range)) { text += piece }
                if !stopped && !text.isEmpty { ai.summaries[key] = .init(text: text, evidence: ctx.evidence, signature: ctx.signature, model: m.name, date: Date()); generatedAt = Date() }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct BriefingView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("过去一段时间，我关注的所有领域发生了什么值得了解的变化？").foregroundStyle(.secondary)
                SummaryPanel(ai: model.ai, watchID: nil)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle("AI 简报")
    }
}

struct AskRadarView: View {
    @EnvironmentObject var model: AppModel
    @State var scope: Int64?
    @State private var watches: [Watch] = []
    @State private var range: TimeRange?
    struct Turn: Identifiable { let id = UUID(); var question: String; var answer = ""; var evidence: [Evidence] = []; var done = false; var failed: String? }
    @State private var turns: [Turn] = []
    @State private var evidence: [Evidence] = []
    @State private var input = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    var scopeTitle: String { scope.flatMap { id in watches.first { $0.id == id }?.title } ?? "全部关注事项" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("范围", selection: $scope) {
                    Text("全部关注事项").tag(Int64?.none)
                    ForEach(watches) { Text($0.title).tag(Int64?.some($0.id!)) }
                }.frame(width: 260)
                Picker("时间", selection: $range) {
                    Text("按问题自动").tag(TimeRange?.none)
                    ForEach(TimeRange.allCases) { Text($0.label).tag(TimeRange?.some($0)) }
                }.frame(width: 190)
                Spacer()
                ModelMenu(ai: model.ai)
                Button("新对话") { task?.cancel(); turns = []; evidence = []; busy = false }.disabled(turns.isEmpty).fixedSize()
            }.padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("直接问已经采集的内容，例如：").foregroundStyle(.secondary)
                                ForEach(["最近一周发现了哪些 AI Agent 项目？", "这些项目中，哪些适合本地运行？", "比较最近发现的三个项目"], id: \.self) { q in
                                    Button(q) { input = q }.buttonStyle(.link)
                                }
                                Text("回答只依据 Radar 已保存的内容，不会联网搜索；资料不足时会直接告诉你。").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            }
                        }
                        ForEach(turns) { t in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(t.question).font(.headline).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                if let f = t.failed { Label(f, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                                if t.answer.isEmpty && t.failed == nil { HStack { ProgressView().controlSize(.small); Text("正在检索并生成…").font(.caption).foregroundStyle(.secondary) } }
                                else if !t.answer.isEmpty { MarkdownText(text: RadarAssistant.linkCitations(t.answer, t.evidence)) }
                                if t.done { SourceList(items: RadarAssistant.cited(t.answer, t.evidence)) }
                                if t.done || !t.answer.isEmpty { Text("本次检索了 \(t.evidence.count) 条资料").font(.caption2).foregroundStyle(.secondary) }
                            }.id(t.id)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: turns.last?.answer) { _, _ in if let l = turns.last?.id { proxy.scrollTo(l, anchor: .bottom) } }
            }
            Divider()
            OllamaNotice(ai: model.ai).padding(.horizontal, 10).padding(.top, 6)
            HStack {
                TextField("问 Radar…", text: $input, axis: .vertical).lineLimit(1...4).onSubmit(send).textFieldStyle(.roundedBorder)
                if busy { Button("停止") { task?.cancel() } } else { Button("发送", action: send).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.ai.selected == nil).keyboardShortcut(.return, modifiers: .command) }
            }.padding(10)
        }
        .navigationTitle("问 Radar")
        .task { if model.ai.status == .unknown { await model.ai.refresh() } }
        .task(id: model.revision) { watches = (try? await model.store.db.read { try Watch.order(Column("createdAt").desc).fetchAll($0) }) ?? [] }
        .onDisappear { task?.cancel() }
    }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, let m = model.ai.selected else { return }
        input = ""; busy = true
        let history = turns.filter { $0.done && !$0.answer.isEmpty }.flatMap { [ChatMessage(role: "user", content: $0.question), ChatMessage(role: "assistant", content: $0.answer)] }
        let a = model.ai.assistant, prev = evidence, wid = scope, rg = range, title = scopeTitle
        turns.append(Turn(question: q)); let idx = turns.count - 1
        task = Task {
            defer { busy = false; turns[idx].done = true }
            do {
                let ev = try await Task.detached { try a.askContext(question: q, watchID: wid, range: rg, previous: prev) }.value
                evidence = ev; turns[idx].evidence = ev
                for try await piece in model.ai.client.chat(model: m, messages: RadarAssistant.askMessages(history: history, question: q, evidence: ev, scope: title)) { turns[idx].answer += piece }
            } catch is CancellationError {} catch { turns[idx].failed = error.localizedDescription }
        }
    }
}

import GRDB
