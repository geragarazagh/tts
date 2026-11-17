// From text to sound. The text step (`tts`) gives the sentences with their place in the text; each sentence is spoken
// on its own by a worker into a CAF file that grows while the voice speaks, so the first sound comes in a fraction of a
// second, and the sentence being heard is known exactly (for the highlight). Finished sentences go into one temporary
// file, deleted the moment it is opened: no name on disk while the app uses it, nothing left even after a crash.

import AVFoundation

/// One sentence (or a part of a very long one): where it stands in the text, its language and the words to say.
struct Part {
    let from: Int, to: Int          // UTF-16 range in the text as shown
    let lang: String
    let text: String                // after the text step
    let join: String                // what follows it: "par" (its paragraph ends), "sent" (a sentence ends) or "cut"
                                    // (a sentence over maxPart cut at a comma); `tts` decides (joinOf)
    var paragraphEnd: Bool { join == "par" }
}

/// The silence after a sentence, in frames at 48 kHz, for one voice at one speed: the voice's own pause between two
/// sentences, its longest one after a paragraph, 0.6 of it after a cut, each less the two 10 ms faded edges around
/// it. `tts` makes the numbers (gapOf, pauseOf): the same joins as the command's, which hears them inside its parts.
struct Joins: Equatable { let sent: Int, par: Int, cut: Int, measured: Bool }

/// The text step of a whole text.
struct Plan {
    let text: String
    var parts: [Part] = []
    var chars: [String: Int] = [:]  // characters per language
    /// The language most of the text is in: the voice list shows its voices.
    var main: String? { chars.max { $0.value < $1.value }?.key }
    var langs: [String] { chars.keys.sorted { chars[$0]! > chars[$1]! } }
}

enum Speed {
    // 1 = the Mac's normal speaking rate. The voice itself speaks faster or slower (AVSpeechUtterance.rate through
    // `tts`), so a new speed is spoken anew, never stretched. Siri's range is 0.56x to 3.93x (measured 2026-11-10 on
    // Yelena, Aleksei, Lesya); 0.6 to 3.5 in steps of 0.1 covers slow dictation to fast listening.
    static let min = 0.6, max = 3.5, step = 0.1, standard = 1.0
    static func round(_ v: Double) -> Double { ((v / step).rounded() * step * 100).rounded() / 100 }
    static func text(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1)).locale(appLocale)) + "×" }
}

/// Sound of all parts of a text at one speed with one choice of voices. Parts are spoken in order from where the
/// listener is, a few at once, up to `ahead` seconds ahead; saving asks for all.
@MainActor final class Speech {
    static let maxPart = 400                // characters: a longer sentence is cut at a comma (about 25 s of speech)
    nonisolated static let rate = 48000     // Siri's own rate; the 22.05 kHz voices are converted to it

    // Pauses (2026-11-15, as the `tts` command since that day): the voice's own, measured by `tts` on the first
    // sentences of this voice in the text spoken together (op joins); its usual ones until then. A voice given a whole
    // text makes no longer pause at a paragraph break, and the pause belongs to voice and speed (Yelena and Aleksei
    // ~0.37 s / speed, Simone ~0.6 s and Lesya ~0.18 s at 1.2x), so no constant fits. Before: 0.32 and 0.65 s / speed
    // plus each sentence's own lead and tail silence, ~0.6 s at every paragraph join at 1.2x.
    // One part of the command (its PART): as many of the voice's pauses as the command hears in one part, so the longest
    // of them comes out as the command's (Yelena 1.2x: 0.32 s; on 600 characters 0.29 s). ~10-14 s of work for one
    // speaker beside the two that speak; the voice's usual pauses until then.
    static let measureChars = 1200
    private(set) var joins: [String: Joins] = [:]   // voice id -> its joins at this speed
    private var measured: Set<String> = [], asked: Set<String> = [], usualAsked: Set<String> = [], measureTries: [String: Int] = [:]
    // Ended with the speech (a cancelled speech's measuring held a speaker for 10 s), its folder removed with it.
    private var measuring: [(worker: Worker, dir: String)] = []
    private var measureRetry = false

    let plan: Plan
    let voices: [String: String]            // language -> voice id
    let speed: Double
    var parts: [Part] { plan.parts }
    var onChange: (() -> Void)?             // sound arrived, or a part failed
    var onError: ((String) -> Void)?

    /// How many workers speak at once: enough to stay far ahead of the listener (one speaks 5-6 times faster than
    /// speech at 1x), few enough not to load the Mac. Saving uses them all.
    var concurrency = 2 { didSet { schedule() } }
    var ahead: Double = 600 { didSet { schedule() } }
    private(set) var listener = 0           // the part being heard: speaking starts there

    private enum State { case none, speaking(Render), done(offset: Int, frames: Int), failed(String) }
    private var states: [State]
    private var tries: [Int]
    private let store: PCMFile
    private var poll: Timer?

    init(plan: Plan, voices: [String: String], speed: Double) throws {
        self.plan = plan; self.voices = voices; self.speed = speed
        states = Array(repeating: .none, count: plan.parts.count)
        tries = Array(repeating: 0, count: plan.parts.count)
        store = try PCMFile()
    }

    func voice(of p: Int) -> String { voices[parts[p].lang] ?? voices.values.first ?? "" }

    // MARK: what is known

    func isDone(_ p: Int) -> Bool { if case .done = states[p] { return true }; return false }
    func isFailed(_ p: Int) -> Bool { if case .failed = states[p] { return true }; return false }
    var isComplete: Bool { states.indices.allSatisfy { isDone($0) || isFailed($0) } && usedVoices.isSubset(of: measured) }
    private var usedVoices: Set<String> { Set(parts.indices.map { voice(of: $0) }) }
    var doneCount: Int { states.indices.filter { isDone($0) || isFailed($0) }.count }

    /// Frames of speech of a part known so far (all of it once done).
    func available(_ p: Int) -> Int {
        switch states[p] {
        case .done(_, let n): return n
        case .speaking(let r): return r.frames
        default: return 0
        }
    }

    func gap(after p: Int) -> Int {
        guard p < parts.count - 1, let j = joins[voice(of: p)] else { return 0 }
        switch parts[p].join { case "par": return j.par; case "cut": return j.cut; default: return j.sent }
    }
    /// Whether the pause after a part is known (the voice's usual one comes a moment after the speech starts).
    func gapKnown(after p: Int) -> Bool { p >= parts.count - 1 || joins[voice(of: p)] != nil }

    /// A part's speech plus the pause after it: exact once spoken, else estimated from the characters.
    func slot(_ p: Int) -> Int {
        if case .done(_, let n) = states[p] { return n + gap(after: p) }
        if isFailed(p) { return 0 }
        return Int(Double(parts[p].text.count) * secondsPerChar * Double(Self.rate)) + gap(after: p)
    }

    /// Seconds of speech per character at this speed, measured on what is spoken (about 0.06 s at 1x: 990
    /// characters a minute, measured 2026-11-10).
    private var spokenFrames = 0, spokenChars = 0
    private var secondsPerChar: Double {
        spokenChars > 200 ? Double(spokenFrames) / Double(Self.rate) / Double(spokenChars) : 0.0606 / speed
    }

    /// Where every part's speech lies in the file and the pause after it, once all are spoken (for the MP3).
    func layout() -> [(offset: Int, frames: Int, gap: Int)]? {
        guard usedVoices.isSubset(of: measured) else { return nil }
        var out: [(Int, Int, Int)] = []
        for p in parts.indices {
            switch states[p] {
            case .done(let off, let n): out.append((off, n, gap(after: p)))
            case .failed: continue
            default: return nil
            }
        }
        return out
    }
    var file: PCMFile { store }

    func read(_ p: Int, at frame: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        switch states[p] {
        case .done(let off, let n): return store.read(at: off + frame, count: max(0, min(count, n - frame)), into: out)
        case .speaking(let r): return r.read(at: frame, count: count, into: out)
        default: return 0
        }
    }

    // MARK: speaking

    /// The listener is at part `p`: speaking goes on from there.
    func listen(from p: Int) {
        listener = max(0, min(p, parts.count - 1))
        schedule()
    }

    private var cancelled = false
    private var reported = false       // one error message a speech, not one a sentence

    private func schedule() {
        guard !parts.isEmpty, !cancelled else { return }
        askUsual()
        var running = states.filter { if case .speaking = $0 { return true }; return false }.count
        // ahead of the listener, in order, as far as `ahead` reaches; then what is behind
        var t = 0.0, order: [Int] = []
        for p in listener..<parts.count {
            if t > ahead { break }
            order.append(p)
            t += Double(slot(p)) / Double(Self.rate)
        }
        if ahead.isInfinite { order += Array(0..<listener) }
        // the pauses are measured once 15 s from the listener on are spoken (2 s at most): a new start, voice or speed
        // is not slowed by it, and the voice's usual pauses hold until then
        var ready = 0, p = listener
        while p < parts.count && ready < 15 * Self.rate && (isDone(p) || isFailed(p)) { ready += slot(p); p += 1 }
        let heard = p == parts.count || ready >= 15 * Self.rate
        if heard { measure() }
        var waiting = false
        for p in order where running < concurrency {
            guard case .none = states[p] else { continue }
            guard let w = Engine.shared.speaker(max: concurrency + 1) else { waiting = true; break }
            start(p, on: w)
            running += 1
        }
        if heard { measure() }
        // every worker busy with another speech (a sample, a sentence being dropped): look again shortly
        if waiting && running == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.schedule() }
        }
        let speaking = states.contains { if case .speaking = $0 { return true }; return false }
        if speaking && poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollAll() } }
        } else if !speaking { poll?.invalidate(); poll = nil }
    }

    /// The voices' usual joins, at once from the quick worker: the player needs a pause after the first sentence.
    private func askUsual() {
        for v in usedVoices where joins[v] == nil && !usualAsked.contains(v) {
            if let j = Engine.shared.knownJoins(voice: v, speed: speed) { joins[v] = j; measured.insert(v); continue }
            usualAsked.insert(v)
            Engine.shared.usualJoins(voice: v, speed: speed) { [weak self] j in
                guard let self, !self.cancelled, self.joins[v] == nil else { return }   // the measured ones may be there first
                self.joins[v] = j
                self.onChange?()
            }
        }
    }

    /// Asks `tts` for the joins of every voice of the text not known yet, each on a free speaker.
    private func measure() {
        for v in usedVoices.sorted() where !measured.contains(v) && !asked.contains(v) {
            if let j = Engine.shared.knownJoins(voice: v, speed: speed) { joins[v] = j; measured.insert(v); continue }
            // a speaker of its own: the free ones stay for the sentences, so a new voice or speed still starts at once
            guard let w = Engine.shared.speaker(max: concurrency + 2, fresh: true) else {
                // every speaker busy (another speech's sample): looked at again shortly, since with every sentence
                // spoken nothing else calls schedule() and saving would wait for this measurement for ever
                if !measureRetry {
                    measureRetry = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.measureRetry = false; self?.schedule() }
                }
                return
            }
            let dir = NSTemporaryDirectory() + "tts-\(UUID().uuidString)"
            asked.insert(v)
            measuring.append((w, dir))
            Engine.shared.joins(on: w, voice: v, speed: speed, texts: measureTexts(v), dir: dir) { [weak self] j, last in
                if last { try? FileManager.default.removeItem(atPath: dir) }
                guard let self, !self.cancelled else { return }
                if last { self.measuring.removeAll { $0.worker === w } }
                if let j, last || self.joins[v] == nil { self.joins[v] = j }
                if last {
                    self.measureTries[v, default: 0] += 1
                    // the speaker died before its answer: asked again, twice; then the usual pause, if it came, stays
                    if j == nil && self.measureTries[v]! < 3 { self.asked.remove(v) } else { self.measured.insert(v) }
                    if self.joins[v] == nil && self.measured.contains(v) {   // not even the usual one: 0.32 s / speed, as before
                        let g = Int(0.32 / self.speed * Double(Self.rate)); self.joins[v] = Joins(sent: g, par: g, cut: g / 2, measured: false)
                    }
                }
                self.onChange?()
                if last { self.schedule() }
            }
        }
    }

    /// Paragraphs of this voice's first sentences, about measureChars in all: what `tts` speaks to hear its pauses.
    private func measureTexts(_ v: String) -> [[String]] {
        var out: [[String]] = [], cur: [String] = [], n = 0
        for p in parts.indices where voice(of: p) == v {
            cur.append(parts[p].text); n += parts[p].text.count
            if parts[p].paragraphEnd { out.append(cur); cur = [] }
            if n >= Self.measureChars { break }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func start(_ p: Int, on w: Worker) {
        let path = NSTemporaryDirectory() + "tts-\(UUID().uuidString).caf"
        let r = Render(worker: w, path: path)
        states[p] = .speaking(r)
        tries[p] += 1
        Engine.shared.render(on: w, voice: voice(of: p), speed: speed, text: parts[p].text, path: path) { [weak self] err in
            guard let self, case .speaking(let cur) = self.states[p], cur === r else { r.discard(); return }
            if let err {
                r.discard()
                self.states[p] = self.tries[p] < 2 ? .none : .failed(err)
                if self.tries[p] >= 2 && !self.reported { self.reported = true; self.onError?("«\(self.parts[p].text.prefix(80))»\n\(err)") }
            } else {
                r.finish()
                do {
                    let off = try self.store.append(r)
                    self.spokenFrames += r.frames; self.spokenChars += self.parts[p].text.count
                    self.states[p] = .done(offset: off, frames: r.frames)
                } catch {
                    self.states[p] = .failed("\(error)")
                    if !self.reported { self.reported = true; self.onError?("\(error)") }
                }
                r.discard()
            }
            self.onChange?()
            self.schedule()
        }
    }

    private func pollAll() {
        var grew = false
        for s in states { if case .speaking(let r) = s, r.poll() { grew = true } }
        if grew { onChange?() }
    }

    /// Everything stops; workers in the middle of a sentence are ended (their sentence is not needed any more).
    func cancel() {
        cancelled = true
        poll?.invalidate(); poll = nil
        for (i, s) in states.enumerated() {
            if case .speaking(let r) = s { Engine.shared.abandon(r.worker); r.discard(); states[i] = .none }
        }
        for m in measuring { Engine.shared.abandon(m.worker); try? FileManager.default.removeItem(atPath: m.dir) }
        measuring = []
        onChange = nil; onError = nil
    }
}

/// One sentence being spoken: reads the growing CAF file, converts to 48 kHz if the voice speaks at another rate, and
/// keeps the samples in memory until the sentence is done. What is heard of it is its sound alone, as `tts` cuts its
/// parts (assemble(), 2026-11-15): from 10 ms before the first 5 ms window above -50 dBFS in its first second to 10 ms
/// after the last one in its last second, those 10 ms faded in and out, so the voice's own lead and tail silence (0-40
/// ms) don't add to the pause after it. The start is found as the sound arrives: nothing is heard before it.
@MainActor final class Render {
    private static let win = 240, edge = 480                    // 5 ms windows, 10 ms edges, at 48 kHz
    private static let quiet = Float(pow(10, -50.0 / 10)) * Float(win)   // a window's sum of squares at -50 dBFS
    private var from: Int?                  // first sample heard, once found
    private var to: Int?                    // after the last one heard, once the sentence is done
    private var scanned = 0                 // windows of the first second looked at for the start
    let worker: Worker
    let path: String
    private var handle: FileHandle?
    private var dataStart = -1, bytesPerFrame = 4, isFloat = true, bigEndian = false, sourceRate = 48000.0
    private var readBytes = 0
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var finished = false
    var frames: Int { from.map { (to ?? samples.count) - $0 } ?? 0 }

    init(worker: Worker, path: String) { self.worker = worker; self.path = path }

    private func loud(_ at: Int) -> Bool {
        var e: Float = 0
        for i in at..<at + Self.win { e += samples[i] * samples[i] }
        return e > Self.quiet
    }

    /// The start of the sound, looked for in the first second as it arrives; none there: the start of the sentence.
    private func findStart(final: Bool) {
        guard from == nil else { return }
        let look = Swift.min(samples.count, Speech.rate)
        var start: Int?
        while (scanned + 1) * Self.win <= look {
            if loud(scanned * Self.win) { start = Swift.max(0, scanned * Self.win - Self.edge); break }
            scanned += 1
        }
        if start == nil && (final || samples.count >= Speech.rate) { start = 0 }
        // the fade-in needs its 10 ms whole: until they have arrived the start waits (that window is looked at again),
        // or the samples after them would stay unfaded behind a cut-off ramp
        guard let f = start, final || samples.count >= f + Self.edge else { return }
        from = f
        for i in 0..<Swift.min(Self.edge, samples.count - f) { let g = Float(i) / Float(Self.edge); samples[f + i] *= g * g }
    }

    /// The end of the sound in the last second, once all of it is there; its last 10 ms faded out.
    private func findEnd() {
        let n = samples.count, look = Swift.min(n, Speech.rate), off = n - look
        var w = look / Self.win - 1
        while w >= 0 && !loud(off + w * Self.win) { w -= 1 }
        var t = w >= 0 ? Swift.min(n, off + (w + 1) * Self.win + Self.edge) : n
        if t - (from ?? 0) > 4 * Self.edge {
            for i in 0..<Self.edge { let g = Float(Self.edge - 1 - i) / Float(Self.edge); samples[t - Self.edge + i] *= g * g }
        } else { from = 0; t = n }            // under 40 ms of sound: kept whole, as in `tts`
        to = t
    }

    /// New sound since the last look; true if some arrived.
    @discardableResult func poll() -> Bool {
        if handle == nil { handle = FileHandle(forReadingAtPath: path) }
        guard let h = handle else { return false }
        if dataStart < 0 { guard parseHeader(h) else { return false } }
        try? h.seek(toOffset: UInt64(dataStart + readBytes))
        guard let d = try? h.readToEnd(), d.count >= bytesPerFrame else { return false }
        let n = d.count / bytesPerFrame
        readBytes += n * bytesPerFrame
        var f = [Float](repeating: 0, count: n)
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let o = i * bytesPerFrame
                if isFloat {
                    var u = b.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                    if bigEndian { u = u.byteSwapped }
                    f[i] = Float(bitPattern: u)
                } else {
                    var u = b.loadUnaligned(fromByteOffset: o, as: UInt16.self)
                    if bigEndian { u = u.byteSwapped }
                    f[i] = Float(Int16(bitPattern: u)) / 32768
                }
            }
        }
        append(f, end: false)
        findStart(final: false)
        return true
    }

    /// CAF: «caff», version, flags, then chunks (type, 64-bit big-endian size). «desc» says the format, the samples
    /// follow the «data» chunk's 4-byte edit count. Written by AVAudioFile in `tts` (32-bit float, little-endian).
    private func parseHeader(_ h: FileHandle) -> Bool {
        try? h.seek(toOffset: 0)
        guard let d = try? h.read(upToCount: 16384), d.count >= 8, d.prefix(4) == Data("caff".utf8) else { return false }
        var o = 8
        func be<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
            d.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: T.self)) }
        }
        while o + 12 <= d.count {
            let type = String(decoding: d[o..<o + 4], as: UTF8.self)
            let size = Int(be(o + 4, Int64.self))
            let body = o + 12
            if type == "desc", body + 32 <= d.count {
                sourceRate = Double(bitPattern: be(body, UInt64.self))
                let flags: UInt32 = be(body + 12, UInt32.self)
                let bpp: UInt32 = be(body + 16, UInt32.self)
                isFloat = flags & 1 != 0
                bigEndian = flags & 2 == 0
                bytesPerFrame = Int(bpp)
            } else if type == "data" {
                guard body + 4 <= d.count else { return false }
                dataStart = body + 4
                if sourceRate != Double(Speech.rate) {
                    let a = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
                    let b = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Speech.rate), channels: 1, interleaved: false)!
                    inFormat = a
                    converter = AVAudioConverter(from: a, to: b)
                }
                return bytesPerFrame == (isFloat ? 4 : 2)
            }
            guard size >= 0 else { return false }
            o = body + size
        }
        return false
    }

    private func append(_ f: [Float], end: Bool) {
        guard let c = converter, let inF = inFormat else { samples += f; return }
        let outF = c.outputFormat
        var given = false
        let input = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(max(1, f.count)))!
        input.frameLength = AVAudioFrameCount(f.count)
        if !f.isEmpty { f.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: f.count) } }
        let cap = AVAudioFrameCount(Double(f.count) * outF.sampleRate / inF.sampleRate) + 4096
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return }
            var err: NSError?
            let st = c.convert(to: out, error: &err) { _, status in
                if !given && !f.isEmpty { given = true; status.pointee = .haveData; return input }
                status.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0 { samples += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)) }
            if st != .haveData || out.frameLength == 0 { break }
        }
    }

    /// The voice has finished: the rest of the file, and the converter's tail.
    func finish() {
        guard !finished else { return }
        poll()
        finished = true
        if converter != nil { append([], end: true) }
        findStart(final: true)
        findEnd()
    }

    func read(at frame: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        let n = max(0, min(count, frames - frame)), base = from ?? 0
        if n > 0 { samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress! + base + frame, count: n) } }
        return n
    }

    var allSamples: [Float] { from.map { Array(samples[$0..<(to ?? samples.count)]) } ?? [] }

    func discard() {
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// 16-bit samples of finished sentences, one after another, in a file without a name.
final class PCMFile: @unchecked Sendable {   // pread and pwrite at fixed places: safe from any thread
    private let fd: Int32
    private var end = 0     // in frames

    init() throws {
        let path = NSTemporaryDirectory() + "tts-\(UUID().uuidString).pcm"
        fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw EngineError("\(path)\n\(String(cString: strerror(errno)))") }
        unlink(path)
    }
    deinit { close(fd) }

    /// Appends a finished sentence; returns where it starts.
    @MainActor func append(_ r: Render) throws -> Int {
        let s = r.allSamples
        var pcm = [Int16](repeating: 0, count: s.count)
        for k in 0..<s.count { pcm[k] = Int16(max(-1, min(1, s[k])) * 32767) }
        let wrote = pcm.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(end * 2)) }
        guard wrote == s.count * 2 else { throw EngineError("pwrite\n\(String(cString: strerror(errno)))") }
        let at = end
        end += s.count
        return at
    }

    func read(at: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard count > 0 else { return 0 }
        var pcm = [Int16](repeating: 0, count: count)
        let got = pcm.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count * 2, off_t(at * 2)) }
        let m = max(0, got / 2)
        for k in 0..<m { out[k] = Float(pcm[k]) / 32767 }
        return m
    }
}
