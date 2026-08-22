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
    @ObservedObject var sleepBlocker = PreventSleep.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    /// How tall the popover may grow before its contents start scrolling.
    /// Passed in from the screen the menu bar item sits on.
    var maxHeight: CGFloat = 700
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    /// Closes the popover before opening something that needs focus.
    var onDismiss: () -> Void = {}
    /// Renders without the ScrollView, for `--render-ui` previews: ImageRenderer
    /// draws a ScrollView's contents as blank.
    var flattened = false
    /// Which tab to open on; only used by `--render-ui`.
    var initialTab: PanelTab? = nil

    @State private var tab: PanelTab = .system
    @State private var metric: SystemMetric = .cpu

    enum PanelTab: String, CaseIterable, Identifiable {
        case system, screen, tools
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .system: return "gauge.medium"
            case .screen: return "macwindow"
            case .tools: return "wrench.and.screwdriver"
            }
        }
    }

    /// Each tab is exactly as tall as its own content, so no tab carries dead
    /// space and none of them scroll. The popover follows because its hosting
    /// controller tracks the SwiftUI size (`sizingOptions`) rather than being
    /// handed one fixed size up front — setting it once was what previously
    /// left the popover clipping its own header.
    ///
    /// The cap only engages on a display too short to show a tab outright; that
    /// is the single case where scrolling is preferable to overflowing.
    private var contentCap: CGFloat { max(150, maxHeight - 120) }

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            if flattened {
                // ImageRenderer draws a ScrollView's contents as blank, so
                // `--render-ui` previews bypass it.
                sections
            } else {
                ScrollView(.vertical) {
                    sections
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
                .frame(height: min(max(contentHeight, 80), contentCap))
            }

            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            if let initialTab { tab = initialTab }
            syncSampling()
        }
        .onChange(of: tab) { _, _ in syncSampling() }
        .onDisappear {
            HardwareStats.shared.stop()
            ProcessMonitor.shared.stop()
        }
    }

    /// Per-core, GPU and per-process sampling walks a lot of kernel structures,
    /// so it runs only while the System tab is actually visible.
    private func syncSampling() {
        if tab == .system {
            HardwareStats.shared.start()
            ProcessMonitor.shared.start()
        } else {
            HardwareStats.shared.stop()
            ProcessMonitor.shared.stop()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol).font(.system(size: 11.5))
                        Text(item.title).font(.system(size: 9))
                    }
                    .foregroundStyle(tab == item ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(tab == item ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var sections: some View {
        Group {
            switch tab {
            case .system: statsSection
            case .screen: screenSection
            case .tools: toolsSection
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Perch").font(.system(size: 12.5, weight: .semibold))
            Spacer()
            iconButton("doc.on.clipboard", help: "Clipboard History  (⌘⇧V)") {
                onDismiss()
                ClipboardPanelController.shared.toggle()
            }
            iconButton("gearshape", help: "Settings", action: onOpenSettings)
            iconButton("power", help: "Quit Perch", action: onQuit)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
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
        SystemDetailView(metric: $metric)
    }

    // MARK: - Windows

    /// Windows and display controls together: everything about the screen
    /// in front of you.
    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            windowsSection
            displaySection
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Layout")
            Card(padding: 8) {
                VStack(spacing: 5) {
                    ForEach(tileRows, id: \.first) { row in
                        HStack(spacing: 5) {
                            ForEach(row, id: \.self) { tile($0) }
                        }
                    }
                    Divider().opacity(0.4)
                    HStack(spacing: 5) {
                        ForEach(CustomLayout.builtins) { layout in
                            HoverButton(action: { WindowManager.shared.apply(layout: layout) }) {
                                LayoutPreview(panes: layout.panes, compact: true)
                                    .frame(height: 22)
                                    .frame(maxWidth: .infinity)
                                    .padding(3)
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
                .frame(height: 26)
                .frame(maxWidth: .infinity)
                .padding(3)
        }
        .help(action.title)
    }

    // MARK: - Brightness

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Brightness & night")
            Card(padding: 9) {
                VStack(spacing: 7) {
                    ForEach(brightness.displays) { display in
                        HStack(spacing: 7) {
                            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 13)
                            if flattened {
                                StaticSlider(value: display.level)
                            } else {
                                Slider(value: Binding(
                                    get: { display.level },
                                    set: { brightness.setLevel($0, for: display.id) }
                                ), in: 0...1)
                                .controlSize(.mini)
                            }
                            Text("\(Int(display.level * 100))")
                                .font(Theme.Font.numeric)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 26, alignment: .trailing)
                        }
                        .help(display.isBuiltin ? display.name : "\(display.name) — software dimming")
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 7) {
                        Image(systemName: night.isActive ? "moon.fill" : "moon")
                            .font(.system(size: 10))
                            .foregroundStyle(night.isActive ? Color.orange : .secondary)
                            .frame(width: 13)
                        if night.isActive {
                            if flattened {
                                StaticSlider(value: (night.temperature - 2400) / 4100)
                            } else {
                                Slider(value: Binding(get: { night.temperature },
                                                      set: { night.temperature = $0 }),
                                       in: 2400...6500)
                                .controlSize(.mini)
                            }
                            Text("\(Int(night.temperature))K")
                                .font(Theme.Font.numeric)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 44, alignment: .trailing)
                        } else {
                            Text("Night Mode").font(Theme.Font.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        if flattened {
                            StaticToggle(isOn: night.isActive)
                        } else {
                            Toggle("", isOn: Binding(get: { night.isActive }, set: { _ in night.toggle() }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Tools")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    tool("sparkles.tv", "Screen Clean", .cyan) { ScreenCleaner.shared.start() }
                    tool("keyboard", "Keyboard Clean", .mint) { InputCleaner.shared.start(.keyboard) }
                    tool("doc.on.clipboard", "Clipboard", .orange) { ClipboardPanelController.shared.toggle() }
                    tool("macwindow.on.rectangle", "Switcher", .blue) { WindowSwitcher.shared.toggle() }
                    tool("internaldrive", "Disk Clean", .purple) { SettingsWindow.shared.show(tab: .disk) }
                    tool("rectangle.and.hand.point.up.left", "Trackpad Clean", .pink) {
                        InputCleaner.shared.start(.trackpad)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionHeader("Switches")
                Card(padding: 9) {
                    VStack(spacing: 8) {
                        switchRow("cup.and.saucer.fill", "Prevent Sleep", .brown,
                                  isOn: sleepBlocker.isActive) { sleepBlocker.toggle() }
                        Divider().opacity(0.4)
                        switchRow("doc.on.clipboard.fill", "Record Clipboard", .orange,
                                  isOn: prefs.clipboardEnabled) {
                            prefs.clipboardEnabled.toggle()
                            prefs.clipboardEnabled ? ClipboardStore.shared.start() : ClipboardStore.shared.stop()
                        }
                        Divider().opacity(0.4)
                        switchRow("power", "Launch at Login", .green, isOn: launchAtLogin) {
                            launchAtLogin.toggle()
                            LoginItem.set(enabled: launchAtLogin)
                        }
                    }
                }
            }
        }
    }

    private func switchRow(_ symbol: String, _ title: String, _ tint: Color,
                           isOn: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(isOn ? tint : .secondary)
                .frame(width: 14)
            Text(title).font(Theme.Font.body).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if flattened {
                StaticToggle(isOn: isOn)
            } else {
                Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    private func tool(_ symbol: String, _ title: String, _ tint: Color,
                     action: @escaping () -> Void) -> some View {
        HoverButton(action: action) {
            VStack(spacing: 3) {
                GlyphBadge(symbol: symbol, tint: tint, size: 24)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 7) {
            updateGlyph
            Text(footerText)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if case .available = updater.state {
                HoverButton(action: { updater.downloadLatest() }) {
                    Text("Download").font(Theme.Font.keycap)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                }
            } else if !isBusy {
                HoverButton(action: { updater.check() }) {
                    Text("Check").font(Theme.Font.keycap)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }

    private var isBusy: Bool {
        if case .checking = updater.state { return true }
        if case .downloading = updater.state { return true }
        return false
    }

    @ViewBuilder
    private var updateGlyph: some View {
        switch updater.state {
        case .checking, .downloading:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 13, height: 13)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.orange)
        default:
            Image(systemName: "bird.fill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var footerText: String {
        switch updater.state {
        case .checking: return "Checking for updates…"
        case .available(let v): return "Perch \(v) available"
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .ready: return "Downloaded — revealed in Finder"
        case .upToDate: return "Perch \(updater.currentVersion) — up to date"
        case .failed(let why): return why
        case .idle: return "Perch \(updater.currentVersion)"
        }
    }
}

/// Each tab reports its natural height so the panel can size to it exactly.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Labelled bar with a faint sparkline of recent samples behind the fill.
private struct StatRow: View {
    let title: String
    let value: Double
    let detail: String
    let history: [Double]
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 27, alignment: .leading)
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
            .frame(height: 6)
            Text(detail)
                .font(Theme.Font.numeric)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
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
