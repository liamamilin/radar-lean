import SwiftUI
import RadarCore

/// Model backend (local Ollama or an OpenAI-compatible service) + the user's choice of model + cached summaries. Nothing here runs unless the user asks for it.
@MainActor
final class AssistantModel: ObservableObject {
    enum Status: Equatable { case unknown, ready, unreachable, noModels, failed }
    enum Provider: String, CaseIterable, Identifiable {
        case ollama, openai
        var id: String { rawValue }
        var label: String { self == .ollama ? "本机 Ollama" : "OpenAI 兼容服务" }
    }
    /// Presets for `.openai`; picking one fills the address, "自定义" leaves it to the user.
    static let presets: [(name: String, url: String)] = [("OpenCode Go", "https://opencode.ai/zen/go/v1"), ("DeepSeek 官方", "https://api.deepseek.com"), ("自定义", "")]
    let ollama = OllamaClient(baseURL: URL(string: ProcessInfo.processInfo.environment["OLLAMA_HOST_URL"] ?? "http://127.0.0.1:11434")!)   // env override is a dev aid for testing the unreachable state
    let assistant: RadarAssistant
    @Published var status = Status.unknown
    @Published var models: [OllamaModel] = []
    @Published var lastError: String?
    @Published var provider = Provider(rawValue: UserDefaults.standard.string(forKey: "llmProvider") ?? "") ?? .ollama {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider"); models = []; status = .unknown; lastError = nil }
    }
    @Published var baseURLString = UserDefaults.standard.string(forKey: "llmBaseURL") ?? AssistantModel.presets[0].url {
        didSet { UserDefaults.standard.set(baseURLString, forKey: "llmBaseURL") }
    }
    /// Lives in the Keychain (see AppModel.setLLMKey); kept in memory for requests.
    @Published var apiKey = ProcessInfo.processInfo.environment["RADAR_LLM_KEY"] ?? ""
    /// Which Keychain item holds the key for the current address: each service has its own key. (OpenCode keeps the original item.)
    var keyService: String {
        let host = URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host == "opencode.ai" || host.isEmpty ? Keychain.llmService : Keychain.llmService + "." + host
    }
    /// When the chosen model cannot answer, a cheaper available one is tried (see FailoverChat).
    @Published var autoSwitch = UserDefaults.standard.object(forKey: "llmAutoSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "llmAutoSwitch") }
    }
    @Published var switchNote: String?      // "X was unavailable, Y answered instead": shown until the next refresh
    var lastUsedModel: String?              // the model that actually answered the latest request
    let health = ModelHealth()
    /// The chosen model is remembered per service (a model name from one service means nothing at another).
    private var modelKey: String {
        guard provider == .openai else { return "llmModel." + provider.rawValue }
        let host = URL(string: baseURLString.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host == "opencode.ai" || host.isEmpty ? "llmModel.openai" : "llmModel.openai." + host
    }
    var selectedName: String? {
        get { UserDefaults.standard.string(forKey: modelKey) ?? (provider == .ollama ? UserDefaults.standard.string(forKey: "ollamaModel") : nil) }
        set { UserDefaults.standard.set(newValue, forKey: modelKey); objectWillChange.send() }
    }
    /// What the current settings talk to.
    var client: ChatClient {
        switch provider {
        case .ollama: return ollama
        case .openai:
            let url = URL(string: baseURLString.trimmingCharacters(in: .whitespaces)) ?? URL(string: "https://invalid.local")!
            let base = OpenAICompatClient(baseURL: url, apiKey: apiKey, disableThinking: url.host == "api.deepseek.com")
            guard autoSwitch else { return base }
            let f = FailoverChat(base: base, alternatives: models, health: health)
            f.onSwitch = { [weak self] from, to, why in
                DispatchQueue.main.async { self?.switchNote = "「\(from)」\(why)，已自动改用「\(to)」。" }
            }
            f.onUsed = { [weak self] name in DispatchQueue.main.async { self?.lastUsedModel = name } }
            return f
        }
    }
    struct Cached: Codable { var text: String; var evidence: [Evidence]; var signature: String; var model: String; var date: Date }
    private let store: Store
    static let keepPerKey = 20
    /// Every generated summary per "<watch>|<range>", newest first. The first one is the cache.
    private(set) var history: [String: [Cached]] = [:]
    func latest(_ key: String) -> Cached? { history[key]?.first }

    init(store: Store) {
        self.store = store; assistant = RadarAssistant(store: store)
        let rows = (try? store.db.read { try Row.fetchAll($0, sql: "SELECT key, json FROM summaryHistory ORDER BY id") }) ?? []
        for r in rows { if let k: String = r["key"], let d: Data = r["json"], let c = try? JSONDecoder().decode(Cached.self, from: d) { history[k, default: []].insert(c, at: 0) } }
    }

    func save(_ key: String, _ c: Cached) {
        history[key, default: []].insert(c, at: 0)
        if history[key]!.count > Self.keepPerKey { history[key]!.removeLast(history[key]!.count - Self.keepPerKey) }
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? store.db.write { db in
            try db.execute(sql: "INSERT INTO summaryHistory (key, json) VALUES (?, ?)", arguments: [key, d])
            try db.execute(sql: "DELETE FROM summaryHistory WHERE key = ? AND id NOT IN (SELECT id FROM summaryHistory WHERE key = ? ORDER BY id DESC LIMIT ?)", arguments: [key, key, Self.keepPerKey])
        }
    }

    /// The chosen model; when none was chosen (or it is no longer offered) the cheapest-looking one, not just the first alphabetically.
    var selected: OllamaModel? {
        models.first { $0.name == selectedName } ?? (provider == .openai ? ModelRanking.best(models) : (models.first { !$0.thinking } ?? models.first))
    }

    func refresh() async {
        let p = provider
        do {
            let list = try await client.models()
            guard p == provider else { return }   // the user switched backend while this was loading
            models = list; lastError = nil; switchNote = nil
            status = models.isEmpty ? .noModels : .ready
        } catch {
            guard p == provider else { return }
            models = []; status = p == .ollama ? .unreachable : .failed
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    var problem: String? {
        switch provider {
        case .ollama:
            switch status { case .unreachable: return OllamaError.unreachable.errorDescription; case .noModels: return OllamaError.noModels.errorDescription; default: return nil }
        case .openai:
            if status == .failed || status == .noModels { return lastError ?? LLMError.noModels.errorDescription }
            return apiKey.isEmpty ? LLMError.noKey.errorDescription : nil
        }
    }
    /// For wording that has to say whether data leaves the machine.
    var isLocal: Bool { provider == .ollama }
}

/// Headings, bullets and inline markdown (bold, links) — enough for summaries without a markdown library.
/// Rendered in an NSTextView: SwiftUI's `.textSelection` swallows link clicks on macOS, an NSTextView gives both
/// mouse selection / ⌘C and clickable [S1] citations (clicks go through LinkOpener).
/// Copying a selection (⌘C or right-click) automatically appends the URLs of any links inside it; hovering a
/// bullet or linked paragraph also reveals a one-click copy button for that single item.
struct MarkdownText: NSViewRepresentable {
    let text: String
    var evidence: [Evidence] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LinkCopyTextView {
        let tv = LinkCopyTextView(frame: .zero)
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = .zero; tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false; tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = false
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor]
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: LinkCopyTextView, context: Context) {
        tv.evidence = evidence
        if context.coordinator.shown != text {
            context.coordinator.shown = text
            tv.textStorage?.setAttributedString(Self.render(text))
            tv.refreshCopyableState()
        }
    }

    /// Measured on the side, never by resizing the live text container: SwiftUI asks with several trial widths and the
    /// last one asked is not necessarily the one used, which left the text wrapped at a stale width and overlapping what follows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: LinkCopyTextView, context: Context) -> CGSize? {
        let w = max(proposal.width ?? 400, 40)
        let textW = max(w - tv.trailingGutter, 40)
        let r = (tv.textStorage ?? NSTextStorage()).boundingRect(with: NSSize(width: textW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: w, height: ceil(r.height) + 2)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown = ""
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let u = link as? URL { LinkOpener.open(u); return true }
            if let s = link as? String, let u = URL(string: s) { LinkOpener.open(u); return true }
            return false
        }
    }

    static func render(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            var font = body, content = Substring(line), indent: CGFloat = 0, before: CGFloat = 0
            let para = NSMutableParagraphStyle()
            if line.hasPrefix("#") {
                font = line.hasPrefix("##") && !line.hasPrefix("###") ? .boldSystemFont(ofSize: 15) : .boldSystemFont(ofSize: 17)
                content = line.drop { $0 == "#" || $0 == " " }; before = 4
            } else if let b = bullet(line) {
                content = b; indent = 14
                para.firstLineHeadIndent = 0; para.headIndent = indent
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            para.paragraphSpacing = 6; para.paragraphSpacingBefore = before
            let piece = NSMutableAttributedString()
            if indent > 0 { piece.append(NSAttributedString(string: "•\t")) }
            piece.append(inline(content, font: font))
            piece.addAttributes([.paragraphStyle: para], range: NSRange(location: 0, length: piece.length))
            piece.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: piece.length)) { v, r, _ in
                if v == nil { piece.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r) }
            }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(piece)
        }
        return out
    }

    static func bullet(_ l: String) -> Substring? {
        let t = l.drop { $0 == " " }
        return (t.hasPrefix("- ") || t.hasPrefix("* ")) ? t.dropFirst(2) : nil
    }

    static func inline(_ s: Substring, font: NSFont) -> NSAttributedString {
        let attr = (try? AttributedString(markdown: String(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(String(s))
        let out = NSMutableAttributedString()
        for run in attr.runs {
            var f = font
            if let i = run.inlinePresentationIntent {
                if i.contains(.code) { f = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                if i.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if i.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            }
            var a: [NSAttributedString.Key: Any] = [.font: f]
            if let l = run.link { a[.link] = l }
            out.append(NSAttributedString(string: String(attr[run.range].characters), attributes: a))
        }
        return out
    }
}

/// NSTextView subclass that preserves links when copying a selection (⌘C / context menu) and offers a hover
/// copy button in a narrow right gutter so any single bullet or linked item can be copied with one click.
final class LinkCopyTextView: NSTextView {
    static let buttonGutter: CGFloat = 28
    var evidence: [Evidence] = []
    private(set) var trailingGutter: CGFloat = 0

    private let hoverButton: NSButton = {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "复制本条（含链接）"
        b.isHidden = true
        return b
    }()
    private var tracking: NSTrackingArea?
    private var hoveredRange: NSRange?
    private var contextRange: NSRange?
    private var feedbackWork: DispatchWorkItem?
    private var showingFeedback = false
    private var pointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHoverButton()
    }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupHoverButton()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHoverButton()
    }

    private func setupHoverButton() {
        guard hoverButton.superview == nil else { return }
        hoverButton.target = self
        hoverButton.action = #selector(copyHoveredParagraph)
        setButtonIcon(copied: false)
        addSubview(hoverButton)
    }

    private func setButtonIcon(copied: Bool) {
        let name = copied ? "checkmark" : "doc.on.doc"
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: copied ? .semibold : .regular)
        hoverButton.image = NSImage(systemSymbolName: name, accessibilityDescription: copied ? "已复制" : "复制本条（含链接）")?.withSymbolConfiguration(cfg)
        hoverButton.contentTintColor = copied ? .systemGreen : .secondaryLabelColor
        hoverButton.toolTip = copied ? "已复制" : "复制本条（含链接）"
    }

    func refreshCopyableState() {
        let hadGutter = trailingGutter
        trailingGutter = hasAnyCopyableParagraph() ? Self.buttonGutter : 0
        if hadGutter != trailingGutter || bounds.width > 0 {
            syncTextContainerWidth(bounds.width)
        }
        hideHoverButton(force: true)
    }

    private func syncTextContainerWidth(_ width: CGFloat) {
        guard width > 0, let tc = textContainer else { return }
        let target = max(width - trailingGutter, 40)
        if abs(tc.containerSize.width - target) > 0.5 {
            tc.containerSize = NSSize(width: target, height: .greatestFiniteMagnitude)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncTextContainerWidth(newSize.width)
    }

    override func layout() {
        super.layout()
        syncTextContainerWidth(bounds.width)
        if let r = hoveredRange, !hoverButton.isHidden { positionHoverButton(for: r) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !hoverButton.isHidden { addCursorRect(hoverButton.frame, cursor: .arrow) }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        super.mouseEntered(with: event)
        updateHover(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInside = true
        super.mouseMoved(with: event)
        updateHover(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        super.mouseExited(with: event)
        hideHoverButton(force: false)
    }

    // MARK: copy with links

    override func copy(_ sender: Any?) {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        Pasteboard.copy(formattedCopy(for: ranges, includeLinks: true, stripSingleBullet: false))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let pt = convert(event.locationInWindow, from: nil)
        let clicked = paragraphRange(at: pt)
        let sel = selectedRange()

        if sel.length > 0 {
            menu.items.filter { $0.action == #selector(NSText.copy(_:)) }.forEach { menu.removeItem($0) }
            let selHasLinks = hasLinks(in: sel)
            var idx = 0
            let primary = NSMenuItem(title: selHasLinks ? "复制（含链接）" : "复制", action: #selector(copySelectionWithLinks), keyEquivalent: "")
            primary.target = self
            menu.insertItem(primary, at: idx); idx += 1
            if selHasLinks {
                let plain = NSMenuItem(title: "仅复制文本", action: #selector(copySelectionPlainText), keyEquivalent: "")
                plain.target = self
                menu.insertItem(plain, at: idx); idx += 1
            }
            if let p = clicked, p != sel, hasLinks(in: p) {
                contextRange = p
                let paraItem = NSMenuItem(title: "复制本条（含链接）", action: #selector(copyContextParagraphWithLinks), keyEquivalent: "")
                paraItem.target = self
                menu.insertItem(paraItem, at: idx); idx += 1
            }
            if menu.items.count > idx { menu.insertItem(.separator(), at: idx) }
        } else if let p = clicked, p.length > 0 {
            contextRange = p
            let paraHasLinks = hasLinks(in: p)
            var idx = 0
            let primary = NSMenuItem(title: paraHasLinks ? "复制本条（含链接）" : "复制本条", action: #selector(copyContextParagraphWithLinks), keyEquivalent: "")
            primary.target = self
            menu.insertItem(primary, at: idx); idx += 1
            if paraHasLinks {
                let plain = NSMenuItem(title: "仅复制本条文本", action: #selector(copyContextParagraphPlainText), keyEquivalent: "")
                plain.target = self
                menu.insertItem(plain, at: idx); idx += 1
            }
            if menu.items.count > idx { menu.insertItem(.separator(), at: idx) }
        }
        return menu
    }

    @objc private func copySelectionWithLinks() {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        Pasteboard.copy(formattedCopy(for: ranges, includeLinks: true, stripSingleBullet: false))
    }

    @objc private func copySelectionPlainText() {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        Pasteboard.copy(formattedCopy(for: ranges, includeLinks: false, stripSingleBullet: false))
    }

    @objc private func copyContextParagraphWithLinks() {
        guard let r = contextRange, r.length > 0 else { return }
        Pasteboard.copy(formattedCopy(for: [r], includeLinks: true, stripSingleBullet: true))
    }

    @objc private func copyContextParagraphPlainText() {
        guard let r = contextRange, r.length > 0 else { return }
        Pasteboard.copy(formattedCopy(for: [r], includeLinks: false, stripSingleBullet: true))
    }

    @objc private func copyHoveredParagraph() {
        guard let r = hoveredRange, r.length > 0 else { return }
        Pasteboard.copy(formattedCopy(for: [r], includeLinks: true, stripSingleBullet: true))
        feedbackWork?.cancel()
        showingFeedback = true
        setButtonIcon(copied: true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showingFeedback = false
            self.setButtonIcon(copied: false)
            if !self.pointerInside { self.hideHoverButton(force: true) }
        }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: hover & paragraph helpers

    private func updateHover(for event: NSEvent) {
        guard trailingGutter > 0 else { hideHoverButton(force: true); return }
        let pt = convert(event.locationInWindow, from: nil)
        if !hoverButton.isHidden && hoverButton.frame.insetBy(dx: -6, dy: -4).contains(pt) { return }
        guard let para = paragraphRange(at: pt), isCopyableParagraph(para) else {
            hideHoverButton(force: false)
            return
        }
        if hoveredRange != para {
            feedbackWork?.cancel()
            showingFeedback = false
            setButtonIcon(copied: false)
            hoveredRange = para
        }
        if !showingFeedback {
            hoverButton.toolTip = hasLinks(in: para) ? "复制本条（含链接）" : "复制本条"
        }
        positionHoverButton(for: para)
        if hoverButton.isHidden {
            hoverButton.isHidden = false
            window?.invalidateCursorRects(for: self)
        }
    }

    private func hideHoverButton(force: Bool) {
        if !force && showingFeedback { return }
        if force { feedbackWork?.cancel(); showingFeedback = false; setButtonIcon(copied: false) }
        if !hoverButton.isHidden {
            hoverButton.isHidden = true
            hoveredRange = nil
            window?.invalidateCursorRects(for: self)
        }
    }

    private func positionHoverButton(for range: NSRange) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage,
              range.location < storage.length else { return }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: range.location)
        guard glyph < lm.numberOfGlyphs else { return }
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = max(0, bounds.width - 24)
        let y = textContainerOrigin.y + lineRect.minY + max(0, (lineRect.height - 22) / 2)
        let frame = NSRect(x: x, y: y, width: 22, height: 22)
        if hoverButton.frame != frame {
            hoverButton.frame = frame
            window?.invalidateCursorRects(for: self)
        }
    }

    private func paragraphRange(at point: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        lm.ensureLayout(for: tc)
        guard lm.numberOfGlyphs > 0 else { return nil }
        let tcPt = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let used = lm.usedRect(for: tc)
        guard tcPt.y >= -2 && tcPt.y <= used.maxY + 4 else { return nil }
        let probe = NSPoint(x: 1, y: max(0, min(tcPt.y, max(used.maxY - 1, 0))))
        let glyph = lm.glyphIndex(for: probe, in: tc)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let charIdx = min(lm.characterIndexForGlyph(at: glyph), storage.length - 1)
        let ns = storage.string as NSString
        var para = ns.paragraphRange(for: NSRange(location: charIdx, length: 0))
        while para.length > 0 {
            let last = ns.character(at: para.location + para.length - 1)
            if last == 10 || last == 13 { para.length -= 1 } else { break }
        }
        return para.length > 0 ? para : nil
    }

    private func hasAnyCopyableParagraph() -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let ns = storage.string as NSString
        var loc = 0
        while loc < ns.length {
            var para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let next = para.location + para.length
            while para.length > 0 {
                let last = ns.character(at: para.location + para.length - 1)
                if last == 10 || last == 13 { para.length -= 1 } else { break }
            }
            if para.length > 0 && isCopyableParagraph(para) { return true }
            if next <= loc { break }
            loc = next
        }
        return false
    }

    private func isCopyableParagraph(_ range: NSRange) -> Bool {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return false }
        let text = (storage.string as NSString).substring(with: range)
        return text.hasPrefix("•\t") || hasLinks(in: range)
    }

    private func hasLinks(in range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        var found = false
        storage.enumerateAttribute(.link, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private func formattedCopy(for ranges: [NSRange], includeLinks: Bool, stripSingleBullet: Bool) -> String {
        guard let storage = textStorage, storage.length > 0 else { return "" }
        let safeRanges = ranges.compactMap { r -> NSRange? in
            let loc = max(0, min(r.location, storage.length))
            let len = max(0, min(r.length, storage.length - loc))
            return len > 0 ? NSRange(location: loc, length: len) : nil
        }
        guard !safeRanges.isEmpty else { return "" }

        let parts = safeRanges.map { r -> String in
            var s = (storage.string as NSString).substring(with: r)
            if stripSingleBullet && safeRanges.count == 1 && s.hasPrefix("•\t") {
                s.removeFirst(2)
            }
            return s.replacingOccurrences(of: "•\t", with: "• ")
        }
        let body = parts.joined(separator: "\n")
        guard includeLinks else { return body }

        var linkLines: [String] = []
        var seenURLs = Set<String>()
        for r in safeRanges {
            let sub = storage.attributedSubstring(from: r)
            sub.enumerateAttribute(.link, in: NSRange(location: 0, length: sub.length)) { value, runRange, _ in
                let rawURL: String?
                if let u = value as? URL { rawURL = u.absoluteString }
                else if let s = value as? String { rawURL = s }
                else { rawURL = nil }
                guard let url = rawURL, !url.isEmpty, seenURLs.insert(url).inserted else { return }
                let label = (sub.string as NSString).substring(with: runRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if let ev = evidence.first(where: { $0.id == label }) ?? evidence.first(where: { $0.url == url }) {
                    linkLines.append(RadarAssistant.formatSourceLine(id: ev.id, title: ev.title, url: url))
                } else {
                    linkLines.append(RadarAssistant.formatSourceLine(id: "", title: label, url: url))
                }
            }
        }
        guard !linkLines.isEmpty else { return body }
        return body.trimmingCharacters(in: .newlines) + "\n\n来源：\n" + linkLines.joined(separator: "\n")
    }
}

enum Pasteboard {
    static func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

struct CopyButton: View {
    let text: String
    var label: String = "复制"
    @State private var copied = false
    var body: some View {
        Button { Pasteboard.copy(text); copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: { Label(copied ? "已复制" : label, systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
    }
}

struct SourceList: View {
    @EnvironmentObject var model: AppModel
    let items: [Evidence]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("来源").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(items) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let u = URL(string: e.url) { Link(e.title, destination: u).lineLimit(1) } else { Text(e.title).lineLimit(1) }
                        if e.kind != "status", e.kind != "page", e.url.hasPrefix("http") {
                            Button { model.readWithRadar(e.url) } label: { Image(systemName: "text.book.closed") }
                                .buttonStyle(.borderless).help("让 Radar 读这一篇并整理要点")
                        }
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
        if let n = ai.switchNote {
            Label(n, systemImage: "arrow.triangle.swap").font(.caption).foregroundStyle(.blue)
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
                for try await piece in ai.client.chat(model: m, messages: RadarAssistant.summaryMessages(ctx, range: range)) { text += piece }
                if !stopped && !text.isEmpty { ai.save(key, .init(text: text, evidence: ctx.evidence, signature: ctx.signature, model: m.name, date: Date())); generatedAt = Date() }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

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
        .confirmationDialog("重新生成今天所有雷达的简报？", isPresented: $confirmAll) {
            Button("全部重新生成") { b.start(.all(force: true)) }
        } message: { Text("会对每个有更新的雷达各调用一次模型。只补齐还没生成的，请用“补齐未生成的”。") }
    }

    // MARK: header and tabs

    var header: some View {
        HStack(spacing: 10) {
            let older = b.days.filter { $0.day < day }.first?.day, newer = b.days.last { $0.day > day }?.day
            Button { if let o = older { day = o } } label: { Image(systemName: "chevron.left") }.disabled(older == nil).help("前一天的简报")
            Menu {
                Button("今天（\(b.today)）") { day = b.today }
                Divider()
                ForEach(b.days.prefix(60).filter { $0.day != b.today }) { d in Button((d.day == day ? "✓ " : "") + d.day + (d.auto ? " · 自动" : "")) { day = d.day } }
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
                for try await piece in model.ai.client.chat(model: m, messages: RadarAssistant.askMessages(history: history, question: q, evidence: base, scope: title)) { update { $0.answer += piece } }
            } catch is CancellationError {} catch { update { $0.failed = error.localizedDescription } }
        }
    }
}

import GRDB

