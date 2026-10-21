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

    /// The standard voices' readiness. Documents can be opened and set up in every state but
    /// `.failed` (the engine reads PDFs without any model); only generating waits for `.ready`.
    enum Status: Equatable {
        case starting
        case downloading            // first launch: the Kokoro voices are coming down in the background (see `kokoro`)
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
    /// Standard (Kokoro) or high quality (Fish Audio S2 Pro). Use `setQuality` — picking High is what
    /// starts the model download.
    private(set) var quality = Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    /// PDFs: leave out page numbers, running heads and footnotes (and the note marks in the text).
    var skipNotes = UserDefaults.standard.object(forKey: "skipNotes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipNotes, forKey: "skipNotes"); document?.skipsNotes = skipNotes }
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

    /// Replaced by a fresh one on "Try Again" (a Process can only be launched once).
    private(set) var engine = Engine()
    let player = Player()
    let samplePlayer = SamplePlayer()
    let browser = BrowserController()
    let updater = Updater()
    let kokoro = ModelPack.kokoro(in: AppModel.modelDir)
    let hq = ModelPack.fish(in: AppModel.modelDir.appendingPathComponent("fish-s2-pro"))
    /// The engine process is up: PDFs can be read even while the voices are still downloading.
    private(set) var engineUp = false
    /// Generate was pressed before the voices were ready: start as soon as they are.
    var generateWhenReady = false
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
        hq.onReady = { [weak self] in self?.hqBecameReady() }
        // High quality was chosen before but isn't all here yet: carry on downloading in the background.
        if quality == .high, !hq.isReady { hq.download() }
        browser.onDownloadedPDF = { [weak self] file in
            self?.showToast("Saved the PDF to Downloads.", isError: false)
            self?.openPDF(file)
        }
        Task { await bootstrap() }
    }

    /// The engine starts straight away — it reads PDFs without any model — and the voices download
    /// in the background meanwhile on first launch. Only generating has to wait for them.
    private func bootstrap() async {
        log.info("bootstrap: python=\(Self.pythonURL.path, privacy: .public) engine=\(Self.engineScriptURL.path, privacy: .public)")
        do {
            engine.onExit = { [weak self] code in
                Task { @MainActor in
                    guard let self, self.engineUp else { return }
                    self.engineUp = false
                    self.status = .failed("The narration engine stopped (exit \(code)). See engine.log in Application Support.")
                }
            }
            try engine.start(python: Self.pythonURL, script: Self.engineScriptURL, modelDir: Self.modelDir,
                             log: Self.supportDir.appendingPathComponent("engine.log"))
            let hello = try await engine.call("hello")
            log.info("bootstrap: hello ok, ffmpeg=\(hello["ffmpeg"] as? Bool ?? false)")
            ffmpegAvailable = hello["ffmpeg"] as? Bool ?? false
            if !formats.contains(format) { format = "mp3" }
            if let key = hello["sample_key"] as? String { sampleKey = key }
            engineUp = true
            let queued = pendingOpen; pendingOpen = []
            if !queued.isEmpty { open(queued) }
            if kokoro.isReady {
                await loadVoices()
            } else {
                log.info("bootstrap: downloading the voices in the background")
                status = .downloading
                kokoro.onReady = { [weak self] in Task { await self?.loadVoices() } }
                kokoro.download()
            }
        } catch {
            log.error("bootstrap failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    private func loadVoices() async {
        do {
            status = .loading
            _ = try await engine.call("warm_up")
            log.info("bootstrap: engine ready")
            status = .ready
            prewarmSamples()
            if generateWhenReady { generateWhenReady = false; generate() }
        } catch {
            log.error("warm_up failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    func retrySetup() {
        prewarmTask?.cancel(); prewarmTask = nil
        sampleJobs.removeAll()
        engineUp = false
        engine.onExit = nil
        engine.stop()
        engine = Engine()
        status = .starting
        started = false
        start()
    }

    // MARK: - Opening things

    func open(_ urls: [URL]) {
        log.info("open: \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public) status=\(String(describing: self.status), privacy: .public)")
        // Files opened from Finder before the engine is up (e.g. double-clicking a PDF at launch): wait for it.
        if !engineUp, urls.contains(where: { $0.pathExtension.lowercased() == "pdf" }) {
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
                var blocks = r["page_blocks"] as? [[String]] ?? []
                var allBlocks = r["page_blocks_all"] as? [[String]] ?? []
                // Pages that are only pictures (a scan): read them with on-device OCR.
                let scanned = (r["scanned_pages"] as? [Int] ?? []).filter { blocks.indices.contains($0 - 1) }
                if !scanned.isEmpty {
                    let name = url.lastPathComponent
                    let found = await PDFScan.ocr(path: url.path, pages: scanned) { done, total in
                        Task { @MainActor in self.extractLabel = "Reading scanned pages of \(name)… \(done + 1) of \(total)" }
                    }
                    if allBlocks.count != blocks.count { allBlocks = blocks }
                    for (p, page) in found { blocks[p - 1] = page.clean; allBlocks[p - 1] = page.all }
                }
                guard blocks.contains(where: { !$0.isEmpty }) || allBlocks.contains(where: { !$0.isEmpty }) else {
                    showToast(scanned.isEmpty ? "No readable text found in that PDF."
                                              : "No readable text found — the scanned pages couldn't be read.", isError: true); return
                }
                let outline = (r["outline"] as? [[String: Any]] ?? []).enumerated().map { i, e in
                    OutlineEntry(id: i, title: e["title"] as? String ?? "Untitled", level: e["level"] as? Int ?? 1,
                                 first: e["first"] as? Int ?? 1, last: e["last"] as? Int ?? 1)
                }
                setDocument(SourceDocument(pdfName: r["name"] as? String ?? url.lastPathComponent, path: url.path,
                                           pageBlocks: blocks, allBlocks: allBlocks, outline: outline,
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
        var doc = doc
        doc.skipsNotes = skipNotes
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
            script = nil
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
    private func sampleName(_ id: String, _ q: Quality) -> String { q == .high ? "hq-\(id)" : id }
    private func sampleFile(_ id: String, _ q: Quality) -> URL { sampleDir.appendingPathComponent("\(sampleName(id, q)).wav") }
    func hasSample(_ id: String, _ q: Quality) -> Bool { cachedSampleIDs.contains(sampleName(id, q)) }

    /// Preview a voice at the current speed, in the quality that would be used. Instant when the
    /// sample is cached; otherwise it's rendered now (and kept), jumping the queue ahead of the
    /// background pre-render.
    func sampleVoice(_ id: String) {
        if samplePlayer.playingID == id { samplePlayer.stop(); return }
        guard status.isReady else {
            showToast(status == .downloading ? "The voices are still downloading — \(Int(kokoro.fraction * 100))% so far." : "The voices are still loading.", isError: true)
            return
        }
        let q = effectiveQuality
        Task {
            do {
                if !hasSample(id, q) { loadingSampleID = id }
                defer { if loadingSampleID == id { loadingSampleID = nil } }
                let url = try await ensureSample(id, q)
                try samplePlayer.play(url: url, id: id, rate: speed)
            } catch is CancellationError {
            } catch {
                showToast("Sample failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private var hoverTask: Task<Void, Never>?

    /// Hovering an orb plays its sample after a beat (so sweeping across the grid doesn't fire them
    /// all); leaving it stops. Pass nil to cancel everything. A high quality sample takes a while to
    /// render the first time, so until it's cached the standard one plays and the high quality one
    /// is rendered in the background for next time.
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
            var q = effectiveQuality
            if q == .high, !hasSample(id, .high) {
                if !isGenerating { renderInBackground(id, .high) }
                q = .standard
            }
            do {
                if !hasSample(id, q) { loadingSampleID = id }
                defer { if loadingSampleID == id { loadingSampleID = nil } }
                let url = try await ensureSample(id, q)
                guard !Task.isCancelled else { return }
                try samplePlayer.play(url: url, id: id, rate: speed)
            } catch {}
        }
    }

    private func renderInBackground(_ id: String, _ q: Quality) {
        guard sampleJobs[sampleName(id, q)] == nil, !hasSample(id, q) else { return }
        Task { _ = try? await ensureSample(id, q) }
    }

    /// Render every voice's standard sample that isn't on disk yet (plus the chosen voice's high
    /// quality one when that's in use), selected voice first, one at a time and only while nothing
    /// else needs the engine. Also drops caches left by older sample scripts.
    private func prewarmSamples() {
        prewarmTask?.cancel()
        let fm = FileManager.default
        try? fm.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        if let dirs = try? fm.contentsOfDirectory(at: sampleDir.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            for d in dirs where d.lastPathComponent != sampleKey { try? fm.removeItem(at: d) }
        }
        let names = (try? fm.contentsOfDirectory(atPath: sampleDir.path)) ?? []
        cachedSampleIDs = Set(names.filter { $0.hasSuffix(".wav") }.map { ($0 as NSString).deletingPathExtension })
        var order: [(String, Quality)] = ([voiceID] + Voice.all.map(\.id).filter { $0 != voiceID }).map { ($0, .standard) }
        if effectiveQuality == .high { order.insert((voiceID, .high), at: 1) }
        prewarmTask = Task {
            for (id, q) in order where !hasSample(id, q) {
                while isGenerating || isCapturing {                 // don't compete with real work
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                if Task.isCancelled || !status.isReady { return }
                _ = try? await ensureSample(id, q)
            }
            log.info("samples: \(self.cachedSampleIDs.count) voice previews cached")
        }
    }

    /// The on-disk sample for a voice, rendering it if needed. Concurrent callers share one render.
    private func ensureSample(_ id: String, _ q: Quality) async throws -> URL {
        let file = sampleFile(id, q), name = sampleName(id, q)
        if FileManager.default.fileExists(atPath: file.path) { cachedSampleIDs.insert(name); return file }
        if let job = sampleJobs[name] { return try await job.value }
        let job = Task<URL, Error> {
            defer { sampleJobs[name] = nil }
            // Write to a temp name and rename, so a half-written file is never mistaken for a sample.
            let tmp = file.appendingPathExtension("part")
            _ = try await engine.call("sample", ["voice": id, "speed": 1.0, "out": tmp.path, "quality": q.rawValue])
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            cachedSampleIDs.insert(name)
            return file
        }
        sampleJobs[name] = job
        return try await job.value
    }

    // MARK: - High quality voices

    /// High quality only once its model is on disk; until then (or while it downloads) Standard is used.
    var effectiveQuality: Quality { quality == .high && hq.isReady ? .high : .standard }

    /// Picking High Quality is what downloads the model — in the background, nothing waits on it.
    func setQuality(_ q: Quality) {
        quality = q
        if q == .high {
            if !hq.isReady { hq.download() } else { prewarmSamples() }
        } else if !(isGenerating && job?.quality == .high) {
            engine.send("hq_unload")                          // hand the ~7 GB of memory back
        }
    }

    private func hqBecameReady() {
        showToast("High quality voices are ready" + (showReader ? " — choose one from the voice menu." : "."), isError: false)
        if quality == .high { prewarmSamples() }
    }

    /// Free the disk space again. Anything narrated with them stays.
    func deleteHQModel() {
        if isGenerating, job?.quality == .high {
            showToast("Wait for the high quality narration to finish (or cancel it) first.", isError: true); return
        }
        engine.send("hq_unload")
        hq.delete()
        let fm = FileManager.default
        try? fm.removeItem(at: Self.supportDir.appendingPathComponent("fish-references"))
        for name in cachedSampleIDs where name.hasPrefix("hq-") {
            try? fm.removeItem(at: sampleDir.appendingPathComponent("\(name).wav"))
        }
        cachedSampleIDs = cachedSampleIDs.filter { !$0.hasPrefix("hq-") }
        quality = .standard
        showToast("Deleted the high quality voices.", isError: false)
    }

    // MARK: - Generation

    var canGenerate: Bool { status.isReady && document != nil && !isGenerating && !isExtracting }
    /// The voices are still coming: Generate can be pressed anyway and starts once they're in.
    var canQueueGeneration: Bool { (status == .downloading || status == .loading || status == .starting) && document != nil && !isExtracting }

    /// What's being narrated — kept so a voice switch can narrate the same thing again.
    private struct Script {
        let title: String
        let paragraphs: [String]
        let folder: String
        let stem: String
        let speed: Double
    }
    /// One engine `narrate` request: a voice reading the script.
    private struct Job {
        let id = UUID()
        let engineID: Int
        let voiceID: String
        let quality: Quality
    }
    /// A voice switch in progress. The new voice's chunks collect here while the old voice keeps
    /// talking; once the chunk the listener is in exists, the swap is armed for the next natural
    /// break (`armedWord`) and happens on the player's clock, mid-sentence, without a gap.
    private struct VoiceSwitch {
        let job: UUID
        var chunks: [Timeline.Chunk]
        var armedWord: Int? = nil
        var armedTime = 0.0          // when that word starts in the old voice
    }

    private var script: Script?
    private var job: Job?
    private var voiceSwitch: VoiceSwitch?
    /// "Bella HQ" while a switch to it is being prepared (the reader says so).
    var switchingTo: String? {
        guard voiceSwitch != nil, let j = job else { return nil }
        return Voice.named(j.voiceID).name + j.quality.suffix
    }

    func generate() {
        if canQueueGeneration { generateWhenReady.toggle(); return }
        guard canGenerate, let doc = document else { return }
        if doc.isPDF, doc.selection.isEmpty { showToast("Choose at least one page or chapter first.", isError: true); return }
        let folder = doc.path.map { ($0 as NSString).deletingLastPathComponent }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        var stem = (doc.isPDF ? (doc.name as NSString).deletingPathExtension : doc.name)
            .replacing(regex: #"[\\/:*?"<>|]+"#, with: " ").trimmingCharacters(in: .whitespaces)
        stem = String(stem.prefix(80))
        if stem.isEmpty { stem = "Narration" }
        // Same whitespace normalisation as the engine, so word counts line up chunk for chunk.
        let paragraphs = doc.paragraphs
            .map { $0.replacing(regex: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        script = Script(title: doc.isPDF ? (doc.name as NSString).deletingPathExtension : doc.name,
                        paragraphs: paragraphs, folder: folder, stem: stem, speed: speed)
        cleanupChunks()
        chunkDir = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-\(UUID().uuidString)")
        progress = GenerationProgress(label: "Warming up…")
        startJob(voiceID: voiceID, quality: effectiveQuality, startWord: 0, switching: false)
    }

    private func startJob(voiceID: String, quality: Quality, startWord: Int, switching: Bool) {
        guard let s = script, let root = chunkDir else { return }
        let rid = engine.reserveID()
        let j = Job(engineID: rid, voiceID: voiceID, quality: quality)
        job = j
        isGenerating = true
        let voice = Voice.named(voiceID)
        let label = voice.name + quality.suffix
        let outBase = (s.folder as NSString).appendingPathComponent("\(s.stem) – \(label)")
        // Each job its own folder: the old voice's files keep playing while the new one writes.
        let dir = root.appendingPathComponent(String(j.id.uuidString.prefix(8)))
        let t0 = Date()
        Task {
            do {
                let r = try await engine.call("narrate", [
                    "paragraphs": s.paragraphs, "voice": voice.id, "speed": s.speed, "fmt": format,
                    "out_base": outBase, "chunk_dir": dir.path, "quality": quality.rawValue, "start_word": startWord,
                ], id: rid) { p in
                    Task { @MainActor in self.handleGenerationEvent(p, job: j, switching: switching, startedAt: t0) }
                }
                guard job?.id == j.id else { return }       // superseded by another voice switch
                if voiceSwitch?.job == j.id { performSwitch(at: voiceSwitch?.armedWord ?? currentWord()) }
                job = nil
                isGenerating = false
                let words = (r["paragraphs"] as? [[[Any]]] ?? []).map { p in
                    p.compactMap { w -> TimedWord? in
                        guard w.count == 3, let t = w[0] as? String, let s = w[1] as? Double, let e = w[2] as? Double else { return nil }
                        return TimedWord(text: t, start: s, end: e)
                    }
                }
                let path = r["path"] as? String ?? outBase
                let n = Narration(path: path, name: (path as NSString).lastPathComponent, title: s.title,
                                  voice: label, duration: r["duration"] as? Double ?? 0, paragraphs: words,
                                  voiceID: voice.id, quality: quality)
                try? n.writeSidecar()
                narration = n
                if !showReader { try openReader(Timeline(narration: n)); cleanupChunks() }
                showToast("Saved \(n.name) — AirDrop it to your phone from the toolbar.", isError: false)
            } catch {
                guard job?.id == j.id else { return }       // a cancelled, superseded job: nothing to say
                job = nil
                isGenerating = false
                if voiceSwitch?.job == j.id { voiceSwitch = nil }
                if !showReader { cleanupChunks() }          // reader was closed mid-way; the engine has stopped now
                if let e = error as? Engine.Failure, e.cancelled {
                    showToast("Cancelled", isError: false)
                } else {
                    showToast((switching ? "Couldn't switch voices: " : "Generation failed: ") + error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func handleGenerationEvent(_ p: Engine.JSON, job j: Job, switching: Bool, startedAt: Date) {
        guard job?.id == j.id else { return }               // a job that's been replaced
        switch p["event"] as? String {
        case "plan":
            let chunks = (p["chunks"] as? [[String: Any]] ?? []).map {
                Timeline.Chunk(index: $0["index"] as? Int ?? 0, paragraph: $0["paragraph"] as? Int ?? 0,
                               wordOffset: $0["word_offset"] as? Int ?? 0, wordCount: $0["words"] as? Int ?? 0)
            }
            progress = GenerationProgress(label: nil, done: 0, total: chunks.count)
            if switching, let t = timeline {
                voiceSwitch = VoiceSwitch(job: j.id, chunks: chunks)
                // The listener may have moved on since the switch was asked for.
                engine.send("prioritize", ["chunk": Timeline.chunk(containingWord: t.wordIndex(at: player.currentTime), in: chunks)])
            } else if !showReader, let s = script {
                let t = Timeline(title: s.title, voiceID: j.voiceID, quality: j.quality,
                                 paragraphs: s.paragraphs.map { $0.components(separatedBy: " ") }, chunks: chunks, speed: s.speed)
                try? openReader(t)
            }
        case "chunk":
            guard let index = p["index"] as? Int, let path = p["path"] as? String else { return }
            let words = (p["words"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? (start: $0[0], end: $0[1]) : nil }
            let url = URL(fileURLWithPath: path), duration = p["duration"] as? Double ?? 0
            if var sw = voiceSwitch, sw.job == j.id {
                guard sw.chunks.indices.contains(index) else { return }
                sw.chunks[index].url = url; sw.chunks[index].duration = duration; sw.chunks[index].words = words
                voiceSwitch = sw
                trySwitch()
            } else if let t = timeline, t.chunks.indices.contains(index), !t.chunks[index].isReady {
                t.receive(index: index, url: url, duration: duration, words: words)
                player.chunkArrived(index)
            }
        default:
            if let label = p["label"] as? String { progress.label = label; return }
            let done = p["done"] as? Int ?? 0, total = p["total"] as? Int ?? 0
            let elapsed = Date().timeIntervalSince(startedAt)
            progress = GenerationProgress(label: nil, done: done, total: total, seconds: timeline?.duration ?? 0,
                                          eta: done > 0 ? elapsed / Double(done) * Double(total - done) : nil)
        }
    }

    // MARK: - Switching voices mid-book

    /// Change the voice while listening. The new voice is narrated from where the listener is (then
    /// the rest of the book, then the beginning), and takes over at the next natural break as soon as
    /// that part exists — the old voice carries on until then, so there's no pause and no restart.
    /// When it's done, the finished file is the new voice's.
    func switchVoice(to id: String, quality requested: Quality) {
        voiceID = id
        if requested != quality { setQuality(requested) }
        guard showReader, let t = timeline else { return }
        let q: Quality = requested == .high && hq.isReady ? .high : .standard
        if id == t.voiceID, q == t.quality {
            // Back to the voice that's already playing: drop the switch in progress.
            guard voiceSwitch != nil, let j = job else { return }
            cancel(j); job = nil; voiceSwitch = nil; isGenerating = false
            if !t.isComplete { startJob(voiceID: id, quality: q, startWord: currentWord(), switching: false) }
            return
        }
        if script == nil, let n = narration ?? lastNarration {
            // A reopened audiobook: narrate its own text again, saved next to it.
            let stem = (n.name as NSString).deletingPathExtension.components(separatedBy: " – ").first ?? n.title
            script = Script(title: n.title, paragraphs: t.paragraphs.map { $0.joined(separator: " ") },
                            folder: (n.path as NSString).deletingLastPathComponent, stem: stem, speed: speed)
        }
        guard script != nil else { return }
        if chunkDir == nil { chunkDir = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-\(UUID().uuidString)") }
        if let old = job { cancel(old) }
        if q == .standard, t.quality == .high { engine.send("hq_unload") }   // queued ahead of the new job: frees ~7 GB
        voiceSwitch = nil
        if narration != nil { lastNarration = narration }
        narration = nil                     // the finished file is the old voice; the new one is saved when done
        let start = currentWord()
        startJob(voiceID: id, quality: q, startWord: start, switching: true)
        log.info("switchVoice: → \(id, privacy: .public) \(q.rawValue, privacy: .public) from word \(start)")
    }
    /// The last finished file, kept so a reopened audiobook can still be re-voiced after a first switch.
    private var lastNarration: Narration?

    private func cancel(_ j: Job) { engine.send("cancel", ["target": j.engineID]) }

    private func currentWord() -> Int { timeline?.wordIndex(at: player.currentTime) ?? 0 }

    /// New audio arrived for a pending switch: arm it if the part the listener is in now exists.
    private func trySwitch() {
        guard var sw = voiceSwitch, sw.armedWord == nil, let t = timeline else { return }
        let words = t.words
        guard !words.isEmpty else { return }
        let g = currentWord()
        var target = g
        if player.isPlaying, !player.isWaiting {
            // The next breath — a word after punctuation — within a few seconds, else the next word.
            target = min(g + 1, words.count - 1)
            for i in (g + 1)..<min(words.count, g + 20) where words[i - 1].last.map({ ".,;:!?".contains($0) }) == true {
                target = i; break
            }
        }
        let k = Timeline.chunk(containingWord: target, in: sw.chunks)
        guard sw.chunks[k].isReady else { engine.send("prioritize", ["chunk": k]); return }
        sw.armedWord = target
        sw.armedTime = t.wordStarts()[target]
        voiceSwitch = sw
        switchTick()
    }

    /// Runs on the player's clock (30×/s) while a switch is armed.
    private func switchTick() {
        guard let sw = voiceSwitch, let target = sw.armedWord else { return }
        let now = player.currentTime
        if !player.isPlaying || player.isWaiting || abs(now - sw.armedTime) < 0.035 || (now > sw.armedTime && now - sw.armedTime < 0.5) {
            performSwitch(at: !player.isPlaying || player.isWaiting ? currentWord() : target)
        } else if now > sw.armedTime + 0.5 || now < sw.armedTime - 12 {
            // The listener jumped somewhere else: pick a new moment from there.
            voiceSwitch?.armedWord = nil
            trySwitch()
        }
    }

    private func performSwitch(at word: Int) {
        guard let sw = voiceSwitch, let t = timeline, let j = job, j.id == sw.job else { return }
        let k = Timeline.chunk(containingWord: word, in: sw.chunks)
        guard sw.chunks.indices.contains(k), sw.chunks[k].isReady else { return }
        voiceSwitch = nil
        t.adopt(voiceID: j.voiceID, quality: j.quality, chunks: sw.chunks)
        let starts = t.wordStarts()
        let at = starts.indices.contains(word) ? starts[word] : 0
        player.reload(at: max(0, at - 0.03))
        log.info("switchVoice: now speaking \(j.voiceID, privacy: .public) at word \(word)")
    }

    func cleanupChunks() {
        if let d = chunkDir { try? FileManager.default.removeItem(at: d) }
        chunkDir = nil
    }

    func cancelGeneration() {
        if let j = job { cancel(j) } else { engine.cancelCurrent() }
    }

    /// The listener skipped somewhere that isn't synthesized yet: make the engine go there next.
    private func prioritize(chunk: Int) {
        guard isGenerating else { return }
        if let sw = voiceSwitch, let t = timeline {
            // Still on the old voice: what matters is the new voice's chunk for that spot.
            let g = t.wordIndex(at: t.offsets.indices.contains(chunk) ? t.offsets[chunk] : 0)
            engine.send("prioritize", ["chunk": Timeline.chunk(containingWord: g, in: sw.chunks)])
            return
        }
        engine.send("prioritize", ["chunk": chunk])
    }

    // MARK: - Reader

    private func openReader(_ t: Timeline) throws {
        player.onNeedChunk = { [weak self] k in self?.prioritize(chunk: k) }
        player.onTick = { [weak self] in self?.switchTick() }
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
        if isGenerating { cancelGeneration() }
        voiceSwitch = nil
        showReader = false
        timeline = nil
        narration = nil
        lastNarration = nil
        script = nil
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
