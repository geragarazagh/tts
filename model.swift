// The voice model: Supertonic 3 by Supertone (huggingface.co/Supertone/supertonic-3), ONNX, OpenRAIL-M.
// Not in the app: 401 MB that a person downloads only after saying yes, into one plain folder,
// ~/Library/Application Support/TTS/Supertonic 3, removable from the app menu.
//
// Files come from Supertone's own Hugging Face repository at a fixed commit, each checked against its SHA-256
// (Hugging Face's own LFS hashes for the four models; measured for the rest, 2026-11-09). Supertone archived the
// GitHub repo in 2026-08, so the same files are also kept as assets of this app's GitHub release «model-3»:
// a file that fails from the first address is fetched from the second. OpenRAIL-M allows that (section 4),
// with its LICENSE passed on, which is why LICENSE is one of the files.

import AppKit

struct ModelFile {
    let path: String, size: Int64, sha: String
}

enum Model {
    static let commit = "724fb5abbf5502583fb520898d45929e62f02c0b"
    static let files: [ModelFile] = [
        ModelFile(path: "onnx/vector_estimator.onnx", size: 256_534_781, sha: "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
        ModelFile(path: "onnx/vocoder.onnx", size: 101_424_195, sha: "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
        ModelFile(path: "onnx/text_encoder.onnx", size: 36_416_150, sha: "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
        ModelFile(path: "onnx/duration_predictor.onnx", size: 3_700_147, sha: "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
        ModelFile(path: "onnx/tts.json", size: 8_253, sha: "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
        ModelFile(path: "onnx/unicode_indexer.json", size: 277_676, sha: "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"),
        ModelFile(path: "LICENSE", size: 15_007, sha: "0d944a9110fed9a9602d60e0423a272903e7bd21ab060490774efc77c2275e9f"),
    ] + voiceFiles

    // Measured from the files at the commit above (shasum -a 256), 2026-11-09.
    static let voiceFiles: [ModelFile] = [
        ("M1", 291_748, "e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b"),
        ("M2", 292_055, "b76cbf62bac707c710cf0ae5aba5e31eea1a6339a9734bfae33ab98499534a50"), ("M3", 290_198, "ea1ac35ccb91b0d7ecad533a2fbd0eec10c91513d8951e3b25fbba99954e159b"), ("M4", 291_522, "ca8eefad4fcd989c9379032ff3e50738adc547eeb5e221b82593a6d7b3bac303"), ("M5", 291_469, "dd22b92740314321f8ae11c5e87f8dd60d060f15dd3a632b5adf77f471f77af2"),
        ("F1", 292_046, "bbdec6ee00231c2c742ad05483df5334cab3b52fda3ba38e6a07059c4563dbc2"), ("F2", 292_423, "7c722c6a72707b1a77f035d67f0d1351ba187738e06f7683e8c72b1df3477fc6"), ("F3", 290_794, "12f6ef2573baa2defa1128069cb59f203e3ab67c92af77b42df8a0e3a2f7c6ab"), ("F4", 291_808, "c2fa764c1225a76dfc3e2c73e8aa4f70d9ee48793860eb34c295fff01c2e032b"),
        ("F5", 291_479, "45966e73316415626cf41a7d1c6f3b4c70dbc1ba2bee5c1978ef0ce33244fc8d"),
    ].map { ModelFile(path: "voice_styles/\($0.0).json", size: $0.1, sha: $0.2) }

    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTS/Supertonic 3", isDirectory: true)
    }

    static var isHere: Bool {
        files.allSatisfy { f in
            let s = (try? folder.appendingPathComponent(f.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
            return s == f.size
        }
    }

    static func sources(_ f: ModelFile) -> [URL] {
        [URL(string: "https://huggingface.co/Supertone/supertonic-3/resolve/\(commit)/\(f.path)")!,
         URL(string: "https://github.com/geragarazagh/tts/releases/download/model-3/\((f.path as NSString).lastPathComponent)")!]
    }

    /// Removes the app's folder in Application Support with the model in it, and leftovers of a broken download.
    static func delete() throws {
        let app = folder.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: app.path) { try FileManager.default.removeItem(at: app) }
    }

    static func removeParts() {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let u as URL in e where u.pathExtension == "part" { try? FileManager.default.removeItem(at: u) }
    }
}

/// Downloads every missing file one after another; progress is over all bytes.
final class ModelDownload: @unchecked Sendable {
    private var current: Download?
    private var stopped = false
    private let lock = NSLock()
    let progress: @Sendable (Double) -> Void
    let done: @Sendable (String?) -> Void

    init(progress: @escaping @Sendable (Double) -> Void, done: @escaping @Sendable (String?) -> Void) {
        self.progress = progress; self.done = done
    }

    func start() {
        do {
            for d in Set(Model.files.map { ($0.path as NSString).deletingLastPathComponent }) {
                try FileManager.default.createDirectory(at: Model.folder.appendingPathComponent(d), withIntermediateDirectories: true)
            }
        } catch { done("\(Model.folder.path)\n\(error)"); return }
        next(0, source: 0, errors: [])
    }

    func cancel() {
        lock.lock(); stopped = true; let c = current; lock.unlock()
        c?.cancel()
    }

    private func next(_ i: Int, source: Int, errors: [String]) {
        lock.lock(); let stop = stopped; lock.unlock()
        if stop { return }
        guard i < Model.files.count else { done(nil); return }
        let f = Model.files[i]
        let target = Model.folder.appendingPathComponent(f.path)
        if let s = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize), Int64(s) == f.size {
            next(i + 1, source: 0, errors: errors); return
        }
        let before = Model.files[..<i].reduce(Int64(0)) { $0 + $1.size }
        let total = Double(Model.totalSize)
        let urls = Model.sources(f)
        let d = Download(url: urls[source], target: target, sha: f.sha, size: f.size,
                         progress: { [weak self] p in self?.progress((Double(before) + p * Double(f.size)) / total) },
                         done: { [weak self] err in
                             guard let self else { return }
                             if let err {
                                 try? FileManager.default.removeItem(at: target.appendingPathExtension("part"))
                                 if source + 1 < urls.count { self.next(i, source: source + 1, errors: errors + [err]) }
                                 else { self.done((errors + [err]).joined(separator: "\n\n")) }
                             } else {
                                 self.next(i + 1, source: 0, errors: [])
                             }
                         })
        lock.lock(); current = d; lock.unlock()
        d.start()
    }
}
