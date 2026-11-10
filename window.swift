// The window. Top: voice menu with a ▶ sample, then the speed. Middle: the text. Bottom: the player, or the model
// download while there is no model yet.
//
// Keys: Space plays and pauses, ← and → jump 15 seconds, whenever the text has no cursor. With the cursor in the text
// they type as usual; a click anywhere outside the text, or Esc, takes the cursor out.

import AppKit
import UniformTypeIdentifiers

final class RootView: NSView {
    weak var owner: MainWindow?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49: owner?.togglePlay()
        case 123: owner?.skip(-15)
        case 124: owner?.skip(15)
        default: super.keyDown(with: e)
        }
    }
    // Typing or pasting with the cursor out of the text goes back into the text.
    @objc func paste(_ s: Any?) { owner?.focusText(); owner?.textView.paste(s) }
    override func selectAll(_ s: Any?) { owner?.focusText(); owner?.textView.selectAll(s) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { owner?.dragOperation(s) ?? [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { owner?.drop(s) ?? false }
}

final class TextView: NSTextView {
    weak var owner: MainWindow?
    var placeholder = ""

    override func cancelOperation(_ s: Any?) { window?.makeFirstResponder(owner?.root) }

    override func draw(_ r: NSRect) {
        super.draw(r)
        if string.isEmpty {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let a: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor,
                                                    .paragraphStyle: p]
            let h = (font?.boundingRectForFont.height ?? 16)
            let rect = NSRect(x: 0, y: (enclosingScrollView?.contentView.bounds.height ?? bounds.height) / 2 - h, width: bounds.width, height: h * 2)
            placeholder.draw(in: rect, withAttributes: a)
        }
    }

    // Pasted Markdown loses its syntax at once.
    override func paste(_ s: Any?) {
        if let t = NSPasteboard.general.string(forType: .string), TextImport.looksLikeMarkdown(t) {
            insertText(TextImport.tidy(TextImport.markdown(t)), replacementRange: selectedRange())
        } else {
            pasteAsPlainText(s)
        }
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        owner?.isFileDrag(s) == true ? .copy : super.draggingEntered(s)
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        owner?.isFileDrag(s) == true ? .copy : super.draggingUpdated(s)
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if owner?.isFileDrag(s) == true { return owner?.drop(s) ?? false }
        return super.performDragOperation(s)
    }
}

final class MainWindow: NSWindow, NSWindowDelegate, NSTextViewDelegate {
    let root = RootView()
    // TextKit 1 on purpose: the highlight of the sentence being read is a temporary attribute (it never touches the
    // text, its undo or what is copied), and following it needs the sentence's exact place, which TextKit 1 lays out
    // for the whole text while TextKit 2 only estimates it outside the visible part.
    let textView = TextView(usingTextLayoutManager: false)
    let scroll = NSScrollView()

    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speedSlider = NSSlider(value: Speed.standard, minValue: Speed.min, maxValue: Speed.max, target: nil, action: nil)
    private let speedValue = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: L("Speed"))
    private let topBar = NSView()

    private let bar = NSView()
    private let playerRow = NSView()
    private let backButton = NSButton()
    private let playButton = NSButton()
    private let forwardButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L("Save MP3…"), target: nil, action: nil)

    private let downloadRow = NSView()
    private let downloadNote = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: L("Download"), target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: L("Cancel"), target: nil, action: nil)

    private var engine: Supertonic?
    private var voices: [String: Voice] = [:]
    private var loading = false
    private var playWhenLoaded = false
    private var download: ModelDownload?
    private let player = Player()
    private let samplePlayer = Player()
    private var generator: Generator?
    private var generatorText = ""
    private var generatorVoice = -1
    private var preparing = false
    private var saving: Saving?
    private var fileName: String?

    // MARK: size

    /// Default size, the way TextEdit sizes a new window: so many characters wide and so many lines high in the text's
    /// own font (TextEdit's defaults are 75 and 30). The text column never gets wider than 80 characters: a wider window
    /// (or full screen) widens the margins instead, so lines stay readable.
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static func charWidth(_ font: NSFont = font) -> CGFloat {
        let sample = "the quick brown fox jumps over the lazy dog съешь же ещё этих мягких французских булок"
        return (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
    }

    /// Text sizes for ⌘+ and ⌘−, as TextEdit's Bigger and Smaller do it for plain text, but in steps the eye sees:
    /// one point at a time near the standard 13, wider steps further up (TextEdit adds one point, which from 24 on
    /// takes a dozen presses to notice). Kept between launches, like the voice and the speed.
    static let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64, 72]
    static let inset: CGFloat = 20
    static let barHeight: CGFloat = 52

    init() {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Self.font)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        var size = NSSize(width: (75 * Self.charWidth() + 2 * Self.inset + scroller).rounded(),
                          height: (30 * lineHeight + 2 * 12 + 2 * Self.barHeight).rounded())
        if let v = NSScreen.main?.visibleFrame { size.width = min(size.width, v.width * 0.9); size.height = min(size.height, v.height * 0.9) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "TTS"
        isReleasedWhenClosed = false
        isRestorable = false
        delegate = self
        collectionBehavior = [.fullScreenPrimary]
        minSize = NSSize(width: 480, height: 260)
        tabbingMode = .disallowed
        center()
        setFrameAutosaveName("")
        build()
        restoreSettings()
        refreshModelState()
        makeFirstResponder(textView)
    }

    // MARK: building

    private func build() {
        root.owner = self
        root.registerForDraggedTypes([.fileURL])
        contentView = root

        textView.owner = self
        textView.placeholder = L("Paste text or drop a file")
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Self.font
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: Self.inset, height: 12)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.registerForDraggedTypes([.fileURL])
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        // Top bar, plain AppKit controls in the family's grammar (STT, #HEX, OCR: 13 pt labels, regular controls,
        // 20 pt margins), not an NSToolbar: on macOS 26+ a toolbar wraps every item in a Liquid Glass capsule, and the
        // speed slider looked like a foreign object in one (the author's remark, 2026-11-09).
        voicePopup.target = self; voicePopup.action = #selector(voiceChanged)
        voicePopup.refusesFirstResponder = true
        fillVoiceMenu()

        speedSlider.target = self; speedSlider.action = #selector(speedChanged)
        speedSlider.isContinuous = true
        speedSlider.refusesFirstResponder = true
        speedSlider.setAccessibilityLabel(L("Speed"))
        voicePopup.setAccessibilityLabel(L("Voice"))
        speedValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        speedValue.alignment = .right
        speedLabel.font = .systemFont(ofSize: NSFont.systemFontSize)   // the menu says «Голос 1» by itself
        topBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)
        let topLine = NSBox(); topLine.boxType = .separator; topLine.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topLine)
        for v in [voicePopup, speedLabel, speedSlider, speedValue] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        let valueWidth = ("0,00" as NSString).size(withAttributes: [.font: speedValue.font!]).width.rounded(.up) + 2
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            topLine.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            voicePopup.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 20),
            voicePopup.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            speedValue.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -20),
            speedValue.firstBaselineAnchor.constraint(equalTo: speedLabel.firstBaselineAnchor),
            speedValue.widthAnchor.constraint(equalToConstant: valueWidth),
            speedSlider.trailingAnchor.constraint(equalTo: speedValue.leadingAnchor, constant: -8),
            speedSlider.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            speedSlider.widthAnchor.constraint(equalToConstant: 140),
            speedLabel.trailingAnchor.constraint(equalTo: speedSlider.leadingAnchor, constant: -8),
            speedLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            speedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: voicePopup.trailingAnchor, constant: 20),
        ])

        // bottom bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(line)

        for (b, name, tip, act) in [(backButton, "gobackward.15", L("Back 15 Seconds"), #selector(back)),
                                    (playButton, "play.fill", L("Play"), #selector(playPressed)),
                                    (forwardButton, "goforward.15", L("Forward 15 Seconds"), #selector(forward))] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.image = symbol(name, tip, size: b === playButton ? 22 : 17)
            b.toolTip = tip
            b.target = self; b.action = act
            b.refusesFirstResponder = true
            b.translatesAutoresizingMaskIntoConstraints = false
            playerRow.addSubview(b)
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self; saveButton.action = #selector(saveMP3)
        saveButton.bezelStyle = .rounded
        saveButton.refusesFirstResponder = true
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        playerRow.addSubview(timeLabel); playerRow.addSubview(saveButton)

        downloadNote.textColor = .secondaryLabelColor
        downloadNote.lineBreakMode = .byTruncatingTail
        downloadNote.translatesAutoresizingMaskIntoConstraints = false
        downloadNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadButton.target = self; downloadButton.action = #selector(startDownload)
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelDownload)
        cancelButton.bezelStyle = .rounded
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar
        for v in [downloadNote, downloadButton, cancelButton, progress] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            downloadRow.addSubview(v)
        }
        for r in [playerRow, downloadRow] {
            r.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(r)
            NSLayoutConstraint.activate([r.leadingAnchor.constraint(equalTo: bar.leadingAnchor), r.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                                         r.topAnchor.constraint(equalTo: bar.topAnchor), r.bottomAnchor.constraint(equalTo: bar.bottomAnchor)])
        }

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            playButton.centerXAnchor.constraint(equalTo: playerRow.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: playerRow.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            backButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -14),
            backButton.centerYAnchor.constraint(equalTo: playerRow.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 30),
            backButton.heightAnchor.constraint(equalToConstant: 30),
            forwardButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 14),
            forwardButton.centerYAnchor.constraint(equalTo: playerRow.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 30),
            forwardButton.heightAnchor.constraint(equalToConstant: 30),
            timeLabel.leadingAnchor.constraint(equalTo: playerRow.leadingAnchor, constant: m),
            timeLabel.centerYAnchor.constraint(equalTo: playerRow.centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -8),
            saveButton.trailingAnchor.constraint(equalTo: playerRow.trailingAnchor, constant: -m),
            saveButton.centerYAnchor.constraint(equalTo: playerRow.centerYAnchor),
            saveButton.leadingAnchor.constraint(greaterThanOrEqualTo: forwardButton.trailingAnchor, constant: 8),

            downloadNote.leadingAnchor.constraint(equalTo: downloadRow.leadingAnchor, constant: m),
            downloadNote.centerYAnchor.constraint(equalTo: downloadRow.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: downloadRow.trailingAnchor, constant: -m),
            downloadButton.centerYAnchor.constraint(equalTo: downloadRow.centerYAnchor),
            downloadNote.trailingAnchor.constraint(lessThanOrEqualTo: downloadButton.leadingAnchor, constant: -12),
            cancelButton.trailingAnchor.constraint(equalTo: downloadRow.trailingAnchor, constant: -m),
            cancelButton.centerYAnchor.constraint(equalTo: downloadRow.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: downloadRow.leadingAnchor, constant: m),
            progress.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: downloadRow.centerYAnchor),
        ])

        player.onChange = { [weak self] in self?.refreshPlayer() }
        samplePlayer.onEnd = { [weak self] in self?.samplePlayer.load(nil) }
    }

    private func symbol(_ name: String, _ label: String, size: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func fillVoiceMenu() {
        let menu = NSMenu()
        func header(_ t: String) -> NSMenuItem {
            if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: t) }
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }
        func tagged(_ i: NSMenuItem) -> NSMenuItem { i.tag = -1; return i }   // headers never match a voice
        menu.addItem(tagged(header(L("Male"))))
        for i in 0..<10 {
            if i == 5 { menu.addItem(.separator()); menu.addItem(tagged(header(L("Female")))) }
            let it = NSMenuItem(title: String(format: L("Voice %d"), i + 1), action: nil, keyEquivalent: "")
            it.tag = i
            menu.addItem(it)
        }
        menu.autoenablesItems = false
        voicePopup.menu = menu
    }

    // MARK: settings

    private func restoreSettings() {
        let v = UserDefaults.standard.integer(forKey: "voice")
        voicePopup.selectItem(withTag: (0..<10).contains(v) ? v : 0)
        let stored = UserDefaults.standard.object(forKey: "speed") as? Double ?? Speed.standard
        let s = Speed.round(min(Speed.max, max(Speed.min, stored)))
        speedSlider.doubleValue = s
        speedValue.stringValue = Speed.text(s)
        player.speed = Float(s)
        let size = UserDefaults.standard.double(forKey: "textSize")
        setTextSize(Self.sizes.contains(CGFloat(size)) ? CGFloat(size) : NSFont.systemFontSize)
    }

    // MARK: text size

    private var textSize: CGFloat { textView.font?.pointSize ?? NSFont.systemFontSize }

    private func setTextSize(_ size: CGFloat) {
        textView.font = .systemFont(ofSize: size)
        UserDefaults.standard.set(Double(size), forKey: "textSize")
        fitColumn()
        textView.needsDisplay = true
        if let r = highlighted { follow(r, always: true) }
    }

    @objc func biggerText(_ s: Any?) { if let n = Self.sizes.first(where: { $0 > textSize }) { setTextSize(n) } }
    @objc func smallerText(_ s: Any?) { if let n = Self.sizes.last(where: { $0 < textSize }) { setTextSize(n) } }
    @objc func actualSizeText(_ s: Any?) { setTextSize(NSFont.systemFontSize) }

    private var voiceIndex: Int { voicePopup.selectedItem?.tag ?? 0 }
    private var speed: Float { Float(Speed.round(speedSlider.doubleValue)) }

    // MARK: model

    private func refreshModelState() {
        let here = Model.isHere
        playerRow.isHidden = !here
        downloadRow.isHidden = here
        let downloading = download != nil
        downloadNote.isHidden = downloading
        downloadButton.isHidden = downloading
        progress.isHidden = !downloading
        cancelButton.isHidden = !downloading
        downloadNote.stringValue = String(format: L("Voices need the Supertonic 3 model, %@."), sizeText(Model.totalSize))
        if here && engine == nil && !loading { loadEngine() }
        refreshControls()
    }

    private func loadEngine() {
        loading = true
        refreshControls()
        let dir = Model.folder
        let threads = Workers.threads
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(Supertonic, [String: Voice]), Error> = Result {
                let e = try Supertonic(onnxDir: dir.appendingPathComponent("onnx"), threads: threads)
                var v: [String: Voice] = [:]
                for id in Voices.ids { v[id] = try Voice(url: dir.appendingPathComponent("voice_styles/\(id).json")) }
                return (e, v)
            }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let (e, v)):
                    self.engine = e; self.voices = v
                    if self.playWhenLoaded { self.playWhenLoaded = false; self.togglePlay() }
                case .failure(let err):
                    self.report(L("The model could not be loaded"), "\(Model.folder.path)\n\(err)")
                }
                self.refreshControls()
            }
        }
    }

    @objc private func startDownload() {
        let free = (try? Model.folder.deletingLastPathComponent().deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < Model.totalSize + 50_000_000 {
            alert(L("Not enough disk space"), String(format: L("%1$@ needs %2$@. Free: %3$@."), "Supertonic 3",
                                                          sizeText(Model.totalSize), sizeText(free)))
            return
        }
        progress.doubleValue = 0
        download = ModelDownload(progress: { p in
            DispatchQueue.main.async { self.progress.doubleValue = p }
        }, done: { err in
            DispatchQueue.main.async {
                self.download = nil
                if let err { Model.removeParts(); self.report(L("The download failed"), err) }
                self.refreshModelState()
            }
        })
        refreshModelState()
        download?.start()
    }

    @objc private func cancelDownload() {
        download?.cancel()
        download = nil
        Model.removeParts()
        refreshModelState()
    }

    @objc func showModel() {
        guard FileManager.default.fileExists(atPath: Model.folder.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Model.folder])
    }

    @objc func deleteModel() {
        guard Model.isHere || FileManager.default.fileExists(atPath: Model.folder.path) else { return }
        let a = NSAlert()
        a.messageText = L("Delete the Supertonic 3 model?")
        a.informativeText = String(format: L("%@. The voices will need it downloaded again."), sizeText(Model.totalSize))
        a.addButton(withTitle: L("Delete"))
        a.addButton(withTitle: L("Cancel"))
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        stopAll()
        releaseEngine()
        do { try Model.delete() } catch { report(L("The model could not be deleted"), "\(error)") }
        refreshModelState()
    }

    private func releaseEngine() {
        // The engine goes only when nothing is using it.
        generator?.cancel(); saving?.generator?.cancel()
        generator?.wait(); saving?.generator?.wait()
        generator = nil
        engine = nil
        voices = [:]
    }

    // MARK: text

    func textDidChange(_ n: Notification) {
        if generator != nil || player.source != nil { stopAll() }
        refreshControls()
        textView.needsDisplay = true
    }

    func focusText() { makeFirstResponder(textView) }

    @objc func openDocument(_ s: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = TextImport.types
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: self) { r in
            if r == .OK, let u = p.url { self.open(u) }
        }
    }

    func open(_ url: URL) {
        do {
            let t = try TextImport.read(url)
            stopAll()
            textView.string = t
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            fileName = url.deletingPathExtension().lastPathComponent
            title = url.lastPathComponent
            makeFirstResponder(root)
            refreshControls()
            textView.needsDisplay = true
        } catch {
            report(L("This file could not be read"), "\(url.path)\n\(error)")
        }
    }

    func isFileDrag(_ s: NSDraggingInfo) -> Bool {
        s.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
    func dragOperation(_ s: NSDraggingInfo) -> NSDragOperation { isFileDrag(s) ? .copy : [] }
    func drop(_ s: NSDraggingInfo) -> Bool {
        guard let u = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        else { return false }
        open(u)
        return true
    }

    private var text: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: playing

    func togglePlay() {
        stopSample()
        if player.source != nil, generatorText == textView.string, generatorVoice == voiceIndex {
            player.toggle(); return
        }
        guard !text.isEmpty, !preparing else { return }
        guard let engine, let voice = voices[Voices.ids[voiceIndex]] else {
            if loading { playWhenLoaded = true }
            return
        }
        startGenerating(engine: engine, voice: voice, fromPiece: 0, play: true)
    }

    private func startGenerating(engine: Supertonic, voice: Voice, fromPiece: Int, play: Bool) {
        let content = textView.string, vi = voiceIndex, sp = speed
        preparing = true
        refreshControls()
        DispatchQueue.global(qos: .userInitiated).async {
            let script = Pieces.script(content, fallback: appLanguage)
            let pieces = script.pieces
            let result = Result { try Generator(engine: engine, pieces: pieces, voice: voice, voiceName: Voices.ids[vi], steps: flowSteps,
                                                 speed: Speed.engine(sp), startAt: min(fromPiece, max(0, pieces.count - 1))) }
            DispatchQueue.main.async {
                self.preparing = false
                guard content == self.textView.string, vi == self.voiceIndex else { self.refreshControls(); return }
                switch result {
                case .failure(let e): self.report(L("Speech could not be made"), "\(e)")
                case .success(let g):
                    self.generator?.cancel()
                    self.generator = g
                    self.sentences = script.sentences
                    self.generatorText = content
                    self.generatorVoice = vi
                    g.onProgress = { DispatchQueue.main.async { self.refreshPlayer() } }
                    g.onDone = { err in
                        DispatchQueue.main.async {
                            if let err, err != "cancelled", self.generator === g { self.player.pause(); self.report(L("Speech could not be made"), err) }
                            self.refreshPlayer()
                        }
                    }
                    let start = g.store.offsets.isEmpty ? 0 : g.store.offsets[min(fromPiece, g.store.offsets.count - 1)]
                    self.player.load(g.store, at: fromPiece == 0 ? 0 : start)
                    g.start(workers: Workers.count)
                    if play { self.player.play() }
                }
                self.refreshControls()
            }
        }
    }

    private func stopAll() {
        generator?.cancel()
        generator = nil
        generatorText = ""
        generatorVoice = -1
        player.pause()
        player.load(nil)
        sentences = []
        stopSample()
        refreshControls()
    }

    @objc private func playPressed() { togglePlay() }
    @objc private func back() { skip(-15) }
    @objc private func forward() { skip(15) }

    func skip(_ s: Double) {
        guard player.source != nil else { return }
        player.skip(seconds: s)
    }

    /// The voice is its own sample (the author's design, 2026-11-09): choosing a voice plays it, choosing the same voice again
    /// plays it again (NSPopUpButton sends its action for the chosen item even when it was already chosen). While the
    /// text is being read, a new voice goes on reading from the same place instead: that is hearing it too.
    @objc private func voiceChanged() {
        let changed = voiceIndex != UserDefaults.standard.integer(forKey: "voice")
        UserDefaults.standard.set(voiceIndex, forKey: "voice")
        if let g = generator, player.isPlaying, let engine, let voice = voices[Voices.ids[voiceIndex]] {
            guard changed else { return }
            stopSample()
            let piece = g.store.piece(at: player.position)
            g.cancel()
            generator = nil
            player.pause()
            player.load(nil)
            startGenerating(engine: engine, voice: voice, fromPiece: piece, play: true)
            return
        }
        // Paused or stopped: the made sound belongs to the old voice and goes; the sample plays.
        if changed && player.source != nil { stopAll() }
        sample()
    }

    @objc private func speedChanged() {
        let s = Speed.round(speedSlider.doubleValue)
        speedSlider.doubleValue = s
        speedValue.stringValue = Speed.text(s)
        player.speed = Float(s)
        UserDefaults.standard.set(s, forKey: "speed")
        refreshPlayer()
    }

    // MARK: sample

    private func stopSample() {
        sampleToken = UUID()
        sampleBusy = false
        if samplePlayer.source != nil { samplePlayer.pause(); samplePlayer.load(nil) }
    }

    private func sample() {
        stopSample()
        guard let engine, let voice = voices[Voices.ids[voiceIndex]] else { return }
        if player.isPlaying { player.pause() }
        let (t, lang) = sampleText()
        let sp = speed
        sampleBusy = true
        let token = UUID()
        sampleToken = token
        sampleWork.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try engine.synthesize(t, lang: lang, voice: voice, steps: flowSteps, speed: Speed.engine(sp)) }
            self.sampleWork.leave()
            DispatchQueue.main.async {
                guard self.sampleToken == token, self.sampleBusy else { return }
                self.sampleBusy = false
                switch r {
                case .success(let w):
                    self.samplePlayer.speed = sp
                    self.samplePlayer.load(MemorySource(w, sampleRate: engine.sampleRate, speed: Speed.engine(sp)))
                    self.samplePlayer.play()
                case .failure(let e): self.report(L("Speech could not be made"), "\(e)")
                }
            }
        }
    }

    private var sampleBusy = false
    private let sampleWork = DispatchGroup()
    private var sampleToken = UUID()

    /// The first sentence of the text, or a passage of classic literature in the app's language.
    private func sampleText() -> (String, String) {
        let t = text
        if !t.isEmpty {
            let pieces = Pieces.make(t, fallback: appLanguage)
            if let p = pieces.first {
                let first = Pieces.split(p.text, lang: p.lang).first ?? p.text
                return (Pieces.cut(first, max: 200).first ?? first, p.lang)
            }
        }
        let lang = Samples.texts[appLanguage] != nil ? appLanguage : "en"
        return (Samples.texts[lang]!.randomElement()!, lang)
    }

    // MARK: save

    @objc func saveMP3() {
        guard !text.isEmpty, engine != nil, saving == nil else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.mp3]
        p.nameFieldStringValue = suggestedName() + ".mp3"
        p.beginSheetModal(for: self) { r in
            guard r == .OK, let u = p.url else { return }
            self.save(to: u)
        }
    }

    private func suggestedName() -> String {
        if let f = fileName { return f }
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.prefix(6).joined(separator: " ")
        let clean = words.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return clean.isEmpty ? "TTS" : String(clean.prefix(60))
    }

    private func save(to url: URL) {
        guard let engine, let voice = voices[Voices.ids[voiceIndex]] else { return }
        let s = Saving(window: self)
        saving = s
        refreshControls()
        // The sound already made is used when it is whole and at this speed; otherwise the text is spoken anew at
        // the chosen speed (the engine's own speed sounds better than stretching, measured).
        if let store = player.source as? SampleStore, store.isComplete, store.speed == Speed.engine(speed),
           generatorText == textView.string, generatorVoice == voiceIndex {
            s.encode(store, to: url, speed: speed) { self.saveDone(url, $0) }
            return
        }
        let content = textView.string, vi = voiceIndex, sp = speed
        DispatchQueue.global(qos: .userInitiated).async {
            let pieces = Pieces.make(content, fallback: appLanguage)
            let r = Result { try Generator(engine: engine, pieces: pieces, voice: voice, voiceName: Voices.ids[vi], steps: flowSteps, speed: Speed.engine(sp)) }
            DispatchQueue.main.async {
                switch r {
                case .failure(let e): self.saveDone(url, "\(e)")
                case .success(let g): s.generate(g, to: url, speed: sp) { self.saveDone(url, $0) }
                }
            }
        }
    }

    private func saveDone(_ url: URL, _ err: String?) {
        saving?.close()
        saving = nil
        if let err, err != "cancelled" {
            try? FileManager.default.removeItem(at: url)
            report(L("The MP3 could not be saved"), err)
        } else if err == "cancelled" {
            try? FileManager.default.removeItem(at: url)
        }
        refreshControls()
    }

    // MARK: state

    private func refreshControls() {
        let ready = engine != nil
        let hasText = !text.isEmpty
        voicePopup.isEnabled = Model.isHere
        speedSlider.isEnabled = true
        playButton.isEnabled = (ready || loading) && (hasText || player.source != nil)
        saveButton.isEnabled = ready && hasText && saving == nil
        refreshPlayer()
    }

    private func refreshPlayer() {
        let playing = player.isPlaying
        playButton.image = symbol(playing ? "pause.fill" : "play.fill", playing ? L("Pause") : L("Play"), size: 22)
        playButton.toolTip = playing ? L("Pause") : L("Play")
        let has = player.source != nil
        backButton.isEnabled = has
        forwardButton.isEnabled = has
        if let s = player.source {
            let r = Double(player.rate), sr = Double(s.sampleRate)
            timeLabel.stringValue = "\(clock(Double(player.position) / sr / r)) / \(clock(Double(s.total) / sr / r))"
        } else {
            timeLabel.stringValue = preparing ? "–:–– / –:––" : "0:00 / 0:00"
        }
        refreshHighlight()
    }

    // MARK: highlight

    private var sentences: [NSRange] = []
    private var highlighted: NSRange?

    /// The sentence being read is marked in the text, which scrolls to keep it in view. Shown while playing and while
    /// paused in the middle; gone when the text has played to its end (the player goes back to the start then, and
    /// jumping the view to the top would only lose the reader's place).
    private func refreshHighlight() {
        var r: NSRange?
        if let g = generator, player.source === g.store, player.isPlaying || player.position > 0,
           let i = g.sentence(at: player.position), i < sentences.count,
           NSMaxRange(sentences[i]) <= (textView.string as NSString).length {
            r = sentences[i]
        }
        guard r != highlighted else { return }
        guard let lm = textView.layoutManager else { return }
        if let old = highlighted {
            // after an edit the old range may run past the text
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(old, all))
        }
        highlighted = r
        if let r {
            lm.addTemporaryAttribute(.backgroundColor, value: Self.highlightColor, forCharacterRange: r)
            follow(r, always: false)
        }
    }

    /// The system's accent colour, faint, so the text stays black on light and white on dark; opaque, so it reads the
    /// same over any background. Follows the accent the user chose in System Settings.
    static let highlightColor = NSColor(name: nil) { a in
        let dark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.textBackgroundColor.blended(withFraction: dark ? 0.38 : 0.22, of: .controlAccentColor) ?? .selectedTextBackgroundColor
    }

    /// Brings the sentence into view when it is not wholly visible: its top a quarter of the way down, so the text it
    /// leads into is seen too.
    private func follow(_ r: NSRange, always: Bool) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.y += textView.textContainerOrigin.y
        let clip = scroll.contentView
        let visible = clip.bounds
        if !always && rect.minY >= visible.minY && rect.maxY <= visible.maxY { return }
        let line = textView.font.map { lm.defaultLineHeight(for: $0) } ?? 16
        var y = rect.height > visible.height * 0.7 ? rect.minY - line : rect.minY - visible.height * 0.25
        y = max(0, min(y, textView.frame.height - visible.height))
        let to = NSPoint(x: visible.minX, y: y.rounded())
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || always {
            clip.setBoundsOrigin(to)
        } else {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.3
                c.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(to)
            }
        }
        scroll.reflectScrolledClipView(clip)
    }

    private func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: menus, closing

    override func validateMenuItem(_ i: NSMenuItem) -> Bool {
        switch i.action {
        case #selector(saveMP3): return engine != nil && !text.isEmpty && saving == nil
        case #selector(biggerText(_:)): return textSize < Self.sizes.last!
        case #selector(smallerText(_:)): return textSize > Self.sizes.first!
        case #selector(actualSizeText(_:)): return textSize != NSFont.systemFontSize
        case #selector(showModel), #selector(deleteModel): return FileManager.default.fileExists(atPath: Model.folder.path) && download == nil
        default: return super.validateMenuItem(i)
        }
    }

    func windowDidResize(_ n: Notification) { fitColumn() }
    func windowDidEndLiveResize(_ n: Notification) { fitColumn() }
    func windowDidEnterFullScreen(_ n: Notification) { fitColumn() }
    func windowDidExitFullScreen(_ n: Notification) { fitColumn() }

    /// No line longer than 80 characters: extra width goes to the margins.
    private func fitColumn() {
        let w = scroll.contentSize.width
        let column = 80 * Self.charWidth(textView.font ?? Self.font)
        let side = max(Self.inset, ((w - column) / 2).rounded())
        if textView.textContainerInset.width != side {
            textView.textContainerInset = NSSize(width: side, height: 12)
        }
        // The text fills the whole area, so a click anywhere in it puts the cursor in the text.
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    }

    override func becomeKey() { super.becomeKey(); fitColumn() }

    /// Quitting: everything that uses the engine stops first, then the engine goes. ONNX Runtime's own clean-up at
    /// exit crashes when a model is still loaded or running (measured: «mutex lock failed»), so if something can't stop
    /// in time the process ends without that clean-up.
    func shutDown() {
        download?.cancel()
        Model.removeParts()
        player.shutDown()
        samplePlayer.shutDown()
        generator?.cancel(); saving?.generator?.cancel()
        let stopped = (generator?.wait(seconds: 3) ?? true) && (saving?.generator?.wait(seconds: 3) ?? true)
            && sampleWork.wait(timeout: .now() + 3) == .success && !loading
        if stopped { releaseEngine() } else { _exit(0) }
    }

    // MARK: messages

    func sizeText(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000).rounded().formatted(.number.locale(appLocale)) + " " + L("MB")
    }

    private func alert(_ t: String, _ info: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = info
        a.beginSheetModal(for: self)
    }

    /// Errors are shown in full and can be copied as a report.
    func report(_ t: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = t
        a.informativeText = detail
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: L("Copy"))
        a.beginSheetModal(for: self) { r in
            if r == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("TTS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")\n\(t)\n\(detail)", forType: .string)
            }
        }
    }
}


/// Saving an MP3: a sheet with progress and Cancel, the speech made anew if needed, then encoded.
final class Saving {
    private let sheet: NSWindow
    private let bar = NSProgressIndicator()
    private weak var window: NSWindow?
    private(set) var generator: Generator?
    private var cancelled = false

    init(window: NSWindow) {
        self.window = window
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: L("Saving MP3…"))
        let cancel = NSButton(title: L("Cancel"), target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.style = .bar
        let v = sheet.contentView!
        for x in [label, bar, cancel] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        cancel.target = self; cancel.action = #selector(cancelPressed)
        window.beginSheet(sheet)
    }

    @objc private func cancelPressed() {
        cancelled = true
        generator?.cancel()
    }

    func close() { window?.endSheet(sheet) }

    func generate(_ g: Generator, to url: URL, speed: Float, done: @escaping (String?) -> Void) {
        generator = g
        let total = Double(g.store.lengths.count)
        var made = 0.0
        g.onProgress = { DispatchQueue.main.async { made += 1; self.bar.doubleValue = 0.92 * made / total } }
        g.onDone = { err in
            DispatchQueue.main.async {
                if self.cancelled { done("cancelled"); return }
                if let err { done(err); return }
                self.encode(g.store, to: url, speed: speed, from: 0.92, done: done)
            }
        }
        g.start(workers: Workers.count)
    }

    /// `speed` is the speed chosen; the part the engine didn't make is stretched as the player does it.
    func encode(_ store: SampleStore, to url: URL, speed: Float, from start: Double = 0, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r: String? = {
                do {
                    let w = try MP3Writer(url: url, sampleRate: store.sampleRate, title: url.deletingPathExtension().lastPathComponent)
                    let rate = speed / store.speed
                    let stretch = abs(rate - 1) > 0.001 ? try OfflineStretch(sampleRate: store.sampleRate, rate: rate) : nil
                    let block = 1 << 16
                    var buf = [Float](repeating: 0, count: block)
                    var at = 0
                    while at < store.total {
                        if self.cancelled { return "cancelled" }
                        let n = buf.withUnsafeMutableBufferPointer { store.read(at: at, count: block, into: $0.baseAddress!) }
                        if n <= 0 { break }
                        try buf.withUnsafeBufferPointer { b in
                            if let stretch { try stretch.feed(b.baseAddress!, count: n) { try w.write($0, count: $1) } }
                            else { try w.write(b.baseAddress!, count: n) }
                        }
                        at += n
                        let p = start + (1 - start) * Double(at) / Double(store.total)
                        DispatchQueue.main.async { self.bar.doubleValue = p }
                    }
                    try stretch?.finish { try w.write($0, count: $1) }
                    try w.finish()
                    return nil
                } catch { return "\(url.path)\n\(error)" }
            }()
            DispatchQueue.main.async { done(r) }
        }
    }
}
