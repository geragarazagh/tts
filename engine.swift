// The voices: Apple's, Siri's among them, spoken by the `tts` script in the app's Resources, run by macOS's own
// /usr/bin/osascript. Why not AVSpeechSynthesizer in the app itself: macOS lists Siri voices only to processes Apple
// signed. A Developer ID app sees Milena, Katya, Yuri, Lesya and nothing better; the same app starting osascript gets
// every Siri voice (measured 2026-11-10 on macOS 27.2 and a clean 26.6.2). osascript is part of every Mac, so nothing
// is installed for it. Apple doesn't document this way and may close it; then the voices it gives apps are used.
//
// `tts` is also the author's command line tool, the same file: the text step (numbers, dates, units, abbreviations
// in ru and uk read in the right case), the choice of voice per paragraph and the speed curve are one code, measured
// once. Here it runs as `tts --serve`: one JSON request a line on stdin, the answers a line each on stdout.

import Foundation

struct VoiceInfo: Equatable {
    let id: String, name: String, lang: String, code: String, gender: Int, kind: String
    var isSiri: Bool { kind == "Siri" }
}

/// One `osascript tts --serve`. Requests go one at a time; the answers are read on a thread of their own and handed
/// to the main thread.
final class Worker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var pending: [Int: ([String: Any]) -> Bool] = [:]     // id -> handler; true when it was the last line
    private let lock = NSLock()
    private var nextID = 1
    var busy: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    private(set) var dead = false
    var onDeath: (() -> Void)?
    var lastUsed = Date()

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        guard let script = Bundle.main.url(forResource: "tts", withExtension: nil) else { throw EngineError("tts is missing from the app") }
        process.arguments = ["-l", "JavaScript", script.path, "--serve"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.died() }
        try process.run()
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    /// Sends a request; `handler` gets every answer line on the main thread and returns true at the last one.
    func send(_ request: [String: Any], handler: @escaping ([String: Any]) -> Bool) {
        lock.lock()
        let id = nextID; nextID += 1
        pending[id] = handler
        lock.unlock()
        lastUsed = Date()
        var r = request; r["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: r) else { return }
        data.append(0x0a)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { kill() }
    }

    private func readLoop() {
        let h = output.fileHandleForReading
        var buffer = Data()
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = o["id"] as? Int else { continue }
                DispatchQueue.main.async {
                    self.lock.lock(); let h = self.pending[id]; self.lock.unlock()
                    if let h, h(o) { self.lock.lock(); self.pending[id] = nil; self.lock.unlock(); self.lastUsed = Date() }
                }
            }
        }
    }

    private func died() {
        DispatchQueue.main.async {
            guard !self.dead else { return }
            self.dead = true
            // whoever waits gets an answer
            self.lock.lock(); let hs = self.pending; self.pending = [:]; self.lock.unlock()
            for (_, h) in hs { _ = h(["error": "the voice process ended"]) }
            self.onDeath?()
        }
    }

    func kill() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
    init(description d: String) { description = d }
}

/// The workers. One answers the quick questions (voices, the text step); the rest speak, as many at once as the
/// speech asks for, up to `limit`. Measured on the M3 Pro, 2026-11-10: one worker speaks about 120 characters a
/// second (5-6 times faster than speech at 1x), six 298 (much of the work is in Apple's own sirittsd, so more don't
/// help). Idle speakers end after a minute; one stays ready, so a new start or a new speed sounds at once.
@MainActor final class Engine {
    static let shared = Engine()
    static var limit: Int { max(2, min(6, Workers.performanceCores)) }

    private var control: Worker?
    private var speakers: [Worker] = []
    private var sweeper: Timer?
    private(set) var voices: [VoiceInfo] = []
    var onVoices: (() -> Void)?

    private init() {
        sweeper = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { Engine.shared.sweep() } }
    }

    private func controlWorker() throws -> Worker {
        if let c = control, !c.dead { return c }
        let w = try Worker()
        control = w
        return w
    }

    /// Reads the voices again (at launch, and when the app comes back to the front: a voice may have been
    /// downloaded in System Settings meanwhile).
    func loadVoices() {
        guard let w = try? controlWorker() else { return }
        w.send(["op": "voices"]) { [weak self] o in
            if let list = o["voices"] as? [[String: Any]] {
                let v = list.compactMap { d -> VoiceInfo? in
                    guard let id = d["id"] as? String, let name = d["name"] as? String, let lang = d["lang"] as? String,
                          let code = d["code"] as? String else { return nil }
                    return VoiceInfo(id: id, name: name, lang: lang, code: code, gender: d["gender"] as? Int ?? 0, kind: d["kind"] as? String ?? "")
                }
                if v != self?.voices { self?.voices = v; self?.onVoices?() }
            }
            return true
        }
    }

    /// The text step for the whole text: paragraphs with their language, sentences with their place and words.
    /// Paragraphs arrive as they are ready.
    func plan(_ text: String, paragraph: @escaping (String?, [[String: Any]]) -> Void, done: @escaping (String?) -> Void) {
        let w: Worker
        do { w = try controlWorker() } catch { done("\(error)"); return }
        w.send(["op": "plan", "text": text, "max": Speech.maxPart]) { o in
            if let p = o["par"] as? [String: Any] {
                paragraph(p["lang"] as? String, p["sentences"] as? [[String: Any]] ?? [])
                return false
            }
            done(o["error"] as? String)
            return true
        }
    }

    /// The voice for each language: the one chosen for it, else the best of the same kind (gender).
    func pick(langs: [String], chosen: [String: String], gender: Int, done: @escaping ([String: String]) -> Void) {
        guard let w = try? controlWorker() else { done([:]); return }
        w.send(["op": "pick", "langs": langs, "voice": chosen, "gender": gender]) { o in
            done(o["pick"] as? [String: String] ?? [:])
            return true
        }
    }

    // MARK: speaking

    /// A free speaker, started if needed; nil when `max` are busy.
    func speaker(max: Int) -> Worker? {
        speakers.removeAll { $0.dead }
        if let w = speakers.first(where: { $0.busy == 0 }) { return w }
        guard speakers.count < Swift.min(max, Self.limit) else { return nil }
        guard let w = try? Worker() else { return nil }
        speakers.append(w)
        return w
    }

    /// Speaks into a CAF file that grows while the voice speaks; `done` gets nil or the error.
    func render(on w: Worker, voice: String, speed: Double, text: String, path: String, done: @escaping (String?) -> Void) {
        w.send(["op": "render", "voice": voice, "speed": speed, "text": text, "path": path]) { o in
            done(o["error"] as? String)
            return true
        }
    }

    /// Stops a speaker in the middle of a sentence nobody needs any more; a new one takes its place when asked for.
    func abandon(_ w: Worker) {
        w.kill()
        speakers.removeAll { $0 === w }
    }

    /// One speaker warmed with a voice before anything is asked, so the first sentence sounds at once.
    func warm(voice: String) {
        guard let w = speaker(max: 1) else { return }
        let path = NSTemporaryDirectory() + "tts-\(UUID().uuidString).caf"
        render(on: w, voice: voice, speed: 1, text: ".", path: path) { _ in try? FileManager.default.removeItem(atPath: path) }
    }

    private func sweep() {
        let idle = speakers.filter { $0.busy == 0 && Date().timeIntervalSince($0.lastUsed) > 60 }
        for w in idle.dropFirst(speakers.count == idle.count ? 1 : 0) { abandon(w) }
    }

    func shutDown() {
        for w in speakers { w.kill() }
        control?.kill()
        speakers = []; control = nil
    }
}

/// How many speakers suit this Mac: its performance cores.
enum Workers {
    static var performanceCores: Int {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
