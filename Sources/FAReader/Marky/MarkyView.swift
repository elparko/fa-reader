import AppKit

/// A self-contained Markdown viewer/editor view: a native preview (md4c → TextKit),
/// a syntax-highlighted source editor, or both side by side.
///
///     let marky = MarkyView()
///     marky.baseURL = fileURL.deletingLastPathComponent()  // resolves relative links & images
///     marky.text = try String(contentsOf: fileURL, encoding: .utf8)
///     marky.onTextChange = { save(marky.text) }
///     marky.mode = .split
///
/// The editor is created lazily the first time it's needed, so a view that only
/// ever previews never pays for it.
final class MarkyView: NSView, NSTextViewDelegate {

    enum Mode: Int { case preview = 0, split = 1, editor = 2 }

    // MARK: - Public API

    var mode: Mode {
        get { currentMode }
        set { apply(newValue) }
    }

    /// The Markdown source, including unsaved edits. Setting it replaces the content
    /// and clears the editor's undo history.
    var text: String {
        get { editor?.string ?? storedText }
        set { replaceText(newValue) }
    }

    /// Directory used to resolve relative links and images.
    var baseURL: URL? {
        didSet { if baseURL != oldValue { invalidatePreview() } }
    }

    var fontSize: CGFloat = Theme.defaultFontSize {
        didSet { if fontSize != oldValue { fontSizeDidChange() } }
    }

    /// Called after every user edit (typing, undo, checkbox toggles). Read `text` for the content.
    var onTextChange: (() -> Void)?
    var onModeChange: ((Mode) -> Void)?
    /// Handles clicks on links to other Markdown files. Defaults to opening them with NSWorkspace.
    var openMarkdownLink: ((_ file: URL, _ fragment: String?) -> Void)?
    /// Handles any other link first; return true when handled.
    var openURL: ((URL) -> Bool)?
    /// Undo manager for the editor. Defaults to the window's.
    var undoManagerProvider: (() -> UndoManager?)?

    /// Makes the visible text view first responder.
    func focus() {
        window?.makeFirstResponder(currentMode == .preview ? preview : editor)
    }

    // MARK: - State

    private var currentMode: Mode = .preview
    private var storedText = ""
    private let previewScroll: NSScrollView
    private let preview: PreviewTextView
    private var editorScroll: NSScrollView?
    private var editor: EditorTextView?
    private var highlighter: MarkdownHighlighter?
    private var splitView: NSSplitView?
    private var needsSplitPosition = false

    private var anchors: [String: Int] = [:]
    private var version = 0          // bumped whenever the preview's inputs change
    private var renderedVersion = -1
    private var renderedWidth: CGFloat = 0
    private var renderScheduled = false

    override init(frame: NSRect) {
        previewScroll = makeScrollingTextView({ PreviewTextView(frame: $0, textContainer: $1) },
                                              frame: NSRect(origin: .zero, size: frame.size))
        preview = previewScroll.documentView as! PreviewTextView
        super.init(frame: frame)

        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = true
        preview.importsGraphics = false
        preview.displaysLinkToolTips = false
        preview.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        preview.delegate = self
        preview.onToggleTask = { [weak self] offset in self?.toggleTask(utf8Offset: offset) }
        preview.updateInset()
        apply(.preview)
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Modes

    private func apply(_ newMode: Mode) {
        let fraction = scrollFraction(currentMode == .preview ? previewScroll : (editorScroll ?? previewScroll))
        let changed = newMode != currentMode
        currentMode = newMode
        splitView?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        splitView?.removeFromSuperview()
        previewScroll.removeFromSuperview()
        editorScroll?.removeFromSuperview()

        switch newMode {
        case .preview:
            renderIfNeeded()
            install(previewScroll)
            setScrollFraction(fraction, previewScroll)
        case .editor:
            ensureEditor()
            install(editorScroll!)
            setScrollFraction(fraction, editorScroll!)
        case .split:
            ensureEditor()
            renderIfNeeded()
            let split = splitView ?? makeSplitView()
            install(split)
            split.addArrangedSubview(editorScroll!)
            split.addArrangedSubview(previewScroll)
            split.adjustSubviews()
            needsSplitPosition = true
            positionSplitIfNeeded()
            setScrollFraction(fraction, editorScroll!)
            syncPreviewScroll()
        }
        focus()
        if changed { onModeChange?(newMode) }
    }

    private func install(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func makeSplitView() -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        return split
    }

    private func positionSplitIfNeeded() {
        guard needsSplitPosition, let split = splitView, split.bounds.width > 0 else { return }
        split.setPosition(floor(split.bounds.width / 2), ofDividerAt: 0)
        needsSplitPosition = false
    }

    override func layout() {
        super.layout()
        positionSplitIfNeeded()
        if currentMode != .editor && renderedVersion != version { render() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Images are sized to the column, so re-lay them out at the new width.
        if currentMode != .editor && abs(renderedWidth - preview.contentWidth) > 1
            && preview.textStorage?.containsAttachments == true {
            render()
        }
    }

    // MARK: - Editor

    private func ensureEditor() {
        guard editor == nil else { return }
        let scroll = makeScrollingTextView({ EditorTextView(frame: $0, textContainer: $1) },
                                           frame: NSRect(origin: .zero, size: bounds.size))
        let tv = scroll.documentView as! EditorTextView
        let hl = MarkdownHighlighter(fontSize: fontSize)
        tv.isEditable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(forKey: "SpellCheck")
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.textStorage?.delegate = hl
        tv.typingAttributes = hl.baseAttributes
        tv.highlighter = hl
        tv.string = storedText
        tv.delegate = self
        tv.updateInset()
        tv.setSelectedRange(NSRange(location: 0, length: 0))

        editor = tv
        editorScroll = scroll
        highlighter = hl
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManagerProvider?() ?? window?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === editor else { return }
        version += 1
        scheduleRender()
        onTextChange?()
    }

    private func replaceText(_ newText: String) {
        if let editor, let ts = editor.textStorage {
            let sel = editor.selectedRange()
            ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: newText)
            highlighter?.highlightAll(ts)
            editor.setSelectedRange(NSRange(location: min(sel.location, ts.length), length: 0))
            undoManager(for: editor)?.removeAllActions()
        } else {
            storedText = newText
        }
        invalidatePreview()
    }

    private func toggleTask(utf8Offset offset: Int) {
        ensureEditor() // edits go through the editor so they're undoable
        guard let editor else { return }
        let s = editor.string
        let utf8 = s.utf8
        guard offset >= 0, let idx = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex),
              idx < utf8.endIndex else { return }
        let ch = utf8[idx]
        guard ch == 0x20 || ch == 0x78 || ch == 0x58 else { return } // ' ', 'x', 'X'
        editor.replace(NSRange(idx..<utf8.index(after: idx), in: s), with: ch == 0x20 ? "x" : " ")
        if currentMode == .preview { render() }
    }

    private func fontSizeDidChange() {
        if let hl = highlighter, let editor, let ts = editor.textStorage {
            hl.fontSize = fontSize
            editor.typingAttributes = hl.baseAttributes
            hl.highlightAll(ts)
        }
        invalidatePreview()
    }

    // MARK: - Rendering

    private func invalidatePreview() {
        version += 1
        needsLayout = true // renders before the next display, coalescing changes
    }

    private func scheduleRender() {
        guard currentMode != .editor, !renderScheduled else { return }
        renderScheduled = true
        let length = (editor?.string as NSString?)?.length ?? 0
        let delay: TimeInterval = length < 30_000 ? 0.02 : length < 300_000 ? 0.1 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            if self.currentMode != .editor { self.render() }
        }
    }

    private func renderIfNeeded() {
        if renderedVersion != version || abs(renderedWidth - preview.contentWidth) > 1 { render() }
    }

    private func render() {
        let start = CACurrentMediaTime()
        let width = preview.contentWidth
        let result = MarkdownRenderer.render(text, baseURL: baseURL, fontSize: fontSize, maxImageWidth: width)
        let built = CACurrentMediaTime()
        let y = previewScroll.contentView.bounds.origin.y
        preview.textStorage?.setAttributedString(result.text)
        anchors = result.anchors
        renderedVersion = version
        renderedWidth = width
        if y > 0 { restorePreviewScroll(y) }
        if Debug.trace {
            NSLog("render: parse+build %.1fms, layout %.1fms (%d chars)",
                  (built - start) * 1000, (CACurrentMediaTime() - built) * 1000, result.text.length)
        }
        if !result.pendingImages.isEmpty {
            ImageStore.shared.fetch(result.pendingImages) { [weak self] in self?.render() }
        }
    }

    private func restorePreviewScroll(_ y: CGFloat) {
        guard let lm = preview.layoutManager, let tc = preview.textContainer else { return }
        let visible = previewScroll.contentView.bounds.height
        lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: tc.size.width, height: y + visible), in: tc)
        previewScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    // MARK: - Scrolling

    private func scrollFraction(_ scroll: NSScrollView) -> CGFloat {
        guard let docView = scroll.documentView else { return 0 }
        let maxY = docView.frame.height - scroll.contentView.bounds.height
        return maxY > 0 ? min(1, scroll.contentView.bounds.origin.y / maxY) : 0
    }

    private func setScrollFraction(_ f: CGFloat, _ scroll: NSScrollView) {
        guard f > 0, let tv = scroll.documentView as? NSTextView,
              let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let maxY = tv.frame.height - scroll.contentView.bounds.height
        guard maxY > 0 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (f * maxY).rounded()))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func editorDidScroll() {
        if currentMode == .split { syncPreviewScroll() }
    }

    private func syncPreviewScroll() {
        guard let editorScroll else { return }
        let f = scrollFraction(editorScroll)
        let maxY = preview.frame.height - previewScroll.contentView.bounds.height
        guard maxY > 0 else { return }
        previewScroll.contentView.scroll(to: NSPoint(x: 0, y: (f * maxY).rounded()))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if let openURL, openURL(url) { return true }
        if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
            scrollToAnchor(fragment)
            return true
        }
        if url.isFileURL {
            let file = URL(fileURLWithPath: url.path)
            guard FileManager.default.fileExists(atPath: file.path) else { NSSound.beep(); return true }
            let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "txt"]
            if markdown.contains(file.pathExtension.lowercased()), let open = openMarkdownLink {
                open(file, url.fragment)
            } else {
                NSWorkspace.shared.open(file)
            }
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Scrolls the preview to a heading by its GitHub-style slug (e.g. "getting-started").
    func scrollToAnchor(_ fragment: String) {
        if currentMode == .editor { mode = .preview }
        renderIfNeeded()
        let key = (fragment.removingPercentEncoding ?? fragment).lowercased()
        guard let loc = anchors[key] ?? anchors[key.replacingOccurrences(of: " ", with: "-")],
              let lm = preview.layoutManager, let tc = preview.textContainer else { NSSound.beep(); return }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
        lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        preview.scroll(NSPoint(x: 0, y: max(0, rect.minY + preview.textContainerOrigin.y - 12)))
    }
}
