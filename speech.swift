// From text to sound: pieces of text with their language, their exact length in samples known before any sound is
// made (the duration model is cheap), and a generator that fills a sample store in the background while the player
// already plays the start.

import Foundation
import NaturalLanguage

// The engine's own speed, as the Supertonic package defines it: 0.7 to 2.0, default 1.05. Steps of 0.05, as the
// developer's demo page moves its speed. One control: live while listening, and the saved MP3 is at the same speed.
enum Speed {
    static let min = 0.7, max = 2.0, step = 0.05, standard = 1.05
    static func round(_ v: Double) -> Double { (v / step).rounded() * step }

    // What the model makes and what is stretched, measured on the night of 2026-11-09 (TTS card): 12 sentences each of
    // ru, uk, en, voices M1 and F1, read back by Whisper large-v3. The model's own speed keeps the words only near its
    // default: word errors 1.2 % at 1.05, 1.3 % at 0.95, 1.6 % at 1.25, but 3.2 % at 0.85, 21 % at 0.7 (it babbles in
    // ru and uk), 4.5 % at 1.5, 55 % at 2.0 (it drops words). Apple's time-stretch keeps every word at any speed but
    // sounds worse the further it goes (DNSMOS 3.06 at 1.5 from 1.05). So the model speaks inside [0.95, 1.25] and
    // the stretch does only the rest: at 1.5 that gives 1.7 % errors and DNSMOS 3.25, at 2.0 1.5 % and 2.64 (pure
    // stretch 2.1 % and 2.32). 1.35 as the top was worse in errors (1.8 %; 2.4 % at 2.0).
    static let engineMin: Float = 0.95, engineMax: Float = 1.25
    static func engine(_ s: Float) -> Float { Swift.min(engineMax, Swift.max(engineMin, s)) }
}

// Steps of the flow model (Supertonic's total_step), fixed. Measured on the night of 2026-11-09 (same 72 sentences,
// same noise): word errors 15.8 % at 2 steps, 2.3 % at 4, then 1.2-1.4 % from 6 to 32, DNSMOS 3.42-3.44 from 6 on;
// time grows with the steps (M3 Pro: 232 chars/s at 4, 125 at 8, 66 at 16). 8 is the developer's default, on the
// plateau with a step of margin, and still about 5x faster than speech on the slowest Apple silicon (inference
// from the M3 Pro numbers and the M1's multi-core score).
let flowSteps = 8

/// How many pieces are made at once and with how many threads each. Measured on the M3 Pro (6 performance + 6
/// efficiency cores), 2026-11-09, chars of speech made per second at 8 steps: 3 pieces x 4 threads 178 (first piece
/// 2.2 s), 6 x 1 178 (4.3 s), 6 x 2 181 (4.7 s), 3 x 2 122, 2 x 3 131, 1 x 6 79, 1 x 12 61. So: half as many pieces
/// as performance cores, and all cores shared among them.
enum Workers {
    static var performanceCores: Int {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
    static var count: Int { max(1, performanceCores / 2) }
    static var threads: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / count) }
}

// MARK: - Pieces

/// A part of a sentence inside a piece: which sentence of the text it belongs to (for the highlight) and its words.
struct Span {
    let sentence: Int
    let text: String
}

struct Piece {
    let text: String
    let lang: String
    let pauseBefore: Double      // seconds of silence before this piece
    let spans: [Span]
}

/// The pieces to speak and where each sentence stands in the text as shown (UTF-16 ranges, as NSTextView counts).
struct Script {
    let pieces: [Piece]
    let sentences: [NSRange]
}

enum Pieces {
    // The engine's own limit per call (supertonic DEFAULT_MAX_CHUNK_LENGTH); the first piece is shorter so the first
    // sound comes quickly: one sentence, cut at a comma if long.
    static let maxLength = 300
    static let firstLength = 120
    static let sentencePause = 0.3       // supertonic DEFAULT_SILENCE_DURATION
    static let paragraphPause = 0.6

    static func make(_ text: String, fallback: String) -> [Piece] { script(text, fallback: fallback).pieces }

    static func script(_ text: String, fallback: String) -> Script {
        // Paragraphs: lines trimmed and joined by one space, blank lines between. Each paragraph keeps a map from its
        // own UTF-16 offsets back to the text, so a sentence found in it can be highlighted where it stands.
        var paragraphs: [(text: String, map: [Int])] = []
        var cur = "", curMap: [Int] = []
        func flush() { if !cur.isEmpty { paragraphs.append((cur, curMap)); cur = ""; curMap = [] } }
        var loc = 0
        for line in text.components(separatedBy: "\n") {
            let l = line as NSString
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush() } else {
                let r = l.range(of: t, options: .literal)
                if !cur.isEmpty { cur += " "; curMap.append((curMap.last ?? loc) + 1) }
                cur += t
                for k in 0..<r.length { curMap.append(loc + r.location + k) }
            }
            loc += l.length + 1
        }
        flush()
        paragraphs = paragraphs.filter {
            $0.text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        }

        let whole = Language.detect(text) ?? fallback
        var out: [Piece] = []
        var sentenceRanges: [NSRange] = []
        var last = whole
        for (pi, para) in paragraphs.enumerated() {
            let p = para.text
            let lang = Language.detect(p) ?? last
            last = lang
            var sentences: [Span] = splitRanges(p, lang: lang).map { s, r in
                let a = para.map[r.location], b = para.map[r.location + r.length - 1] + 1
                sentenceRanges.append(NSRange(location: a, length: b - a))
                return Span(sentence: sentenceRanges.count - 1, text: s)
            }
            if out.isEmpty, let first = sentences.first, first.text.count > firstLength {
                sentences.removeFirst()
                sentences = cut(first.text, max: firstLength).map { Span(sentence: first.sentence, text: $0) } + sentences
            }
            var current: [Span] = []
            var pieces: [[Span]] = []
            func length(_ spans: [Span]) -> Int { spans.reduce(-1) { $0 + 1 + $1.text.count } }
            for s in sentences {
                let limit = (out.isEmpty && pieces.isEmpty) ? firstLength : maxLength
                if s.text.count > limit {
                    if !current.isEmpty { pieces.append(current); current = [] }
                    pieces += cut(s.text, max: limit).map { [Span(sentence: s.sentence, text: $0)] }
                } else if current.isEmpty {
                    current = [s]
                } else if length(current) + 1 + s.text.count <= limit {
                    current.append(s)
                } else {
                    pieces.append(current); current = [s]
                }
                if out.isEmpty && pieces.isEmpty && !current.isEmpty { pieces.append(current); current = [] }
            }
            if !current.isEmpty { pieces.append(current) }
            for (i, spans) in pieces.enumerated() {
                let pause = out.isEmpty && i == 0 ? 0 : (i == 0 && pi > 0 ? paragraphPause : sentencePause)
                out.append(Piece(text: spans.map(\.text).joined(separator: " "), lang: lang, pauseBefore: pause, spans: spans))
            }
        }
        return Script(pieces: out, sentences: sentenceRanges)
    }

    static func split(_ p: String, lang: String) -> [String] { splitRanges(p, lang: lang).map(\.0) }

    /// Sentences, trimmed, with their UTF-16 ranges in `p`.
    static func splitRanges(_ p: String, lang: String) -> [(String, NSRange)] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = p
        tok.setLanguage(NLLanguage(lang))
        var s: [(String, NSRange)] = []
        tok.enumerateTokens(in: p.startIndex..<p.endIndex) { r, _ in
            var a = r.lowerBound, b = r.upperBound
            while a < b, p[a].isWhitespace { a = p.index(after: a) }
            while b > a, p[p.index(before: b)].isWhitespace { b = p.index(before: b) }
            if a < b { s.append((String(p[a..<b]), NSRange(a..<b, in: p))) }
            return true
        }
        return s.isEmpty ? [(p, NSRange(location: 0, length: (p as NSString).length))] : s
    }

    /// A sentence longer than the limit: at commas and the like, then at spaces.
    static func cut(_ s: String, max: Int) -> [String] {
        var parts: [String] = []
        var cur = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if cur.isEmpty { cur = word; continue }
            if cur.count + 1 + word.count > max {
                // go back to the last punctuation inside cur if it is not too early
                if let r = cur.range(of: "[,;:\u{2014}\u{2013}]\\s", options: [.regularExpression, .backwards]),
                   cur.distance(from: cur.startIndex, to: r.lowerBound) > max / 3 {
                    let head = String(cur[...r.lowerBound])
                    let tail = String(cur[r.upperBound...])
                    parts.append(head)
                    cur = tail + " " + word
                } else {
                    parts.append(cur); cur = word
                }
            } else {
                cur += " " + word
            }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts
    }
}

enum Language {
    // The 31 languages of Supertonic 3; NLLanguage uses the same ISO codes.
    static let model = ["en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu", "id", "it",
                        "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi"]

    /// Language of a paragraph, or nil when there is nothing to tell it by.
    static func detect(_ text: String) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return nil }
        // Letters only one of the two has settle Russian and Ukrainian at once, also in short lines where
        // statistics are weak.
        let lower = text.lowercased()
        let uk = lower.unicodeScalars.contains { "іїєґ".unicodeScalars.contains($0) }
        let ru = lower.unicodeScalars.contains { "ыэъё".unicodeScalars.contains($0) }
        if uk && !ru { return "uk" }
        if ru && !uk { return "ru" }
        let r = NLLanguageRecognizer()
        r.languageConstraints = model.map { NLLanguage($0) }
        r.processString(text)
        guard let best = r.languageHypotheses(withMaximum: 1).first else { return nil }
        if best.value < 0.3 && letters.count < 20 { return nil }
        return best.key.rawValue
    }
}

// MARK: - Sample store

/// 16-bit samples in a temporary file that is deleted the moment it is opened: the file has no name on disk while
/// the app uses it, so nothing is left behind, even after a crash. Pieces are written at their own offsets from any
/// thread (pwrite), read by the player (pread).
final class SampleStore: @unchecked Sendable {
    let sampleRate: Int
    let speed: Float
    let voice: String
    let offsets: [Int]          // first sample of each piece (its pause comes before it)
    let lengths: [Int]          // samples of each piece's speech
    let total: Int
    private let fd: Int32
    private var ready: [Bool]
    private var readyEnds: Int = 0   // pieces ready from the first one on, without a gap
    private let lock = NSLock()

    init(sampleRate: Int, speed: Float, voice: String, pieces: [Piece], lengths: [Int]) throws {
        self.sampleRate = sampleRate; self.speed = speed; self.voice = voice; self.lengths = lengths
        var offs: [Int] = []
        var pos = 0
        for (p, n) in zip(pieces, lengths) {
            pos += Int(p.pauseBefore * Double(sampleRate))
            offs.append(pos)
            pos += n
        }
        offsets = offs
        total = pos
        ready = Array(repeating: false, count: lengths.count)
        let path = NSTemporaryDirectory() + "tts-\(UUID().uuidString).pcm"
        fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw EngineError(description: "\(path)\n\(String(cString: strerror(errno)))") }
        unlink(path)
        // Silence everywhere first: pauses read as zeros. ftruncate makes a sparse file of zeros.
        guard ftruncate(fd, off_t(total * 2)) == 0 else {
            close(fd); throw EngineError(description: "ftruncate\n\(String(cString: strerror(errno)))")
        }
    }

    deinit { close(fd) }

    func write(piece i: Int, _ samples: [Float]) throws {
        let n = min(samples.count, lengths[i])
        var pcm = [Int16](repeating: 0, count: n)
        for k in 0..<n { pcm[k] = Int16(max(-1, min(1, samples[k])) * 32767) }
        let wrote = pcm.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offsets[i] * 2)) }
        guard wrote == n * 2 else { throw EngineError(description: "pwrite\n\(String(cString: strerror(errno)))") }
        lock.lock()
        ready[i] = true
        while readyEnds < ready.count && ready[readyEnds] { readyEnds += 1 }
        lock.unlock()
    }

    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return readyEnds == ready.count }

    /// Samples from `from` on that can be played without a gap.
    func playableEnd(from: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var i = piece(at: from)
        while i < ready.count && ready[i] { i += 1 }
        return i >= ready.count ? total : offsets[i]
    }

    func piece(at sample: Int) -> Int {
        var lo = 0, hi = offsets.count - 1
        if hi < 0 { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= sample { lo = mid } else { hi = mid - 1 }
        }
        // the pause before a piece belongs to that piece
        if sample >= offsets[lo] + lengths[lo] && lo + 1 < offsets.count { return lo + 1 }
        return lo
    }

    func read(at: Int, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        let n = max(0, min(count, total - at))
        guard n > 0 else { return 0 }
        var pcm = [Int16](repeating: 0, count: n)
        let got = pcm.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n * 2, off_t(at * 2)) }
        let m = max(0, got / 2)
        for k in 0..<m { out[k] = Float(pcm[k]) / 32767 }
        return m
    }
}

// MARK: - Generator

/// Makes the sound of all pieces into a store. Several pieces at once, each with a part of the CPU: measured faster
/// than one piece with all of it (night of 2026-11-09). Pieces are taken in order, so the start is ready first.
final class Generator: @unchecked Sendable {
    let store: SampleStore
    private let engine: Supertonic
    private let pieces: [Piece]
    private let voice: Voice
    private let steps: Int
    private var cancelled = false
    private var failed: String?
    private let lock = NSLock()
    private let group = DispatchGroup()
    var onProgress: (@Sendable () -> Void)?
    var onDone: (@Sendable (String?) -> Void)?

    init(engine: Supertonic, pieces: [Piece], voice: Voice, voiceName: String, steps: Int, speed: Float, startAt: Int = 0) throws {
        self.engine = engine; self.pieces = pieces; self.voice = voice; self.steps = steps
        var lengths: [Int] = []
        for p in pieces { lengths.append(try engine.length(p.text, lang: p.lang, voice: voice, speed: speed)) }
        store = try SampleStore(sampleRate: engine.sampleRate, speed: speed, voice: voiceName, pieces: pieces, lengths: lengths)
        order = Array(startAt..<pieces.count) + Array(0..<startAt)
        let offsets = store.offsets
        starts = pieces.enumerated().map { i, p in p.spans.prefix(1).map { (offsets[i], $0.sentence) } }
    }

    // Where each sentence starts in the sound, for the highlight. A piece of one sentence starts with it; a piece of
    // several shares its length among them as the duration model measures each alone, worked out by the worker that
    // makes the piece (so a long text starts as fast as before: 83 000 characters took 0.5 s more when it was done
    // for all pieces up front). Measured 2026-11-10 (bench/align: ru, uk, en, voices 1 and 6, speeds 0.70, 1.05,
    // 2.00, Whisper large-v3 word times): 131 of 132 starts fell after the last word of the sentence before and before
    // the end of the first word of their own. Snapping them to pauses in the made sound scored 130 of 130: not worth
    // the code. The duration of all the text before a sentence read as one (the model's pauses included) put the
    // starts later, not closer.
    private var starts: [[(sample: Int, sentence: Int)]]

    private func findStarts(piece i: Int) throws {
        let p = pieces[i]
        guard p.spans.count > 1 else { return }
        let w = try p.spans.map { Double(try engine.length($0.text, lang: p.lang, voice: voice, speed: store.speed)) }
        let sum = max(1, w.reduce(0, +))
        var acc = 0.0, list: [(Int, Int)] = []
        for (s, x) in zip(p.spans, w) {
            list.append((store.offsets[i] + Int(acc / sum * Double(store.lengths[i])), s.sentence))
            acc += x
        }
        lock.lock(); starts[i] = list; lock.unlock()
    }

    /// All starts known so far, in order (for the measuring tools).
    var sentenceStarts: [(sample: Int, sentence: Int)] { lock.lock(); defer { lock.unlock() }; return starts.flatMap { $0 } }

    /// The sentence heard at `sample`: the last one that started; in a pause the one before it stays.
    func sentence(at sample: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        var k = store.piece(at: sample)
        if k > 0 && sample < store.offsets[k] { k -= 1 }     // the pause before a piece still shows the sentence before
        lock.lock(); defer { lock.unlock() }
        let list = starts[k]
        return (list.last { $0.sample <= sample } ?? list.first)?.sentence
    }

    private var order: [Int]

    func start(workers: Int) {
        for _ in 0..<max(1, workers) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { self.work() }
        }
        group.notify(queue: .global()) {
            self.lock.lock(); let f = self.failed; let c = self.cancelled; self.lock.unlock()
            // The callbacks go once used: they often hold the generator itself, which would never be freed otherwise
            // (with its store, its file and the engine).
            let done = self.onDone
            self.onDone = nil; self.onProgress = nil
            done?(c ? "cancelled" : f)   // always told, so whoever waits (the save sheet) can close
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    /// Waits for the pieces being made to stop (each checks for cancel between the model's steps), at most `seconds`.
    @discardableResult func wait(seconds: Double = 5) -> Bool { group.wait(timeout: .now() + seconds) == .success }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func work() {
        defer { group.leave() }
        while true {
            lock.lock()
            if cancelled || failed != nil || order.isEmpty { lock.unlock(); return }
            let i = order.removeFirst()
            lock.unlock()
            let p = pieces[i]
            do {
                let wav = try engine.synthesize(p.text, lang: p.lang, voice: voice, steps: steps, speed: store.speed,
                                                cancelled: { [weak self] in self?.isCancelled ?? true })
                try findStarts(piece: i)
                try store.write(piece: i, wav)
                onProgress?()
            } catch is CancellationError {
                return
            } catch {
                lock.lock(); failed = "\(p.text.prefix(80))…\n\(error)"; lock.unlock()
                return
            }
        }
    }
}
