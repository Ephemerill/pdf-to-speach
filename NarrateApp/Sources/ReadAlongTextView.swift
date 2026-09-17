import AppKit
import SwiftUI

/// Book-style text with the spoken word highlighted. Built on NSTextView so a whole book stays
/// cheap to render: the text is laid out once, and only the ranges that change get re-attributed.
///
/// Scrolling: the view follows the narration, but the moment you scroll it stops following and
/// lets you read ahead or back. It picks the narration up again after ten seconds without a
/// scroll (and only while something is playing), or at once when you click a word / seek.
struct ReadAlongTextView: NSViewRepresentable {
    let timeline: Timeline
    let timelineVersion: Int
    let currentTime: Double
    let isPlaying: Bool
    let bottomInset: CGFloat          // space under the text for the floating player bar
    let onWordTap: (Double) -> Void
    let onPlayerKey: (ReaderTextView.PlayerKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = ReaderTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)  // grow with the text
        tv.autoresizingMask = .width
        tv.textContainerInset = NSSize(width: 48, height: 40)
        tv.postsFrameChangedNotifications = true
        tv.onWordTap = { [weak coord = context.coordinator] idx in coord?.tapped(charIndex: idx) }
        tv.onPlayerKey = onPlayerKey

        let scroll = FollowScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scroll.onUserScroll = { [weak coord = context.coordinator] in coord?.userScrolled() }

        let c = context.coordinator
        c.textView = tv
        c.scrollView = scroll
        c.onWordTap = onWordTap
        c.load(timeline)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: tv)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.liveScroll),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onWordTap = onWordTap
        c.textView?.onPlayerKey = onPlayerKey
        c.isPlaying = isPlaying
        if c.timelineID != timeline.id { c.load(timeline) }
        else if c.version != timelineVersion { c.refreshTimings(timeline) }
        c.highlight(time: currentTime)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var textView: ReaderTextView?
        weak var scrollView: FollowScrollView?
        var onWordTap: ((Double) -> Void)?
        var timelineID: UUID?
        var version = -1
        var isPlaying = false
        /// How long the reader gets to look around after scrolling before the view goes back to the narration.
        static let idleBeforeFollowing: TimeInterval = 10

        private var ranges: [NSRange] = []       // one per word, reading order
        private var starts: [Double] = []
        private var current = -1
        private var follow = true
        private var resumeFollow: DispatchWorkItem?
        private var scrollAnimation: Timer?

        static let bodyFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 18.5)
            let d = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return NSFont(descriptor: d, size: 18.5) ?? base
        }()
        static let baseColor = NSColor.labelColor
        static let doneColor = NSColor.secondaryLabelColor
        static let highlight = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.systemOrange.withAlphaComponent(0.6) : NSColor.systemYellow.withAlphaComponent(0.55)
        }

        func load(_ t: Timeline) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            timelineID = t.id
            current = -1
            follow = true
            resumeFollow?.cancel(); resumeFollow = nil
            ranges.removeAll(keepingCapacity: true)

            // One string, one attribute run: a whole book builds in milliseconds this way, where
            // appending an attributed string per word took seconds and stalled the window.
            let head = t.title.uppercased() + "\n"
            var text = head
            text.reserveCapacity(t.paragraphs.reduce(0) { $0 + $1.count * 7 })
            var utf16 = (head as NSString).length
            for para in t.paragraphs where !para.isEmpty {
                for (wi, w) in para.enumerated() {
                    let len = (w as NSString).length
                    ranges.append(NSRange(location: utf16, length: len))
                    text += w
                    text += wi == para.count - 1 ? "\n" : " "
                    utf16 += len + 1
                }
            }
            text += "\n"
            let headStyle = NSMutableParagraphStyle()
            headStyle.paragraphSpacing = 22
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineHeightMultiple = 1.32
            paraStyle.paragraphSpacing = 15
            let tail = NSMutableParagraphStyle(); tail.paragraphSpacingBefore = 320   // keeps the last lines up where the eye is
            let body = NSMutableAttributedString(string: text, attributes: [
                .font: Self.bodyFont, .foregroundColor: Self.baseColor, .paragraphStyle: paraStyle,
            ])
            body.setAttributes([
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.4, .paragraphStyle: headStyle,
            ], range: NSRange(location: 0, length: (head as NSString).length))
            body.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: body.length - 1, length: 1))
            storage.setAttributedString(body)
            refreshTimings(t)
            scrollView?.contentView.scroll(to: .zero)
            scrollView?.reflectScrolledClipView(scrollView!.contentView)
            frameChanged()
        }

        func refreshTimings(_ t: Timeline) {
            version = t.version
            starts = t.wordStarts()
            if starts.count != ranges.count {     // shouldn't happen; keep the arrays consistent anyway
                starts = Array(starts.prefix(ranges.count)) + Array(repeating: .greatestFiniteMagnitude, count: max(0, ranges.count - starts.count))
            }
        }

        private var insetUpdate: DispatchWorkItem?

        /// Keep the column readable: centre it and cap its measure on wide windows. Changing the inset
        /// relays out the whole text, so during a live resize it waits for the frames to settle.
        @objc func frameChanged() {
            guard let tv = textView else { return }
            let inset = max(44, (tv.bounds.width - 720) / 2)
            guard abs(tv.textContainerInset.width - inset) > 0.5 else { return }
            insetUpdate?.cancel()
            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                let inset = max(44, (tv.bounds.width - 720) / 2)
                if abs(tv.textContainerInset.width - inset) > 0.5 {
                    tv.textContainerInset = NSSize(width: inset, height: 40)
                    // Layout starts over: put the spoken word back where it was.
                    if self.current >= 0, self.follow { self.keepVisible(self.ranges[self.current], force: true) }
                }
            }
            insetUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (tv.textStorage?.length ?? 0 > 200_000 ? 0.25 : 0.08), execute: work)
        }

        private func index(for t: Double) -> Int {   // binary search on start times
            var lo = 0, hi = starts.count - 1, ans = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return ans
        }

        func highlight(time t: Double) {
            guard let tv = textView, let storage = tv.textStorage, !ranges.isEmpty else { return }
            let i = index(for: t)
            guard i != current else { return }
            let jumped = current >= 0 && abs(i - current) > 1     // a seek / click, not the narration advancing
            storage.beginEditing()
            if current >= 0 { storage.removeAttribute(.backgroundColor, range: ranges[current]) }
            // The spaces between words are recoloured too, which is invisible — and it makes a seek
            // across the whole book one attribute run instead of one edit per word.
            if i > current {
                let from = ranges[max(0, current)].location
                storage.addAttribute(.foregroundColor, value: Self.doneColor, range: NSRange(location: from, length: ranges[i].location - from))
            } else if i < current {
                let from = ranges[max(0, i)].location
                storage.addAttribute(.foregroundColor, value: Self.baseColor, range: NSRange(location: from, length: NSMaxRange(ranges[current]) - from))
            }
            if i >= 0 {
                storage.addAttributes([.backgroundColor: Self.highlight, .foregroundColor: Self.baseColor], range: ranges[i])
            }
            storage.endEditing()
            current = i
            if i >= 0 {
                if jumped { follow = true; resumeFollow?.cancel(); resumeFollow = nil }
                keepVisible(ranges[i])
            }
        }

        // MARK: Following

        private func wordRect(_ range: NSRange) -> NSRect? {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y
            return rect
        }

        private var scrollTarget: CGFloat?

        private func keepVisible(_ range: NSRange, force: Bool = false) {
            guard let scroll = scrollView, let tv = textView, let rect = wordRect(range),
                  rect.height > 0, rect.height < 400, rect.origin.y.isFinite else { return }   // not laid out yet
            let visible = scroll.contentView.bounds
            guard follow else { return }          // the reader scrolled away; the idle timer brings us back
            let top = visible.minY + 80, bottom = visible.maxY - 150
            guard force || rect.minY < top || rect.maxY > bottom else { return }
            // While a big document is still being laid out its frame lags behind the text, so the
            // clamp trusts the word's own position over the frame height.
            let docHeight = max(tv.bounds.height, rect.maxY + 400)
            let target = max(0, min(rect.minY - visible.height * 0.38, docHeight - visible.height))
            // Already gliding to a spot that shows this word comfortably? Let it finish.
            if let t = scrollTarget, scrollAnimation != nil, rect.minY >= t + 80, rect.maxY <= t + visible.height - 150 { return }
            animateScroll(to: target)
        }

        private func animateScroll(to y: CGFloat) {
            guard let scroll = scrollView else { return }
            scrollAnimation?.invalidate()
            scrollTarget = y
            let from = scroll.contentView.bounds.origin.y
            if abs(from - y) < 1 { scrollTarget = nil; return }
            let start = Date()
            let duration = min(0.5, 0.25 + Double(abs(from - y)) / 4000)   // long jumps take a touch longer
            scrollAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak scroll] timer in
                Task { @MainActor in
                    guard let scroll else { timer.invalidate(); return }
                    let p = min(1, Date().timeIntervalSince(start) / duration)
                    let eased = 1 - pow(1 - p, 3)
                    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: from + (y - from) * eased))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if p >= 1 {
                        timer.invalidate()
                        self?.scrollAnimation = nil
                        self?.scrollTarget = nil
                    }
                }
            }
        }

        func userScrolled() {
            scrollAnimation?.invalidate(); scrollAnimation = nil; scrollTarget = nil
            follow = false
            // Every scroll restarts the clock; after ten quiet seconds the narration takes over again
            // — but only if it's playing, so a paused reader stays where you left it.
            resumeFollow?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.follow = true
                if self.isPlaying, self.current >= 0 { self.keepVisible(self.ranges[self.current]) }
            }
            resumeFollow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleBeforeFollowing, execute: work)
        }

        @objc func liveScroll() { userScrolled() }

        func tapped(charIndex: Int) {
            // Find the word whose range contains (or immediately precedes) the click.
            var lo = 0, hi = ranges.count - 1, ans = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if ranges[mid].location <= charIndex { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            guard ans >= 0, charIndex < NSMaxRange(ranges[ans]) + 1 else { return }
            resumeFollow?.cancel(); resumeFollow = nil
            follow = true
            onWordTap?(starts[ans])
        }
    }
}

/// Reports scroll gestures so auto-follow can step aside.
final class FollowScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

/// A non-editable text view that reports single clicks (not drags/selections) as word taps.
final class ReaderTextView: NSTextView {
    var onWordTap: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let before = selectedRange()
        super.mouseDown(with: event)      // runs the tracking loop; returns on mouse up
        let after = selectedRange()
        guard event.clickCount == 1, after.length == 0, before.length == 0 || after != before else { return }
        let p = convert(event.locationInWindow, from: nil)
        onWordTap?(characterIndexForInsertion(at: p))
    }

    /// Player keys. SwiftUI's shortcuts normally catch these first; this is the fallback when the
    /// text view is first responder, so space never page-scrolls the text instead of pausing.
    var onPlayerKey: ((PlayerKey) -> Void)?
    enum PlayerKey { case playPause, back, forward, previousParagraph, nextParagraph }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: onPlayerKey?(.playPause)              // space
        case 123: onPlayerKey?(.back)                  // ←
        case 124: onPlayerKey?(.forward)               // →
        case 126: onPlayerKey?(.previousParagraph)     // ↑
        case 125: onPlayerKey?(.nextParagraph)         // ↓
        default: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
