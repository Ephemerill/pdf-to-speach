import Foundation

/// Fetches the Kokoro model files (~340 MB, once) into Application Support with progress.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    // model-files-v1.1 exposes phoneme durations, which the read-along word timings depend on.
    static let base = URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/")!
    static let files: [(name: String, size: Int64)] = [("kokoro-v1.0.onnx", 325_505_369), ("voices-v1.0.bin", 28_214_398)]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static func isReady(in dir: URL) -> Bool {
        files.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)
            return (attrs?[.size] as? Int64) == f.size
        }
    }

    private var progressHandler: ((String, Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var doneBefore: Int64 = 0
    private var currentName = ""
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(to dir: URL, progress: @escaping (String, Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        progressHandler = progress
        doneBefore = 0
        for f in Self.files {
            let dest = dir.appendingPathComponent(f.name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64, size == f.size {
                doneBefore += f.size
                continue
            }
            currentName = f.name
            let tmp: URL = try await withCheckedThrowingContinuation { cont in
                continuation = cont
                var req = URLRequest(url: Self.base.appendingPathComponent(f.name))
                req.setValue("narrate/2.0", forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: req).resume()
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            doneBefore += f.size
        }
        progress("Ready", 1)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let frac = Double(doneBefore + totalBytesWritten) / Double(Self.totalBytes)
        progressHandler?("Downloading \(currentName)", min(frac, 0.999))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so hop it somewhere stable first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse)
            }
            continuation?.resume(returning: keep)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let cont = continuation {
            continuation = nil
            cont.resume(throwing: error)
        }
    }
}
