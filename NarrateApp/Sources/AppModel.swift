import AppKit
import Foundation
import Observation
import os
import UniformTypeIdentifiers

let log = Logger(subsystem: "com.narrate.app", category: "app")

/// All app state. The views render it; it drives the engine, the downloader, the browser and the player.
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    enum Source: String, CaseIterable, Identifiable {
        case pdf = "PDF", text = "Text", link = "Link"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case starting
        case downloading(String, Double)
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    struct GenerationProgress: Equatable {
        var label: String? = nil
        var done = 0, total = 0
        var seconds = 0.0
        var eta: Double? = nil
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    // Engine / setup
    var status: Status = .starting
    var ffmpegAvailable = false
    var formats: [String] { ffmpegAvailable ? ["mp3", "m4a", "wav"] : ["mp3", "wav"] }

    // Input
    var source: Source = .pdf
    var document: SourceDocument?
    var pastedText = ""
    var linkText = ""
    /// The page-range field on the document card ("6-13, 24-50"); applied on submit.
    var rangesText = ""
    var isExtracting = false
    var extractLabel = "Reading PDF…"

    var showVoicePicker = false

    // Options (remembered between launches)
    var voiceID = UserDefaults.standard.string(forKey: "voice") ?? "af_heart" {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voice") }
    }
    var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speed, forKey: "speed") }
    }
    var format = UserDefaults.standard.string(forKey: "format") ?? "mp3" {
        didSet { UserDefaults.standard.set(format, forKey: "format") }
    }

    // Work in flight
    var isGenerating = false
    var progress = GenerationProgress()
    var isCapturing = false
    var captureLabel = "Capturing…"
    var loadingSampleID: String?

    // Output
    var timeline: Timeline?          // what the reader shows (streams in during generation)
    var narration: Narration?        // the finished, encoded file (nil until generation completes)
    var showReader = false
    private var chunkDir: URL?

    // Feedback
    var toast: (text: String, isError: Bool)?
    /// Opens one of the app's `Window` scenes by id; the root view hands this in (it lives in the SwiftUI environment).
    var openWindow: (String) -> Void = { _ in }

    let engine = Engine()
    let player = Player()
    let samplePlayer = SamplePlayer()
    let browser = BrowserController()
    let updater = Updater()
    /// Voice previews live on disk (Application Support/Narrate/samples/<key>/), rendered once per voice
    /// in the background right after the engine comes up, so pressing play is instant from then on.
    private var sampleKey = "default"
    private var sampleJobs: [String: Task<URL, Error>] = [:]
    private var prewarmTask: Task<Void, Never>?
    private(set) var cachedSampleIDs: Set<String> = []
    private var toastTask: Task<Void, Never>?
    private var started = false
    private var pendingOpen: [URL] = []

    // MARK: - Locations

    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Narrate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let modelDir = supportDir.appendingPathComponent("models")

    /// The embedded Python runtime and engine script (overridable for development runs outside the bundle).
    static var pythonURL: URL {
        if let p = ProcessInfo.processInfo.environment["NARRATE_PYTHON"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
    }
    static var engineScriptURL: URL {
        if let p = ProcessInfo.processInfo.environment["NARRATE_ENGINE"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL!.appendingPathComponent("engine/narrate_engine.py")
    }

    // MARK: - Startup

    func start() {
        guard !started else { return }
        started = true
        updater.onMessage = { [weak self] text, isError in self?.showToast(text, isError: isError) }
        browser.onDownloadedPDF = { [weak self] file in
            self?.showToast("Saved the PDF to Downloads.", isError: false)
            self?.openPDF(file)
        }
        updater.checkAutomatically()
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        log.info("bootstrap: python=\(Self.pythonURL.path, privacy: .public) engine=\(Self.engineScriptURL.path, privacy: .public)")
        do {
            if !ModelDownloader.isReady(in: Self.modelDir) {
                log.info("bootstrap: downloading model")
                status = .downloading("Downloading voice model…", 0)
                try await ModelDownloader().download(to: Self.modelDir) { label, frac in
                    Task { @MainActor in self.status = .downloading(label, frac) }
                }
            }
            status = .loading
            engine.onExit = { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    if self.status == .ready || self.status == .loading {
                        self.status = .failed("The narration engine stopped (exit \(code)). See engine.log in Application Support.")
                    }
                }
            }
            try engine.start(python: Self.pythonURL, script: Self.engineScriptURL, modelDir: Self.modelDir,
                             log: Self.supportDir.appendingPathComponent("engine.log"))
            let hello = try await engine.call("hello")
            log.info("bootstrap: hello ok, ffmpeg=\(hello["ffmpeg"] as? Bool ?? false)")
            ffmpegAvailable = hello["ffmpeg"] as? Bool ?? false
            if !formats.contains(format) { format = "mp3" }
            if let key = hello["sample_key"] as? String { sampleKey = key }
            _ = try await engine.call("warm_up")
            log.info("bootstrap: engine ready")
            status = .ready
            let queued = pendingOpen; pendingOpen = []
            if !queued.isEmpty { open(queued) }
            prewarmSamples()
        } catch {
            log.error("bootstrap failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    func retrySetup() {
        prewarmTask?.cancel(); prewarmTask = nil
        sampleJobs.removeAll()
        engine.stop()
        status = .starting
        started = false
        start()
    }

    // MARK: - Opening things

    func open(_ urls: [URL]) {
        log.info("open: \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public) status=\(String(describing: self.status), privacy: .public)")
        // Files opened from Finder before the engine is up (e.g. double-clicking a PDF at launch): wait for it.
        if !status.isReady, urls.contains(where: { $0.pathExtension.lowercased() == "pdf" }) {
            pendingOpen = urls
            return
        }
        guard leaveReader() else { return }
        // A link dragged in from a browser.
        if let web = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
            readArticle(web.absoluteString); return
        }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { openPDF(url); return }
            if url.lastPathComponent.lowercased().hasSuffix(".narrate.json") { reopen(sidecar: url); return }
            if ["mp3", "m4a", "wav"].contains(ext) {
                let sidecar = url.deletingPathExtension().appendingPathExtension("narrate.json")
                if FileManager.default.fileExists(atPath: sidecar.path) { reopen(sidecar: sidecar); return }
            }
        }
        showToast("Drop a PDF, a link, or an audiobook Narrate made earlier.", isError: true)
    }

    /// A new document arrived while the reader was showing an earlier audiobook: go back to the
    /// setup screen so it can be looked over (and pages chosen) instead of loading behind the reader.
    /// A generation in progress is never thrown away by an accidental drop.
    private func leaveReader() -> Bool {
        guard showReader else { return true }
        if isGenerating {
            showToast("An audiobook is still being generated — cancel it first (⌘N) to open something else.", isError: true)
            return false
        }
        closeReader()
        return true
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .mp3, .wav, UTType(filenameExtension: "m4a") ?? .audio, .json]
        panel.message = "Choose a PDF, or an audiobook Narrate made earlier"
        if panel.runModal() == .OK, let url = panel.url { open([url]) }
    }

    /// Read the whole file once — every page's text plus its chapters — then let the user pick pages.
    func openPDF(_ url: URL) {
        guard !isExtracting, leaveReader() else { return }
        isExtracting = true
        extractLabel = "Reading \(url.lastPathComponent)…"
        source = .pdf
        Task {
            defer { isExtracting = false }
            do {
                let r = try await engine.call("extract", ["path": url.path]) { p in
                    if let label = p["label"] as? String { Task { @MainActor in self.extractLabel = label } }
                }
                let blocks = r["page_blocks"] as? [[String]] ?? []
                guard blocks.contains(where: { !$0.isEmpty }) else {
                    showToast("No readable text found. This PDF looks like scanned images.", isError: true); return
                }
                let outline = (r["outline"] as? [[String: Any]] ?? []).enumerated().map { i, e in
                    OutlineEntry(id: i, title: e["title"] as? String ?? "Untitled", level: e["level"] as? Int ?? 1,
                                 first: e["first"] as? Int ?? 1, last: e["last"] as? Int ?? 1)
                }
                setDocument(SourceDocument(pdfName: r["name"] as? String ?? url.lastPathComponent, path: url.path,
                                           pageBlocks: blocks, outline: outline,
                                           outlineSource: r["outline_source"] as? String ?? "none"))
                if !outline.isEmpty, blocks.count > 30 {
                    showToast("Found \(outline.count) chapters — tick the ones you want, or choose pages.", isError: false)
                }
            } catch {
                showToast("Couldn't read that PDF: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func useText() {
        // Someone pasted a link into the text box: treat it as one.
        if BrowserController.webURL(from: pastedText) != nil { readArticle(pastedText); return }
        let paras = pastedText.components(separatedBy: #"\n\s*\n"#, regex: true)
            .map { $0.replacing(regex: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paras.isEmpty else { showToast("Paste some text first.", isError: true); return }
        let title = paras[0].count > 60 ? String(paras[0].prefix(60)) + "…" : paras[0]
        setDocument(SourceDocument(name: title, path: nil, pages: 0, paragraphs: paras, method: nil))
    }

    private func setDocument(_ doc: SourceDocument) {
        document = doc
        rangesText = doc.isPDF ? doc.rangesText : ""
    }

    func clearDocument() { document = nil; rangesText = "" }

    // MARK: - Choosing pages

    /// Commit whatever is typed in the ranges field ("6-13, 24-50").
    func applyRanges() {
        guard let doc = document, doc.isPDF else { return }
        let text = rangesText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { document?.selection = IndexSet(1...doc.pages); syncRangesText(); return }
        guard let set = SourceDocument.parseRanges(text, pages: doc.pages) else {
            showToast("Type page ranges like 6-13, 24-50.", isError: true); return
        }
        document?.selection = set
        syncRangesText()
    }

    func setPages(_ set: IndexSet) {
        guard let doc = document, doc.isPDF else { return }
        document?.selection = set.intersection(IndexSet(1...doc.pages))
        syncRangesText()
    }

    func selectAllPages() { if let doc = document, doc.isPDF { setPages(IndexSet(1...doc.pages)) } }
    func clearPages() { setPages([]) }

    func select(_ range: ClosedRange<Int>, _ on: Bool) {
        guard var doc = document, doc.isPDF else { return }
        if on { doc.selection.insert(integersIn: range) } else { doc.selection.remove(integersIn: range) }
        setPages(doc.selection)
    }

    func setSelected(_ entry: OutlineEntry, _ on: Bool) { select(entry.pages, on) }

    private func syncRangesText() { rangesText = document?.rangesText ?? "" }

    func openPagePicker() {
        guard document?.isPDF == true else { return }
        openWindow("pages")
    }

    func reopen(sidecar: URL) {
        do {
            let n = try Narration.load(sidecar: sidecar)
            narration = n
            try openReader(Timeline(narration: n))
            showToast("Reopened an audiobook Narrate made earlier. Drop a PDF to make a new one.", isError: false)
        } catch {
            showToast("Couldn't reopen narration: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Links

    /// Paste a link, get the article: the page loads in the (possibly hidden) web view and the
    /// readable text is pulled out of it. Links to PDFs are downloaded and opened like any PDF.
    /// When there's no article to be found — a login wall, a bot check, JSTOR's page scans — the
    /// browser window opens on the page so the user can deal with it and press Capture.
    func readArticle(_ text: String? = nil) {
        let raw = text ?? linkText
        guard let url = BrowserController.webURL(from: raw) else {
            showToast("That doesn't look like a web address.", isError: true); return
        }
        guard !isCapturing else { return }
        linkText = url.absoluteString
        source = .link
        isCapturing = true
        captureLabel = "Loading page…"
        log.info("readArticle: \(url.absoluteString, privacy: .public)")
        Task {
            defer { isCapturing = false }
            do {
                switch try await browser.load(url) {
                case .pdf(let file):
                    showToast("That link is a PDF — saved it to Downloads.", isError: false)
                    openPDF(file)
                case .page:
                    captureLabel = "Reading article…"
                    await browser.settle()
                    var article = try await Article.extract(browser.webView)
                    if (article?.words ?? 0) < Article.minimumWords {   // client-rendered pages can be a beat late
                        try await Task.sleep(for: .seconds(1.5))
                        article = try await Article.extract(browser.webView)
                    }
                    guard let a = article, a.words >= Article.minimumWords else {
                        log.info("readArticle: only \(article?.words ?? 0) words, falling back to the browser")
                        openWindow("browser")
                        showToast("Couldn't find an article there. If the page needs a login, sign in here, then press Capture Page Text.", isError: true)
                        return
                    }
                    setDocument(SourceDocument(name: a.title, path: nil, pages: 0, paragraphs: a.spokenParagraphs, method: "article"))
                    showToast("Read “\(a.title)” — \(a.words.formatted()) words.", isError: false)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } catch {
                log.error("readArticle failed: \(error.localizedDescription, privacy: .public)")
                openWindow("browser")
                showToast("Couldn't load that link: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Built-in browser

    func openLink() {
        guard BrowserController.webURL(from: linkText) != nil else { return }
        openWindow("browser")
        browser.load(linkText)
    }

    func capturePage() {
        guard browser.isOpen, !isCapturing else { return }
        isCapturing = true
        captureLabel = "Capturing…"
        Task {
            defer { isCapturing = false }
            do {
                let r = try await Capture.run(browser.webView) { label, _ in
                    Task { @MainActor in self.captureLabel = label }
                }
                guard !r.paragraphs.isEmpty else { showToast("Couldn't find readable text on that page.", isError: true); return }
                setDocument(SourceDocument(name: r.title, path: nil, pages: 0, paragraphs: r.paragraphs, method: r.method))
                source = .link
                showToast("Captured \(r.paragraphs.count) paragraphs via \(r.method).", isError: false)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                showToast("Capture failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Voices

    private var sampleDir: URL { Self.supportDir.appendingPathComponent("samples/\(sampleKey)") }
    private func sampleFile(_ id: String) -> URL { sampleDir.appendingPathComponent("\(id).wav") }

    /// Preview a voice at the current speed. Instant when the sample is cached; otherwise it's rendered
    /// now (and kept), jumping the queue ahead of the background pre-render.
    func sampleVoice(_ id: String) {
        if samplePlayer.playingID == id { samplePlayer.stop(); return }
        guard status.isReady else { showToast("The voice model is still loading.", isError: true); return }
        Task {
            do {
                if !cachedSampleIDs.contains(id) { loadingSampleID = id }
                defer { if loadingSampleID == id { loadingSampleID = nil } }
                let url = try await ensureSample(id)
                try samplePlayer.play(url: url, id: id, rate: speed)
            } catch is CancellationError {
            } catch {
                showToast("Sample failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private var hoverTask: Task<Void, Never>?

    /// Hovering an orb plays its sample after a beat (so sweeping across the grid doesn't fire them
    /// all); leaving it stops. Pass nil to cancel everything.
    func hoverPreview(_ id: String?, _ inside: Bool) {
        hoverTask?.cancel(); hoverTask = nil
        guard let id, inside else {
            if id == nil || samplePlayer.playingID == id { samplePlayer.stop() }
            return
        }
        if samplePlayer.playingID == id { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, status.isReady else { return }
            do {
                if !cachedSampleIDs.contains(id) { loadingSampleID = id }
                defer { if loadingSampleID == id { loadingSampleID = nil } }
                let url = try await ensureSample(id)
                guard !Task.isCancelled else { return }
                try samplePlayer.play(url: url, id: id, rate: speed)
            } catch {}
        }
    }

    /// Render every voice's sample that isn't on disk yet, selected voice first, one at a time and only
    /// while nothing else needs the engine. Also drops caches left by older sample scripts.
    private func prewarmSamples() {
        prewarmTask?.cancel()
        let fm = FileManager.default
        try? fm.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        if let dirs = try? fm.contentsOfDirectory(at: sampleDir.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            for d in dirs where d.lastPathComponent != sampleKey { try? fm.removeItem(at: d) }
        }
        cachedSampleIDs = Set(Voice.all.map(\.id).filter { fm.fileExists(atPath: sampleFile($0).path) })
        let order = [voiceID] + Voice.all.map(\.id).filter { $0 != voiceID }
        prewarmTask = Task {
            for id in order where !cachedSampleIDs.contains(id) {
                while isGenerating || isCapturing {                 // don't compete with real work
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                if Task.isCancelled || !status.isReady { return }
                _ = try? await ensureSample(id)
            }
            log.info("samples: all \(self.cachedSampleIDs.count) voice previews cached")
        }
    }

    /// The on-disk sample for a voice, rendering it if needed. Concurrent callers share one render.
    private func ensureSample(_ id: String) async throws -> URL {
        let file = sampleFile(id)
        if FileManager.default.fileExists(atPath: file.path) { cachedSampleIDs.insert(id); return file }
        if let job = sampleJobs[id] { return try await job.value }
        let job = Task<URL, Error> {
            defer { sampleJobs[id] = nil }
            // Write to a temp name and rename, so a half-written file is never mistaken for a sample.
            let tmp = file.appendingPathExtension("part")
            _ = try await engine.call("sample", ["voice": id, "speed": 1.0, "out": tmp.path])
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            cachedSampleIDs.insert(id)
            return file
        }
        sampleJobs[id] = job
        return try await job.value
    }

    // MARK: - Generation

    var canGenerate: Bool { status.isReady && document != nil && !isGenerating && !isExtracting }

    func generate() {
        guard canGenerate, let doc = document else { return }
        if doc.isPDF, doc.selection.isEmpty { showToast("Choose at least one page or chapter first.", isError: true); return }
        isGenerating = true
        progress = GenerationProgress(label: "Warming up…")
        let voice = Voice.named(voiceID)
        let folder = doc.path.map { ($0 as NSString).deletingLastPathComponent }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        var stem = (doc.isPDF ? (doc.name as NSString).deletingPathExtension : doc.name)
            .replacing(regex: #"[\\/:*?"<>|]+"#, with: " ").trimmingCharacters(in: .whitespaces)
        stem = String(stem.prefix(80))
        if stem.isEmpty { stem = "Narration" }
        let title = doc.isPDF ? (doc.name as NSString).deletingPathExtension : doc.name
        let outBase = (folder as NSString).appendingPathComponent("\(stem) – \(voice.name)")
        // Same whitespace normalisation as the engine, so word counts line up chunk for chunk.
        let paragraphs = doc.paragraphs
            .map { $0.replacing(regex: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-\(UUID().uuidString)")
        cleanupChunks()
        chunkDir = dir
        let t0 = Date()
        let speed = self.speed

        Task {
            defer {
                isGenerating = false
                if !showReader { cleanupChunks() }     // reader was closed mid-way; the engine has stopped now
            }
            do {
                let r = try await engine.call("narrate", [
                    "paragraphs": paragraphs, "voice": voice.id, "speed": speed, "fmt": format,
                    "out_base": outBase, "chunk_dir": dir.path,
                ]) { p in
                    Task { @MainActor in self.handleGenerationEvent(p, title: title, voice: voice.name,
                                                                     paragraphs: paragraphs, speed: speed, startedAt: t0) }
                }
                let words = (r["paragraphs"] as? [[[Any]]] ?? []).map { p in
                    p.compactMap { w -> TimedWord? in
                        guard w.count == 3, let t = w[0] as? String, let s = w[1] as? Double, let e = w[2] as? Double else { return nil }
                        return TimedWord(text: t, start: s, end: e)
                    }
                }
                let path = r["path"] as? String ?? outBase
                let n = Narration(path: path, name: (path as NSString).lastPathComponent, title: title,
                                  voice: voice.name, duration: r["duration"] as? Double ?? 0, paragraphs: words)
                try? n.writeSidecar()
                narration = n
                if !showReader { try openReader(Timeline(narration: n)) }
                showToast("Saved \(n.name) — AirDrop it to your phone from the toolbar.", isError: false)
            } catch let e as Engine.Failure where e.cancelled {
                showToast("Cancelled", isError: false)
            } catch {
                showToast("Generation failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func handleGenerationEvent(_ p: Engine.JSON, title: String, voice: String, paragraphs: [String],
                                       speed: Double, startedAt: Date) {
        switch p["event"] as? String {
        case "plan":
            let chunks = (p["chunks"] as? [[String: Any]] ?? []).map {
                Timeline.Chunk(index: $0["index"] as? Int ?? 0, paragraph: $0["paragraph"] as? Int ?? 0,
                               wordOffset: $0["word_offset"] as? Int ?? 0, wordCount: $0["words"] as? Int ?? 0)
            }
            let t = Timeline(title: title, voice: voice, paragraphs: paragraphs.map { $0.components(separatedBy: " ") },
                             chunks: chunks, speed: speed)
            progress = GenerationProgress(label: nil, done: 0, total: chunks.count)
            try? openReader(t)
        case "chunk":
            guard let t = timeline, let index = p["index"] as? Int, let path = p["path"] as? String else { return }
            let words = (p["words"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? (start: $0[0], end: $0[1]) : nil }
            t.receive(index: index, url: URL(fileURLWithPath: path), duration: p["duration"] as? Double ?? 0, words: words)
            player.chunkArrived(index)
        default:
            if let label = p["label"] as? String { progress.label = label; return }
            let done = p["done"] as? Int ?? 0, total = p["total"] as? Int ?? 0
            let elapsed = Date().timeIntervalSince(startedAt)
            progress = GenerationProgress(label: nil, done: done, total: total, seconds: timeline?.duration ?? 0,
                                          eta: done > 0 ? elapsed / Double(done) * Double(total - done) : nil)
        }
    }

    func cleanupChunks() {
        if let d = chunkDir { try? FileManager.default.removeItem(at: d) }
        chunkDir = nil
    }

    func cancelGeneration() { engine.cancelCurrent() }

    /// The listener skipped somewhere that isn't synthesized yet: make the engine go there next.
    private func prioritize(chunk: Int) {
        guard isGenerating else { return }
        engine.send("prioritize", ["chunk": chunk])
    }

    // MARK: - Reader

    private func openReader(_ t: Timeline) throws {
        player.onNeedChunk = { [weak self] k in self?.prioritize(chunk: k) }
        player.load(t)
        timeline = t
        showReader = true
        player.play()
    }

    func jumpParagraph(_ delta: Int) {
        guard let tl = timeline else { return }
        let t = player.currentTime
        // First word of each paragraph, on the (possibly estimated) timeline.
        let flat = tl.wordStarts()
        var starts: [Double] = []
        var i = 0
        for p in tl.paragraphs where !p.isEmpty { starts.append(flat[i]); i += p.count }
        guard !starts.isEmpty else { return }
        var cur = starts.lastIndex { $0 <= t } ?? 0
        // Going back restarts the current paragraph first, like a track button.
        if delta < 0, t - starts[cur] > 2 { cur += 1 }
        let target = max(0, min(starts.count - 1, cur + delta))
        player.seek(to: starts[target])
    }

    func closeReader() {
        player.stop()
        if isGenerating { engine.cancelCurrent() }
        showReader = false
        timeline = nil
        narration = nil
        if !isGenerating { cleanupChunks() }
    }

    func revealInFinder() {
        guard let n = narration else { return }
        NSWorkspace.shared.activateFileViewerSelecting([n.url])
    }

    // MARK: - Getting the audio onto other devices

    /// Send the finished audio file straight to a nearby iPhone/iPad/Mac.
    func airDrop() {
        guard let n = narration else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [n.url]) else {
            showToast("AirDrop isn't available — check that Wi-Fi and Bluetooth are on.", isError: true); return
        }
        service.perform(withItems: [n.url])
    }

    /// Save a copy of the audio file somewhere else (iCloud Drive is the other easy route to a phone).
    func exportCopy() {
        guard let n = narration else { return }
        let panel = NSSavePanel()
        panel.title = "Export Audiobook"
        panel.message = "Choose where to save a copy of the audio. Save it in iCloud Drive to open it from the Files app on your phone."
        panel.nameFieldStringValue = n.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: n.url.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: n.url, to: dest)
            showToast("Saved a copy to \(dest.deletingLastPathComponent().lastPathComponent).", isError: false)
        } catch {
            showToast("Couldn't save the copy: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Toast

    func showToast(_ text: String, isError: Bool) {
        toast = (text, isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }
}
