import Foundation

// MARK: - Voices

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: String   // "US" | "UK"
    let gender: String   // "F" | "M"
    let grade: String    // Kokoro's published quality grade
    let note: String

    /// Curated English voices, ordered by Kokoro's quality grades (mirrors engine/narrate/tts.py).
    static let all: [Voice] = [
        Voice(id: "af_heart",    name: "Heart",    accent: "US", gender: "F", grade: "A",  note: "Warm, natural, the flagship voice"),
        Voice(id: "af_bella",    name: "Bella",    accent: "US", gender: "F", grade: "A-", note: "Bright and expressive"),
        Voice(id: "af_nicole",   name: "Nicole",   accent: "US", gender: "F", grade: "B-", note: "Soft, intimate, ASMR-like"),
        Voice(id: "bf_emma",     name: "Emma",     accent: "UK", gender: "F", grade: "B-", note: "Calm British narrator"),
        Voice(id: "af_aoede",    name: "Aoede",    accent: "US", gender: "F", grade: "C+", note: "Clear and even"),
        Voice(id: "af_kore",     name: "Kore",     accent: "US", gender: "F", grade: "C+", note: "Crisp, slightly formal"),
        Voice(id: "af_sarah",    name: "Sarah",    accent: "US", gender: "F", grade: "C+", note: "Friendly and light"),
        Voice(id: "am_fenrir",   name: "Fenrir",   accent: "US", gender: "M", grade: "C+", note: "Deep, steady"),
        Voice(id: "am_michael",  name: "Michael",  accent: "US", gender: "M", grade: "C+", note: "Neutral newsreader"),
        Voice(id: "am_puck",     name: "Puck",     accent: "US", gender: "M", grade: "C+", note: "Youthful, energetic"),
        Voice(id: "bf_isabella", name: "Isabella", accent: "UK", gender: "F", grade: "C",  note: "Measured British"),
        Voice(id: "bm_george",   name: "George",   accent: "UK", gender: "M", grade: "C",  note: "Classic British narrator"),
        Voice(id: "bm_fable",    name: "Fable",    accent: "UK", gender: "M", grade: "C",  note: "Storyteller tone"),
        Voice(id: "am_echo",     name: "Echo",     accent: "US", gender: "M", grade: "D",  note: "Relaxed baritone"),
        Voice(id: "bm_lewis",    name: "Lewis",    accent: "UK", gender: "M", grade: "D+", note: "Gruff, characterful"),
        Voice(id: "bm_daniel",   name: "Daniel",   accent: "UK", gender: "M", grade: "D",  note: "Low and quiet"),
    ]
    static func named(_ id: String) -> Voice { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Source document

/// A chapter (or any bookmark/heading) of a PDF and the pages it spans.
struct OutlineEntry: Identifiable, Equatable {
    let id: Int
    var title: String
    var level: Int              // 1 = top level
    var first: Int              // 1-based, inclusive
    var last: Int
    var pages: ClosedRange<Int> { first...max(first, last) }
}

struct SourceDocument: Equatable {
    var name: String
    var path: String?          // nil for pasted / captured text
    var pages: Int             // 0 when not a PDF
    var method: String?        // how a web capture got its text

    /// Pasted / captured text, already in paragraphs.
    private var text: [String] = []
    /// PDFs: cleaned text blocks per page (index 0 = page 1). Everything the file has, so any set of
    /// pages can be narrated without going back to the engine.
    private(set) var pageBlocks: [[String]] = []
    private var pageWords: [Int] = []
    var outline: [OutlineEntry] = []
    var outlineSource = "none"
    /// PDFs: the 1-based page numbers that will be narrated. Everything else in the file is ignored —
    /// the preview, the word count and the reader only ever see these pages.
    var selection = IndexSet()

    init(name: String, path: String?, pages: Int, paragraphs: [String], method: String?) {
        self.name = name; self.path = path; self.pages = pages; self.method = method
        text = paragraphs
    }

    init(pdfName name: String, path: String, pageBlocks: [[String]], outline: [OutlineEntry], outlineSource: String) {
        self.name = name; self.path = path; self.pages = pageBlocks.count
        self.pageBlocks = pageBlocks
        pageWords = pageBlocks.map { $0.reduce(0) { $0 + $1.split(separator: " ").count } }
        self.outline = outline; self.outlineSource = outlineSource
        selection = IndexSet(1...max(1, pages))
    }

    var isPDF: Bool { pages > 0 }

    /// The paragraphs that will be narrated.
    var paragraphs: [String] {
        guard isPDF else { return text }
        return Self.join(pageBlocks, pages: selection)
    }

    var words: Int {
        isPDF ? selection.reduce(0) { $0 + (pageWords.indices.contains($1 - 1) ? pageWords[$1 - 1] : 0) }
              : text.reduce(0) { $0 + $1.split(separator: " ").count }
    }

    var preview: String {
        guard isPDF else { return String(text.joined(separator: "\n\n").prefix(600)) }
        var out = ""
        for p in selection where pageBlocks.indices.contains(p - 1) {
            for b in pageBlocks[p - 1] {
                out += (out.isEmpty ? "" : "\n\n") + b
                if out.count > 600 { return String(out.prefix(600)) }
            }
        }
        return out
    }

    /// Blocks of the selected pages → paragraphs. A paragraph cut by a page break is re-joined, but
    /// only across pages that are both selected and adjacent (mirrors the engine's join_paragraphs).
    static func join(_ blocks: [[String]], pages: IndexSet) -> [String] {
        var out: [String] = []
        for range in pages.rangeView {
            var joinable = false
            for p in range where blocks.indices.contains(p - 1) {
                for b in blocks[p - 1] {
                    if joinable, let last = out.last, !last.hasSuffix(where: ".!?\":)"), let c = b.first, c.isLowercase {
                        out[out.count - 1] = last + " " + b
                    } else {
                        out.append(b)
                    }
                    joinable = true
                }
            }
        }
        return out
    }

    // MARK: Selection

    var selectedRanges: [ClosedRange<Int>] { selection.rangeView.map { $0.lowerBound...($0.upperBound - 1) } }
    var isEverythingSelected: Bool { selection.count == pages }

    /// "Pages 6–13, 24–50" / "All 300 pages" / "No pages selected".
    var selectionSummary: String {
        if selection.isEmpty { return "No pages selected" }
        if isEverythingSelected { return "All \(pages) pages" }
        return "Pages " + rangesText
    }

    /// The selection the way people type it: "6-13, 24-50".
    var rangesText: String {
        selectedRanges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            .joined(separator: ", ")
    }

    /// "6-13, 24-50" (or "6–13; 24 to 50", any separators) → pages, clamped to the document. nil when
    /// nothing in it parses.
    static func parseRanges(_ text: String, pages: Int) -> IndexSet? {
        var set = IndexSet()
        let parts = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        var any = false
        for part in parts {
            let nums = part.components(separatedBy: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { continue }
            let a = nums[0]!, b = nums.count > 1 ? nums.last!! : a
            let lo = max(1, min(a, b)), hi = min(pages, max(a, b))
            guard lo <= hi else { continue }
            set.insert(integersIn: lo...hi)
            any = true
        }
        return any ? set : nil
    }

    func isSelected(_ e: OutlineEntry) -> Bool { selection.contains(integersIn: e.pages) }
    func isPartlySelected(_ e: OutlineEntry) -> Bool { !isSelected(e) && selection.intersects(integersIn: e.pages) }

    mutating func setSelected(_ e: OutlineEntry, _ on: Bool) {
        if on { selection.insert(integersIn: e.pages) } else { selection.remove(integersIn: e.pages) }
    }
}

private extension String {
    func hasSuffix(where chars: String) -> Bool { last.map { chars.contains($0) } ?? false }
}

// MARK: - Finished narration (+ .narrate.json sidecar so audio files can be re-opened later)

struct TimedWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double

    init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }

    // Stored compactly as [text, start, end] to match the Python app's sidecar format.
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        text = try c.decode(String.self); start = try c.decode(Double.self); end = try c.decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(text); try c.encode(start); try c.encode(end)
    }
}

struct Narration: Codable, Equatable, Identifiable {
    var path: String
    var name: String
    var title: String
    var voice: String
    var duration: Double
    var paragraphs: [[TimedWord]]

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var sidecarURL: URL { URL(fileURLWithPath: (path as NSString).deletingPathExtension + ".narrate.json") }
    var fileSize: Int64 { (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0 }
    var format: String { (path as NSString).pathExtension.uppercased() }

    func writeSidecar() throws {
        try JSONEncoder().encode(self).write(to: sidecarURL)
    }

    static func load(sidecar: URL) throws -> Narration {
        let n = try JSONDecoder().decode(Narration.self, from: Data(contentsOf: sidecar))
        guard FileManager.default.fileExists(atPath: n.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: n.path])
        }
        return n
    }
}

// MARK: - Formatting helpers

enum Format {
    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = s % 3600 / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }
    static func bytes(_ b: Int64) -> String {
        b > 1_000_000 ? String(format: "%.1f MB", Double(b) / 1e6) : "\(b / 1000) KB"
    }
}

// MARK: - Streaming timeline

/// The narration as it is being synthesized: the full text is known from the start, audio arrives
/// one chunk at a time (in whatever order the listener asked for). Chunk start offsets are exact
/// for synthesized chunks and estimated from word counts for the rest, so the reader can already
/// place every word on a time axis and seek anywhere.
@Observable @MainActor
final class Timeline {
    struct Chunk {
        let index: Int
        let paragraph: Int
        let wordOffset: Int          // first word of this chunk within its paragraph
        let wordCount: Int
        var url: URL? = nil          // set once synthesized
        var duration: Double? = nil
        var words: [(start: Double, end: Double)] = []   // relative to chunk start
        var isReady: Bool { url != nil }
    }

    let id = UUID()
    let title: String
    let voice: String
    let paragraphs: [[String]]       // words per paragraph (whitespace-split, same as the engine's)
    private(set) var chunks: [Chunk]
    /// Bumped whenever timings change so views can resync cheaply.
    private(set) var version = 0
    private(set) var offsets: [Double] = []      // chunk start times
    private(set) var duration: Double = 0
    private var secondsPerWord: Double

    init(title: String, voice: String, paragraphs: [[String]], chunks: [Chunk], speed: Double) {
        self.title = title; self.voice = voice; self.paragraphs = paragraphs; self.chunks = chunks
        secondsPerWord = 0.36 / speed
        relayout()
    }

    /// A finished narration (one audio file, exact timings) as a single-chunk timeline.
    convenience init(narration n: Narration) {
        let paras = n.paragraphs.map { $0.map(\.text) }
        var chunk = Chunk(index: 0, paragraph: 0, wordOffset: 0, wordCount: paras.reduce(0) { $0 + $1.count })
        chunk.url = n.url; chunk.duration = n.duration
        chunk.words = n.paragraphs.flatMap { $0.map { (start: $0.start, end: $0.end) } }
        self.init(title: n.title, voice: n.voice, paragraphs: paras, chunks: [chunk], speed: 1)
        singleFile = true
    }
    private(set) var singleFile = false

    var readyCount: Int { chunks.filter(\.isReady).count }
    var isComplete: Bool { readyCount == chunks.count }

    func receive(index: Int, url: URL, duration: Double, words: [(start: Double, end: Double)]) {
        guard chunks.indices.contains(index) else { return }
        chunks[index].url = url; chunks[index].duration = duration; chunks[index].words = words
        let known = chunks.filter(\.isReady)
        let w = known.reduce(0) { $0 + $1.wordCount }
        if w > 20 { secondsPerWord = known.reduce(0) { $0 + ($1.duration ?? 0) } / Double(w) }
        relayout()
    }

    private func relayout() {
        var t = 0.0
        offsets = chunks.map { c in
            let start = t
            t += c.duration ?? Double(c.wordCount) * secondsPerWord
            return start
        }
        duration = t
        version += 1
    }

    func estimatedDuration(of c: Chunk) -> Double { c.duration ?? Double(c.wordCount) * secondsPerWord }

    /// Which chunk a time falls in, and how far into it.
    func locate(_ time: Double) -> (chunk: Int, within: Double) {
        var lo = 0, hi = chunks.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= time { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (ans, max(0, time - offsets[ans]))
    }

    /// Absolute start time of every word, flattened in reading order. Unsynthesized chunks spread
    /// their words evenly across the chunk's estimated duration.
    func wordStarts() -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(paragraphs.reduce(0) { $0 + $1.count })
        // Chunks are in reading order already (paragraph, wordOffset ascending).
        for c in chunks {
            let base = offsets[c.index]
            if c.isReady, c.words.count == c.wordCount {
                out += c.words.map { base + $0.start }
            } else {
                let step = estimatedDuration(of: c) / Double(max(1, c.wordCount))
                out += (0..<c.wordCount).map { base + Double($0) * step }
            }
        }
        return out
    }
}
