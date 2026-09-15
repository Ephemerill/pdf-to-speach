import AVFoundation
import Foundation
import Observation

/// Plays a `Timeline`: chunk audio files queued back to back, starting as soon as the first one
/// exists. Seeking into a chunk that isn't synthesized yet parks the player ("waiting") and asks
/// the engine for that chunk via `onNeedChunk`. Rates above 2× work because this is AVPlayer
/// with a time-domain pitch algorithm, not AVAudioPlayer.
@Observable @MainActor
final class Player {
    private(set) var isPlaying = false
    private(set) var isWaiting = false          // wants to play but the next chunk isn't ready yet
    private(set) var currentTime: Double = 0
    private(set) var currentChunk = 0
    var duration: Double { timeline?.duration ?? 0 }
    var rate: Float = 1 {
        didSet { if isPlaying, !isWaiting { queue.rate = rate } }
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The app hooks this up to `prioritize` on the engine.
    var onNeedChunk: ((Int) -> Void)?

    private(set) var timeline: Timeline?
    private let queue = AVQueuePlayer()
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var itemChunk: [ObjectIdentifier: Int] = [:]
    private var queuedThrough = -1               // highest chunk index currently in the queue
    private var pendingSeek: (chunk: Int, within: Double)?

    init() {
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = false
        timeObserver = queue.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        itemObserver = queue.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemChanged() }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.itemEnded(n.object as? AVPlayerItem) }
        }
    }

    // MARK: - Loading

    func load(_ t: Timeline) {
        stop()
        timeline = t
        currentChunk = 0
        currentTime = 0
    }

    func stop() {
        queue.pause()
        queue.removeAllItems()
        itemChunk.removeAll()
        queuedThrough = -1
        pendingSeek = nil
        isPlaying = false; isWaiting = false
        timeline = nil
        currentTime = 0; currentChunk = 0
    }

    /// Called when chunk `index` has been synthesized.
    func chunkArrived(_ index: Int) {
        guard let t = timeline else { return }
        if let seek = pendingSeek, seek.chunk == index {
            pendingSeek = nil
            enqueue(from: index, seekWithin: seek.within)
            if isWaiting { isWaiting = false; if isPlaying { queue.rate = rate } }
            return
        }
        // Extend the queue if this is the next contiguous chunk after what's queued.
        if index == queuedThrough + 1 {
            var i = index
            while i < t.chunks.count, t.chunks[i].isReady { append(chunk: i); i += 1 }
            if isWaiting { isWaiting = false; if isPlaying { queue.rate = rate } }
        }
    }

    // MARK: - Transport

    func play() {
        guard let t = timeline, !t.chunks.isEmpty else { return }
        isPlaying = true
        if queue.items().isEmpty {
            // Nothing queued: either fresh, or we drained. Start from the current chunk if it's ready.
            let start = pendingSeek?.chunk ?? currentChunk
            if t.chunks[start].isReady, pendingSeek == nil {
                enqueue(from: start, seekWithin: 0)
            } else {
                isWaiting = true
                onNeedChunk?(start)
                return
            }
        }
        isWaiting = false
        queue.rate = rate
    }

    func pause() {
        queue.pause()
        isPlaying = false
        isWaiting = false
        tick()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        guard let t = timeline else { return }
        let (k, within) = t.locate(max(0, min(time, max(0, t.duration - 0.05))))
        currentTime = time
        if t.chunks[k].isReady {
            pendingSeek = nil
            if let item = queue.currentItem, itemChunk[ObjectIdentifier(item)] == k {
                item.seek(to: CMTime(seconds: within, preferredTimescale: 1000), completionHandler: nil)
            } else {
                enqueue(from: k, seekWithin: within)
            }
            if isPlaying { isWaiting = false; queue.rate = rate }
        } else {
            // Park here; the engine is asked to synthesize this chunk next.
            queue.pause()
            queue.removeAllItems(); itemChunk.removeAll(); queuedThrough = -1
            currentChunk = k
            pendingSeek = (k, within)
            isWaiting = isPlaying
            onNeedChunk?(k)
        }
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    // MARK: - Queue plumbing

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain     // speech-friendly, allows rates well past 2×
        return item
    }

    private func append(chunk i: Int) {
        guard let url = timeline?.chunks[i].url else { return }
        let item = makeItem(url)
        itemChunk[ObjectIdentifier(item)] = i
        queue.insert(item, after: nil)
        queuedThrough = i
    }

    private func enqueue(from k: Int, seekWithin: Double) {
        guard let t = timeline else { return }
        queue.pause()
        queue.removeAllItems(); itemChunk.removeAll(); queuedThrough = k - 1
        var i = k
        while i < t.chunks.count, t.chunks[i].isReady { append(chunk: i); i += 1 }
        currentChunk = k
        if seekWithin > 0, let item = queue.currentItem {
            item.seek(to: CMTime(seconds: seekWithin, preferredTimescale: 1000), completionHandler: nil)
        }
        if isPlaying, !isWaiting { queue.rate = rate }
    }

    private func itemChanged() {
        guard let item = queue.currentItem, let k = itemChunk[ObjectIdentifier(item)] else { return }
        currentChunk = k
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, let k = itemChunk[ObjectIdentifier(item)], let t = timeline else { return }
        itemChunk[ObjectIdentifier(item)] = nil
        // AVQueuePlayer advances by itself when a next item is queued. Only act when it ran dry.
        guard queue.currentItem == nil || queue.currentItem === item else { return }
        let next = k + 1
        if next >= t.chunks.count {
            isPlaying = false; isWaiting = false
            currentChunk = k
            currentTime = t.duration
        } else if t.chunks[next].isReady {
            enqueue(from: next, seekWithin: 0)
        } else {
            currentChunk = next
            isWaiting = true
            onNeedChunk?(next)
        }
    }

    private func tick() {
        guard let t = timeline, pendingSeek == nil else { return }   // parked on a seek: keep showing its target
        if let item = queue.currentItem, let k = itemChunk[ObjectIdentifier(item)], t.offsets.indices.contains(k) {
            let within = item.currentTime().seconds
            if within.isFinite { currentTime = t.offsets[k] + within }
        }
    }
}

/// Plays voice samples; independent of the main player so previews never interrupt reading.
@Observable @MainActor
final class SamplePlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    private var audio: AVAudioPlayer?

    /// Samples are rendered once at 1× and time-stretched here, so previews are instant at any speed.
    func play(url: URL, id: String, rate: Double = 1) throws {
        audio?.stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.enableRate = true
        p.rate = Float(min(2, max(0.5, rate)))
        p.play()
        audio = p
        playingID = id
    }

    func stop() {
        audio?.stop(); audio = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}
