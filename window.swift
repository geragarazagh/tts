// The window. Top: the voice (a list to choose and to listen, voices.swift), then the speed. Middle: the text. Bottom: the player, or the model
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

final class MainWindow: NSWindow, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate {
    let root = RootView()
    // TextKit 1 on purpose: the highlight of the sentence being read is a temporary attribute (it never touches the
    // text, its undo or what is copied), and following it needs the sentence's exact place, which TextKit 1 lays out
    // for the whole text while TextKit 2 only estimates it outside the visible part.
    let textView = TextView(usingTextLayoutManager: false)
    let scroll = NSScrollView()

    private let voicePopup = VoiceButton(frame: .zero, pullsDown: false)
    private let voicePopover = NSPopover()
    private let voiceList = VoiceList()
    private let speedSlider = NSSlider(value: Speed.standard, minValue: Speed.min, maxValue: Speed.max, target: nil, action: nil)
    private let speedValue = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: L("Speed"))
    private let topBar = NSView()

    private let bar = NSView()
    private let backButton = NSButton()
    private let playButton = NSButton()
    private let forwardButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L("Save MP3…"), target: nil, action: nil)

    // The text step of the text as it is now (made while typing stops, so Play starts at once), the voices chosen per
    // language, and the speech being heard.
    private var plan: Plan?
    private var planning = false
    private var playWhenPlanned = false
    private var chosen: [String: String] = [:]      // language -> voice id, the person's choices
    private var gender = 2                          // 1 male, 2 female: for languages without a choice
    private var voiceMap: [String: String] = [:]    // language -> voice id, for this text
    private var speechSpeed = Speed.standard
    private let player = Player()
    private let samplePlayer = Player()
    private var samples: [String: Speech] = [:]     // voice + speed -> its sample, spoken once a session
    private var listening: String?                  // the voice whose sample plays
    private var resumePart = 0                      // where Play goes on after the voice or speed changed while paused
    private var saving: Saving?
    private var fileName: String?
    private var planTimer: Timer?
    private var speedTimer: Timer?

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
        Engine.shared.onVoices = { [weak self] in self?.voicesChanged() }
        Engine.shared.loadVoices()
        refreshControls()
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
        voicePopup.onPress = { [weak self] in self?.showVoices() }
        voicePopup.refusesFirstResponder = true
        voicePopover.behavior = .transient
        voicePopover.contentViewController = voiceList
        voicePopover.delegate = self
        voiceList.onChoose = { [weak self] in self?.choose($0) }
        voiceList.onListen = { [weak self] in self?.listen($0) }
        voiceList.onDownload = { [weak self] in self?.openVoiceSettings() }

        speedSlider.target = self; speedSlider.action = #selector(speedChanged)
        speedSlider.isContinuous = true
        speedSlider.refusesFirstResponder = true
        speedSlider.setAccessibilityLabel(L("Speed"))
        voicePopup.setAccessibilityLabel(L("Voice"))
        speedValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        speedValue.alignment = .right
        speedLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)
        let topLine = NSBox(); topLine.boxType = .separator; topLine.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topLine)
        for v in [voicePopup, speedLabel, speedSlider, speedValue] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        let valueWidth = ("0,0×" as NSString).size(withAttributes: [.font: speedValue.font!]).width.rounded(.up) + 2
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
            bar.addSubview(b)
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self; saveButton.action = #selector(saveMP3)
        saveButton.bezelStyle = .rounded
        saveButton.refusesFirstResponder = true
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(timeLabel); bar.addSubview(saveButton)

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

            playButton.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
            backButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -14),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 30),
            backButton.heightAnchor.constraint(equalToConstant: 30),
            forwardButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 14),
            forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 30),
            forwardButton.heightAnchor.constraint(equalToConstant: 30),
            timeLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: m),
            timeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -8),
            saveButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -m),
            saveButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            saveButton.leadingAnchor.constraint(greaterThanOrEqualTo: forwardButton.trailingAnchor, constant: 8),
        ])

        player.onChange = { [weak self] in self?.refreshPlayer() }
        samplePlayer.onEnd = { [weak self] in self?.stopListening() }
        samplePlayer.onChange = { [weak self] in self?.refreshVoices() }
    }

    private func symbol(_ name: String, _ label: String, size: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    // MARK: settings

    private func restoreSettings() {
        let d = UserDefaults.standard
        chosen = d.dictionary(forKey: "voices") as? [String: String] ?? [:]
        gender = d.integer(forKey: "gender") == 1 ? 1 : 2
        let stored = d.object(forKey: "speed") as? Double ?? Speed.standard
        let s = Speed.round(min(Speed.max, max(Speed.min, stored)))
        speedSlider.doubleValue = s
        speedValue.stringValue = Speed.text(s)
        speechSpeed = s
        let size = d.double(forKey: "textSize")
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

    // MARK: voices

    /// The language whose voices the list shows: the text's main one; with no text, the app's, else the Mac's first.
    private var listLanguage: String {
        if let m = plan?.main, !text.isEmpty { return m }
        let has = { (c: String) in Engine.shared.voices.contains { $0.code == c } }
        if has(appLanguage) { return appLanguage }
        for l in Locale.preferredLanguages {
            let c = Locale(identifier: l).language.languageCode?.identifier ?? ""
            if has(c) { return c }
        }
        return "en"
    }

    /// Voices appeared or went (at launch, or after a download in System Settings).
    private func voicesChanged() {
        if voicePopover.isShown { voiceList.build(language: listLanguage, voices: Engine.shared.voices); refreshVoices() }
        pickVoices { [weak self] in
            guard let self, let v = self.voiceMap[self.listLanguage] else { return }
            Engine.shared.warm(voice: v)
        }
    }

    /// The voice for every language of the text, from the choices (in `tts`, the same rule as the command line).
    private func pickVoices(then: (() -> Void)? = nil) {
        var langs = plan?.langs ?? []
        if !langs.contains(listLanguage) { langs.append(listLanguage) }
        let want = (chosen, gender)
        // Nothing chosen yet for the list's language: its voice of the same kind from the list itself (the list shows
        // the person's region, `tts` alone would take the language's main one)
        var ask = chosen
        let list = VoiceMenu.voices(of: listLanguage, in: Engine.shared.voices)
        if ask[listLanguage] == nil, let v = list.first(where: { $0.gender == gender }) ?? list.first { ask[listLanguage] = v.id }
        Engine.shared.pick(langs: langs, chosen: ask, gender: gender) { [weak self] map in
            guard let self, self.chosen == want.0, self.gender == want.1 else { return }
            self.voiceMap = map
            self.refreshVoiceTitle()
            then?()
        }
    }

    private func refreshVoiceTitle() {
        let code = listLanguage
        let all = Engine.shared.voices
        let list = VoiceMenu.voices(of: code, in: all)
        if let id = voiceMap[code], let v = all.first(where: { $0.id == id }) {
            voicePopup.show(VoiceMenu.title(v, among: list))
        } else {
            voicePopup.show(L("Voice"))
        }
    }

    /// A click on a voice's name chooses it, silently (listening is the waveform button). While the text is being
    /// read, the new voice goes on from the start of the same sentence. Paused, Play goes on from there in the new voice.
    private func choose(_ v: VoiceInfo) {
        chosen[v.code] = v.id
        if v.gender == 1 || v.gender == 2 { gender = v.gender }
        UserDefaults.standard.set(chosen, forKey: "voices")
        UserDefaults.standard.set(gender, forKey: "gender")
        refreshVoices()
        pickVoices { [weak self] in self?.restartSpeech() }
    }

    /// The speech in another voice or at another speed: from the start of the sentence being heard. His wish
    /// (2026-11-10): the change is heard at once, and going back a little shows it changed.
    private func restartSpeech() {
        guard let s = player.speech, s.plan.text == textView.string else { return }
        guard s.voices != voiceMap || s.speed != speechSpeed else { return }
        let at = player.position.part
        let wasPlaying = player.isPlaying
        guard let new = try? Speech(plan: s.plan, voices: voiceMap, speed: speechSpeed) else { return }
        s.cancel()
        attach(new)
        if wasPlaying {
            player.load(new, part: at)
        } else {
            player.load(nil)
            resumePart = at
            pending = new
        }
        refreshControls()
    }

    /// A speech made while paused waits here for Play.
    private var pending: Speech?

    private func attach(_ s: Speech) {
        s.onChange = { [weak self] in self?.refreshPlayer() }
        s.onError = { [weak self] e in self?.report(L("Speech could not be made"), e) }
    }

    private func openVoiceSettings() {
        voicePopover.performClose(nil)
        // System Settings › Accessibility › Spoken Content (macOS 13 and later), where System Voice › Manage Voices
        // downloads Siri's voices; the app reads the voices again when it comes back to the front.
        for u in ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                  "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems"] {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: text

    func textDidChange(_ n: Notification) {
        stopAll()
        plan = nil
        refreshControls()
        textView.needsDisplay = true
        schedulePlan()
    }

    /// The text step runs when typing stops for a moment, so Play starts at once.
    private func schedulePlan(after: Double = 0.3) {
        planTimer?.invalidate()
        planTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.makePlan() }
        }
    }

    private func makePlan() {
        let content = textView.string
        guard !text.isEmpty else { plan = nil; refreshVoiceTitle(); return }
        if plan?.text == content || planning { return }
        planning = true
        var p = Plan(text: content)
        Engine.shared.plan(content, paragraph: { lang, sentences in
            let l = lang ?? "en"
            for (i, s) in sentences.enumerated() {
                guard let a = s["from"] as? Int, let b = s["to"] as? Int, let t = s["text"] as? String else { continue }
                p.parts.append(Part(from: a, to: b, lang: l, text: t, paragraphEnd: i == sentences.count - 1))
                p.chars[l, default: 0] += t.count
            }
        }, done: { [weak self] err in
            guard let self else { return }
            self.planning = false
            guard content == self.textView.string else { self.makePlan(); return }
            if let err { self.playWhenPlanned = false; self.report(L("Speech could not be made"), err); return }
            self.plan = p
            self.pickVoices {
                if self.playWhenPlanned { self.playWhenPlanned = false; self.togglePlay() }
            }
            self.refreshControls()
        })
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
            plan = nil
            schedulePlan(after: 0)
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
        stopListening()
        if let s = player.speech, s.plan.text == textView.string, s.voices == voiceMap, s.speed == speechSpeed {
            player.toggle(); return
        }
        guard !text.isEmpty else { return }
        // the voice of every language of the text is known (the pick after the text step comes a moment later)
        guard let plan, plan.text == textView.string, plan.langs.allSatisfy({ voiceMap[$0] != nil }) else {
            playWhenPlanned = true
            if !planning { schedulePlan(after: 0) }
            refreshPlayer()
            return
        }
        guard !plan.parts.isEmpty else { return }
        let s: Speech
        if let p = pending, p.plan.text == plan.text, p.voices == voiceMap, p.speed == speechSpeed { s = p }
        else {
            pending?.cancel()
            guard let n = try? Speech(plan: plan, voices: voiceMap, speed: speechSpeed) else { return }
            attach(n); s = n
        }
        pending = nil
        player.load(s, part: resumePart)
        resumePart = 0
        player.play()
    }

    private func stopAll() {
        player.speech?.cancel()
        pending?.cancel(); pending = nil
        player.pause()
        player.load(nil)
        resumePart = 0
        playWhenPlanned = false
        stopListening()
        refreshControls()
    }

    @objc private func playPressed() { togglePlay() }
    @objc private func back() { skip(-15) }
    @objc private func forward() { skip(15) }

    func skip(_ s: Double) {
        guard player.speech != nil else { return }
        player.skip(seconds: s)
    }

    @objc private func speedChanged() {
        let s = Speed.round(speedSlider.doubleValue)
        speedSlider.doubleValue = s
        speedValue.stringValue = Speed.text(s)
        UserDefaults.standard.set(s, forKey: "speed")
        // The voice speaks anew at the new speed once the slider rests (dragging would start it over and over).
        speedTimer?.invalidate()
        let up = NSApp.currentEvent?.type == .leftMouseUp
        speedTimer = Timer.scheduledTimer(withTimeInterval: up ? 0 : 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.speechSpeed != s else { return }
                self.speechSpeed = s
                self.stopListening()
                self.restartSpeech()
            }
        }
    }

    // MARK: listening

    private func showVoices() {
        if voicePopover.isShown { voicePopover.performClose(nil); return }
        voiceList.build(language: listLanguage, voices: Engine.shared.voices)
        refreshVoices()
        voicePopover.show(relativeTo: voicePopup.bounds, of: voicePopup, preferredEdge: .maxY)
    }

    func popoverDidClose(_ n: Notification) { stopListening() }

    /// A voice reads its sample at the speed set; the same button again stops it. Reading the text pauses meanwhile.
    /// Samples are spoken on this Mac by its own voices (Apple's licence allows no recordings of them in the app) and
    /// kept in memory until the app quits.
    private func listen(_ v: VoiceInfo) {
        if listening == v.id { stopListening(); return }
        stopListening()
        if player.isPlaying { player.pause() }
        listening = v.id
        let key = "\(v.id) \(speechSpeed)"
        if let s = samples[key] { play(sample: s); return }
        let sampleText = Samples.text(for: v.code, from: textView.string)
        var p = Plan(text: sampleText)
        Engine.shared.plan(sampleText, paragraph: { _, sentences in
            for (i, s) in sentences.enumerated() {
                guard let t = s["text"] as? String else { continue }
                p.parts.append(Part(from: 0, to: 0, lang: v.code, text: t, paragraphEnd: i == sentences.count - 1))
            }
        }, done: { [weak self] _ in
            guard let self, self.listening == v.id, !p.parts.isEmpty, let s = try? Speech(plan: p, voices: [v.code: v.id], speed: self.speechSpeed)
            else { return }
            s.concurrency = 1
            self.samples[key] = s
            self.play(sample: s)
        })
        refreshVoices()
    }

    private func play(sample s: Speech) {
        s.onChange = { [weak self] in self?.refreshVoices() }
        samplePlayer.load(s)
        samplePlayer.play()
        refreshVoices()
    }

    private func stopListening() {
        if samplePlayer.speech != nil { samplePlayer.pause(); samplePlayer.load(nil) }
        listening = nil
        refreshVoices()
    }

    private func refreshVoices() {
        guard voiceList.isViewLoaded else { return }
        let loading = listening != nil && (samplePlayer.speech == nil || samplePlayer.isWaiting)
        voiceList.show(chosen: voiceMap[listLanguage], listening: listening, loading: loading)
    }

    // MARK: save

    @objc func saveMP3() {
        guard !text.isEmpty, saving == nil else { return }
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

    /// The MP3 is the speech as heard: this voice, this speed, the same pauses. What is spoken already is used; the rest
    /// is spoken now by all the workers.
    @objc func save(to url: URL) {
        let s = Saving(window: self)
        saving = s
        refreshControls()
        func go() {
            guard let plan, plan.text == textView.string else { saveDone(url, L("The text changed")); return }
            let speech: Speech
            if let cur = player.speech ?? pending, cur.plan.text == plan.text, cur.voices == voiceMap, cur.speed == speechSpeed { speech = cur }
            else {
                guard let n = try? Speech(plan: plan, voices: voiceMap, speed: speechSpeed) else { saveDone(url, "Speech"); return }
                attach(n); pending?.cancel(); pending = n; speech = n
            }
            s.save(speech, to: url, title: url.deletingPathExtension().lastPathComponent) { [weak self] in self?.saveDone(url, $0) }
        }
        let ready = { self.plan?.text == self.textView.string && (self.plan?.langs.allSatisfy { self.voiceMap[$0] != nil } ?? false) }
        if ready() { go() } else {
            schedulePlan(after: 0)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.saving === s else { t.invalidate(); return }
                    if ready() { t.invalidate(); go() }
                }
            }
        }
    }

    private func saveDone(_ url: URL, _ err: String?) {
        saving?.close()
        saving = nil
        if let err { try? FileManager.default.removeItem(at: url); if err != "cancelled" { report(L("The MP3 could not be saved"), err) } }
        refreshControls()
    }

    // MARK: state

    private func refreshControls() {
        let hasText = !text.isEmpty
        playButton.isEnabled = hasText || player.speech != nil
        saveButton.isEnabled = hasText && saving == nil
        refreshPlayer()
    }

    private func refreshPlayer() {
        let playing = player.isPlaying || playWhenPlanned
        playButton.image = symbol(playing ? "pause.fill" : "play.fill", playing ? L("Pause") : L("Play"), size: 22)
        playButton.toolTip = playing ? L("Pause") : L("Play")
        let has = player.speech != nil
        backButton.isEnabled = has
        forwardButton.isEnabled = has
        if has {
            timeLabel.stringValue = "\(clock(Double(player.now) / Double(Speech.rate))) / \(clock(Double(player.total) / Double(Speech.rate)))"
        } else {
            timeLabel.stringValue = playWhenPlanned ? "–:–– / –:––" : "0:00 / 0:00"
        }
        refreshHighlight()
    }

    // MARK: highlight

    private var highlighted: NSRange?

    /// The sentence being read is marked in the text, which scrolls to keep it in view. Shown while playing and while
    /// paused in the middle; gone when the text has played to its end (the player goes back to the start then, and
    /// jumping the view to the top would only lose the reader's place).
    private func refreshHighlight() {
        var r: NSRange?
        if let s = player.speech, s.plan.text == textView.string {
            let pos = player.position
            if (player.isPlaying || pos.part > 0 || pos.frame > 0), pos.part < s.parts.count {
                let p = s.parts[pos.part]
                let range = NSRange(location: p.from, length: p.to - p.from)
                if NSMaxRange(range) <= (textView.string as NSString).length { r = range }
            }
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
        case #selector(saveMP3): return !text.isEmpty && saving == nil
        case #selector(biggerText(_:)): return textSize < Self.sizes.last!
        case #selector(smallerText(_:)): return textSize > Self.sizes.first!
        case #selector(actualSizeText(_:)): return textSize != NSFont.systemFontSize
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

    func shutDown() {
        player.shutDown()
        samplePlayer.shutDown()
        player.speech?.cancel(); pending?.cancel()
        samples.values.forEach { $0.cancel() }
        Engine.shared.shutDown()
    }

    // MARK: messages

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


/// Saving an MP3: a sheet with progress and Cancel; the sentences not spoken yet are spoken by all the workers, then
/// everything is encoded with the pauses as heard.
@MainActor final class Saving {
    private let sheet: NSWindow
    private let bar = NSProgressIndicator()
    private weak var window: NSWindow?
    private var cancelled = false
    private var speech: Speech?
    private var watch: Timer?
    private var done: ((String?) -> Void)?

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
        restore()
        watch?.invalidate()
        done?("cancelled"); done = nil
    }

    func close() { watch?.invalidate(); window?.endSheet(sheet) }

    private func restore() { speech?.concurrency = 2; speech?.ahead = 600 }

    func save(_ s: Speech, to url: URL, title: String, done: @escaping (String?) -> Void) {
        speech = s
        self.done = done
        s.ahead = .infinity
        s.concurrency = Engine.limit
        let total = Double(max(1, s.parts.count))
        watch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { t.invalidate(); return }
                self.bar.doubleValue = 0.9 * Double(s.doneCount) / total
                guard s.isComplete else { return }
                t.invalidate()
                self.restore()
                self.encode(s, to: url, title: title)
            }
        }
    }

    private func encode(_ s: Speech, to url: URL, title: String) {
        if let p = s.parts.indices.first(where: { s.isFailed($0) }) {
            done?("«\(s.parts[p].text.prefix(80))»"); done = nil; return
        }
        guard let layout = s.layout() else { done?("incomplete"); done = nil; return }
        let file = s.file
        let check = { [weak self] () -> Bool in self?.cancelled ?? true }
        DispatchQueue.global(qos: .userInitiated).async {
            let r: String? = {
                do {
                    let w = try MP3Writer(url: url, sampleRate: Speech.rate, title: title)
                    var buf = [Float](repeating: 0, count: 1 << 16)
                    let zeros = [Float](repeating: 0, count: 1 << 16)
                    for (k, x) in layout.enumerated() {
                        if k % 20 == 0, DispatchQueue.main.sync(execute: { MainActor.assumeIsolated { check() } }) { return "cancelled" }
                        var at = 0
                        while at < x.frames {
                            let got = buf.withUnsafeMutableBufferPointer { file.read(at: x.offset + at, count: min($0.count, x.frames - at), into: $0.baseAddress!) }
                            if got <= 0 { break }
                            try buf.withUnsafeBufferPointer { try w.write($0.baseAddress!, count: got) }
                            at += got
                        }
                        var g = x.gap
                        while g > 0 { let n = min(g, zeros.count); try zeros.withUnsafeBufferPointer { try w.write($0.baseAddress!, count: n) }; g -= n }
                        let f = 0.9 + 0.1 * Double(k + 1) / Double(layout.count)
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.bar.doubleValue = f } }
                    }
                    try w.finish()
                    return nil
                } catch { return "\(url.path)\n\(error)" }
            }()
            DispatchQueue.main.async { MainActor.assumeIsolated { if r != "cancelled" { self.done?(r); self.done = nil } } }
        }
    }
}
