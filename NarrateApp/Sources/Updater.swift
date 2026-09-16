import AppKit
import Foundation
import Observation
import os

private let ulog = Logger(subsystem: "com.narrate.app", category: "updater")

/// Keeps the app current from GitHub Releases: checks the latest release, downloads the zipped
/// app, swaps it in over the running copy and relaunches. Downloads made by the app itself carry no
/// quarantine flag, so the new build opens without the Gatekeeper "Open Anyway" step.
@Observable @MainActor
final class Updater {
    static let repo = "Ephemerill/pdf-to-speach"
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking
        case available(Release)
        case downloading(Double)
        case installing
    }

    private(set) var state: State = .idle
    var isBusy: Bool { switch state { case .checking, .downloading, .installing: return true; default: return false } }

    /// Feedback for the user (toast); wired up by the app model.
    var onMessage: ((String, Bool) -> Void)?

    var automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate") }
    }
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "skippedUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedUpdate") }
    }

    // MARK: - Checking

    /// The quiet launch-time check: at most once a day, never for development runs.
    func checkAutomatically() {
        guard automatic, ProcessInfo.processInfo.environment["NARRATE_ENGINE"] == nil else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check(interactive: false) }
    }

    func check(interactive: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            if Self.isNewer(release.version, than: Self.currentVersion), interactive || release.version != skipped {
                ulog.info("update available: \(release.version, privacy: .public)")
                state = .available(release)
            } else {
                state = .idle
                if interactive { onMessage?("You're on the latest version (\(Self.currentVersion)).", false) }
            }
        } catch {
            ulog.error("update check failed: \(error.localizedDescription, privacy: .public)")
            state = .idle
            if interactive { onMessage?("Couldn't check for updates: \(error.localizedDescription)", true) }
        }
    }

    func skip() {
        if case .available(let r) = state { skipped = r.version }
        state = .idle
    }

    private func fetchLatest() async throws -> Release {
        // NARRATE_UPDATE_URL points a development run at a fake "latest release" JSON.
        let api = ProcessInfo.processInfo.environment["NARRATE_UPDATE_URL"]
            ?? "https://api.github.com/repos/\(Self.repo)/releases/latest"
        var req = URLRequest(url: URL(string: api)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Narrate/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub didn't return a release.") }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init),
              let assets = j["assets"] as? [[String: Any]] else { throw Failure("Unexpected reply from GitHub.") }
        guard let zip = assets.first(where: { ($0["name"] as? String) == "Narrate.zip" }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init) else {
            throw Failure("The latest release has no Narrate.zip attached.")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: j["body"] as? String ?? "", zipURL: zipURL, pageURL: page)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: - Installing

    func install() {
        guard case .available(let release) = state else { return }
        Task {
            do {
                try await download(release)
            } catch {
                ulog.error("update failed: \(error.localizedDescription, privacy: .public)")
                state = .available(release)
                onMessage?("Update failed: \(error.localizedDescription)", true)
            }
        }
    }

    private func download(_ release: Release) async throws {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        // Running from a disk image or somewhere we can't write? Send them to the release page instead.
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else {
            NSWorkspace.shared.open(release.pageURL)
            throw Failure("Narrate can't replace itself where it's installed — download the new version from the page that just opened.")
        }
        state = .downloading(0)
        let work = fm.temporaryDirectory.appendingPathComponent("narrate-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try await stage(release, in: work, over: app)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private func stage(_ release: Release, in work: URL, over app: URL) async throws {
        let fm = FileManager.default
        let zip = work.appendingPathComponent("Narrate.zip")
        try await Download.fetch(release.zipURL, to: zip) { [weak self] frac in
            Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(frac) } }
        }
        state = .installing
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let new = work.appendingPathComponent("Narrate.app")
        let info = new.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: new.appendingPathComponent("Contents/MacOS/Narrate").path),
              let plist = NSDictionary(contentsOf: info), plist["CFBundleShortVersionString"] as? String == release.version else {
            throw Failure("The downloaded update doesn't look like Narrate \(release.version).")
        }
        try? fm.removeItem(at: zip)
        try swapAndRelaunch(new: new, over: app, work: work)
    }

    /// The bundle can't replace itself while it's running: a detached shell script waits for us to
    /// quit, moves the new build into place (keeping the old one until that succeeds) and reopens it.
    private func swapAndRelaunch(new: URL, over app: URL, work: URL) throws {
        let script = work.appendingPathComponent("install.sh")
        let old = work.appendingPathComponent("Narrate-old.app")
        let sh = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv "\(app.path)" "\(old.path)" && mv "\(new.path)" "\(app.path)"; then
          xattr -cr "\(app.path)" 2>/dev/null
          rm -rf "\(old.path)"
        else
          [ -d "\(old.path)" ] && [ ! -d "\(app.path)" ] && mv "\(old.path)" "\(app.path)"
        fi
        open "\(app.path)"
        rm -rf "\(work.path)"
        """
        try sh.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \"\(script.path)\" >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
        ulog.info("update staged; relaunching")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).") }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

/// A file download with progress, on top of URLSession's delegate API.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(dest: URL, progress: @escaping (Double) -> Void) { self.dest = dest; self.progress = progress }

    static func fetch(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let d = Download(dest: dest, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try FileManager.default.moveItem(at: location, to: dest) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation; continuation = nil
        if let error = error ?? moveError { c?.resume(throwing: error) }
        else if let code = (task.response as? HTTPURLResponse)?.statusCode, code != 200 {
            c?.resume(throwing: Updater.Failure("Download failed (HTTP \(code))."))
        } else { c?.resume() }
    }
}
