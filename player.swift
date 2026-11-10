// Playback: AVAudioPlayerNode -> AVAudioUnitTimePitch -> output. The time-pitch unit changes the speed live without
// changing the pitch; the sound is fed in short buffers from the store while the generator is still filling it.

import AVFoundation

protocol AudioSource: AnyObject {
    var sampleRate: Int { get }
    var total: Int { get }
    var speed: Float { get }               // the engine speed this sound was made at
    func playableEnd(from: Int) -> Int
    func read(at: Int, count: Int, into: UnsafeMutablePointer<Float>) -> Int
}

extension SampleStore: AudioSource {}

final class MemorySource: AudioSource {
    let sampleRate: Int, speed: Float
    let samples: [Float]
    var total: Int { samples.count }
    init(_ s: [Float], sampleRate: Int, speed: Float) { samples = s; self.sampleRate = sampleRate; self.speed = speed }
    func playableEnd(from: Int) -> Int { total }
    func read(at: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        let n = max(0, min(count, total - at))
        samples.withUnsafeBufferPointer { b in for k in 0..<n { out[k] = b[at + k] } }
        return n
    }
}

@MainActor final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private(set) var source: AudioSource?
    private var format: AVAudioFormat?
    private var base = 0             // sample where the node's timeline started
    private var scheduled = 0        // samples handed to the node
    private var pausedAt = 0
    private(set) var isPlaying = false
    private(set) var isWaiting = false    // playing, but the next sound is still being made
    private var timer: Timer?
    var onChange: (() -> Void)?
    var onEnd: (() -> Void)?
    var speed: Float = 1.05 { didSet { applyRate() } }

    init() {
        engine.attach(node)
        engine.attach(pitch)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    func load(_ s: AudioSource?, at sample: Int = 0) {
        stopNode()
        source = s
        pausedAt = max(0, min(sample, s?.total ?? 0))
        if let s {
            let f = AVAudioFormat(standardFormatWithSampleRate: Double(s.sampleRate), channels: 1)!
            if f != format {
                engine.disconnectNodeOutput(node); engine.disconnectNodeOutput(pitch)
                engine.connect(node, to: pitch, format: f)
                engine.connect(pitch, to: engine.mainMixerNode, format: f)
                format = f
            }
        }
        applyRate()
        if isPlaying { startNode(at: pausedAt) }
        onChange?()
    }

    var position: Int {
        guard isPlaying, !isWaiting, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return pausedAt }
        return min(base + max(0, Int(p.sampleTime)), scheduled)
    }

    var total: Int { source?.total ?? 0 }

    func play() {
        guard let s = source, s.total > 0 else { return }
        if pausedAt >= s.total { pausedAt = 0 }
        isPlaying = true
        startNode(at: pausedAt)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onChange?()
    }

    func pause() {
        pausedAt = position
        isPlaying = false
        isWaiting = false
        stopNode()
        timer?.invalidate(); timer = nil
        engine.pause()
        onChange?()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to sample: Int) {
        guard let s = source else { return }
        let target = max(0, min(sample, s.total))
        pausedAt = target
        if isPlaying {
            if target >= s.total { finish(); return }
            startNode(at: target)
        }
        onChange?()
    }

    /// Seconds as heard: shorter at a higher speed.
    func skip(seconds: Double) {
        guard let s = source else { return }
        let samples = Int(seconds * Double(s.sampleRate) * Double(rate))
        var target = position + samples
        // Forward never jumps past what is made yet.
        if seconds > 0 { target = min(target, s.playableEnd(from: position)) }
        seek(to: target)
    }

    var rate: Float { source.map { speed / $0.speed } ?? 1 }

    private func applyRate() { pitch.rate = max(1 / 32, min(32, rate)) }

    private func startNode(at sample: Int) {
        stopNode()
        base = sample
        scheduled = sample
        isWaiting = false
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { isPlaying = false; return }
        }
        topUp()
        if scheduled > base { node.play() } else { isWaiting = true }
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
        pausedAt = 0
        onChange?()
        onEnd?()
    }

    /// Keeps about a second of sound queued in buffers of a quarter of a second.
    private func topUp() {
        guard let s = source, let f = format else { return }
        let block = s.sampleRate / 4
        let ahead = s.sampleRate
        let end = s.playableEnd(from: scheduled)
        while scheduled < end && scheduled - position < ahead {
            let n = min(block, end - scheduled)
            guard let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)) else { return }
            let got = s.read(at: scheduled, count: n, into: buf.floatChannelData![0])
            if got <= 0 { break }
            buf.frameLength = AVAudioFrameCount(got)
            node.scheduleBuffer(buf, completionHandler: nil)
            scheduled += got
        }
    }

    private func tick() {
        guard isPlaying, let s = source else { return }
        if isWaiting {
            // resume once a little sound is ready after the gap
            let end = s.playableEnd(from: pausedAt)
            if end >= s.total || end - pausedAt >= s.sampleRate / 2 { startNode(at: pausedAt) }
            onChange?()
            return
        }
        let pos = position
        if pos >= s.total { finish(); return }
        if pos >= scheduled {
            // ran dry: the generator is behind
            pausedAt = scheduled
            stopNode()
            isWaiting = true
        } else {
            topUp()
        }
        onChange?()
    }

    private func outputChanged() {
        // Headphones in or out: the engine stops; carry on from where it was.
        let pos = position
        format = nil
        let s = source
        let playing = isPlaying
        isPlaying = false
        load(s, at: pos)
        if playing { play() }
    }

    func shutDown() {
        timer?.invalidate(); timer = nil
        stopNode()
        engine.stop()
    }
}
