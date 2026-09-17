import AppKit
import Foundation
import Vision
import WebKit

/// Reads text out of a live page in the built-in browser window.
///
/// Strategy, in order:
///   1. Page-scan images (JSTOR-style viewers): fetch each page image → OCR with column-aware ordering.
///   2. The article's text (Article.swift's Reader-style extractor), when the page has a real text body.
///   3. Scroll the page and screenshot the viewport step by step → OCR (works on anything visible).
/// OCR runs on macOS's built-in Vision framework, so nothing extra is downloaded.
enum Capture {
    struct Result { var title: String; var paragraphs: [String]; var method: String }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: - Driver

    @MainActor
    static func run(_ web: WKWebView, progress: @escaping (String, Double) -> Void) async throws -> Result {
        let title = cleanTitle((try await eval(web, "document.title") as? String) ?? "Web page")
        guard let dims = try await eval(web, JS.scroller) as? [String: Any] else { throw Failure(message: "The page did not respond.") }
        let h = (dims["h"] as? NSNumber)?.intValue ?? 0, ch = (dims["ch"] as? NSNumber)?.intValue ?? 0
        let hasPages = ((dims["pages"] as? NSNumber)?.intValue ?? 0) > 0
        let step = max(200, Int(Double(ch) * (hasPages ? 0.6 : 0.85)))
        var positions = Array(stride(from: 0, to: max(1, h - ch + 1), by: step)) + [max(0, h - ch)]
        positions = Array(Set(positions)).sorted()

        // Pass 1: scroll through everything (triggers lazy loading), collect page images and viewport shots.
        var shots: [CGImage] = []
        for (i, y) in positions.enumerated() {
            _ = try await eval(web, String(format: JS.scrollTo, y))
            try await Task.sleep(for: .milliseconds(i == 0 || hasPages ? 900 : 450))   // lazy viewers need time to paint
            _ = try await eval(web, JS.collectImages)
            if !hasPages { shots.append(try await snapshot(web)) }
            progress("Scanning page… \(i + 1)/\(positions.count)", 0.3 * Double(i + 1) / Double(positions.count))
        }
        if hasPages {
            _ = try await eval(web, String(format: JS.scrollTo, 0))
            try await Task.sleep(for: .milliseconds(1200))
            _ = try await eval(web, JS.collectImages)
        }
        let nImages = (try await eval(web, "window.__narrate.imgs.size") as? NSNumber)?.intValue ?? 0
        if nImages > 0 && !hasPages { _ = try await eval(web, JS.scroller) }   // pages appeared during the scroll: rescan

        // Strategy 1: page images.
        if nImages >= 1 {
            let dataURLs = ((try await eval(web, JS.fetchImages, isAsync: true, timeout: 300)) as? [Any] ?? []).compactMap { $0 as? String }
            let images = dataURLs.compactMap(decodeDataURL)
            if !images.isEmpty {
                var paras: [String] = []
                for (i, img) in images.enumerated() {
                    let lines = try await Task.detached { try ocr(img) }.value
                    paras += linesToParagraphs(lines)
                    progress("Reading page scans… \(i + 1)/\(images.count)", 0.3 + 0.7 * Double(i + 1) / Double(images.count))
                }
                if wordCount(paras) >= 80 { return Result(title: title, paragraphs: mergePageBreaks(paras), method: "page images") }
            }
        }

        // Strategy 2: the article's own text — the Reader-style extractor first, then the crude
        // innerText of the main region for pages it can't make sense of.
        if let a = try await Article.extract(web), a.words >= 200 {
            progress("Reading article text…", 1)
            return Result(title: a.title, paragraphs: a.spokenParagraphs, method: "article text")
        }
        let dom = (try await eval(web, JS.domText) as? [String: Any]) ?? [:]
        let domParas = textToParagraphs(dom["text"] as? String ?? "")
        if wordCount(domParas) >= 200 {
            progress("Reading article text…", 1)
            return Result(title: cleanTitle(dom["title"] as? String ?? title), paragraphs: domParas, method: "page text")
        }

        // Strategy 3: OCR the viewport screenshots, de-duplicating the overlap between frames.
        if shots.isEmpty {
            for y in positions {
                _ = try await eval(web, String(format: JS.scrollTo, y))
                try await Task.sleep(for: .milliseconds(500))
                shots.append(try await snapshot(web))
            }
        }
        var paras: [String] = []
        var seen = Set<String>()
        for (i, shot) in shots.enumerated() {
            var lines = try await Task.detached { try ocr(shot) }.value
            // drop lines touching the frame edge (they may be cut); overlap guarantees they appear intact elsewhere
            lines = lines.filter { $0.y > 0.01 && ($0.y + $0.h) < 0.99 }
            var fresh: [Line] = []
            for l in lines {
                let key = norm(l.text)
                if !key.isEmpty, !seen.contains(key) { seen.insert(key); fresh.append(l) }
            }
            paras += linesToParagraphs(fresh)
            progress("Reading screen… \(i + 1)/\(shots.count)", 0.3 + 0.7 * Double(i + 1) / Double(shots.count))
        }
        return Result(title: title, paragraphs: mergePageBreaks(paras), method: "screen OCR")
    }

    // MARK: - WebKit helpers

    /// Evaluate a JS expression; the result comes back through JSON so any structure survives the bridge.
    @MainActor
    static func eval(_ web: WKWebView, _ script: String, isAsync: Bool = false, timeout: Double = 120) async throws -> Any? {
        let json: Any? = try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                if isAsync {
                    web.callAsyncJavaScript("return JSON.stringify(await (\(script)));", arguments: [:], in: nil, in: .page) { result in
                        switch result {
                        case .success(let r): cont.resume(returning: r)
                        case .failure(let e): cont.resume(throwing: Failure(message: "page script error: \(e.localizedDescription)"))
                        }
                    }
                } else {
                    web.evaluateJavaScript("JSON.stringify(\(script))") { r, e in
                        if let e { cont.resume(throwing: Failure(message: "page script error: \(e.localizedDescription)")) }
                        else { cont.resume(returning: r) }
                    }
                }
            }
        }
        guard let s = json as? String, let data = s.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    @MainActor
    static func snapshot(_ web: WKWebView) async throws -> CGImage {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            web.takeSnapshot(with: cfg) { img, err in
                if let img { cont.resume(returning: img) } else { cont.resume(throwing: Failure(message: err?.localizedDescription ?? "snapshot failed")) }
            }
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure(message: "snapshot failed") }
        return cg
    }

    @MainActor
    static func withTimeout<T>(_ seconds: Double, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await op() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw Failure(message: "the page did not respond") }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    static func decodeDataURL(_ s: String) -> CGImage? {
        guard let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - OCR

    struct Line {
        var text: String
        var x0: Double, x1: Double
        var y: Double      // top, 0 at top of image
        var h: Double
    }

    static func cleanOCRText(_ t: String) -> String {
        var s = t
        for (a, b) in [("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{00AD}", "-"), ("\u{2012}", "-")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.trimmingCharacters(in: .whitespaces)
        s = s.replacing(regex: #"(?<=[\w.,;:!?"')\]])[®°†‡§¶]+"#, with: "")          // superscript footnote marks read as symbols
        s = s.replacing(regex: #"(?<=[a-z])\s?['’]\s(?=[a-z])"#, with: "'")          // apostrophes split by spacing
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func recognize(_ handler: VNImageRequestHandler, roi: CGRect? = nil) throws -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if let roi { req.regionOfInterest = roi }
        try handler.perform([req])
        var lines: [Line] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cleanOCRText(cand.string)
            if text.isEmpty { continue }
            var b = obs.boundingBox   // normalised, origin bottom-left (relative to the ROI when one is set)
            if let roi {
                b = CGRect(x: roi.origin.x + b.origin.x * roi.width, y: roi.origin.y + b.origin.y * roi.height,
                           width: b.width * roi.width, height: b.height * roi.height)
            }
            lines.append(Line(text: text, x0: b.minX, x1: b.maxX, y: 1 - b.maxY, h: b.height))
        }
        return lines
    }

    static func ocr(_ image: CGImage) throws -> [Line] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let lines = try recognize(handler)
        if lines.count < 6 { return lines }
        // Drop caps make Vision merge two lines into one garbled observation. Re-read the text
        // to the right of the big initial and keep the initial letter itself.
        let medH = median(lines.map(\.h))
        let aspect = image.height > 0 ? Double(image.width) / Double(image.height) : 0.7
        var fixed: [Line] = []
        for l in lines {
            if l.h > 1.6 * medH, (l.x1 - l.x0) > 0.25, l.y > 0.05 {
                let capW = l.h / aspect * 0.95                          // a drop cap is roughly square in pixels
                let roi = CGRect(x: l.x0 + capW, y: 1 - (l.y + l.h), width: max(0.05, l.x1 - l.x0 - capW), height: l.h)
                let sub = try recognize(handler, roi: roi).sorted { $0.y < $1.y }
                if sub.count >= 2 {
                    let initial = l.text.first.map { $0.isLetter ? String($0) : "" } ?? ""
                    var s = sub
                    s[0] = Line(text: initial + s[0].text, x0: l.x0, x1: s[0].x1, y: s[0].y, h: s[0].h)
                    fixed += s
                    continue
                }
            }
            fixed.append(l)
        }
        return dedupeFragments(fixed)
    }

    /// Vision sometimes emits a fragment of a line as a second observation; drop such duplicates.
    static func dedupeFragments(_ lines: [Line]) -> [Line] {
        var keep: [Line] = []
        for l in lines.sorted(by: { ($0.x1 - $0.x0) > ($1.x1 - $1.x0) }) {
            let nl = norm(l.text)
            let dup = keep.contains { k in
                let overlap = min(l.y + l.h, k.y + k.h) - max(l.y, k.y)
                return overlap > 0.5 * min(l.h, k.h) && l.x0 < k.x1 && k.x0 < l.x1 && !nl.isEmpty && norm(k.text).contains(nl)
            }
            if !dup { keep.append(l) }
        }
        return keep.sorted { $0.y < $1.y }
    }

    /// Footnotes sit at the foot of the page in smaller type with tighter line pitch; drop that block.
    static func stripFootnotes(_ lines: [Line]) -> [Line] {
        if lines.count < 8 { return lines }
        let pitches = zip(lines, lines.dropFirst()).map { $1.y - $0.y }.filter { $0 > 0 && $0 < 0.05 }
        if pitches.isEmpty { return lines }
        let medPitch = median(pitches)
        // Walk up from the bottom while the block's average pitch stays tight (single pitches jitter).
        var i = lines.count - 1
        var blockStart: Int? = nil
        while i > 0, lines[i].y > 0.5 {
            let pitch = lines[i].y - lines[i - 1].y
            let avg = (lines[lines.count - 1].y - lines[i - 1].y) / Double(lines.count - i)
            if pitch > 0, pitch < 1.05 * medPitch, avg < 0.88 * medPitch { blockStart = i - 1; i -= 1 } else { break }
        }
        guard let start = blockStart, lines.count - start >= 3 else { return lines }
        let first = lines[start].text.drop(while: { $0.isWhitespace })
        if String(first).range(of: #"^(\d{1,2}|[*†‡§¶])\s*\S"#, options: .regularExpression) != nil {
            return Array(lines[..<start])
        }
        return lines
    }

    /// Reconstruct reading order: detect 2-column layouts, split paragraphs on vertical gaps.
    static func linesToParagraphs(_ input: [Line]) -> [String] {
        if input.isEmpty { return [] }
        var lines = input.sorted { $0.y < $1.y }
        let medH = median(lines.map(\.h))

        func isFurniture(_ l: Line) -> Bool {
            let words = l.text.split(separator: " ")
            let short = words.count <= 8
            let letters = l.text.filter(\.isLetter).count
            let caps = Double(l.text.filter(\.isUppercase).count) >= 0.6 * Double(max(1, letters))
            let digits = l.text.contains { $0.isNumber }
            if l.y < 0.1, short, caps || digits { return true }                       // running header / page number
            if l.y > 0.88, short, digits || caps, words.count <= 4 { return true }    // page number / journal footer
            return false
        }

        if lines.count >= 6 {
            let kept = lines.filter { !isFurniture($0) }
            lines = kept.isEmpty ? lines : kept
            lines = stripFootnotes(lines)
        }
        let left = lines.filter { $0.x1 < 0.55 && $0.x0 < 0.45 }
        let right = lines.filter { $0.x0 > 0.45 }
        let twoCol = left.count >= 4 && right.count >= 4 && Double(min(left.count, right.count)) >= 0.25 * Double(lines.count)

        var ordered: [Line] = []
        if twoCol {
            // Full-width lines (titles, footers) act as section breaks; within a section read L then R.
            var sl: [Line] = [], sr: [Line] = []
            func flush() { ordered += sl; ordered += sr; sl.removeAll(); sr.removeAll() }
            for l in lines {
                if l.x0 < 0.4, l.x1 > 0.6 { flush(); ordered.append(l) }
                else if (l.x0 + l.x1) / 2 < 0.5 { sl.append(l) }
                else { sr.append(l) }
            }
            flush()
        } else {
            ordered = lines
        }

        var paras: [String] = []
        var buf: [String] = []
        var prev: Line? = nil
        for l in ordered {
            var breakHere = false
            if let p = prev {
                let gapBreak = (l.y - (p.y + p.h)) > medH * 1.1
                let colJump = l.y < p.y - medH               // jumped back up = new column/section
                let indent = abs(l.x0 - p.x0) > 0.03 && l.x0 > p.x0 && p.x1 < 0.9 * l.x1 + 0.1
                let endsSentence = p.text.hasSuffix(".") || p.text.hasSuffix("?") || p.text.hasSuffix("!") || p.text.hasSuffix("\"")
                breakHere = gapBreak || colJump || (indent && endsSentence)
            }
            if !buf.isEmpty, breakHere { paras.append(buf.joined(separator: " ")); buf = [] }
            if let last = buf.last, last.hasSuffix("-"), let f = l.text.first, f.isLowercase {
                buf[buf.count - 1] = String(last.dropLast()) + l.text
            } else {
                buf.append(l.text)
            }
            prev = l
        }
        if !buf.isEmpty { paras.append(buf.joined(separator: " ")) }

        return paras.compactMap { p in
            let s = p.replacing(regex: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
            let letters = s.filter(\.isLetter).count
            return (letters >= 3 && Double(letters) >= 0.4 * Double(s.count)) ? s : nil
        }
    }

    // MARK: - Text helpers

    static func textToParagraphs(_ text: String) -> [String] {
        var out: [String] = []
        for block in text.components(separatedBy: #"\n\s*\n"#, regex: true) {
            let b = block.replacing(regex: #"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
            let words = b.split(separator: " ")
            if words.count >= 6 || (!words.isEmpty && (b.hasSuffix(".") || b.hasSuffix("!") || b.hasSuffix("?"))) { out.append(b) }
        }
        return out
    }

    /// 'What Is It Like to Be a Bat? | JSTOR' -> 'What Is It Like to Be a Bat?'
    static func cleanTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.components(separatedBy: #"\s+[|—–·:-]\s+"#, regex: true)
        return (parts.first.map { $0.count >= 8 } ?? false) ? parts[0] : t
    }

    /// Join a paragraph that was cut at a page/frame boundary with its continuation.
    static func mergePageBreaks(_ paras: [String]) -> [String] {
        var out: [String] = []
        for p in paras {
            if let last = out.last, let f = p.first, f.isLowercase, !last.hasSuffix(".") && !last.hasSuffix("!") && !last.hasSuffix("?")
                && !last.hasSuffix("\"") && !last.hasSuffix(":") && !last.hasSuffix(")") {
                out[out.count - 1] = last + " " + p
            } else {
                out.append(p)
            }
        }
        return out
    }

    static func wordCount(_ paras: [String]) -> Int { paras.reduce(0) { $0 + $1.split(separator: " ").count } }
    static func norm(_ t: String) -> String { t.lowercased().replacing(regex: #"\W+"#, with: "") }
    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); let n = s.count
        if n == 0 { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    // MARK: - Page scripts (identical to the Python app's; they run inside the captured page)

    enum JS {
        // An expression (so it can be composed with the comma operator) that installs shared helpers once.
        static let helpers = #"""
        (window.__narrate = window.__narrate || (() => {
          const bigPages = () => [...document.querySelectorAll('img, canvas')].filter(e => {
            const w = e.naturalWidth || e.width, h = e.naturalHeight || e.height;
            return w >= 500 && h > w * 1.05 && e.getBoundingClientRect().width > 200;
          });
          const scrollsY = e => e === document.scrollingElement || /(auto|scroll)/.test(getComputedStyle(e).overflowY);
          const scrollerOf = el => { for (let e = el.parentElement; e; e = e.parentElement) if (scrollsY(e) && e.scrollHeight > e.clientHeight + 40) return e; return document.scrollingElement; };
          const rendered = c => {   // a pdf.js canvas is blank until the page has been painted
            if (c.tagName !== 'CANVAS') return true;
            try { const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let first = d[0] + d[1] + d[2] + d[3];
              for (let i = 4; i < d.length; i += 4 * 997) if (d[i] + d[i + 1] + d[i + 2] + d[i + 3] !== first) return true; return false; }
            catch (_) { return true; }
          };
          return { bigPages, scrollerOf, rendered, imgs: new Map() };
        })())
        """#

        static let scroller = "(" + helpers + #"""
        , (() => {
          const N = window.__narrate, pages = N.bigPages();
          let best;
          if (pages.length) best = N.scrollerOf(pages[0]);
          else {
            best = document.scrollingElement;
            for (const e of document.querySelectorAll('div, main, section, article'))
              if (/(auto|scroll)/.test(getComputedStyle(e).overflowY) && e.clientHeight > 200 && e.scrollHeight > Math.max(best.scrollHeight, e.clientHeight + 40)) best = e;
          }
          N.scroller = best;
          return { h: best.scrollHeight, ch: best.clientHeight, pages: pages.length };
        })())
        """#

        static let scrollTo = "(() => { window.__narrate.scroller.scrollTo(0, %d); return window.__narrate.scroller.scrollTop; })()"

        static let collectImages = "(" + helpers + #"""
        , (() => {
          const N = window.__narrate;
          for (const e of N.bigPages()) {
            const pageEl = e.closest('[data-page-number], [data-page], .page');
            const num = pageEl && (pageEl.dataset.pageNumber || pageEl.dataset.page || pageEl.dataset.pageIndex);
            const top = e.getBoundingClientRect().top + (N.scroller ? N.scroller.scrollTop : 0);
            const key = e.tagName === 'IMG' ? (e.currentSrc || e.src) : ('canvas:' + (num != null ? num : Math.round(top / 8)));
            const px = (e.naturalWidth || e.width) * (e.naturalHeight || e.height);
            const prev = N.imgs.get(key);
            if (prev && prev.px >= px) continue;          // keep the sharpest render we have seen (pdf.js paints low-res first)
            if (!N.rendered(e)) continue;
            let data = null;
            if (e.tagName === 'CANVAS') { try { data = e.toDataURL('image/png'); } catch (_) {} }
            N.imgs.set(key, { key, data, px, sort: num != null ? +num : top });
          }
          return N.imgs.size;
        })())
        """#

        static let fetchImages = #"""
        (async () => {
          const out = [];
          for (const v of [...window.__narrate.imgs.values()].sort((a, b) => a.sort - b.sort)) {
            if (v.data) { out.push(v.data); continue; }
            try {
              const r = await fetch(v.key, { credentials: 'include' });
              const b = await r.blob();
              out.push(await new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(b); }));
            } catch (e) {
              // cross-origin without CORS: draw via an <img> into a canvas if allowed
              try {
                const img = await new Promise((res, rej) => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = rej; i.src = v.key; });
                const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
                c.getContext('2d').drawImage(img, 0, 0); out.push(c.toDataURL('image/png'));
              } catch (_) { out.push(null); }
            }
          }
          return out;
        })()
        """#

        static let domText = #"""
        (() => {
          const sels = ['article', 'main', '[role=main]', '#content', '.content', '#main', 'body'];
          for (const s of sels) {
            const el = document.querySelector(s);
            if (!el) continue;
            const t = el.innerText || '';
            if (t.split(/\s+/).length >= 200) return { title: document.title, text: t, sel: s };
          }
          return { title: document.title, text: document.body ? document.body.innerText : '', sel: 'body' };
        })()
        """#
    }
}

// MARK: - Small regex conveniences (ICU regex via NSRegularExpression)

extension String {
    func replacing(regex pattern: String, with template: String) -> String {
        replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    func components(separatedBy pattern: String, regex: Bool) -> [String] {
        guard regex, let re = try? NSRegularExpression(pattern: pattern) else { return components(separatedBy: pattern) }
        let ns = self as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}
