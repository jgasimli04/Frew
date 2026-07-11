import SwiftUI

/// BeeDeck design tokens — one place for the workspace's chrome, so every
/// panel reads as the same instrument (the Logic/rekordbox "industrial"
/// register: near-black surfaces, hairline seams, one accent, monospaced
/// numerics for anything that moves).
enum BD {
    // surfaces, darkest to lightest
    static let bg        = Color(white: 0.075)   // window floor
    static let panel     = Color(white: 0.115)   // panes sit on this
    static let panelDeep = Color(white: 0.055)   // wells: waveforms, meters
    static let seam      = Color(white: 0.22)    // hairline borders

    // ink
    static let text    = Color(white: 0.92)
    static let textDim = Color(white: 0.55)

    // the one accent — the honey/θ amber the brand already owns
    static let accent  = Color(hue: 0.115, saturation: 0.85, brightness: 1.0)
    static let good    = Color(hue: 0.33, saturation: 0.6, brightness: 0.85)
    static let warn    = Color(hue: 0.02, saturation: 0.75, brightness: 0.95)

    static let radius: CGFloat = 6
    static let gap: CGFloat = 8                  // the 8pt grid everything snaps to
}

/// A workspace panel: content on a raised surface with a hairline seam and
/// an optional Logic-style CAPS header row.
struct Panel<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(BD.textDim)
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color(white: 0.14))
            }
            content()
        }
        .background(BD.panel)
        .clipShape(RoundedRectangle(cornerRadius: BD.radius))
        .overlay(RoundedRectangle(cornerRadius: BD.radius)
            .strokeBorder(BD.seam.opacity(0.5), lineWidth: 1))
    }
}

/// Monospaced value readout (time, bpm, dB) — the "anything that moves is
/// monospaced" rule.
struct Readout: View {
    let value: String
    var color: Color = BD.text
    var size: CGFloat = 11

    var body: some View {
        Text(value)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundColor(color)
    }
}
