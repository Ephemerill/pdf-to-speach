import SwiftUI

/// Every voice as a small living orb: a slow-drifting cloud of colour that brightens and stirs
/// when it's hovered or speaking. Each voice has its own palette, so the grid reads like a row of
/// little personalities rather than a list of names.
struct VoiceOrb: View {
    let voice: Voice
    let size: CGFloat
    let active: Bool        // hovered or previewing → livelier
    let level: Double       // audio level 0…1 while previewing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = Palette.of(voice)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 4, height: 4, points: points(t, phase: p.phase), colors: p.mesh, smoothsColors: true)
                .frame(width: size, height: size)
                // The whole body of colour turns very slowly, so even a still frame reads as liquid.
                .rotationEffect(.degrees((t * 4 + p.phase * 40).truncatingRemainder(dividingBy: 360)))
        }
        .modifier(OrbEnergy(energy: active ? 1 : 0, level: level))
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {   // glassy sheen: a soft highlight top-left, a darker rim bottom-right
            Circle().fill(
                RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0.0)],
                               center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.45))
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05), .black.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .shadow(color: p.base.opacity(active ? 0.6 : 0.18), radius: active ? size * 0.32 : size * 0.12, y: 2)
        .scaleEffect(active ? 1.08 + level * 0.08 : 1)
        .animation(.spring(duration: 0.45, bounce: 0.35), value: active)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// 4×4 mesh. Corners pinned, edge points slide along their edges, and the four interior points
    /// wander on slow Lissajous paths — that's what makes the colour look like it's pouring around.
    /// Each voice has its own phase so a grid of orbs never moves in lock-step.
    private func points(_ t: Double, phase: Double) -> [SIMD2<Float>] {
        let s = t * 0.35 + phase
        func edge(_ base: Float, _ a: Double, _ b: Double) -> Float { base + Float(0.09 * sin(s * a + b)) }
        func inner(_ x: Double, _ y: Double, _ a: Double, _ b: Double, _ k: Double) -> SIMD2<Float> {
            SIMD2(Float(x + 0.16 * sin(s * a + k)), Float(y + 0.16 * cos(s * b + k * 1.6)))
        }
        return [
            [0, 0], [edge(0.33, 0.7, 0.3), 0], [edge(0.67, 0.5, 2.0), 0], [1, 0],
            [0, edge(0.33, 0.9, 2.1)], inner(0.33, 0.33, 0.8, 0.6, phase), inner(0.67, 0.33, 0.55, 0.85, phase + 2), [1, edge(0.33, 0.6, 4.0)],
            [0, edge(0.67, 0.8, 1.1)], inner(0.33, 0.67, 0.65, 0.9, phase + 4), inner(0.67, 0.67, 0.9, 0.5, phase + 6), [1, edge(0.67, 0.7, 5.2)],
            [0, 1], [edge(0.33, 0.6, 3.3), 1], [edge(0.67, 0.8, 0.9), 1], [1, 1],
        ]
    }
}

/// Animatable bridge so "active" and the audio level fade smoothly instead of snapping.
private struct OrbEnergy: ViewModifier, Animatable {
    var energy: Double
    var level: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(energy, level) }
        set { energy = newValue.first; level = newValue.second }
    }
    func body(content: Content) -> some View {
        content
            .saturation(1 + energy * 0.25 + level * 0.3)
            .brightness(energy * 0.05 + level * 0.12)
    }
}

/// A colour personality per voice: base tone, a lighter tint, a near-white cloud and a deep shade.
struct Palette {
    let base: Color, light: Color, cloud: Color, deep: Color
    let phase: Double

    /// Row-major 4×4 colours: a bright cloud pooled near the top, deep tones settling at the bottom.
    var mesh: [Color] {
        [light, cloud, cloud, light,
         base,  light, cloud, base,
         base,  base,  light, deep,
         deep,  base,  deep,  deep]
    }

    static func of(_ v: Voice) -> Palette { all[v.id] ?? all["af_heart"]! }

    private static func p(_ base: UInt32, _ light: UInt32, _ cloud: UInt32, _ deep: UInt32, _ phase: Double) -> Palette {
        Palette(base: Color(hex: base), light: Color(hex: light), cloud: Color(hex: cloud), deep: Color(hex: deep), phase: phase)
    }
    private static let all: [String: Palette] = [
        "af_heart":    p(0xFF6B8A, 0xFFB3C1, 0xFFF3F5, 0xE63E6D, 0.0),    // coral rose
        "af_bella":    p(0xE255C7, 0xF7A8E5, 0xFFF0FB, 0xB02A9A, 0.9),    // orchid
        "af_nicole":   p(0x9B8CFF, 0xCFC7FF, 0xF6F4FF, 0x6E5BE0, 1.8),    // lavender
        "bf_emma":     p(0x3FB8A8, 0xA8E5DC, 0xF0FFFC, 0x1F8C80, 2.7),    // sage teal
        "af_aoede":    p(0x3D9BFF, 0xA9D4FF, 0xFFFFFF, 0x1466E0, 3.6),    // sky
        "af_kore":     p(0x4FD4A0, 0xB3F0D6, 0xF2FFF8, 0x2AA878, 4.5),    // mint
        "af_sarah":    p(0xFFB347, 0xFFD9A0, 0xFFF8EC, 0xF08C1A, 5.4),    // peach gold
        "am_fenrir":   p(0x4C4CFF, 0x9C9CFF, 0xEDEDFF, 0x2A2AB8, 6.3),    // indigo
        "am_michael":  p(0x5A8FCC, 0xA9C8EA, 0xF0F5FC, 0x365F99, 7.2),    // steel blue
        "am_puck":     p(0xA8E63D, 0xD5F59A, 0xF8FFEB, 0x78B317, 8.1),    // lime
        "bf_isabella": p(0xB060C8, 0xDCB0E8, 0xFBF0FF, 0x7E3A96, 9.0),    // plum
        "bm_george":   p(0x3A5BA0, 0x9DB4E0, 0xF3EAD3, 0x1F3670, 9.9),    // navy & cream
        "bm_fable":    p(0xF2953A, 0xFFC98F, 0xFFF5E8, 0xC46A15, 10.8),   // amber
        "am_echo":     p(0x4B7C8C, 0x98BEC9, 0xEAF4F7, 0x2C5461, 11.7),   // slate
        "bm_lewis":    p(0xC4553A, 0xE8A08C, 0xFBEDE8, 0x8E3320, 12.6),   // rust
        "bm_daniel":   p(0x3E4E6E, 0x8C9BB8, 0xE8ECF3, 0x232D45, 13.5),   // charcoal blue
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The voice row on the setup screen: the chosen voice as a living orb; click for the full picker.
struct VoiceRow: View {
    @Environment(AppModel.self) private var model
    @State private var hoveringOrb = false

    var body: some View {
        @Bindable var model = model
        let voice = Voice.named(model.voiceID)
        let playing = model.samplePlayer.playingID == voice.id
        HStack(spacing: 14) {
            VoiceOrb(voice: voice, size: 44, active: hoveringOrb || playing, level: playing ? model.samplePlayer.level : 0)
                .onHover { inside in hoveringOrb = inside; model.hoverPreview(voice.id, inside) }
                .help("Hover to hear \(voice.name)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.name).fontWeight(.semibold)
                    Text(voice.accent == "US" ? "American" : "British").font(.caption2).foregroundStyle(.tertiary)
                    GradeBadge(grade: voice.grade)
                }
                Text(voice.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("Change").font(.callout).foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.showVoicePicker.toggle() }
        .popover(isPresented: $model.showVoicePicker, arrowEdge: .bottom) {
            VoicePicker { model.showVoicePicker = false }
        }
    }
}

/// The picker itself: a 4×4 grid of orbs. Hover to hear a voice, click to choose it.
struct VoicePicker: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    @State private var hovered: String?

    private let columns = Array(repeating: GridItem(.fixed(104), spacing: 8), count: 4)

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Voice.all) { voice in
                    let selected = voice.id == model.voiceID
                    let playing = model.samplePlayer.playingID == voice.id
                    let loading = model.loadingSampleID == voice.id
                    VStack(spacing: 8) {
                        ZStack {
                            VoiceOrb(voice: voice, size: 72, active: hovered == voice.id || playing,
                                     level: playing ? model.samplePlayer.level : 0)
                            if loading { ProgressView().controlSize(.small) }
                        }
                        .padding(5)
                        .overlay {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .opacity(selected ? 1 : 0)
                                .scaleEffect(selected ? 1 : 0.85)
                                .animation(.spring(duration: 0.35, bounce: 0.3), value: selected)
                        }
                        Text(voice.name)
                            .font(.callout).fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .frame(width: 104)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(hovered == voice.id ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture {
                        model.voiceID = voice.id
                        model.hoverPreview(nil, false)
                        Task { try? await Task.sleep(for: .milliseconds(220)); dismiss() }   // let the ring land first
                    }
                    .onHover { inside in
                        hovered = inside ? voice.id : (hovered == voice.id ? nil : hovered)
                        model.hoverPreview(voice.id, inside)
                    }
                    .accessibilityLabel("\(voice.name), \(voice.accent == "US" ? "American" : "British"), \(voice.note)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            let shown = Voice.named(hovered ?? model.voiceID)
            HStack(spacing: 6) {
                Text(shown.name).fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text(shown.accent == "US" ? "American" : "British").foregroundStyle(.secondary)
                GradeBadge(grade: shown.grade)
                Text("·").foregroundStyle(.tertiary)
                Text(shown.note).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(hovered == nil ? "Hover to listen" : "Click to choose").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .animation(.easeOut(duration: 0.15), value: shown.id)
        }
        .padding(14)
        .onDisappear { model.hoverPreview(nil, false) }
    }
}
