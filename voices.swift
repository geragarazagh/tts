// The voice choice (the author's design, 2026-11-10, after trying 0.1: «подумал секунду, начал включать, потом
// оборвал»). The top bar keeps a pop-up button that says the chosen voice; pressing it opens a list instead of a
// menu. In the list a click on a voice's name only chooses it (the tick moves, no sound); the waveform button at the
// right of each row only listens: the voice starts at once from a ready clip, the button turns blue and moves while it
// plays, and a second press, another voice's button, Esc or closing the list stops it. Choosing and listening are two
// different things, as in the voice style list of the Claude app that the author named as the model.

import AppKit
import AVFoundation

/// Looks and sits like the old pop-up, but a press shows the list.
final class VoiceButton: NSPopUpButton {
    var onPress: (() -> Void)?
    override func mouseDown(with event: NSEvent) { if isEnabled { onPress?() } }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    func show(_ title: String) { removeAllItems(); addItem(withTitle: title) }
}

/// The round waveform button of one row.
final class ListenButton: NSView {
    var onPress: (() -> Void)?
    private let image = NSImageView()
    var playing = false { didSet { if playing != oldValue { update() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        image.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = playing ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        image.contentTintColor = playing ? .white : .secondaryLabelColor
        if #available(macOS 14, *) {
            if playing { image.addSymbolEffect(.variableColor.iterative.reversing) } else { image.removeAllSymbolEffects() }
        }
        toolTip = playing ? L("Stop") : L("Listen")
        setAccessibilityLabel(toolTip)
    }
}

/// One voice: tick, name, waveform button. A click anywhere but the button chooses.
final class VoiceRow: NSView {
    let index: Int
    var onChoose: ((Int) -> Void)?
    let listen = ListenButton()
    private let tick = NSImageView()
    private let name: NSTextField
    private var hover = false { didSet { needsDisplay = true } }

    init(index: Int, title: String) {
        self.index = index
        name = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        tick.contentTintColor = .labelColor
        for v in [tick, name, listen] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            tick.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
            tick.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            listen.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            listen.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: listen.leadingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
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
    override func mouseDown(with e: NSEvent) { onChoose?(index) }
    override func accessibilityPerformPress() -> Bool { onChoose?(index); return true }

    override func draw(_ r: NSRect) {
        guard hover else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// The list in the popover: «Мужские» Голос 1-5, «Женские» Голос 6-10, the developer's order.
final class VoiceList: NSViewController {
    var onChoose: ((Int) -> Void)?
    var onListen: ((Int) -> Void)?
    private(set) var rows: [VoiceRow] = []

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        func header(_ t: String) -> NSView {
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
        for i in 0..<10 {
            if i == 0 { stack.addArrangedSubview(header(L("Male"))) }
            if i == 5 { stack.addArrangedSubview(header(L("Female"))) }
            let row = VoiceRow(index: i, title: String(format: L("Voice %d"), i + 1))
            row.onChoose = { [weak self] in self?.onChoose?($0) }
            row.listen.onPress = { [weak self] in self?.onListen?(i) }
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 220).isActive = true
        view = stack
    }

    func show(chosen: Int, playing: Int?) {
        for r in rows { r.chosen = r.index == chosen; r.listen.playing = r.index == playing }
    }
}

/// The ready voice samples in the app (Contents/Resources/Samples, made by bench/clips from samples.swift): every
/// voice reads the same passage in ru, uk and en, at the engine speeds 1.05 and 1.25. Reading a clip takes a few
/// milliseconds where synthesizing it took 2.3-2.5 s (measured 2026-11-10), so a voice sounds the moment it is pressed,
/// and even before the model is downloaded.
enum Clips {
    static let speeds: [Float] = [1.05, 1.25]
    private static var cache: [String: [Float]] = [:]

    /// The clip's language: the text's own when it is one of the three, else the app's, else English.
    static func language(for text: String) -> String {
        let three: Set = ["ru", "uk", "en"]
        if let l = Language.detect(String(text.prefix(500))), three.contains(l) { return l }
        return three.contains(appLanguage) ? appLanguage : "en"
    }

    /// The clip made at the higher of the two speeds not above the chosen one (1.05 below 1.25), stretched to it, as on the site.
    static func speed(for s: Float) -> Float { s < 1.25 ? 1.05 : 1.25 }

    static func load(voice: String, lang: String, speed: Float) -> MemorySource? {
        let name = "\(lang)-\(voice)-\(String(format: "%.2f", speed))"
        if let s = cache[name] { return MemorySource(s, sampleRate: 44100, speed: speed) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Samples"),
              let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let s = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        cache[name] = s
        return MemorySource(s, sampleRate: Int(f.processingFormat.sampleRate), speed: speed)
    }
}
