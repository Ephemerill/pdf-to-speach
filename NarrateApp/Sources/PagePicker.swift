import PDFKit
import SwiftUI

/// The "Choose Pages" window: the PDF itself, page by page, with a sidebar of chapters and the
/// selected ranges. Pages that won't be narrated are veiled so it's obvious what's in and what's
/// out; mark runs of pages with Start Here / End Here (or tick the page you're looking at).
struct PagePickerWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var currentPage = 1
    @State private var jump: Int? = nil
    @State private var rangeStart: Int? = nil

    var body: some View {
        if let doc = model.document, doc.isPDF, let path = doc.path {
            HStack(spacing: 0) {
                PDFPagesView(url: URL(fileURLWithPath: path), selection: doc.selection, currentPage: $currentPage, jump: $jump)
                Divider()
                sidebar(doc)
            }
            .frame(minWidth: 900, minHeight: 560)
            .navigationTitle(doc.name)
            .navigationSubtitle("Page \(currentPage) of \(doc.pages)")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { jump = max(1, currentPage - 1) } label: { Image(systemName: "chevron.up") }
                        .disabled(currentPage <= 1).help("Previous page")
                    Button { jump = min(doc.pages, currentPage + 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(currentPage >= doc.pages).help("Next page")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle("Include page \(currentPage)", isOn: Binding(get: { doc.selection.contains(currentPage) },
                                                                        set: { model.select(currentPage...currentPage, $0) }))
                    .toggleStyle(.checkbox)
                    .help("Narrate the page you're looking at")

                    if let start = rangeStart {
                        Button {
                            model.select(min(start, currentPage)...max(start, currentPage), true)
                            rangeStart = nil
                        } label: {
                            Label("End Here (from \(start))", systemImage: "flag.checkered").labelStyle(.titleAndIcon)
                        }
                        .help("Include pages \(min(start, currentPage))–\(max(start, currentPage))")
                        Button("Cancel") { rangeStart = nil }
                    } else {
                        Button { rangeStart = currentPage } label: { Label("Start Here", systemImage: "flag").labelStyle(.titleAndIcon) }
                            .help("Begin a range at page \(currentPage); scroll to its last page and press End Here")
                    }

                    Button("Done") { dismissWindow(id: "pages") }
                        .prominentGlassButton()
                        .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            ContentUnavailableView("No PDF open", systemImage: "doc.text",
                                   description: Text("Drop a PDF on the Narrate window, then choose pages here."))
                .frame(minWidth: 600, minHeight: 400)
        }
    }

    private func sidebar(_ doc: SourceDocument) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(doc.selectionSummary).font(.headline).lineLimit(2)
                Text("\(doc.words.formatted()) words · about \(Format.time(Double(doc.words) / (165 * model.speed) * 60)) of audio")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 6) {
                    TextField("Pages", text: $model.rangesText, prompt: Text("e.g. 6-13, 24-50"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .onSubmit { model.applyRanges() }
                    Button("Apply") { model.applyRanges() }.disabled(model.rangesText == doc.rangesText)
                }
                .controlSize(.small)
                HStack {
                    Button("Select All") { model.selectAllPages() }.disabled(doc.isEverythingSelected)
                    Button("Clear") { model.clearPages() }.disabled(doc.selection.isEmpty)
                }
                .controlSize(.small)
            }
            .padding(14)

            Divider()

            if !doc.selectedRanges.isEmpty, !doc.isEverythingSelected {
                Text("Selected ranges").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(doc.selectedRanges, id: \.lowerBound) { r in
                            HStack {
                                Button {
                                    jump = r.lowerBound
                                } label: {
                                    Text(r.lowerBound == r.upperBound ? "Page \(r.lowerBound)" : "Pages \(r.lowerBound)–\(r.upperBound)")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button { model.select(r, false) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                    .buttonStyle(.plain).help("Remove these pages")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
                Divider()
            }

            if doc.outline.isEmpty {
                Text("This PDF has no chapter list. Scroll through it and mark pages with Start Here / End Here, or type ranges above.")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                HStack {
                    Text(doc.outlineSource == "bookmarks" ? "Chapters" : "Chapters (detected)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("click a name to jump there").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                ChapterList(doc: doc, onJump: { jump = $0 }).padding(.horizontal, 10)
            }
        }
        .frame(width: 320)
        .background(.background)
    }
}

// MARK: - PDFKit

/// The PDF with a thumbnail strip, veiling pages that aren't selected.
struct PDFPagesView: NSViewRepresentable {
    let url: URL
    let selection: IndexSet
    @Binding var currentPage: Int
    @Binding var jump: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.pageOverlayViewProvider = c
        c.pdfView = pdfView
        c.selection = selection
        c.onPageChange = { [weak c] in
            guard let c, let page = c.pdfView?.currentPage, let doc = c.pdfView?.document else { return }
            let n = doc.index(for: page) + 1
            DispatchQueue.main.async { c.setPage?(n) }
        }
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)

        let thumbs = PDFThumbnailView()
        thumbs.pdfView = pdfView
        thumbs.thumbnailSize = NSSize(width: 84, height: 108)
        thumbs.backgroundColor = .underPageBackgroundColor
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(thumbs)
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: container.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbs.widthAnchor.constraint(equalToConstant: 116),
            pdfView.leadingAnchor.constraint(equalTo: thumbs.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Loading a big file happens off the main thread so the window appears at once.
        let url = url
        Task.detached(priority: .userInitiated) {
            let doc = PDFDocument(url: url)
            await MainActor.run { c.load(doc) }
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.setPage = { currentPage = $0 }
        c.selection = selection
        c.refreshOverlays()
        if let target = jump {
            c.go(to: target)
            DispatchQueue.main.async { jump = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        weak var pdfView: PDFView?
        var selection = IndexSet()
        var setPage: ((Int) -> Void)?
        var onPageChange: (() -> Void)?
        private var overlays: [Int: PageVeil] = [:]
        private var pendingJump: Int?

        func load(_ doc: PDFDocument?) {
            pdfView?.document = doc
            go(to: pendingJump ?? 1)      // PDFKit otherwise opens with the first page's top margin scrolled away
            pendingJump = nil
        }

        func go(to page: Int) {
            guard let v = pdfView, let doc = v.document else { pendingJump = page; return }
            guard let p = doc.page(at: max(0, min(doc.pageCount - 1, page - 1))) else { return }
            v.go(to: PDFDestination(page: p, at: NSPoint(x: 0, y: p.bounds(for: v.displayBox).maxY)))
        }

        @objc func pageChanged() { onPageChange?() }

        func refreshOverlays() {
            for (index, veil) in overlays { veil.isExcluded = !selection.contains(index + 1) }
        }

        nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            MainActor.assumeIsolated {
                guard let doc = view.document else { return nil }
                let index = doc.index(for: page)
                if let v = overlays[index] { return v }
                let v = PageVeil(pageNumber: index + 1)
                v.isExcluded = !selection.contains(index + 1)
                overlays[index] = v
                return v
            }
        }
    }
}

/// Sits over a page; dims it with a "Not narrated" tag when the page is out of the selection.
/// Never takes clicks, so scrolling and text selection in the PDF work as usual.
final class PageVeil: NSView {
    private let badge = NSTextField(labelWithString: "")
    var isExcluded = false {
        didSet { if isExcluded != oldValue { apply() } }
    }

    init(pageNumber: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        badge.stringValue = "  Not narrated  "
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 6
        badge.sizeToFit()
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(badge)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        badge.frame.origin = NSPoint(x: bounds.maxX - badge.frame.width - 10, y: bounds.maxY - badge.frame.height - 10)
    }

    private func apply() {
        layer?.backgroundColor = isExcluded ? NSColor.black.withAlphaComponent(0.42).cgColor : nil
        badge.isHidden = !isExcluded
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }
}
