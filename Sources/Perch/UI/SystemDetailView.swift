import SwiftUI
import AppKit

/// Which metric the System tab is showing in detail.
enum SystemMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, sound
    var id: String { rawValue }

    var short: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Mem"
        case .disk: return "Disk"
        case .network: return "Net"
        case .sound: return "Sound"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return .blue
        case .gpu: return .pink
        case .memory: return .green
        case .disk: return .orange
        case .network: return .teal
        case .sound: return .indigo
        }
    }
}

/// The System tab: pick a metric, see it in detail.
///
/// Each metric gets a headline gauge, a history trace, the specifics that only
/// make sense for that metric, and — for CPU and memory — what is actually
/// responsible, grouped by application.
struct SystemDetailView: View {
    @ObservedObject var monitor = SystemMonitor.shared
    @ObservedObject var hardware = HardwareStats.shared
    @ObservedObject var processes = ProcessMonitor.shared
    @Binding var metric: SystemMetric
    @ObservedObject private var audio = AudioControl.shared
    @State private var wifi: WiFiLink?
    @State private var query = ""
    @State private var pendingKill: ProcessGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            selector
            headline
            detail
        }
        .confirmationDialog(
            pendingKill.map { "Force quit \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingKill != nil },
                                 set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let group = pendingKill { quit(group, force: true) }
                pendingKill = nil
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: {
            Text("The app closes immediately. Unsaved work is lost.")
        }
        // Link details change slowly, so read them when the tab opens and then
        // alongside the sampler rather than on a timer of their own.
        .onAppear { refreshWiFi(); AudioControl.shared.start() }
        .onChange(of: metric) { _, _ in refreshWiFi() }
        .onReceive(hardware.$interfaces.dropFirst()) { _ in refreshWiFi() }
    }

    private func refreshWiFi() {
        guard metric == .network else { return }
        wifi = RenderMode.isActive ? RenderMode.demoWiFi : WiFiStats.read()
    }

    // MARK: - Selector

    private var selector: some View {
        HStack(spacing: 3) {
            ForEach(SystemMetric.allCases) { item in
                Button { metric = item } label: {
                    Text(item.short)
                        .font(.system(size: 10.5, weight: metric == item ? .semibold : .regular))
                        .foregroundStyle(metric == item ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(metric == item ? item.tint : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Headline gauge and trace

    private var headline: some View {
        let s = monitor.snapshot
        return Card(padding: 9) {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(headlineValue)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(metric.tint)
                    Text(headlineCaption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // Volume is a setting, not a measurement, so there is no
                // trace for it and the gauge should not reserve room for one.
                if !history.isEmpty {
                    Trace(values: history, tint: metric.tint)
                        .frame(height: 34)
                }
            }
        }
        .id(metric)          // reset the trace cleanly when the metric changes
        .onAppear { _ = s }
    }

    private var headlineValue: String {
        let s = monitor.snapshot
        switch metric {
        case .cpu: return String(format: "%.0f%%", s.cpuUsed)
        case .gpu: return hardware.gpuUsage.map { String(format: "%.0f%%", $0) } ?? "—"
        case .memory: return SystemMonitor.bytes(s.memUsed)
        case .disk: return SystemMonitor.bytes(s.diskFree)
        case .network:
            let total = hardware.interfaces.reduce(0.0) { $0 + $1.rateIn + $1.rateOut }
            return SystemMonitor.rate(total)
        case .sound:
            return audio.muted ? "Muted" : "\(Int(audio.volume * 100))%"
        }
    }

    private var headlineCaption: String {
        let s = monitor.snapshot
        switch metric {
        case .cpu: return String(format: "%.0f%% system · %d cores", s.cpuSystem, hardware.cores.count)
        case .gpu: return hardware.gpuName ?? "no reading"
        case .memory: return "of \(SystemMonitor.bytes(s.memTotal))"
        case .disk: return "free of \(SystemMonitor.bytes(s.diskTotal))"
        case .network: return "\(hardware.interfaces.count) active"
        case .sound: return audio.currentDevice?.name ?? "no output"
        }
    }

    private var history: [Double] {
        if RenderMode.isActive {
            switch metric {
            case .cpu:     return RenderMode.demoHistory(seed: 0, base: 26, swing: 16)
            case .gpu:     return RenderMode.demoHistory(seed: 3, base: 34, swing: 22)
            case .memory:  return RenderMode.demoHistory(seed: 7, base: 61, swing: 9)
            case .disk:    return RenderMode.demoHistory(seed: 5, base: 30, swing: 24)
            case .network: return RenderMode.demoHistory(seed: 9, base: 38, swing: 26)
            case .sound:   return []
            }
        }
        switch metric {
        case .cpu: return monitor.cpuHistory
        case .gpu: return hardware.gpuHistory
        case .memory: return monitor.memHistory
        case .disk: return hardware.diskHistory
        case .network: return hardware.netHistory
        // Volume is a setting rather than a measurement, so there is no trace
        // to draw; the gauge shows the level and the rows show who is using it.
        case .sound: return []
        }
    }

    // MARK: - Per-metric detail

    @ViewBuilder
    private var detail: some View {
        switch metric {
        case .cpu:
            cores
            processList(byMemory: false)
        case .gpu:
            gpuDetail
        case .memory:
            memoryDetail
            processList(byMemory: true)
        case .disk:
            diskDetail
        case .network:
            networkDetail
        case .sound:
            soundDetail
        }
    }

    /// Output level, where it is going, and what is currently audible.
    ///
    /// There are no per-app sliders because macOS has none to offer: a process
    /// audio object carries no volume control, and the only way round that is
    /// a virtual output device the whole system is routed through. That is a
    /// driver, and Perch is not one.
    @ViewBuilder
    private var soundDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Output")
            Card(padding: 9) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        HoverButton(action: { audio.toggleMute() }) {
                            Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(audio.muted ? AnyShapeStyle(Color.orange)
                                                             : AnyShapeStyle(.secondary))
                                .frame(width: 15)
                        }
                        .help(audio.muted ? "Unmute" : "Mute")

                        if RenderMode.isActive || !audio.volumeSettable {
                            StaticSlider(value: audio.volume)
                        } else {
                            Slider(value: Binding(get: { audio.volume },
                                                  set: { audio.setVolume($0) }), in: 0...1)
                                .controlSize(.mini)
                        }
                        Text("\(Int(audio.volume * 100))")
                            .font(Theme.Font.numeric).foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                    if !audio.volumeSettable {
                        Text("This output has no software volume.")
                            .font(Theme.Font.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if audio.devices.count > 1 {
                SectionHeader("Device")
                Card(padding: 8) {
                    VStack(spacing: 5) {
                        ForEach(audio.devices) { device in
                            HoverButton(action: { audio.select(device) }) {
                                HStack(spacing: 7) {
                                    Image(systemName: device == audio.currentDevice
                                          ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(device == audio.currentDevice
                                                         ? AnyShapeStyle(Color.indigo)
                                                         : AnyShapeStyle(.tertiary))
                                        .frame(width: 13)
                                    Text(device.name).font(Theme.Font.body)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }

            SectionHeader("Playing now")
            Card(padding: 9) {
                VStack(spacing: 6) {
                    if audio.players.isEmpty {
                        Text("Nothing is playing.")
                            .font(Theme.Font.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(audio.players) { player in
                        HStack(spacing: 7) {
                            if let icon = player.icon {
                                Image(nsImage: icon).resizable()
                                    .frame(width: 14, height: 14).cornerRadius(3)
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    .frame(width: 14)
                            }
                            Text(player.name).font(Theme.Font.body)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 9)).foregroundStyle(.indigo)
                        }
                    }
                }
            }
        }
    }

    private var cores: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Per core")
            Card(padding: 9) {
                VStack(spacing: 4) {
                    ForEach(hardware.cores) { core in
                        HStack(spacing: 7) {
                            Text("\(core.id)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12, alignment: .trailing)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.09))
                                    Capsule().fill(SystemMetric.cpu.tint.opacity(0.85))
                                        .frame(width: max(2, geo.size.width * core.usage / 100))
                                }
                            }
                            .frame(height: 5)
                            Text(String(format: "%.0f%%", core.usage))
                                .font(Theme.Font.numeric).foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var gpuDetail: some View {
        Card(padding: 9) {
            VStack(spacing: 6) {
                if hardware.gpuUsage == nil {
                    Text("This Mac's GPU does not publish a utilisation figure.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                } else {
                    InfoRow(symbol: "cpu", title: "Renderer",
                            value: hardware.gpuName ?? "GPU", tint: .pink)
                    InfoRow(symbol: "thermometer.medium", title: "Thermal",
                            value: monitor.snapshot.thermalPressure,
                            tint: monitor.snapshot.thermalPressure == "Nominal" ? .green : .orange)
                }
            }
        }
    }

    private var memoryDetail: some View {
        let s = monitor.snapshot
        return Card(padding: 9) {
            VStack(spacing: 6) {
                InfoRow(symbol: "memorychip", title: "Pressure",
                        value: "\(Int(s.memPressure * 100))%",
                        tint: s.memPressure > 0.8 ? .red : (s.memPressure > 0.6 ? .orange : .green))
                InfoRow(symbol: "arrow.left.arrow.right.square", title: "Swap used",
                        value: SystemMonitor.bytes(s.swapUsed),
                        tint: s.swapUsed > 2_000_000_000 ? .orange : .secondary)
                InfoRow(symbol: "square.stack.3d.up", title: "Total",
                        value: SystemMonitor.bytes(s.memTotal), tint: .green)
            }
        }
    }

    private var diskDetail: some View {
        let s = monitor.snapshot
        return Card(padding: 9) {
            VStack(spacing: 6) {
                InfoRow(symbol: "arrow.down.circle", title: "Read",
                        value: SystemMonitor.rate(hardware.diskRead), tint: .teal)
                InfoRow(symbol: "arrow.up.circle", title: "Write",
                        value: SystemMonitor.rate(hardware.diskWrite), tint: .indigo)
                Divider().opacity(0.4)
                InfoRow(symbol: "internaldrive", title: "Used",
                        value: SystemMonitor.bytes(s.diskTotal - s.diskFree), tint: .orange)
                InfoRow(symbol: "externaldrive", title: "Capacity",
                        value: SystemMonitor.bytes(s.diskTotal), tint: .secondary)
            }
        }
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let link = wifi {
                SectionHeader("Wi-Fi link")
                Card(padding: 9) {
                    VStack(spacing: 6) {
                        HStack(spacing: 7) {
                            SignalBars(filled: link.bars)
                            Text(link.quality).font(Theme.Font.body).foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text(verbatim: "\(Int(link.linkRateMbps)) Mbps")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.teal)
                        }
                        InfoRow(symbol: "antenna.radiowaves.left.and.right", title: "Signal",
                                value: "\(link.rssi) dBm · SNR \(link.snr) dB", tint: .secondary)
                        InfoRow(symbol: "dot.radiowaves.left.and.right", title: "Channel",
                                value: "\(link.channel) · \(link.band) · \(link.widthMHz) MHz",
                                tint: .secondary)
                        InfoRow(symbol: "wifi", title: link.standard,
                                value: link.security, tint: .secondary)
                    }
                }
            }

            SpeedTestRow()

            SectionHeader("Interfaces")
            Card(padding: 9) {
                VStack(spacing: 6) {
                    if hardware.interfaces.isEmpty {
                        Text("No active interfaces").font(Theme.Font.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(hardware.interfaces.prefix(4)) { iface in
                        VStack(spacing: 2) {
                            HStack(spacing: 7) {
                                Image(systemName: iface.name == "Wi-Fi" ? "wifi" : "cable.connector")
                                    .font(.system(size: 10)).foregroundStyle(.teal).frame(width: 14)
                                Text(iface.name).font(Theme.Font.body).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                // Down and up on one baseline, right-aligned in
                                // equal columns so the numbers line up.
                                Text(SystemMonitor.rate(iface.rateIn))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .trailing)
                                Text(SystemMonitor.rate(iface.rateOut))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                    }
                    HStack(spacing: 7) {
                        Spacer(minLength: 0)
                        Text("down").font(.system(size: 8.5)).foregroundStyle(.quaternary)
                            .frame(width: 58, alignment: .trailing)
                        Text("up").font(.system(size: 8.5)).foregroundStyle(.quaternary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Processes

    private func processList(byMemory: Bool) -> some View {
        let all = processes.groups
            .filter { byMemory ? $0.memory > 0 : $0.cpu > 0.05 }
            .sorted { byMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        let shown = query.isEmpty
            ? Array(all.prefix(6))
            : Array(all.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(6))

        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(byMemory ? "By memory" : "By CPU")
            Card(padding: 8) {
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        if RenderMode.isActive {
                            Text("Search process")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("Search process", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                    if shown.isEmpty {
                        Text("Nothing matching").font(Theme.Font.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(shown) { group in
                        HStack(spacing: 7) {
                            if let icon = group.icon {
                                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                            } else {
                                Image(systemName: group.isSystem ? "gearshape.2" : "terminal")
                                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                    .frame(width: 15)
                            }
                            Text(group.name).font(.system(size: 11)).lineLimit(1)
                            if group.childCount > 0 {
                                Text("+\(group.childCount)")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer(minLength: 4)
                            Text(byMemory
                                 ? (group.isSystem ? "—" : SystemMonitor.bytes(group.memory))
                                 : String(format: "%.2f%%", group.cpu))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            if group.isSystem {
                                Text("System processes cannot be ended from here")
                            } else {
                                Button("Quit \(group.name)") { quit(group, force: false) }
                                Button("Force Quit \(group.name)…", role: .destructive) {
                                    pendingKill = group
                                }
                                Divider()
                                Text(verbatim: "PID \(String(group.pid))")
                            }
                        }
                    }
                }
            }
        }
    }
}

extension SystemDetailView {
    /// Ends a process group.
    ///
    /// Quit asks the application to close, the way ⌘Q does, so it can save and
    /// clean up. Force Quit does not ask — hence the confirmation in front of
    /// it. Only processes owned by this user can be signalled at all; the
    /// System row is excluded because those belong to root.
    fileprivate func quit(_ group: ProcessGroup, force: Bool) {
        guard !group.isSystem, group.pid > 0 else { return }
        // Readings can be a couple of seconds old and pids get reused, so
        // confirm this is still the same process before signalling it.
        guard ProcessMonitor.stillMatches(pid: group.pid, command: group.command) else {
            Notifier.show("\(group.name) is no longer running",
                          "Nothing was ended.", duration: 3)
            return
        }

        if let app = NSRunningApplication(processIdentifier: group.pid) {
            let ended = force ? app.forceTerminate() : app.terminate()
            if !ended {
                Notifier.show("Could not end \(group.name)",
                              "macOS refused the request.", duration: 3)
            }
            return
        }
        // Not a registered application, so signal it directly.
        if kill(group.pid, force ? SIGKILL : SIGTERM) != 0 {
            Notifier.show("Could not end \(group.name)",
                          "It may belong to another user.", duration: 3)
        }
    }
}

/// Filled history trace used behind each headline figure.
struct Trace: Shape, @unchecked Sendable {
    let values: [Double]
    var tint: Color = .accentColor

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        p.move(to: CGPoint(x: 0, y: rect.height))
        for (i, v) in values.enumerated() {
            let y = rect.height * (1 - min(1, max(0, v / 100)))
            p.addLine(to: CGPoint(x: CGFloat(i) * step, y: y))
        }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

extension Trace: View {
    var body: some View {
        ZStack {
            self.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))
            self.stroke(tint.opacity(0.7), lineWidth: 1.2)
        }
    }
}

/// Signal strength as four bars, rated on signal-to-noise rather than raw
/// RSSI: a strong signal in a noisy room is not a good link.
private struct SignalBars: View {
    let filled: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? Color.teal : Color.secondary.opacity(0.25))
                    .frame(width: 2.5, height: 4 + CGFloat(i) * 2.5)
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
    }
}

/// Runs the throughput test and shows the result.
///
/// Deliberately a button rather than something that samples on its own: it is
/// the only outbound request Perch makes besides checking for updates, and it
/// moves real traffic, so it happens when asked and not otherwise.
private struct SpeedTestRow: View {
    @ObservedObject private var test = SpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader("Speed test")
            Card(padding: 9) {
                HStack(spacing: 8) {
                    // ImageRenderer cannot draw a live Button, so documentation
                    // images show a finished run instead of an empty control.
                    if RenderMode.isActive {
                        Text(verbatim: "112")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.teal)
                        Text(verbatim: "Mbps down · 53 ms")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text("Again").font(Theme.Font.body).foregroundStyle(.teal)
                    } else {
                    switch test.state {
                    case .idle:
                        Text("Measure actual throughput")
                            .font(Theme.Font.body).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Button("Run") { test.start() }
                            .buttonStyle(.borderless).font(Theme.Font.body)

                    case .latency:
                        ProgressView().controlSize(.small)
                        Text("Measuring latency")
                            .font(Theme.Font.body).foregroundStyle(.secondary)
                        Spacer(minLength: 0)

                    case .downloading(let mbps, let progress):
                        ProgressView(value: min(1, progress)).controlSize(.small)
                            .frame(width: 54)
                        Text(String(format: "%.0f Mbps", mbps))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.teal)
                        Spacer(minLength: 0)
                        Button("Stop") { test.cancel() }
                            .buttonStyle(.borderless).font(Theme.Font.body)

                    case .done(let down, let latency):
                        Text(String(format: "%.0f", down))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.teal)
                        Text(verbatim: "Mbps down · \(Int(latency)) ms")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Button("Again") { test.start() }
                            .buttonStyle(.borderless).font(Theme.Font.body)

                    case .failed(let why):
                        Text(why).font(Theme.Font.caption).foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        Button("Retry") { test.start() }
                            .buttonStyle(.borderless).font(Theme.Font.body)
                    }
                    }
                }
            }
        }
    }
}
