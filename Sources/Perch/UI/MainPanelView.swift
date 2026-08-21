import SwiftUI
import AppKit

/// The popover that drops out of the menu bar item — stats, window layouts,
/// brightness, tools, and updates in one column.
struct MainPanelView: View {
    @ObservedObject var monitor = SystemMonitor.shared
    @ObservedObject var brightness = BrightnessController.shared
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var updater = Updater.shared
    @ObservedObject var night = NightMode.shared

    /// How tall the popover may grow before its contents start scrolling.
    /// Passed in from the screen the menu bar item sits on.
    var maxHeight: CGFloat = 700
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    statsSection
                    windowsSection
                    brightnessSection
                    nightSection
                    toolsSection
                    updateSection
                }
                .padding(Theme.Space.inset)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                })
            }
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 120), maxHeight))
        }
        .frame(width: 348)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Perch").font(.system(size: 13, weight: .semibold))
            Text(updater.currentVersion)
                .font(Theme.Font.numeric)
                .foregroundStyle(.tertiary)
            Spacer()
            iconButton("gearshape", help: "Settings", action: onOpenSettings)
            iconButton("power", help: "Quit Perch", action: onQuit)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 10)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 21)
        }
        .help(help)
    }

    // MARK: - Stats

    private var statsSection: some View {
        let s = monitor.snapshot
        return VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("System")
            Card {
                VStack(spacing: 9) {
                    StatBar(title: "CPU", value: s.cpuUsed / 100,
                            detail: String(format: "%.0f%%", s.cpuUsed),
                            history: monitor.cpuHistory, tint: .blue)
                    StatBar(title: "Memory", value: s.memPercent / 100,
                            detail: SystemMonitor.bytes(s.memUsed),
                            history: monitor.memHistory, tint: memoryTint(s.memPressure))
                    StatBar(title: "Disk", value: s.diskPercent / 100,
                            detail: "\(SystemMonitor.bytes(s.diskFree)) free",
                            history: [], tint: .purple)

                    Divider().opacity(0.5)

                    HStack(spacing: 0) {
                        chip("arrow.down", SystemMonitor.rate(s.netIn), .teal)
                        chip("arrow.up", SystemMonitor.rate(s.netOut), .indigo)
                        if let b = s.batteryPercent {
                            chip(s.batteryCharging ? "bolt.fill" : "battery.50", "\(b)%",
                                 b < 20 && !s.batteryCharging ? .red : .green)
                        }
                        chip("clock", SystemMonitor.duration(s.uptime), .orange)
                    }
                }
            }
        }
    }

    private func memoryTint(_ pressure: Double) -> Color {
        pressure > 0.8 ? .red : (pressure > 0.6 ? .orange : .green)
    }

    private func chip(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5)).foregroundStyle(tint)
            Text(text).font(Theme.Font.numeric).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Windows

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("Windows") {
                Text("⌃⌥ + arrows").font(Theme.Font.keycap).foregroundStyle(.quaternary)
            }
            Card {
                VStack(spacing: 8) {
                    ForEach(tileRows, id: \.first) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { tile($0) }
                        }
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: 5) {
                        ForEach(CustomLayout.builtins) { layout in
                            HoverButton(action: { WindowManager.shared.apply(layout: layout) }) {
                                VStack(spacing: 3) {
                                    LayoutPreview(panes: layout.panes, compact: true)
                                        .frame(width: 30, height: 19)
                                    Text(layout.name)
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                            }
                            .help("Tile frontmost windows into \(layout.name)")
                        }
                    }
                }
            }
        }
    }

    private var tileRows: [[WindowAction]] {
        [[.left, .right, .top, .bottom],
         [.topLeft, .topRight, .bottomLeft, .bottomRight],
         [.thirdLeft, .thirdCenter, .thirdRight, .maximize]]
    }

    private func tile(_ action: WindowAction) -> some View {
        HoverButton(action: { WindowManager.shared.apply(action) }) {
            TileGlyph(pane: action.unitRect(step: 0))
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .padding(4)
        }
        .help(action.title)
    }

    // MARK: - Brightness

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("Brightness")
            Card {
                VStack(spacing: 8) {
                    ForEach(brightness.displays) { display in
                        HStack(spacing: 9) {
                            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                            Slider(value: Binding(
                                get: { display.level },
                                set: { brightness.setLevel($0, for: display.id) }
                            ), in: 0...1)
                            .controlSize(.small)
                            Text("\(Int(display.level * 100))")
                                .font(Theme.Font.numeric)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                        .help(display.isBuiltin ? display.name : "\(display.name) — software dimming")
                    }
                    if brightness.displays.isEmpty {
                        Text("No displays detected").font(Theme.Font.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Night mode

    private var nightSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("Night") {
                Text("⌃⌥N").font(Theme.Font.keycap).foregroundStyle(.quaternary)
            }
            Card {
                VStack(spacing: 8) {
                    HStack(spacing: 9) {
                        GlyphBadge(symbol: night.isActive ? "moon.fill" : "sun.max",
                                   tint: night.isActive ? .orange : .gray, size: 25)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(night.isActive ? "Warming the screen" : "Night mode off")
                                .font(Theme.Font.title)
                            Text(night.isActive
                                 ? "\(Int(night.temperature))K — gamma, not an overlay"
                                 : "Cuts blue light after dark")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { night.isActive },
                            set: { _ in night.toggle() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    if night.isActive {
                        HStack(spacing: 9) {
                            Image(systemName: "thermometer.low")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 15)
                            Slider(value: Binding(
                                get: { night.temperature },
                                set: { night.temperature = $0 }
                            ), in: 2400...6500)
                            .controlSize(.small)
                            Text("\(Int(night.temperature))K")
                                .font(Theme.Font.numeric).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("Tools")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                tool("sparkles.tv", "Screen clean", .cyan) { ScreenCleaner.shared.start() }
                tool("keyboard", "Keyboard clean", .mint) { KeyboardCleaner.shared.start() }
                tool("doc.on.clipboard", "Clipboard", .orange) { ClipboardPanelController.shared.toggle() }
                tool("macwindow.on.rectangle", "Switcher", .blue) { WindowSwitcher.shared.toggle() }
                tool("internaldrive", "Disk clean", .purple) { SettingsWindow.shared.show(tab: .disk) }
                tool("gearshape", "Settings", .gray, action: onOpenSettings)
            }
        }
    }

    private func tool(_ symbol: String, _ title: String, _ tint: Color,
                     action: @escaping () -> Void) -> some View {
        HoverButton(action: action) {
            VStack(spacing: 5) {
                GlyphBadge(symbol: symbol, tint: tint, size: 25)
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
    }

    // MARK: - Updates

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            SectionHeader("Updates")
            Card(padding: 9) {
                HStack(spacing: 9) {
                    updateIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updateTitle).font(Theme.Font.title)
                        Text(updateSubtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    updateAction
                }
            }
        }
    }

    @ViewBuilder
    private var updateIcon: some View {
        switch updater.state {
        case .checking, .downloading:
            ProgressView().controlSize(.small).frame(width: 25, height: 25)
        case .available:
            GlyphBadge(symbol: "arrow.down.circle.fill", tint: .green, size: 25)
        case .failed:
            GlyphBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, size: 25)
        case .ready:
            GlyphBadge(symbol: "checkmark.circle.fill", tint: .green, size: 25)
        default:
            GlyphBadge(symbol: "arrow.triangle.2.circlepath", tint: .gray, size: 25)
        }
    }

    private var updateTitle: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .available(let v): return "Perch \(v) available"
        case .downloading: return "Downloading…"
        case .ready: return "Downloaded"
        case .upToDate: return "Up to date"
        case .failed: return "Check failed"
        case .idle: return "Check for updates"
        }
    }

    private var updateSubtitle: String {
        switch updater.state {
        case .available: return "Verified download, then drag to Applications."
        case .downloading(let p): return "\(Int(p * 100))% — verifying against published checksum."
        case .ready: return "Revealed in Finder. Open it and drag Perch across."
        case .upToDate: return "You're on \(updater.currentVersion)."
        case .failed(let why): return why
        case .checking: return "Asking GitHub for the latest release."
        case .idle:
            if let last = updater.lastChecked {
                return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Perch only contacts the network when you ask."
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.state {
        case .available:
            HoverButton(action: { updater.downloadLatest() }) {
                Text("Download").font(Theme.Font.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        case .ready:
            HoverButton(action: { updater.openReleasePage() }) {
                Text("Notes").font(Theme.Font.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        case .checking, .downloading:
            EmptyView()
        default:
            HoverButton(action: { updater.check() }) {
                Text("Check").font(Theme.Font.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
    }
}

/// Reports the natural height of the panel contents so the popover can cap
/// itself to the screen instead of running off the top of it.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Labelled bar with a faint sparkline of recent samples behind the fill.
private struct StatBar: View {
    let title: String
    let value: Double
    let detail: String
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(Theme.Font.numeric)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if !history.isEmpty {
                        Sparkline(values: history)
                            .stroke(tint.opacity(0.30), lineWidth: 1)
                            .clipShape(Capsule())
                    }
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 7)
        }
    }
}

private struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        for (i, v) in values.enumerated() {
            let x = rect.width * Double(i) / Double(values.count - 1)
            let y = rect.height * (1 - min(1, max(0, v / 100)))
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}

/// Miniature preview of where a window will land.
struct TileGlyph: View {
    let pane: Pane
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.6)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: max(2, geo.size.width * pane.w - 3),
                           height: max(2, geo.size.height * pane.h - 3))
                    .offset(x: geo.size.width * pane.x + 1.5, y: geo.size.height * pane.y + 1.5)
            }
        }
    }
}
