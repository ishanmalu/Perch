import SwiftUI
import AppKit

/// Shared visual language. Every surface in Perch pulls its spacing, radii,
/// type, and chrome from here so the popover, panels, and settings read as
/// one app rather than three.
enum Theme {
    enum Radius {
        static let card: CGFloat = 10
        static let control: CGFloat = 7
        static let chip: CGFloat = 5
    }

    enum Space {
        static let section: CGFloat = 13
        static let row: CGFloat = 7
        static let inset: CGFloat = 14
    }

    enum Font {
        static let sectionHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 12.5, weight: .medium)
        static let body = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 10.5)
        static let numeric = SwiftUI.Font.system(size: 10.5, design: .monospaced)
        static let keycap = SwiftUI.Font.system(size: 9.5, weight: .medium, design: .rounded)
    }

    /// Fills sit on top of the popover's material, so they stay translucent.
    static let cardFill = Color.primary.opacity(0.055)
    static let cardStroke = Color.primary.opacity(0.07)
    static let hoverFill = Color.primary.opacity(0.10)
}

/// An uppercase section label with a hairline that fills the remaining width.
struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String) { self.title = title }
    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Font.sectionHeader)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Theme.cardStroke)
                .frame(height: 1)
            if let trailing { trailing }
        }
    }
}

/// Rounded translucent container used for every grouped block.
struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

/// A keyboard key, for shortcut hints and the shortcut editor.
struct KeyCap: View {
    let text: String
    var emphasized = false

    var body: some View {
        Text(text)
            .font(Theme.Font.keycap)
            .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(emphasized ? Color.accentColor.opacity(0.15) : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(emphasized ? Color.accentColor.opacity(0.35) : Theme.cardStroke, lineWidth: 1)
            )
            .fixedSize()
    }
}

/// Button that lights up under the cursor — AppKit gives this for free in
/// menus, but SwiftUI's `.plain` style needs it spelled out.
struct HoverButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .background(hovering ? Theme.hoverFill : Theme.cardFill,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.35) : Theme.cardStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Icon in a tinted rounded square — the recurring motif for tools and rows.
struct GlyphBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(tint.opacity(0.16))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}

/// Circular progress ring with an icon and label at its centre — the headline
/// readout for CPU, memory, and disk.
struct RingGauge: View {
    let symbol: String
    let label: String
    let value: Double        // 0...1
    let detail: String
    var tint: Color = .accentColor
    var diameter: CGFloat = 62

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: value)
                VStack(spacing: 1) {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.24, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: diameter * 0.15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: diameter, height: diameter)

            Text(detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Label + value row, the compact list style used under the gauges.
struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title).font(Theme.Font.body).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

/// Small circular dismiss button for the floating panels.
struct CloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .background(hovering ? Theme.hoverFill : Theme.cardFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close  (Esc)")
    }
}

/// Non-interactive stand-ins for Slider and Toggle.
///
/// `ImageRenderer` cannot draw AppKit-backed controls — they come out as a
/// "prohibited" glyph — so `--render-ui` swaps in these, which match the real
/// controls closely enough for documentation images.
struct StaticSlider: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(height: 3)
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1, max(0, value)), height: 3)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 11, height: 11)
                    .offset(x: (geo.size.width - 11) * min(1, max(0, value)))
            }
            .frame(height: geo.size.height, alignment: .center)
        }
        .frame(height: 12)
    }
}

struct StaticToggle: View {
    let isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 26, height: 15)
            .overlay(
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(1.5)
                    .frame(width: 15, height: 15)
                    .offset(x: isOn ? 5.5 : -5.5)
            )
    }
}

extension View {
    /// Standard page padding for the settings panes.
    func settingsPage() -> some View {
        self.padding(.horizontal, 2).padding(.top, 2)
    }
}
