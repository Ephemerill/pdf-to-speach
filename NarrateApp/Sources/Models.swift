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

struct SourceDocument: Equatable {
    var name: String
    var path: String?          // nil for pasted / captured text
    var pages: Int             // 0 when not a PDF
    var paragraphs: [String]
    var method: String?        // how a web capture got its text

    var words: Int { paragraphs.reduce(0) { $0 + $1.split(separator: " ").count } }
    var preview: String { String(paragraphs.joined(separator: "\n\n").prefix(600)) }
    var isPDF: Bool { pages > 0 }
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
