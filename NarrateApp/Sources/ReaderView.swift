import SwiftUI

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let timeline: Timeline

    var body: some View {
        ReadAlongTextView(timeline: timeline, timelineVersion: timeline.version, currentTime: model.player.currentTime,
                          bottomInset: PlayerBar.height + 24,
                          onWordTap: { t in model.player.seek(to: t); if !model.player.isPlaying { model.player.play() } },
                          onPlayerKey: handle)
        .overlay(alignment: .bottom) { PlayerBar(timeline: timeline) }
        .background(.background)
        .navigationTitle(timeline.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.closeReader() } label: { Label("New Document", systemImage: "chevron.left") }
                    .help(model.isGenerating ? "Stop and go back" : "Back to start")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                let done = model.narration != nil
                let waiting = "Available once the audiobook is finished"
                Button { model.airDrop() } label: { Label("AirDrop", systemImage: "iphone.and.arrow.forward") }
                    .labelStyle(.titleAndIcon)
                    .help(done ? "Send the audio to your iPhone or iPad with AirDrop" : waiting)
                    .disabled(!done)
                if let n = model.narration {
                    ShareLink(item: n.url, preview: SharePreview(n.title, image: Image(systemName: "waveform"))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share the audio — Messages, Mail, Notes, AirDrop…")
                } else {
                    Button {} label: { Label("Share", systemImage: "square.and.arrow.up") }.help(waiting).disabled(true)
                }
                Menu {
                    Button("Save a Copy…") { model.exportCopy() }
                    Button("Show in Finder") { model.revealInFinder() }
                } label: {
                    Label("Export", systemImage: "arrow.down.document")
                }
                .help(done ? "Export the audio file" : waiting)
                .disabled(!done)
            }
        }
        .overlay(alignment: .bottom) { ToastView(toast: model.toast).padding(.bottom, PlayerBar.height + 28) }
    }

    private var subtitle: String {
        if let n = model.narration {
            return "\(n.voice) · \(Format.time(n.duration)) · \(Format.bytes(n.fileSize)) \(n.format)"
        }
        return "\(timeline.voice) · about \(Format.time(timeline.duration)) · generating…"
    }

    private func handle(_ key: ReaderTextView.PlayerKey) {
        switch key {
        case .playPause: model.player.toggle()
        case .back: model.player.skip(by: -10)
        case .forward: model.player.skip(by: 10)
        case .previousParagraph: model.jumpParagraph(-1)
        case .nextParagraph: model.jumpParagraph(1)
        }
    }
}

/// Transport controls floating on glass over the text.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    let timeline: Timeline
    @State private var scrub: Double? = nil
    static let height: CGFloat = 96

    private var player: Player { model.player }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeline.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(timeline.voice + (model.narration.map { " · \($0.format)" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 240, alignment: .leading)

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                HStack(spacing: 22) {
                    transport("backward.frame.fill", size: 13, help: "Previous paragraph (↑)") { model.jumpParagraph(-1) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    transport("gobackward.10", size: 19, help: "Back 10 seconds (←)") { player.skip(by: -10) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { player.toggle() } label: {
                        ZStack {
                            if player.isWaiting {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                    .offset(x: player.isPlaying ? 0 : 1.5)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .glassCircle(tint: .accentColor)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(player.isWaiting ? "Waiting for this part to be generated…" : player.isPlaying ? "Pause (space)" : "Play (space)")
                    .keyboardShortcut(.space, modifiers: [])
                    transport("goforward.10", size: 19, help: "Forward 10 seconds (→)") { player.skip(by: 10) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    transport("forward.frame.fill", size: 13, help: "Next paragraph (↓)") { model.jumpParagraph(1) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                }
                HStack(spacing: 10) {
                    Text(Format.time(scrub ?? player.currentTime)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    ZStack {
                        ReadyTrack(timeline: timeline).frame(height: 4).padding(.horizontal, 6).allowsHitTesting(false)
                        Slider(value: Binding(get: { scrub ?? player.currentTime }, set: { scrub = $0 }),
                               in: 0...max(1, player.duration)) { editing in
                            if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                        }
                        .controlSize(.small)
                    }
                    Text(Format.time(player.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                }
                .frame(width: 460)
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                if model.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(timeline.readyCount), total: Double(max(1, timeline.chunks.count)))
                            .progressViewStyle(.circular).controlSize(.small)
                        Text("Generating \(timeline.readyCount)/\(timeline.chunks.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help("You can listen while the rest is generated. Skipping ahead generates that part next.")
                }
                Menu {
                    ForEach(Player.rates, id: \.self) { r in
                        Button { player.rate = r } label: {
                            if player.rate == r { Label(rateLabel(r), systemImage: "checkmark") } else { Text(rateLabel(r)) }
                        }
                    }
                } label: {
                    Text(rateLabel(player.rate)).monospacedDigit()
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Playback speed")
            }
            .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .frame(maxWidth: 1000)
        .glassPanel(cornerRadius: 24)
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func rateLabel(_ r: Float) -> String { (r == r.rounded() ? String(Int(r)) : String(format: "%.2g", r)) + "×" }

    private func transport(_ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Faint marks under the scrubber showing which parts have been generated so far.
struct ReadyTrack: View {
    let timeline: Timeline

    var body: some View {
        if !timeline.isComplete {
            GeometryReader { geo in
                let total = max(1, timeline.duration)
                ForEach(timeline.chunks.filter(\.isReady), id: \.index) { c in
                    let x = timeline.offsets[c.index] / total * geo.size.width
                    let w = timeline.estimatedDuration(of: c) / total * geo.size.width
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(2, w), height: 4)
                        .offset(x: x, y: geo.size.height / 2 + 5)
                }
            }
        }
    }
}
