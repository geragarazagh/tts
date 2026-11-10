// The same speed change the player makes live (AVAudioUnitTimePitch, pitch kept), offline, for the saved MP3:
// what is heard is what is saved.

import AVFoundation

final class OfflineStretch {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private let out: AVAudioPCMBuffer
    let rate: Float

    init(sampleRate: Int, rate: Float) throws {
        self.rate = rate
        format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        engine.attach(node); engine.attach(pitch)
        pitch.rate = rate
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        try engine.start()
        node.play()
    }

    private var fed = 0          // input samples scheduled
    private var made = 0         // output samples rendered

    /// Feeds input; returns output that is certainly made from it (output lags the input by a block).
    func feed(_ x: UnsafePointer<Float>, count: Int, emit: (UnsafePointer<Float>, Int) throws -> Void) throws {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        b.frameLength = AVAudioFrameCount(count)
        b.floatChannelData![0].update(from: x, count: count)
        node.scheduleBuffer(b)
        // render what the input before this block makes; this block stays queued as lookahead
        let target = Int(Double(fed) / Double(rate))
        fed += count
        try render(upTo: target, emit: emit)
    }

    func finish(emit: (UnsafePointer<Float>, Int) throws -> Void) throws {
        try render(upTo: Int(Double(fed) / Double(rate)), emit: emit)
        engine.stop()
    }

    private func render(upTo target: Int, emit: (UnsafePointer<Float>, Int) throws -> Void) throws {
        while made < target {
            let n = AVAudioFrameCount(min(4096, target - made))
            let st = try engine.renderOffline(n, to: out)
            guard st == .success else { throw EngineError(description: "renderOffline \(st.rawValue)") }
            try emit(out.floatChannelData![0], Int(out.frameLength))
            made += Int(out.frameLength)
        }
    }
}
