import SwiftUI
import RadarCore
import GRDB

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
    @State private var older = false   // showing an earlier summary from the history
    @State private var task: Task<Void, Never>?

    var key: String { "\(watchID ?? 0)|\(range.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("时间范围", selection: $range) { ForEach(TimeRange.allCases) { Text($0.label).tag($0) } }.frame(width: 220)
                if busy { Button("停止") { stopped = true; task?.cancel() }; ProgressView().controlSize(.small) }
                else { Button(text.isEmpty ? "生成总结" : "重新生成") { generate() }.disabled(ai.selected == nil) }
                ModelMenu(ai: ai)
                if let h = ai.history[key], h.count > 1 {
                    Menu("历史（\(h.count)）") {
                        ForEach(Array(h.enumerated()), id: \.offset) { i, c in
                            Button(c.date.formatted(date: .abbreviated, time: .shortened) + " · " + c.model + (i == 0 ? "（最新）" : "")) { show(c, latest: i == 0) }
                        }
                    }.fixedSize()
                }
            }
            OllamaNotice(ai: ai)
            if older && !busy { Label("正在查看较早的一次总结", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
            if let error { Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
            if stale && !busy { Label("数据有更新，可重新生成", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.blue) }
            if stopped { Text("已停止，以下为已生成的部分").font(.caption).foregroundStyle(.secondary) }
            if !text.isEmpty {
                let cited = RadarAssistant.cited(text, evidence)
                let copyable = RadarAssistant.textWithLinks(text, evidence)
                MarkdownText(text: RadarAssistant.linkCitations(text, evidence), evidence: evidence)
                if !busy { CopyButton(text: copyable, label: copyable == text ? "复制" : "复制（含链接）") }
                SourceList(items: cited)
                if let g = generatedAt, !busy { Text("生成于 " + g.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary) }
            } else if !busy {
                Text("只在你点击“生成总结”时调用所选模型，采集过程不使用 AI。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await loadCached() }
        .task { if ai.status == .unknown { await ai.refresh() } }
        .onDisappear { task?.cancel() }
    }

    func loadCached() async {
        task?.cancel(); busy = false; stopped = false; error = nil
        older = false
        if let c = ai.latest(key) { show(c, latest: true) } else { text = ""; evidence = []; generatedAt = nil; stale = false }
    }

    func show(_ c: AssistantModel.Cached, latest: Bool) {
        text = c.text; evidence = c.evidence; generatedAt = c.date; older = !latest; stopped = false; error = nil
        let sig = latest ? (try? ai.assistant.summaryContext(watchID: watchID, range: range).signature) : nil
        stale = latest && sig != nil && sig != c.signature
    }

    func generate() {
        guard let m = ai.selected else { return }
        let key = key, wid = watchID, range = range
        task?.cancel(); text = ""; evidence = []; error = nil; stopped = false; busy = true; stale = false; older = false
        task = Task {
            defer { busy = false }
            do {
                let a = ai.assistant
                let ctx = try await Task.detached { try a.summaryContext(watchID: wid, range: range) }.value
                evidence = ctx.evidence
                if ctx.evidence.isEmpty { text = "这个范围内还没有采集到内容（\(range.label)）。可以换一个更长的时间范围，或先点“立即检查”。"; return }
                var pending = ""
                var lastFlush = Date.distantPast
                defer { if !pending.isEmpty { text += pending; pending = "" } }
                for try await piece in ai.client.chat(model: m, messages: RadarAssistant.summaryMessages(ctx, range: range)) {
                    pending += piece
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= 0.08 {
                        text += pending; pending = ""; lastFlush = now
                    }
                }
                if !pending.isEmpty { text += pending; pending = "" }
                if !stopped && !text.isEmpty { ai.save(key, .init(text: text, evidence: ctx.evidence, signature: ctx.signature, model: m.name, date: Date())); generatedAt = Date() }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct AskRadarView: View {
    @EnvironmentObject var model: AppModel
    @State var scope: Int64?
    @State private var watches: [Watch] = []
    @State private var range: TimeRange?
    @State private var turns: [AskTurn] = []
    @State private var evidence: [Evidence] = []
    @State private var input = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var convID: Int64?
    @State private var token = UUID()   // changes when the open conversation changes, so a late-finishing answer does not overwrite another one
    @State private var headers: [ConversationHeader] = []
    @AppStorage("askHistoryShown") private var historyShown = true

    var scopeTitle: String { scope.flatMap { id in watches.first { $0.id == id }?.title } ?? "全部关注事项" }
    var conversations: ConversationStore { ConversationStore(store: model.store) }

    var body: some View {
        HStack(spacing: 0) {
            if historyShown { history; Divider() }
            chat
        }
        .navigationTitle("问 Radar")
        .task { if model.ai.status == .unknown { await model.ai.refresh() } }
        .task(id: model.revision) { watches = (try? await model.store.db.read { try Watch.order(Column("createdAt").desc).fetchAll($0) }) ?? [] }
        .task { reloadHeaders() }
        .task(id: model.askRequest) {
            guard let r = model.askRequest else { return }
            if model.ai.status == .unknown { await model.ai.refresh() }
            model.askRequest = nil
            newConversation(); input = r; send()
        }
        .onDisappear { persist(); task?.cancel() }
    }

    // MARK: history column

    var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("对话").font(.headline)
                Spacer()
                Button { newConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("新对话").disabled(turns.isEmpty && convID == nil)
            }.padding(10)
            Divider()
            if headers.isEmpty {
                Text("还没有历史对话").font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            List(selection: Binding(get: { convID }, set: { if let id = $0 { open(id) } })) {
                ForEach(headers) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).lineLimit(2)
                        Text(h.updatedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(h.id)
                    .contextMenu { Button("删除对话", role: .destructive) { remove(h.id) } }
                }
            }.listStyle(.sidebar)
        }.frame(width: 180)
    }

    // MARK: chat

    var chat: some View {
        VStack(spacing: 0) {
            HStack {
                Button { historyShown.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.borderless).help(historyShown ? "收起历史对话" : "显示历史对话")
                Picker("范围", selection: $scope) {
                    Text("全部关注事项").tag(Int64?.none)
                    ForEach(watches) { Text($0.title).tag(Int64?.some($0.id!)) }
                }.frame(minWidth: 120, idealWidth: 240, maxWidth: 260)
                Picker("时间", selection: $range) {
                    Text("按问题自动").tag(TimeRange?.none)
                    ForEach(TimeRange.allCases) { Text($0.label).tag(TimeRange?.some($0)) }
                }.frame(minWidth: 110, idealWidth: 170, maxWidth: 190)
                Spacer(minLength: 0)
                ModelMenu(ai: model.ai).layoutPriority(1)
                if !historyShown { Button("新对话") { newConversation() }.disabled(turns.isEmpty).fixedSize() }
            }.padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty { intro }
                        ForEach(turns) { t in turnView(t).id(t.id) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: turns.last?.answer) { _, _ in if let l = turns.last?.id { proxy.scrollTo(l, anchor: .bottom) } }
            }
            Divider()
            OllamaNotice(ai: model.ai).padding(.horizontal, 10).padding(.top, 6)
            HStack {
                TextField("问 Radar，或直接贴一个链接让我读…", text: $input, axis: .vertical).lineLimit(1...4).onSubmit(send).textFieldStyle(.roundedBorder)
                if busy { Button("停止") { task?.cancel() } } else { Button("发送", action: send).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.ai.selected == nil).keyboardShortcut(.return, modifiers: .command) }
            }.padding(10)
        }.frame(minWidth: 0, maxWidth: .infinity)
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("直接问已经采集的内容，例如：").foregroundStyle(.secondary)
            ForEach(["最近一周发现了哪些 AI Agent 项目？", "这些项目中，哪些适合本地运行？", "比较最近发现的三个项目"], id: \.self) { q in
                Button(q) { input = q }.buttonStyle(.link)
            }
            Text("回答只依据 Radar 已保存的内容，不会联网搜索；资料不足时会直接告诉你。").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            Text("想读某篇文章或项目：把链接贴进来（可以带一句你想知道什么），Radar 会读取这个网页的正文再回答。简报和回答里每条来源旁边的书本按钮也可以一键发起。").font(.caption).foregroundStyle(.secondary)
        }
    }

    func turnView(_ t: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.question).font(.headline).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            ForEach(t.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if let f = t.failed { Label(f, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
            if t.answer.isEmpty && t.failed == nil && !t.done { HStack { ProgressView().controlSize(.small); Text(t.evidence.contains { $0.kind == "page" } ? "正在阅读并生成…" : "正在检索并生成…").font(.caption).foregroundStyle(.secondary) } }
            else if !t.answer.isEmpty { MarkdownText(text: RadarAssistant.linkCitations(t.answer, t.evidence), evidence: t.evidence) }
            if t.done && !t.answer.isEmpty {
                let copyable = RadarAssistant.textWithLinks(t.answer, t.evidence)
                CopyButton(text: copyable, label: copyable == t.answer ? "复制" : "复制（含链接）")
                SourceList(items: RadarAssistant.cited(t.answer, t.evidence))
            } else if t.done {
                SourceList(items: RadarAssistant.cited(t.answer, t.evidence))
            }
            if t.done || !t.answer.isEmpty {
                Text(t.evidence.contains { $0.kind == "page" } ? "已读取 \(t.evidence.filter { $0.kind == "page" }.count) 个网页，另有 \(t.evidence.filter { $0.kind != "page" }.count) 条已保存资料"
                     : "本次检索了 \(t.evidence.count) 条资料" + (t.searched.isEmpty ? "" : "（扩展检索词：\(t.searched.prefix(8).joined(separator: ", "))）")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: conversations

    func reloadHeaders() { headers = (try? conversations.headers()) ?? [] }

    func persist() {
        guard !turns.isEmpty else { return }
        convID = try? conversations.save(id: convID, turns: turns, scope: scope)
        reloadHeaders()
    }

    func newConversation() {
        persist(); task?.cancel(); token = UUID()
        turns = []; evidence = []; busy = false; convID = nil
    }

    func open(_ id: Int64) {
        guard id != convID else { return }
        persist(); task?.cancel(); token = UUID(); busy = false
        guard let c = try? conversations.load(id) else { reloadHeaders(); return }
        turns = c.turns; convID = id; scope = c.scope
        evidence = turns.last { !$0.evidence.isEmpty }?.evidence ?? []
    }

    func remove(_ id: Int64) {
        try? conversations.delete(id)
        if id == convID { task?.cancel(); token = UUID(); turns = []; evidence = []; busy = false; convID = nil }
        reloadHeaders()
    }

    // MARK: asking

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy, let m = model.ai.selected else { return }
        input = ""; busy = true
        let history = turns.filter { $0.done && !$0.answer.isEmpty && !$0.canned }.flatMap { [ChatMessage(role: "user", content: $0.question), ChatMessage(role: "assistant", content: $0.answer)] }
        let a = model.ai.assistant, prev = evidence, wid = scope, rg = range, title = scopeTitle, fetcher = model.fetcher, my = token
        let turn = AskTurn(question: q); turns.append(turn)
        persist()
        func update(_ f: (inout AskTurn) -> Void) { if my == token, let i = turns.firstIndex(where: { $0.id == turn.id }) { f(&turns[i]) } }   // the conversation may have been switched or removed
        task = Task {
            defer { if my == token { busy = false; update { $0.done = true }; persist() } }
            do {
                var base = prev
                let links = RadarAssistant.urls(in: q)
                if !links.isEmpty {   // reading mode: fetch the pages and answer from them
                    var fetched = 0
                    for l in links {
                        try Task.checkCancellation()
                        do {
                            let art = try await fetcher.readArticle(l)
                            base.removeAll { $0.url == art.url && $0.kind == "page" }
                            base.append(RadarAssistant.pageEvidence(art, id: "S\(base.count + 1)")); fetched += 1
                        } catch is CancellationError { throw CancellationError() } catch {
                            update { $0.notes.append("没有读到 \(l)：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
                        }
                    }
                    if fetched == 0 { update { $0.failed = "链接都没能读取，所以没有回答（避免凭空编造）。可以把正文复制过来贴给我。" }; return }
                    evidence = base; update { $0.evidence = base }
                } else {
                    // the stored content is mostly English: have the model add English search terms for a Chinese question
                    var extra: [String] = []
                    if RadarAssistant.needsExpansion(q) {
                        var raw = ""
                        do { for try await piece in model.ai.client.chat(model: m, messages: RadarAssistant.expandMessages(q)) { raw += piece; if raw.count > 400 { break } } } catch is CancellationError { throw CancellationError() } catch {}   // expansion is optional
                        extra = RadarAssistant.parseTerms(raw)
                    }
                    let r = try await Task.detached { try a.retrieve(question: q, extraTerms: extra, watchID: wid, range: rg, previous: prev) }.value
                    evidence = r.evidence; update { $0.evidence = r.evidence; $0.searched = extra }
                    if !r.matched {
                        update { $0.canned = true; $0.answer = "没有找到和这个问题相关的已保存资料，所以不作回答（避免编造）。\n\n可以试试：\n- 把时间范围改成“全部”，或换个说法\n- 到对应关注里点“立即检查”，让 Radar 先采集最新内容\n- 如果想读某个网页，直接把链接贴给我" }
                        return
                    }
                    base = r.evidence
                }
                var pending = ""
                var lastFlush = Date.distantPast
                defer { if !pending.isEmpty { let tail = pending; pending = ""; update { $0.answer += tail } } }
                for try await piece in model.ai.client.chat(model: m, messages: RadarAssistant.askMessages(history: history, question: q, evidence: base, scope: title)) {
                    pending += piece
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= 0.08 {
                        let chunk = pending; pending = ""; lastFlush = now
                        update { $0.answer += chunk }
                    }
                }
                if !pending.isEmpty { let tail = pending; pending = ""; update { $0.answer += tail } }
            } catch is CancellationError {} catch { update { $0.failed = error.localizedDescription } }
        }
    }
}
