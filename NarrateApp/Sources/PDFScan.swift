import AppKit
import Foundation
import PDFKit

/// Scanned PDFs have pictures of pages and no text. The engine reports which pages came back empty
/// (`scanned_pages`); this renders each one and reads it with the same on-device Vision OCR the
/// browser capture uses, so those pages narrate like any other.
enum PDFScan {
    struct Page { var clean: [String]; var all: [String] }

    /// OCR the given 1-based pages. `progress` is called before each page with (done, total).
    static func ocr(path: String, pages: [Int], progress: @escaping (Int, Int) -> Void) async -> [Int: Page] {
        await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return [:] }
            var out: [Int: Page] = [:]
            for (i, p) in pages.enumerated() {
                if Task.isCancelled { break }
                progress(i, pages.count)
                guard let page = doc.page(at: p - 1), let image = render(page),
                      let lines = try? Capture.ocr(image), !lines.isEmpty else { continue }
                out[p] = Page(clean: Capture.linesToParagraphs(lines), all: Capture.linesToParagraphs(lines, clean: false))
            }
            return out
        }.value
    }

    /// The page as a bitmap about 2400 px on its long side — enough for Vision to read body text from a phone scan.
    private static func render(_ page: PDFPage) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        guard b.width > 0, b.height > 0 else { return nil }
        let scale = min(6, max(1, 2400 / max(b.width, b.height)))
        let size = CGSize(width: (b.width * scale).rounded(), height: (b.height * scale).rounded())
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
