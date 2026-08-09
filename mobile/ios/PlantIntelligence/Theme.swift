import SwiftUI

// Forest palette carried over from the hub dashboard and the original app.
enum Theme {
    static let bg = Color(red: 0.063, green: 0.086, blue: 0.075)        // #101613
    static let bgDeep = Color(red: 0.043, green: 0.059, blue: 0.051)
    static let panel = Color(red: 0.102, green: 0.141, blue: 0.125)     // #1A2420
    static let line = Color(red: 0.165, green: 0.220, blue: 0.188)      // #2A3830
    static let accent = Color(red: 0.298, green: 0.725, blue: 0.420)    // #4CB96B
    static let warn = Color(red: 0.851, green: 0.541, blue: 0.239)
    static let err = Color(red: 0.851, green: 0.416, blue: 0.353)
    static let textMuted = Color(red: 0.561, green: 0.639, blue: 0.596) // #8FA398
}

extension View {
    /// Progressive blur under the status bar — the same treatment the
    /// system gives the bottom tab bar. Drawn manually: a material band
    /// that fades out, so content scrolling beneath the clock blurs away
    /// instead of colliding with it.
    func topEdgeFade() -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 90)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0),
                                .init(color: .black, location: 0.55),
                                .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

/// The app-wide backdrop: a deep botanical gradient the glass layers float over.
struct GardenBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.075, green: 0.125, blue: 0.098), location: 0),
                .init(color: Theme.bg, location: 0.45),
                .init(color: Theme.bgDeep, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Theme.accent.opacity(0.10))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: 80, y: -120)
        }
        .ignoresSafeArea()
    }
}

/// Content-layer card. *Not* glass on purpose: per the HIG, Liquid Glass is
/// for the floating controls layer; content sits on solid panels beneath it.
struct PanelCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.textMuted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.panel, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line, lineWidth: 1))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var detail: String? = nil
    var active = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(active ? Theme.accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func kv(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textMuted)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
