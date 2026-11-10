// Downloads a model to <file>.part and moves it into place only after its SHA-256 matches.
// An ephemeral session, so nothing is left in ~/Library/Caches or HTTPStorages. A broken connection continues from the
// bytes already on disk (Range), which matters on a bad line with a file of a gigabyte. The .part file lives only as long
// as the app runs: cancelling or quitting removes it, so nothing half-finished stays on the Mac.

import CryptoKit
import Foundation

func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var d = SHA256()
    while let chunk = try h.read(upToCount: 1 << 22), !chunk.isEmpty { d.update(data: chunk) }
    return d.finalize().map { String(format: "%02x", $0) }.joined()
}

final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL, target: URL, sha: String, size: Int64
    var part: URL { target.appendingPathExtension("part") }
    private let queue = OperationQueue()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var got: Int64 = 0
    private var failures = 0, stopped = false
    private let progress: @Sendable (Double) -> Void
    private let done: @Sendable (String?) -> Void   // nil = the file is in place

    init(url: URL, target: URL, sha: String, size: Int64, progress: @escaping @Sendable (Double) -> Void, done: @escaping @Sendable (String?) -> Void) {
        self.url = url; self.target = target; self.sha = sha; self.size = size; self.progress = progress; self.done = done
        super.init()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
    }

    func start() {
        queue.addOperation { self.attempt() }
    }

    func cancel() {
        queue.addOperation {
            self.stopped = true
            self.task?.cancel()
            self.closeFile()
            self.session?.invalidateAndCancel()
            try? FileManager.default.removeItem(at: self.part)
        }
    }

    private func closeFile() { try? file?.close(); file = nil }

    private func attempt() {
        guard !stopped else { return }
        got = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        if got >= size { finish(); return }
        if got == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("bytes=\(got)-", forHTTPHeaderField: "Range")
        task = session?.dataTask(with: r)
        task?.resume()
    }

    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive r: URLResponse, completionHandler c: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard code == 200 || code == 206 else { throw NSError(domain: "HTTP \(code)", code: code) }
            let h = try FileHandle(forWritingTo: part)
            if code == 200 { try h.truncate(atOffset: 0); got = 0 } else { try h.seekToEnd() }
            file = h
            c(.allow)
        } catch {
            c(.cancel)
            stopped = true
            session?.invalidateAndCancel()
            done("\(url)\n\(error)")
        }
    }

    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive d: Data) {
        do {
            try file?.write(contentsOf: d)
            got += Int64(d.count)
            failures = 0
            progress(Double(got) / Double(size))
        } catch {
            stopped = true
            t.cancel()
            done("\(part.path)\n\(error)")
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        closeFile()
        guard !stopped else { return }
        if e == nil && got >= size { finish(); return }
        // About 5 minutes of nothing before giving up: a router restart or a power cut shouldn't cost the whole file.
        failures += 1
        if failures > 12 {
            stopped = true
            session?.invalidateAndCancel()
            done("\(url)\n\(e.map { "\($0)" } ?? "\(got) of \(size) bytes")")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(min(failures * 5, 30))) { self.start() }
    }

    private func finish() {
        session?.finishTasksAndInvalidate()
        do {
            let h = try sha256(of: part)
            guard h == sha else {
                try? FileManager.default.removeItem(at: part)
                done("\(url)\nSHA-256 \(h)")
                return
            }
            try FileManager.default.moveItem(at: part, to: target)
            done(nil)
        } catch {
            done("\(part.path)\n\(error)")
        }
    }
}
