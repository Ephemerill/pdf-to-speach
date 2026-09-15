import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Source", selection: $model.source) {
                        ForEach(AppModel.Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)

                    switch model.source {
                    case .pdf: dropZone
                    case .text: textPane
                    case .link: linkPane
                    }
                } header: {
                    Text("Source")
                }

                if let doc = model.document { DocumentCard(doc: doc) }

                Section("Voice") {
                    ForEach(Voice.all) { voice in
                        VoiceRow(voice: voice, selected: voice.id == model.voiceID,
                                 isPlaying: model.samplePlayer.playingID == voice.id,
                                 isLoading: model.loadingSampleID == voice.id,
                                 select: { model.voiceID = voice.id },
                                 sample: { model.sampleVoice(voice.id) })
                    }
                }

                Section("Options") {
                    LabeledContent("Speed") {
                        HStack(spacing: 10) {
                            Slider(value: $model.speed, in: 0.7...2.0, step: 0.05).frame(maxWidth: 220)
                            Text(String(format: "%.2f×", model.speed).replacingOccurrences(of: "0×", with: "×"))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Format", selection: $model.format) {
                        ForEach(model.formats, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 220)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls); return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { StatusPill(status: model.status) }
        }
        .overlay(alignment: .bottom) { ToastView(toast: model.toast).padding(.bottom, 88) }
        .sheet(isPresented: .constant(isSetupSheetShown)) { SetupSheet() }
    }

    private var isSetupSheetShown: Bool {
        switch model.status {
        case .downloading, .failed: return true
        default: return false
        }
    }

    // MARK: Source panes

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            VStack(spacing: 3) {
                Text("Drop a PDF here").font(.headline)
                Text("or ").foregroundStyle(.secondary) +
                Text("choose a file…").foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.18))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.chooseFile() }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var textPane: some View {
        @Bindable var model = model
        return VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $model.pastedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if model.pastedText.isEmpty {
                        Text("Paste anything — an article, notes, a chapter. Blank lines separate paragraphs.")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.top, 7).allowsHitTesting(false)
                    }
                }
            Button("Use This Text") { model.useText() }
                .disabled(model.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var linkPane: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("URL", text: $model.linkText, prompt: Text("https://www.jstor.org/stable/…"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit { model.openLink(openWindow: { openWindow(id: $0) }) }
                Button("Open") { model.openLink(openWindow: { openWindow(id: $0) }) }
                    .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                model.capturePage()
            } label: {
                HStack {
                    if model.isCapturing { ProgressView().controlSize(.small) }
                    Text(model.isCapturing ? model.captureLabel : "Capture Page Text")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.browser.isOpen || model.isCapturing)
            Text("Opens the page in Narrate's own browser window — sign in if you need to, get the article on screen, then hit Capture. Page scans (JSTOR's reader) and screenshots are read with on-device OCR.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if model.isGenerating {
                VStack(spacing: 6) {
                    if let label = model.progress.label {
                        ProgressView().progressViewStyle(.linear)
                        HStack { Text(label); Spacer(); Button("Cancel", role: .cancel) { model.cancelGeneration() } }
                    } else {
                        ProgressView(value: model.progress.fraction).progressViewStyle(.linear)
                        HStack {
                            Text("\(model.progress.done)/\(model.progress.total) · \(Format.time(model.progress.seconds)) of audio"
                                 + (model.progress.eta.map { " · ~\(Format.time($0)) left" } ?? ""))
                                .monospacedDigit()
                            Spacer()
                            Button("Cancel", role: .cancel) { model.cancelGeneration() }
                        }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .controlSize(.small)
            } else {
                Button {
                    model.generate()
                } label: {
                    Label("Generate Audiobook", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canGenerate)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - Pieces

struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let doc: SourceDocument

    var body: some View {
        @Bindable var model = model
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: doc.isPDF ? "doc.text.fill" : (doc.method != nil ? "globe" : "text.alignleft"))
                    .font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.name).font(.headline).lineLimit(2)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                    Text(doc.preview).font(.callout).foregroundStyle(.secondary).lineLimit(3).padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button { model.clearDocument() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Remove")
            }
            .padding(.vertical, 2)
            if doc.isPDF {
                LabeledContent("Pages") {
                    HStack(spacing: 6) {
                        TextField("From", text: $model.pageFrom, prompt: Text("1")).frame(width: 52)
                        Text("–").foregroundStyle(.secondary)
                        TextField("To", text: $model.pageTo, prompt: Text("\(doc.pages)")).frame(width: 52)
                        Button("Apply") { model.applyPageRange() }.controlSize(.small)
                    }
                    .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.center)
                }
            }
        } header: {
            Text("Document")
        }
    }

    private var meta: String {
        let mins = Double(doc.words) / (165 * model.speed)
        var s = (doc.isPDF ? "\(doc.pages) pages · " : "") + "\(doc.words.formatted()) words · about \(Format.time(mins * 60)) of audio"
        if let m = doc.method { s += " · via \(m)" }
        return s
    }
}

struct VoiceRow: View {
    let voice: Voice
    let selected: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let select: () -> Void
    let sample: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(avatarGradient)
                Text(String(voice.name.prefix(1))).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.name).fontWeight(selected ? .semibold : .medium)
                    Text(voice.accent).font(.caption2).foregroundStyle(.tertiary)
                    Text(voice.grade).font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(voice.grade.hasPrefix("A") ? Color.green.opacity(0.18) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(voice.grade.hasPrefix("A") ? Color.green : Color.secondary)
                }
                Text(voice.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor) }
            Button(action: sample) {
                ZStack {
                    Circle().fill(isPlaying ? Color.accentColor : Color.primary.opacity(hovering ? 0.1 : 0.06))
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 9.5)).foregroundStyle(isPlaying ? .white : .secondary)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).help("Play a sample")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .listRowBackground(selected ? Color.accentColor.opacity(0.16) : nil)
    }

    private var avatarGradient: LinearGradient {
        let colors: [Color] = voice.gender == "F"
            ? [Color(red: 0.96, green: 0.62, blue: 0.40), Color(red: 0.90, green: 0.40, blue: 0.45)]
            : [Color(red: 0.36, green: 0.58, blue: 0.95), Color(red: 0.30, green: 0.40, blue: 0.85)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct StatusPill: View {
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 6) {
            if isBusy { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: 7, height: 7) }
            Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var isBusy: Bool { if case .ready = status { return false }; if case .failed = status { return false }; return true }
    private var color: Color { if case .failed = status { return .red }; return .green }
    private var text: String {
        switch status {
        case .starting: return "Starting…"
        case .downloading(_, let f): return "Downloading model \(Int(f * 100))%"
        case .loading: return "Loading voice…"
        case .ready: return "Ready"
        case .failed: return "Engine error"
        }
    }
}

struct ToastView: View {
    let toast: (text: String, isError: Bool)?

    var body: some View {
        if let toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Color.orange : Color.green)
                Text(toast.text).font(.callout).lineLimit(3)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.text)
        }
    }
}

/// First-launch model download (and any engine failure) — a sheet so it's impossible to miss.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color.accentColor)
            switch model.status {
            case .downloading(let label, let frac):
                Text("Setting up Narrate").font(.title2.weight(.semibold))
                Text("Downloading the Kokoro voice model (340 MB). This only happens once, and everything runs on your Mac afterwards — nothing you narrate ever leaves it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                ProgressView(value: frac).progressViewStyle(.linear)
                Text("\(label) · \(Int(frac * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            case .failed(let message):
                Text("Something went wrong").font(.title2.weight(.semibold))
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportDir.appendingPathComponent("engine.log")]) }
                    Button("Try Again") { model.retrySetup() }.buttonStyle(.borderedProminent)
                }
            default:
                EmptyView()
            }
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
