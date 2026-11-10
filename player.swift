// Playback: AVAudioPlayerNode -> output, fed in short buffers from a Speech while its sentences are still being spoken.
// The place is a part (sentence) and a frame inside its slot (its speech, then the pause after it); the time shown is
// the slots before it plus that frame, exact for what is spoken and estimated for the rest.

import AVFoundation

@MainActor final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(Speech.rate), channels: 1)!
    private(set) var speech: Speech?
    private(set) var part = 0, frame = 0            // where it is when not playing, and where the node started
    private(set) var isPlaying = false
    private(set) var isWaiting = false               // playing, but the next sound is still being spoken
    private var segments: [(start: Int, part: Int, frame: Int, count: Int)] = []   // what the node got, in its samples
    private var cursor = (part: 0, frame: 0)        // the next sound to hand to the node
    private var scheduled = 0                        // node samples handed over
    private var timer: Timer?
    var onChange: (() -> Void)?
    var onEnd: (() -> Void)?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    var volume: Float { get { engine.mainMixerNode.outputVolume } set { engine.mainMixerNode.outputVolume = newValue } }

    /// A new speech, from part `p` (its start).
    func load(_ s: Speech?, part p: Int = 0) {
        stopNode()
        speech = s
        part = max(0, min(p, (s?.parts.count ?? 1) - 1)); frame = 0
        s?.listen(from: part)
        if isPlaying { startNode() }
        onChange?()
    }

    /// Where it is now: part and frame in that part's slot.
    var position: (part: Int, frame: Int) {
        guard isPlaying, !isWaiting, let t = node.lastRenderTime, t.isSampleTimeValid,
              let p = node.playerTime(forNodeTime: t) else { return (part, frame) }
        let at = min(max(0, Int(p.sampleTime)), scheduled)
        guard let seg = segments.last(where: { $0.start <= at }) else { return (part, frame) }
        return (seg.part, seg.frame + min(at - seg.start, seg.count))
    }

    // MARK: time

    func time(_ pos: (part: Int, frame: Int)) -> Int {
        guard let s = speech else { return 0 }
        var t = 0
        for q in 0..<min(pos.part, s.parts.count) { t += s.slot(q) }
        return t + pos.frame
    }
    var now: Int { time(position) }
    var total: Int { speech.map { s in s.parts.indices.reduce(0) { $0 + s.slot($1) } } ?? 0 }

    // MARK: control

    func play() {
        guard let s = speech, !s.parts.isEmpty else { return }
        isPlaying = true
        startNode()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onChange?()
    }

    func pause() {
        let p = position
        part = p.part; frame = p.frame
        isPlaying = false
        isWaiting = false
        stopNode()
        timer?.invalidate(); timer = nil
        engine.pause()
        onChange?()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(part p: Int, frame f: Int) {
        guard let s = speech else { return }
        part = max(0, min(p, s.parts.count - 1)); frame = max(0, f)
        s.listen(from: part)
        if isPlaying { startNode() }
        onChange?()
    }

    /// Seconds back or forward as heard. Back lands at the start of a sentence not spoken yet at this speed;
    /// forward never goes past what is spoken.
    func skip(seconds: Double) {
        guard let s = speech else { return }
        let here = position
        var p = here.part, f = here.frame + Int(seconds * Double(Speech.rate))
        while f < 0 && p > 0 {
            p -= 1
            if !s.isDone(p) { f = 0; break }
            f += s.slot(p)
        }
        f = max(0, f)
        while p < s.parts.count {
            let len = s.isDone(p) ? s.slot(p) : (p == here.part ? s.available(p) : 0)
            if s.isFailed(p) { p += 1; continue }
            if f < len || !s.isDone(p) { f = min(f, max(0, s.available(p) - 1)); break }
            f -= len; p += 1
        }
        if p >= s.parts.count { finish(); return }
        seek(part: p, frame: f)
    }

    // MARK: the node

    private func startNode() {
        stopNode()
        cursor = (part, frame)
        scheduled = 0
        segments = []
        isWaiting = false
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { isPlaying = false; return }
        }
        topUp()
        if scheduled > 0 { node.play() } else { isWaiting = true }
    }

    private func stopNode() {
        node.stop()
        node.reset()
    }

    private func finish() {
        isPlaying = false
        isWaiting = false
        stopNode()
        timer?.invalidate(); timer = nil
        engine.pause()
        part = 0; frame = 0
        speech?.listen(from: 0)
        onChange?()
        onEnd?()
    }

    /// Keeps about a second queued, in buffers of up to a quarter of a second: speech while it is there, then the
    /// pause after the sentence (once the sentence is whole), then the next sentence.
    private func topUp() {
        guard let s = speech else { return }
        let block = Speech.rate / 4
        var heard = 0
        if let t = node.lastRenderTime, t.isSampleTimeValid, let pt = node.playerTime(forNodeTime: t) { heard = max(0, Int(pt.sampleTime)) }
        while scheduled - heard < Speech.rate && cursor.part < s.parts.count {
            let p = cursor.part
            if s.isFailed(p) { cursor = (p + 1, 0); continue }
            let have = s.available(p)
            var n = 0
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else { return }
            if cursor.frame < have {
                n = s.read(p, at: cursor.frame, count: min(block, have - cursor.frame), into: buf.floatChannelData![0])
                if n <= 0 { break }
            } else if s.isDone(p) {
                let end = have + s.gap(after: p)
                if cursor.frame >= end { cursor = (p + 1, 0); continue }
                n = min(block, end - cursor.frame)
                memset(buf.floatChannelData![0], 0, n * 4)
            } else { break }
            buf.frameLength = AVAudioFrameCount(n)
            node.scheduleBuffer(buf, completionHandler: nil)
            segments.append((scheduled, p, cursor.frame, n))
            if segments.count > 64 { segments.removeFirst(segments.count - 64) }
            scheduled += n
            cursor.frame += n
        }
    }

    private func tick() {
        guard isPlaying, let s = speech else { return }
        if isWaiting {
            // goes on once a little sound is there (or the sentence is whole)
            let p = part
            if p >= s.parts.count { finish(); return }
            if s.isFailed(p) { part = p + 1; frame = 0; startNode(); onChange?(); return }
            let have = s.available(p)
            if s.isDone(p) || have - frame >= Speech.rate / 10 {   // Siri hands its buffers over far faster than real time
                if s.isDone(p) && frame >= have + s.gap(after: p) { part = p + 1; frame = 0 }
                startNode()
            }
            onChange?()
            return
        }
        let pos = position
        if pos.part != s.listener { s.listen(from: pos.part) }
        if cursor.part >= s.parts.count, let t = node.lastRenderTime, let pt = node.playerTime(forNodeTime: t), Int(pt.sampleTime) >= scheduled {
            finish(); return
        }
        topUp()
        if let t = node.lastRenderTime, let pt = node.playerTime(forNodeTime: t), Int(pt.sampleTime) >= scheduled {
            // ran dry: the voice is behind
            part = cursor.part; frame = cursor.frame
            stopNode()
            isWaiting = true
        }
        onChange?()
    }

    private func outputChanged() {
        // headphones in or out: the engine stops; carry on from where it was
        let pos = position, playing = isPlaying
        isPlaying = false
        stopNode()
        part = pos.part; frame = pos.frame
        if playing { play() }
    }

    func shutDown() {
        timer?.invalidate(); timer = nil
        stopNode()
        engine.stop()
    }
}
