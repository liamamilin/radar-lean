import SwiftUI
import RadarCore

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
