// The voice choice. The top bar keeps a pop-up button that says the chosen voice; pressing it opens a list: the voices
// of the language the text is in, as macOS names them (Siri: «Голос 1», «Голос 2», the numbers of System Settings).
// A click on a name only chooses it (the tick moves, no sound); the waveform button at the right of a row only
// listens: the voice reads a sample at the speed set, the button turns blue and moves while it plays, and a second
// press, another voice's button, Esc or closing the list stops it. Choosing and listening are two different things
// (the author's design, 2026-11-10, from the voice style list of the Claude app).
//
// Which voices: Siri's when the Mac has them (they are the clearest: 34 of 35 numbers read right in Russian against
// 31 for the voices apps get by themselves, measured 2026-11-10); otherwise the best voice of each kind macOS has
// (Ukrainian has no Siri voice: Lesya). Where Siri speaks the language but its voice is not downloaded, a row opens
// System Settings at Spoken Content, where Manage Voices downloads it; nothing is installed behind the person's back.

import AppKit

/// Looks and sits like a pop-up button, but a press shows the list.
final class VoiceButton: NSPopUpButton {
    var onPress: (() -> Void)?
    override func mouseDown(with event: NSEvent) { if isEnabled { onPress?() } }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    func show(_ title: String) { removeAllItems(); addItem(withTitle: title) }
}

/// The voices of a language as the list shows them.
enum VoiceMenu {
    /// Languages with Siri voices on the Mac, as macOS 27.2 lists them (2026-11-10; languages Siri speaks on iPhone
    /// but with no voice seen here are left out): where one of them has no Siri voice installed, the list offers it.
    static let siriLanguages: Set = ["ar", "de", "en", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant"]

    /// Siri voices first, in Apple's numbering (the main region of the language first); without Siri, the best voice
    /// of each gender.
    static func voices(of code: String, in all: [VoiceInfo]) -> [VoiceInfo] {
        var seen = Set<String>(), mine: [VoiceInfo] = []
        // `all` comes ranked best first; the same name in the same region twice (gryphon and its neural version) is one
        for v in all where v.code == code && !seen.contains(v.name + v.lang) { seen.insert(v.name + v.lang); mine.append(v) }
        let siri = mine.filter(\.isSiri)
        if !siri.isEmpty {
            // one region: the person's when the Mac has a Siri voice for it (en-GB in Britain), else the language's
            // main one, else the one with most voices
            let regions = Dictionary(grouping: siri) { $0.lang.split(separator: "-").last.map(String.init) ?? "" }
            let mineR = Locale.current.region?.identifier ?? ""
            let pick = regions[mineR] != nil ? mineR : regions[mainRegion[code] ?? ""] != nil ? mainRegion[code]! :
                regions.max { $0.value.count < $1.value.count }!.key
            return regions[pick]!.sorted { number($0.name) < number($1.name) }
        }
        var out: [VoiceInfo] = []
        for g in [2, 1] { if let v = mine.first(where: { $0.gender == g }) { out.append(v) } }
        if out.isEmpty, let v = mine.first { out.append(v) }
        return out
    }

    static func needsDownload(_ code: String, in all: [VoiceInfo]) -> Bool {
        siriLanguages.contains(code) && !all.contains { $0.code == code && $0.isSiri }
    }

    /// The region Apple itself treats as a language's main one (as `tts` ranks them).
    static let mainRegion = ["en": "US", "es": "ES", "pt": "BR", "fr": "FR", "de": "DE", "nl": "NL", "it": "IT", "ar": "001"]

    private static func number(_ name: String) -> Int {
        Int(name.split(separator: " ").last ?? "") ?? 99
    }

    /// «Voice 2» as System Settings says it in the app's language («Голос 2»); other voices by their own name.
    static func title(_ v: VoiceInfo, among list: [VoiceInfo]) -> String {
        if v.isSiri, v.name.hasPrefix("Voice "), let n = Int(v.name.dropFirst(6)) { return String(format: L("Voice %d"), n) }
        return v.name
    }

    static func languageName(_ code: String) -> String {
        let n = appLocale.localizedString(forLanguageCode: code) ?? code
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}

/// The round waveform button of one row.
final class ListenButton: NSView {
    var onPress: (() -> Void)?
    private let image = NSImageView()
    private let spinner = NSProgressIndicator()
    enum State { case idle, loading, playing }
    var state = State.idle { didSet { if state != oldValue { update() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        image.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [image, spinner] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func updateLayer() { update() }
    override func viewDidChangeEffectiveAppearance() { update() }

    private func update() {
        let on = state != .idle
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = state == .playing ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        image.isHidden = state == .loading
        if state == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        image.contentTintColor = state == .playing ? .white : .secondaryLabelColor
        if #available(macOS 14, *) {
            if state == .playing { image.addSymbolEffect(.variableColor.iterative.reversing) } else { image.removeAllSymbolEffects() }
        }
        toolTip = on ? L("Stop") : L("Listen")
        setAccessibilityLabel(toolTip)
    }
}

/// One row: tick, name, waveform button; or the download row (an arrow, two lines, no tick).
final class VoiceRow: NSView {
    var onChoose: (() -> Void)?
    let listen = ListenButton()
    private let tick = NSImageView()
    private let name: NSTextField
    private var hover = false { didSet { needsDisplay = true } }

    init(title: String, detail: String? = nil, symbol: String? = nil) {
        name = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        tick.image = NSImage(systemSymbolName: symbol ?? "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        tick.contentTintColor = symbol == nil ? .labelColor : .controlAccentColor
        tick.isHidden = symbol == nil
        var views: [NSView] = [tick, name]
        let small = NSTextField(wrappingLabelWithString: detail ?? "")
        if detail != nil {
            small.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            small.textColor = .secondaryLabelColor
            small.preferredMaxLayoutWidth = 200
            views.append(small)
        } else { views.append(listen) }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        var c = [
            tick.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tick.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: 6),
        ]
        if detail != nil {
            c += [name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                  tick.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                  name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                  small.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                  small.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                  small.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                  small.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)]
            name.textColor = .controlAccentColor
            tick.isHidden = false
        } else {
            c += [heightAnchor.constraint(equalToConstant: 28),
                  tick.centerYAnchor.constraint(equalTo: centerYAnchor),
                  name.centerYAnchor.constraint(equalTo: centerYAnchor),
                  listen.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                  listen.centerYAnchor.constraint(equalTo: centerYAnchor),
                  name.trailingAnchor.constraint(lessThanOrEqualTo: listen.leadingAnchor, constant: -8)]
        }
        NSLayoutConstraint.activate(c)
        setAccessibilityElement(true)
        setAccessibilityRole(detail == nil ? .radioButton : .link)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var chosen = false { didSet { tick.isHidden = !chosen; setAccessibilityValue(chosen ? 1 : 0) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseDown(with e: NSEvent) { onChoose?() }
    override func accessibilityPerformPress() -> Bool { onChoose?(); return true }

    override func draw(_ r: NSRect) {
        guard hover else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// The list in the popover: the language as a heading, Siri's voices (or the best others), the download row.
final class VoiceList: NSViewController {
    var onChoose: ((VoiceInfo) -> Void)?
    var onListen: ((VoiceInfo) -> Void)?
    var onDownload: (() -> Void)?
    private var rows: [(VoiceInfo, VoiceRow)] = []
    private let stack = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.widthAnchor.constraint(equalToConstant: 240).isActive = true
        view = stack
    }

    private func header(_ t: String) -> NSView {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        l.textColor = .secondaryLabelColor
        let box = NSView()
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
        ])
        return box
    }

    /// Builds the list for one language.
    func build(language code: String, voices all: [VoiceInfo]) {
        _ = view
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        let list = VoiceMenu.voices(of: code, in: all)
        stack.addArrangedSubview(header(VoiceMenu.languageName(code)))
        if VoiceMenu.needsDownload(code, in: all) {
            // The link opens the page itself (Spoken Content, «Read & Speak» since macOS 26); what is left there, in
            // System Settings' own words
            // macOS 26 moved the downloads from the System Voice menu's «Manage Voices…» to the ⓘ beside it, with a list
            // of languages (seen in the test machine, 2026-11-10)
            let way: String
            if #available(macOS 26, *) { way = String(format: L("System voice ⓘ › %@"), VoiceMenu.languageName(code)) }
            else { way = L("System voice › Manage Voices…") }
            let r = VoiceRow(title: L("Download Siri Voices…"), detail: way,
                             symbol: "arrow.down.circle")
            r.onChoose = { [weak self] in self?.onDownload?() }
            stack.addArrangedSubview(r)
        }
        for v in list {
            let r = VoiceRow(title: VoiceMenu.title(v, among: list))
            r.onChoose = { [weak self] in self?.onChoose?(v) }
            r.listen.onPress = { [weak self] in self?.onListen?(v) }
            rows.append((v, r))
            stack.addArrangedSubview(r)
        }
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true }
    }

    func show(chosen: String?, listening: String?, loading: Bool) {
        for (v, r) in rows {
            r.chosen = v.id == chosen
            r.listen.state = v.id == listening ? (loading ? .loading : .playing) : .idle
        }
    }
}

// Passages the voices read in the list: every voice of a language reads the same one, so voices compare on equal words.
// Public domain (checked 2026-11-09 against these editions; wording as printed, ё added where the printed «е» is a
// homograph for a voice, typographic apostrophes):
// ru  Булгаков, «Мастер и Маргарита», гл. 24, Воланд (М.: Высшая школа, 1989, after Худ. лит., 1982; the quote starts
//     at «Никогда», so its first letter is capital). Public domain in Ukraine and the EU; in the US and Russia still
//     claimed by the heirs: kept by the author's decision 2026-11-09, at his own risk.
// uk  Котляревський, «Енеїда», ч. I, строфа 1, перші чотири рядки (ukrlib; «хоть», as in every edition).
// en  Shakespeare, As You Like It 2.7 (MIT/Globe text, public domain; Folger's is non-commercial).
// Any other language: the start of the text itself, or Apple's own Siri greeting when there is no text.
enum Samples {
    static let texts = [
        "ru": "Никогда и ничего не просите! Никогда и ничего, и в особенности у тех, кто сильнее вас. Сами предложат и сами всё дадут!",
        "uk": "Еней був парубок моторний\nІ хлопець хоть куди козак,\nУдавсь на всеє зле проворний,\nЗавзятіший од всіх бурлак.",
        "en": "All the world’s a stage,\nAnd all the men and women merely players:\nThey have their exits and their entrances;\nAnd one man in his time plays many parts,\nHis acts being seven ages.",
    ]

    static func text(for code: String, from text: String) -> String {
        if let t = texts[code] { return t }
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if start.isEmpty { return "Siri" }
        // up to the end of the sentence nearest to 200 characters
        let head = String(start.prefix(240))
        if let r = head.range(of: "[.!?…](?=\\s)", options: [.regularExpression, .backwards]), head.distance(from: head.startIndex, to: r.lowerBound) > 40 {
            return String(head[...r.lowerBound])
        }
        return head
    }
}
