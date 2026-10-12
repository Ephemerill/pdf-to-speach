import SwiftUI

/// Standard ↔ High Quality, with the high quality model's download state right under it. Picking
/// High starts the download; everything keeps working with the standard voices meanwhile.
struct QualityPicker: View {
    @Environment(AppModel.self) private var model
    /// In the reader the choice re-voices the book being read instead of setting the default.
    var onChange: ((Quality) -> Void)? = nil
    /// The quality to show as chosen (the reader shows the book's, not the default).
    var current: Quality? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Quality", selection: Binding(get: { current ?? model.quality }, set: { q in
                if let onChange { onChange(q) } else { model.setQuality(q) }
            })) {
                Text("Standard").tag(Quality.standard)
                Text("High Quality").tag(Quality.high)
            }
            .pickerStyle(.segmented).labelsHidden()
            HQStatus(compact: onChange != nil)
        }
    }
}

/// Download progress / readiness of the high quality model, in a sentence or two.
struct HQStatus: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let hq = model.hq
        let wantsHQ = model.quality == .high
        switch hq.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: hq.fraction).progressViewStyle(.linear)
                    Button("Pause") { hq.pause() }.controlSize(.small)
                }
                Text(downloadLine(hq) + (compact ? "" : " Standard voices are used until it's done — carry on as normal."))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .paused:
            HStack(spacing: 8) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("High quality download paused at \(gb(hq.received)) of \(gb(hq.totalBytes)).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Resume") { hq.download() }.controlSize(.small)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 4)
                Button("Try Again") { hq.download() }.controlSize(.small)
            }
        case .ready:
            if wantsHQ, !compact {
                Text("Fish Audio S2 Pro — far more natural. Listening starts about 20 seconds after you press Generate (the standard voices take a second or two), then it keeps ahead of you. Needs about 8 GB of memory while it's speaking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .absent:
            if !compact {
                Text("High Quality speaks with Fish Audio S2 Pro, on your Mac like everything else. Choosing it downloads the model (\(gb(hq.totalBytes))) in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func downloadLine(_ hq: ModelPack) -> String {
        var s = "Downloading high quality voices · \(gb(hq.received)) of \(gb(hq.totalBytes))"
        if let left = hq.secondsLeft { s += " · about \(Format.time(left)) left" }
        return s + "."
    }
}

func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

/// A compact progress chip for the toolbar while the high quality model downloads; click for details.
struct HQDownloadChip: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        let hq = model.hq
        if hq.state == .downloading {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 6) {
                    ProgressView(value: hq.fraction).progressViewStyle(.circular).controlSize(.mini)
                    Text("HQ voices \(Int(hq.fraction * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Downloading the high quality voice model in the background")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("High Quality Voices").font(.headline)
                    HQStatus()
                }
                .padding(14).frame(width: 340)
            }
        }
    }
}

/// Options ▸ the high quality model on disk: how big, and a way to get the space back.
struct HQStorageRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let hq = model.hq
        LabeledContent("High quality") {
            HStack(spacing: 10) {
                switch hq.state {
                case .absent:
                    Text("Not downloaded").foregroundStyle(.secondary)
                case .ready:
                    Text("\(gb(hq.diskBytes)) on disk").foregroundStyle(.secondary).monospacedDigit()
                default:
                    Text("\(gb(hq.diskBytes)) of \(gb(hq.totalBytes))").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if hq.state != .absent {
                    Button("Delete…", role: .destructive) { confirmDelete = true }.controlSize(.small)
                }
            }
        }
        .confirmationDialog("Delete the high quality voices?", isPresented: $confirmDelete) {
            Button("Delete \(gb(hq.diskBytes))", role: .destructive) { model.deleteHQModel() }
        } message: {
            Text("Audiobooks you've already made keep working. Choosing High Quality again downloads the model again.")
        }
    }
}

/// The reader's voice button: the current voice as a small orb; click to change voice or quality
/// mid-book.
struct ReaderVoiceButton: View {
    @Environment(AppModel.self) private var model
    let timeline: Timeline
    @State private var show = false

    var body: some View {
        let voice = Voice.named(timeline.voiceID)
        Button { show.toggle() } label: {
            HStack(spacing: 8) {
                VoiceOrb(voice: voice, size: 26, active: model.switchingTo != nil, level: 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeline.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let to = model.switchingTo {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Switching to \(to)…")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(timeline.voice + (model.narration.map { " · \($0.format)" } ?? "") + "  ▾")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change the voice — it carries on from where you are")
        .popover(isPresented: $show, arrowEdge: .top) {
            VStack(spacing: 12) {
                QualityPicker(onChange: { q in
                    if q == .high, !model.hq.isReady { model.setQuality(.high) }   // just start the download
                    else { model.switchVoice(to: timeline.voiceID, quality: q) }
                }, current: timeline.quality)
                .padding(.horizontal, 6)
                VoicePicker(selected: timeline.voiceID, onChoose: { id in
                    model.switchVoice(to: id, quality: timeline.quality)
                }) { show = false }
            }
            .padding(.top, 14)
        }
    }
}

/// First launch: the standard voices download in the background while documents are opened and set up.
struct VoicesDownloadStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let k = model.kokoro
        if model.status == .downloading {
            VStack(alignment: .leading, spacing: 4) {
                switch k.state {
                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Couldn't download the voices: \(message)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 4)
                        Button("Try Again") { k.download() }.controlSize(.small)
                    }
                default:
                    ProgressView(value: k.fraction).progressViewStyle(.linear)
                    Text("Downloading the voices · \(Format.bytes(k.received)) of \(Format.bytes(k.totalBytes))"
                         + (k.secondsLeft.map { " · about \(Format.time($0)) left" } ?? "")
                         + ". Only this once — open a document and get it ready meanwhile.")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 2)
        }
    }
}
