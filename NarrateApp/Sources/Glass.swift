import SwiftUI

/// Liquid Glass on macOS 26, sensible materials on macOS 15 — so the app looks native on both.
extension View {
    /// A floating panel: glass over whatever scrolls beneath it.
    @ViewBuilder func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    /// A round control that reacts to the pointer; tinted when active.
    @ViewBuilder func glassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.background(tint ?? Color.primary.opacity(0.07), in: Circle())
        }
    }

    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}
