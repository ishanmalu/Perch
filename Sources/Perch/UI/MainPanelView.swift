import SwiftUI
import AppKit

/// The popover that drops out of the menu bar item — one place for stats,
/// window layouts, brightness, and the quick actions.
struct MainPanelView: View {
    @ObservedObject var monitor = SystemMonitor.shared
    @ObservedObject var brightness = BrightnessController.shared
    @ObservedObject var prefs = Prefs.shared
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            statsSection
            Divider()
            layoutSection
            Divider()
            brightnessSection
            Divider()
            actionsSection
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Stats

    private var statsSection: some View {
        let s = monitor.snapshot
        return VStack(spacing: 9) {
            Gauge(title: "CPU", value: s.cpuUsed / 100,
                  detail: String(format: "%.0f%%  ·  %.0f%% sys", s.cpuUsed, s.cpuSystem),
                  history: monitor.cpuHistory, tint: .blue)
            Gauge(title: "Memory", value: s.memPercent / 100,
                  detail: "\(SystemMonitor.bytes(s.memUsed)) of \(SystemMonitor.bytes(s.memTotal))",
                  history: monitor.memHistory, tint: memoryTint(s.memPressure))
            Gauge(title: "Disk", value: s.diskPercent / 100,
                  detail: "\(SystemMonitor.bytes(s.diskFree)) free", history: [], tint: .purple)

            HStack(spacing: 12) {
                pill("arrow.down", SystemMonitor.rate(s.netIn))
                pill("arrow.up", SystemMonitor.rate(s.netOut))
                Spacer()
                if let b = s.batteryPercent {
                    pill(s.batteryCharging ? "battery.100.bolt" : "battery.50", "\(b)%")
                }
                pill("clock", SystemMonitor.duration(s.uptime))
            }
            .font(.system(size: 10.5))
        }
    }

    private func memoryTint(_ pressure: Double) -> Color {
        pressure > 0.8 ? .red : (pressure > 0.6 ? .orange : .green)
    }

    private func pill(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Layouts

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Windows")
            HStack(spacing: 6) {
                ForEach([WindowAction.left, .right, .top, .bottom], id: \.self) { tile($0) }
            }
            HStack(spacing: 6) {
                ForEach([WindowAction.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { tile($0) }
            }
            HStack(spacing: 6) {
                ForEach([WindowAction.thirdLeft, .thirdCenter, .thirdRight, .maximize], id: \.self) { tile($0) }
            }
            HStack(spacing: 6) {
                ForEach(CustomLayout.builtins) { layout in
                    Button(layout.name) { WindowManager.shared.apply(layout: layout) }
                        .buttonStyle(.bordered).controlSize(.small).font(.system(size: 10))
                }
            }
        }
    }

    private func tile(_ action: WindowAction) -> some View {
        Button {
            WindowManager.shared.apply(action)
        } label: {
            TileGlyph(pane: action.unitRect(step: 0))
                .frame(width: 34, height: 22)
        }
        .buttonStyle(.plain)
        .help(action.title)
    }

    // MARK: - Brightness

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Brightness")
            ForEach(brightness.displays) { display in
                HStack(spacing: 8) {
                    Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Slider(value: Binding(
                        get: { display.level },
                        set: { brightness.setLevel($0, for: display.id) }
                    ), in: 0...1)
                    Text("\(Int(display.level * 100))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                }
                .help(display.isBuiltin ? display.name : "\(display.name) — software dimming")
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Tools")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                action("sparkles.tv", "Screen clean") { ScreenCleaner.shared.start() }
                action("keyboard", "Keyboard clean") { KeyboardCleaner.shared.start() }
                action("doc.on.clipboard", "Clipboard") { ClipboardPanelController.shared.toggle() }
                action("macwindow.on.rectangle", "Switcher") { WindowSwitcher.shared.toggle() }
                action("internaldrive", "Disk clean") { SettingsWindow.shared.show(tab: .disk) }
                action("gearshape", "Settings", action: onOpenSettings)
            }
        }
    }

    private func action(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 9.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("Perch").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit", action: onQuit).buttonStyle(.borderless).font(.system(size: 10))
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
    }
}

/// Horizontal bar with a faint sparkline of recent samples behind it.
private struct Gauge: View {
    let title: String
    let value: Double
    let detail: String
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    if !history.isEmpty { Sparkline(values: history).stroke(tint.opacity(0.35), lineWidth: 1) }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(0.75))
                        .frame(width: max(2, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 6)
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
                RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: geo.size.width * pane.w - 3, height: geo.size.height * pane.h - 3)
                    .offset(x: geo.size.width * pane.x + 1.5, y: geo.size.height * pane.y + 1.5)
            }
        }
    }
}
