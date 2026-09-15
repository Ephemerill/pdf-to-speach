import Foundation
import os

private let elog = Logger(subsystem: "com.narrate.app", category: "engine")

/// Talks to the bundled Python engine (`engine/narrate_engine.py`) over JSON lines on stdin/stdout.
/// One request → optional `progress` events → one `result` or `error`, matched by `id`.
final class Engine: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        let cancelled: Bool
        var errorDescription: String? { message }
    }

    typealias JSON = [String: Any]
    typealias Progress = (JSON) -> Void

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var progress: [Int: Progress] = [:]
    private(set) var isRunning = false

    /// Called (off the main thread) when the process dies unexpectedly.
    var onExit: ((Int32) -> Void)?

    func start(python: URL, script: URL, modelDir: URL, log: URL) throws {
        process.executableURL = python
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["NARRATE_MODEL_DIR"] = modelDir.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            elog.error("engine exited with status \(p.terminationStatus)")
            self.isRunning = false
            self.failAll("The narration engine stopped unexpectedly (exit \(p.terminationStatus)).")
            self.onExit?(p.terminationStatus)
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(data)
        }
        try process.run()
        isRunning = true
        elog.info("engine started pid=\(self.process.processIdentifier)")
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Send a request and wait for its result.
    func call(_ op: String, _ args: JSON = [:], progress: Progress? = nil) async throws -> JSON {
        guard isRunning else { throw Failure(message: "The narration engine isn't running.", cancelled: false) }
        var req = args
        req["op"] = op
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            let id = nextID; nextID += 1
            req["id"] = id
            pending[id] = cont
            if let progress { self.progress[id] = progress }
            lock.unlock()
            do {
                var line = try JSONSerialization.data(withJSONObject: req)
                line.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: line)
            } catch {
                lock.lock(); pending[id] = nil; self.progress[id] = nil; lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    /// Ask the engine to abort whatever job is running (fire and forget).
    func cancelCurrent() { send("cancel") }

    /// Fire-and-forget request; the reply is ignored.
    func send(_ op: String, _ args: JSON = [:]) {
        lock.lock()
        let id = nextID; nextID += 1
        lock.unlock()
        var req = args
        req["id"] = id; req["op"] = op
        if var line = try? JSONSerialization.data(withJSONObject: req) {
            line.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }
    }

    // MARK: - stdout parsing

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: line) as? JSON, let id = msg["id"] as? Int else {
            elog.error("unparseable engine line: \(String(decoding: line.prefix(200), as: UTF8.self), privacy: .public)")
            return
        }
        if msg["event"] != nil {                       // progress / plan / chunk: streamed to the caller
            lock.lock(); let cb = progress[id]; lock.unlock()
            cb?(msg)
            return
        }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        progress[id] = nil
        lock.unlock()
        guard let cont else { return }
        if let err = msg["error"] as? String {
            cont.resume(throwing: Failure(message: err, cancelled: msg["cancelled"] as? Bool ?? false))
        } else {
            cont.resume(returning: msg["result"] as? JSON ?? [:])
        }
    }

    private func failAll(_ message: String) {
        lock.lock()
        let conts = pending; pending = [:]; progress = [:]
        lock.unlock()
        for (_, c) in conts { c.resume(throwing: Failure(message: message, cancelled: false)) }
    }
}
