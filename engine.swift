import Foundation
import COnnxRuntime

// Supertonic 3 inference on ONNX Runtime's C API. A line-by-line port of the
// reference Python package (supertonic 1.3.1, core.py): same text cleaning,
// same four models, same flow-matching loop. Checked against it sample by sample.

struct EngineError: Error, CustomStringConvertible {
    let description: String
}

private let api: OrtApi = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee

private func check(_ status: OpaquePointer?) throws {
    guard let status else { return }
    let msg = String(cString: api.GetErrorMessage(status)!)
    api.ReleaseStatus(status)
    throw EngineError(description: msg)
}

// MARK: - Model files

enum ModelFiles {
    // Upstream: huggingface.co/Supertone/supertonic-3, commit 724fb5a (the repo
    // on GitHub was archived 2026-08; these files will not change).
    static let onnx = ["duration_predictor", "text_encoder", "vector_estimator", "vocoder"]
    static let voices = ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
}

struct Voice {
    let ttl: [Float]     // 1 x 50 x 256
    let dp: [Float]      // 1 x 8 x 16
    let ttlShape: [Int64]
    let dpShape: [Int64]

    init(url: URL) throws {
        struct Part: Decodable { let dims: [Int64]; let data: [[[Float]]] }
        struct File: Decodable { let style_ttl: Part; let style_dp: Part }
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        ttl = f.style_ttl.data.flatMap { $0.flatMap { $0 } }
        dp = f.style_dp.data.flatMap { $0.flatMap { $0 } }
        ttlShape = f.style_ttl.dims
        dpShape = f.style_dp.dims
    }
}

// MARK: - Text, as core.py prepares it

enum TextPrep {
    static let languages: Set<String> = ["en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi"]

    private static let symbols: [(String, String)] = [
        ("\u{2013}", "-"), ("\u{2011}", "-"), ("\u{2014}", "-"), ("\u{00AF}", " "), ("_", " "),
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
        ("\u{00B4}", "'"), ("`", "'"), ("[", " "), ("]", " "), ("|", " "), ("/", " "),
        ("#", " "), ("\u{2192}", " "), ("\u{2190}", " "),
    ]
    private static let removed: Set<Unicode.Scalar> = ["\u{2665}", "\u{2606}", "\u{2661}", "\u{00A9}", "\\"]
    private static let ending = try! NSRegularExpression(pattern: "[.!?;:,'\"')\\]}…。」』】〉》›»]$")
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")
    private static let dupQuotes = try! NSRegularExpression(pattern: "([\"'`])\\1+")

    static func isEmoji(_ v: UInt32) -> Bool {
        (0x1F600...0x1F64F).contains(v) || (0x1F300...0x1F5FF).contains(v) || (0x1F680...0x1F6FF).contains(v)
            || (0x1F700...0x1F77F).contains(v) || (0x1F780...0x1F7FF).contains(v) || (0x1F800...0x1F8FF).contains(v)
            || (0x1F900...0x1F9FF).contains(v) || (0x1FA00...0x1FA6F).contains(v) || (0x1FA70...0x1FAFF).contains(v)
            || (0x2600...0x26FF).contains(v) || (0x2700...0x27BF).contains(v) || (0x1F1E6...0x1F1FF).contains(v)
    }

    static func clean(_ input: String) -> String {
        var t = input.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for s in t.unicodeScalars where !isEmoji(s.value) { scalars.append(s) }
        t = String(scalars)
        for (a, b) in symbols { t = t.replacingOccurrences(of: a, with: b) }
        scalars = String.UnicodeScalarView()
        for s in t.unicodeScalars where !removed.contains(s) { scalars.append(s) }
        t = String(scalars)
        for (a, b) in [("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        for p in [",", ".", "!", "?", ";", ":", "'"] { t = t.replacingOccurrences(of: " " + p, with: p) }
        t = dupQuotes.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        t = spaces.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        t = t.trimmingCharacters(in: .whitespaces)
        if ending.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil { t += "." }
        return t
    }
}

// MARK: - Engine

final class Supertonic {
    let sampleRate: Int
    private let chunk: Int            // samples per latent frame
    private let latentChannels: Int
    private let indexer: [Int64]
    private var env: OpaquePointer?
    private var dp: OpaquePointer?
    private var enc: OpaquePointer?
    private var est: OpaquePointer?
    private var voc: OpaquePointer?
    private var mem: OpaquePointer?
    private var alloc: UnsafeMutablePointer<OrtAllocator>?

    init(onnxDir: URL, threads: Int) throws {
        struct Cfg: Decodable {
            struct AE: Decodable { let sample_rate: Int; let base_chunk_size: Int }
            struct TTL: Decodable { let chunk_compress_factor: Int; let latent_dim: Int }
            let ae: AE; let ttl: TTL
        }
        let cfg = try JSONDecoder().decode(Cfg.self, from: Data(contentsOf: onnxDir.appendingPathComponent("tts.json")))
        sampleRate = cfg.ae.sample_rate
        chunk = cfg.ae.base_chunk_size * cfg.ttl.chunk_compress_factor
        latentChannels = cfg.ttl.latent_dim * cfg.ttl.chunk_compress_factor
        indexer = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: onnxDir.appendingPathComponent("unicode_indexer.json")))

        try check(api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "tts", &env))
        var opts: OpaquePointer?
        try check(api.CreateSessionOptions(&opts))
        defer { api.ReleaseSessionOptions(opts) }
        try check(api.SetIntraOpNumThreads(opts, Int32(threads)))
        try check(api.SetInterOpNumThreads(opts, 1))
        try check(api.SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL))
        func load(_ name: String) throws -> OpaquePointer? {
            var s: OpaquePointer?
            let path = onnxDir.appendingPathComponent(name + ".onnx").path
            try check(api.CreateSession(env, path, opts, &s))
            return s
        }
        dp = try load("duration_predictor")
        enc = try load("text_encoder")
        est = try load("vector_estimator")
        voc = try load("vocoder")
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem))
        try check(api.GetAllocatorWithDefaultOptions(&alloc))
    }

    deinit {
        for s in [dp, enc, est, voc] where s != nil { api.ReleaseSession(s) }
        if mem != nil { api.ReleaseMemoryInfo(mem) }
        if env != nil { api.ReleaseEnv(env) }
    }

    // MARK: tensors

    private final class Tensor {
        let value: OpaquePointer?
        init(_ v: OpaquePointer?) { value = v }
        deinit { if value != nil { api.ReleaseValue(value) } }
    }

    private func tensor<T>(_ data: [T], _ shape: [Int64], _ type: ONNXTensorElementDataType) throws -> Tensor {
        var v: OpaquePointer?
        try check(api.CreateTensorAsOrtValue(alloc, shape, shape.count, type, &v))
        let t = Tensor(v)
        var p: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(v, &p))
        data.withUnsafeBytes { src in p!.copyMemory(from: src.baseAddress!, byteCount: src.count) }
        return t
    }

    private func floats(_ t: Tensor) throws -> ([Float], [Int64]) {
        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(t.value, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var n = 0
        try check(api.GetDimensionsCount(info, &n))
        var dims = [Int64](repeating: 0, count: n)
        try check(api.GetDimensions(info, &dims, n))
        var count = 0
        try check(api.GetTensorShapeElementCount(info, &count))
        var p: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(t.value, &p))
        let buf = UnsafeBufferPointer(start: p!.assumingMemoryBound(to: Float.self), count: count)
        return (Array(buf), dims)
    }

    private func run(_ session: OpaquePointer?, _ inputs: [(String, Tensor)], _ output: String) throws -> Tensor {
        let names = inputs.map { strdup($0.0) }
        defer { names.forEach { free($0) } }
        var cnames = names.map { UnsafePointer<CChar>($0) }
        let values: [OpaquePointer?] = inputs.map { $0.1.value }
        let oname = strdup(output)
        defer { free(oname) }
        var onames: [UnsafePointer<CChar>?] = [UnsafePointer(oname)]
        var out: OpaquePointer?
        try cnames.withUnsafeMutableBufferPointer { cn in
            try check(api.Run(session, nil, cn.baseAddress, values, values.count, &onames, 1, &out))
        }
        return Tensor(out)
    }

    // MARK: synthesis

    /// Text ids for one chunk, as UnicodeProcessor builds them.
    func ids(_ text: String, lang: String) throws -> [Int64] {
        let l = TextPrep.languages.contains(lang) ? lang : "na"
        let full = "<\(l)>\(TextPrep.clean(text))</\(l)>"
        var out = [Int64]()
        out.reserveCapacity(full.unicodeScalars.count)
        for s in full.unicodeScalars {
            let v = Int(s.value)
            let id = v < indexer.count ? indexer[v] : -1
            out.append(id < 0 ? 0 : id)
        }
        return out
    }

    /// Unsupported characters (the model has no index for them).
    func unsupported(_ text: String) -> Set<Character> {
        var bad = Set<Character>()
        for ch in Set(text) {
            for s in TextPrep.clean(String(ch)).unicodeScalars {
                let v = Int(s.value)
                if v >= indexer.count || indexer[v] < 0 { bad.insert(ch); break }
            }
        }
        return bad
    }

    /// Length in seconds the model will give this chunk at speed 1 (duration predictor only, cheap).
    func duration(_ text: String, lang: String, voice: Voice) throws -> Float {
        let id = try ids(text, lang: lang)
        let n = Int64(id.count)
        let t = try tensor(id, [1, n], ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        let m = try tensor([Float](repeating: 1, count: id.count), [1, 1, n], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let s = try tensor(voice.dp, voice.dpShape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let d = try run(dp, [("text_ids", t), ("style_dp", s), ("text_mask", m)], "duration")
        return try floats(d).0[0]
    }

    /// Exact number of samples `synthesize` will return for this text at this speed.
    func length(_ text: String, lang: String, voice: Voice, speed: Float) throws -> Int {
        let dur = try duration(text, lang: lang, voice: voice) / speed
        return Int(Double(dur) * Double(sampleRate))
    }

    /// One chunk of text to 44.1 kHz mono samples. `noise` lets a test feed the reference's own noise.
    func synthesize(_ text: String, lang: String, voice: Voice, steps: Int, speed: Float,
                    noise: [Float]? = nil, cancelled: () -> Bool = { false }) throws -> [Float] {
        let id = try ids(text, lang: lang)
        let n = Int64(id.count)
        let tIds = try tensor(id, [1, n], ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        let tMask = try tensor([Float](repeating: 1, count: id.count), [1, 1, n], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let tDp = try tensor(voice.dp, voice.dpShape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let tTtl = try tensor(voice.ttl, voice.ttlShape, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)

        let dur = try floats(run(dp, [("text_ids", tIds), ("style_dp", tDp), ("text_mask", tMask)], "duration")).0[0] / speed
        let emb = try run(enc, [("text_ids", tIds), ("style_ttl", tTtl), ("text_mask", tMask)], "text_emb")

        // core.py: wav_len = dur * sr (float), latent_len = ceil(wav_len / chunk) as int32
        let wavLen = Int(Double(dur) * Double(sampleRate))
        let frames = Int((Double(dur) * Double(sampleRate) + Double(chunk) - 1) / Double(chunk))
        let latentCount = latentChannels * frames
        var x: [Float]
        if let noise, noise.count == latentCount {
            x = noise
        } else {
            x = Supertonic.gaussian(latentCount)
        }
        let tLatentMask = try tensor([Float](repeating: 1, count: frames), [1, 1, Int64(frames)], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let tTotal = try tensor([Float(steps)], [1], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        var xt = try tensor(x, [1, Int64(latentChannels), Int64(frames)], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        for step in 0..<steps {
            if cancelled() { throw CancellationError() }
            let tStep = try tensor([Float(step)], [1], ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            xt = try run(est, [("noisy_latent", xt), ("text_emb", emb), ("style_ttl", tTtl), ("text_mask", tMask),
                               ("latent_mask", tLatentMask), ("current_step", tStep), ("total_step", tTotal)],
                         "denoised_latent")
        }
        if cancelled() { throw CancellationError() }
        var wav = try floats(run(voc, [("latent", xt)], "wav_tts")).0
        if wav.count > wavLen { wav.removeLast(wav.count - wavLen) }
        x = []
        return wav
    }

    static func gaussian(_ n: Int) -> [Float] {
        var g = SystemRandomNumberGenerator()
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &g)
            let u2 = Double.random(in: 0..<1, using: &g)
            let r = (-2 * log(u1)).squareRoot()
            out[i] = Float(r * cos(2 * .pi * u2))
            if i + 1 < n { out[i + 1] = Float(r * sin(2 * .pi * u2)) }
            i += 2
        }
        return out
    }
}
