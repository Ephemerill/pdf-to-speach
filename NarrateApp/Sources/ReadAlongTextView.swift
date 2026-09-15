import AppKit
import SwiftUI

/// Book-style text with the spoken word highlighted. Built on NSTextView so a whole book stays
/// cheap to render: the text is laid out once, and only the ranges that change get re-attributed.
///
/// Scrolling: the view follows the narration, but the moment you scroll it stops following and
/// lets you read ahead or back. It picks the narration up again when the spoken word scrolls back
/// into view, or when you click a word / seek.
struct ReadAlongTextView: NSViewRepresentable {
    let timeline: Timeline
    let timelineVersion: Int
    let currentTime: Double
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

        private var ranges: [NSRange] = []       // one per word, reading order
        private var starts: [Double] = []
        private var current = -1
        private var follow = true
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
            ranges.removeAll(keepingCapacity: true)

            let body = NSMutableAttributedString()
            let headStyle = NSMutableParagraphStyle()
            headStyle.paragraphSpacing = 22
            body.append(NSAttributedString(string: t.title.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.4, .paragraphStyle: headStyle,
            ]))
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineHeightMultiple = 1.32
            paraStyle.paragraphSpacing = 15
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: Self.baseColor, .paragraphStyle: paraStyle]
            for para in t.paragraphs where !para.isEmpty {
                for (wi, w) in para.enumerated() {
                    let loc = body.length
                    body.append(NSAttributedString(string: w, attributes: attrs))
                    ranges.append(NSRange(location: loc, length: body.length - loc))
                    body.append(NSAttributedString(string: wi == para.count - 1 ? "\n" : " ", attributes: attrs))
                }
            }
            // Room to keep the last lines up where the eye is while they're being read.
            let tail = NSMutableParagraphStyle(); tail.paragraphSpacingBefore = 320
            body.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: tail, .font: Self.bodyFont]))
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

        /// Keep the column readable: centre it and cap its measure on wide windows.
        @objc func frameChanged() {
            guard let tv = textView else { return }
            let inset = max(44, (tv.bounds.width - 720) / 2)
            if abs(tv.textContainerInset.width - inset) > 0.5 {
                tv.textContainerInset = NSSize(width: inset, height: 40)
            }
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
            if i > current {
                for k in max(0, current)..<i { storage.addAttribute(.foregroundColor, value: Self.doneColor, range: ranges[k]) }
            } else if i < current {
                for k in max(0, i)...current { storage.addAttribute(.foregroundColor, value: Self.baseColor, range: ranges[k]) }
            }
            if i >= 0 {
                storage.addAttributes([.backgroundColor: Self.highlight, .foregroundColor: Self.baseColor], range: ranges[i])
            }
            storage.endEditing()
            current = i
            if i >= 0 {
                if jumped { follow = true }
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

        private func keepVisible(_ range: NSRange) {
            guard let scroll = scrollView, let tv = textView, let rect = wordRect(range) else { return }
            let visible = scroll.contentView.bounds
            if !follow {
                // The reader scrolled away. Resume once the spoken word is back in view.
                if rect.minY >= visible.minY, rect.maxY <= visible.maxY { follow = true } else { return }
            }
            let top = visible.minY + 80, bottom = visible.maxY - 150
            if rect.minY < top || rect.maxY > bottom {
                let target = max(0, min(rect.minY - visible.height * 0.38, tv.bounds.height - visible.height))
                animateScroll(to: target)
            }
        }

        private func animateScroll(to y: CGFloat) {
            guard let scroll = scrollView else { return }
            scrollAnimation?.invalidate()
            let from = scroll.contentView.bounds.origin.y
            let start = Date()
            let duration = 0.35
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
                    }
                }
            }
        }

        func userScrolled() {
            scrollAnimation?.invalidate(); scrollAnimation = nil
            follow = false
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
