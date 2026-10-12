import Foundation
import Observation
import os

private let hlog = Logger(subsystem: "com.narrate.app", category: "models")

/// A set of model files fetched in the background while the app stays fully usable — the Kokoro
/// voices on first launch (~340 MB), and the high quality Fish Audio S2 Pro model (~6.7 GB) once
/// the user picks High Quality. Downloads resume where they left off, across pauses and relaunches
/// (HTTP ranges into `.part` files), and a pack can be deleted again.
@Observable @MainActor
final class ModelPack {
    enum State: Equatable {
        case absent                 // never downloaded (or deleted)
        case downloading
        case paused                 // partly downloaded; resumes from where it stopped
        case ready
        case failed(String)
    }

    typealias File = (name: String, size: Int64)

    /// Kokoro-82M. model-files-v1.1 exposes phoneme durations, which the read-along timings depend on.
    static func kokoro(in dir: URL) -> ModelPack {
        ModelPack(dir: dir, base: URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/")!,
                  files: [("kokoro-v1.0.onnx", 325_505_369), ("voices-v1.0.bin", 28_214_398)])
    }

    /// Fish Audio S2 Pro, int8 for MLX. Pinned to one revision of the conversion, so a changed
    /// upload can never surprise anyone.
    static func fish(in dir: URL) -> ModelPack {
        ModelPack(dir: dir, base: URL(string: "https://huggingface.co/mlx-community/fishaudio-s2-pro-8bit-mlx/resolve/4e9863f2915d6df6dcde5b6d7e1a351bddbc5986/")!,
                  files: [("config.json", 1_077), ("tokenizer.json", 12_217_872), ("tokenizer_config.json", 860_832),
                          ("special_tokens_map.json", 101_864), ("chat_template.jinja", 4_116), ("LICENSE.md", 10_360),
                          ("codec-mlx/config.json", 146), ("codec-mlx/model.safetensors", 1_874_070_622),
                          ("model.safetensors", 4_847_255_597)])
    }

    let dir: URL
    let base: URL
    let files: [File]
    let totalBytes: Int64
    private(set) var state: State = .absent
    /// Bytes on disk so far (finished files + partial ones).
    private(set) var received: Int64 = 0
    /// Recent download speed, for the time-left estimate.
    private(set) var bytesPerSecond: Double = 0
    var fraction: Double { Double(received) / Double(totalBytes) }
    var secondsLeft: Double? { bytesPerSecond > 1000 ? Double(totalBytes - received) / bytesPerSecond : nil }
    var isReady: Bool { state == .ready }

    /// Fires on the main actor once the model has finished downloading.
    var onReady: (() -> Void)?

    private var task: Task<Void, Never>?
    private var fetch: RangeFetch?

    init(dir: URL, base: URL, files: [File]) {
        self.dir = dir; self.base = base; self.files = files
        totalBytes = files.reduce(0) { $0 + $1.size }
        refresh()
    }

    private func path(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private func size(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0 }

    private func complete(_ f: (name: String, size: Int64)) -> Bool { size(path(f.name)) == f.size }

    private func bytesOnDisk() -> Int64 {
        files.reduce(0) { sum, f in
            sum + (complete(f) ? f.size : min(f.size, size(path(f.name + ".part"))))
        }
    }

    private func refresh() {
        received = bytesOnDisk()
        if files.allSatisfy(complete) { state = .ready }
        else if received > 0 { state = .paused }
        else { state = .absent }
    }

    // MARK: - Download

    func download() {
        guard task == nil, state != .ready else { return }
        let missing = totalBytes - bytesOnDisk()
        if let free = try? dir.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < missing + 1_000_000_000 {
            state = .failed("Not enough disk space — this needs \(Format.bytes(missing + 1_000_000_000)) free.")
            return
        }
        state = .downloading
        bytesPerSecond = 0
        hlog.info("download: starting, \(self.received) of \(self.totalBytes) bytes already here")
        task = Task {
            defer { task = nil; fetch = nil }
            do {
                for f in files where !complete(f) {
                    try FileManager.default.createDirectory(at: path(f.name).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await get(f)
                    if Task.isCancelled { return }
                }
                refresh()
                hlog.info("download: complete")
                if state == .ready { onReady?() }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                hlog.error("download failed: \(error.localizedDescription, privacy: .public)")
                received = bytesOnDisk()
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func get(_ f: (name: String, size: Int64)) async throws {
        let part = path(f.name + ".part")
        if size(part) > f.size { try? FileManager.default.removeItem(at: part) }
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let before = received - size(part)          // everything except this file's partial bytes
        var last = (time: Date(), bytes: received)
        let fetch = RangeFetch(url: base.appendingPathComponent(f.name), file: part) { [weak self] have in
            Task { @MainActor in
                guard let self, self.state == .downloading else { return }
                self.received = before + have
                let dt = Date().timeIntervalSince(last.time)
                if dt >= 1 {
                    let rate = Double(self.received - last.bytes) / dt
                    self.bytesPerSecond = self.bytesPerSecond == 0 ? rate : self.bytesPerSecond * 0.8 + rate * 0.2
                    last = (Date(), self.received)
                }
            }
        }
        self.fetch = fetch
        try await withTaskCancellationHandler {
            try await fetch.run()
        } onCancel: {
            fetch.cancel()
        }
        guard size(part) == f.size else { throw Failure("\(f.name) came down incomplete — try again.") }
        try? FileManager.default.removeItem(at: path(f.name))
        try FileManager.default.moveItem(at: part, to: path(f.name))
    }

    /// Stop for now; `download()` carries on from the same byte later.
    func pause() {
        task?.cancel(); task = nil
        fetch?.cancel(); fetch = nil
        refresh()
    }

    /// Remove the pack's files, partial downloads included (and its folder, once empty).
    func delete() {
        pause()
        let fm = FileManager.default
        for f in files {
            try? fm.removeItem(at: path(f.name)); try? fm.removeItem(at: path(f.name + ".part"))
        }
        for sub in [dir.appendingPathComponent("codec-mlx"), dir] where (try? fm.contentsOfDirectory(atPath: sub.path))?.isEmpty == true {
            try? fm.removeItem(at: sub)
        }
        refresh()
        hlog.info("deleted")
    }

    /// What it takes on disk right now (for the Options row).
    var diskBytes: Int64 { received }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

/// Streams one URL into a file from the file's current length onwards (`Range: bytes=n-`), so a
/// 4.8 GB file survives pauses, lost connections and relaunches without starting over.
private final class RangeFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let file: URL
    private let progress: (Int64) -> Void
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private let lock = NSLock()
    private var lastReport = Date.distantPast

    init(url: URL, file: URL, progress: @escaping (Int64) -> Void) {
        self.url = url; self.file = file; self.progress = progress
    }

    func run() async throws {
        let h = try FileHandle(forWritingTo: file)
        have = Int64(try h.seekToEnd())
        handle = h
        defer { try? h.close() }
        var req = URLRequest(url: url)
        req.setValue("Narrate/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); continuation = c; lock.unlock()
            s.dataTask(with: req).resume()
        }
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, have > 0 {               // server ignored the range: start this file over
            try? handle?.truncate(atOffset: 0)
            have = 0
        }
        guard code == 200 || code == 206 else {
            failure = ModelPack.Failure("The download server answered HTTP \(code).")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            have += Int64(data.count)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(have) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progress(have)
        session.finishTasksAndInvalidate()
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let failure { c?.resume(throwing: failure) }
        else if let error { c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error) }
        else { c?.resume() }
    }
}
