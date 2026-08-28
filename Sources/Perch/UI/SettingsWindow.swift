import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, windows, clipboard, disk, shortcuts
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .windows: return "macwindow"
        case .clipboard: return "doc.on.clipboard"
        case .disk: return "internaldrive"
        case .shortcuts: return "keyboard"
        }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(tab: SettingsTab = .general) {
        selection.tab = tab
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsRoot(selection: selection))
        let w = NSWindow(contentViewController: host)
        w.title = "Perch Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(CGSize(width: 640, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

private struct SettingsRoot: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .padding(14)
        .frame(width: 640, height: 520)
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .windows: WindowSettings()
        case .clipboard: ClipboardSettings()
        case .disk: DiskSettings()
        case .shortcuts: ShortcutSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var updater = Updater.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch Perch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LoginItem.set(enabled: $0) }))
                Picker("Menu bar shows", selection: Binding(
                    get: { prefs.menuBarStat }, set: { prefs.menuBarStat = $0 })) {
                    Text("Icon only").tag("none")
                    Text("CPU").tag("cpu")
                    Text("Memory").tag("mem")
                    Text("Network").tag("net")
                    Text("Battery").tag("bat")
                }
                Picker("Sample every", selection: Binding(
                    get: { prefs.sampleInterval }, set: { prefs.sampleInterval = $0; SystemMonitor.shared.start() })) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
            Section("Night mode") {
                Picker("Schedule", selection: Binding(
                    get: { prefs.nightSchedule },
                    set: { prefs.nightSchedule = $0; NightMode.shared.start() })) {
                    ForEach(NightMode.Schedule.allCases) { s in
                        Text(s.title).tag(s.rawValue)
                    }
                }
                if prefs.nightSchedule == NightMode.Schedule.custom.rawValue {
                    Stepper("From \(timeLabel(prefs.nightFromMinutes))",
                            value: Binding(get: { prefs.nightFromMinutes },
                                           set: { prefs.nightFromMinutes = $0; NightMode.shared.start() }),
                            in: 0...(23 * 60 + 30), step: 30)
                    Stepper("Until \(timeLabel(prefs.nightToMinutes))",
                            value: Binding(get: { prefs.nightToMinutes },
                                           set: { prefs.nightToMinutes = $0; NightMode.shared.start() }),
                            in: 0...(23 * 60 + 30), step: 30)
                }
                Text("Applied by rewriting the display gamma, the same mechanism f.lux and Night Shift use — it tints everything without an overlay and never shows up in screenshots.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Screen cleaning") {
                Picker("Start color", selection: Binding(
                    get: { prefs.screenCleanColor }, set: { prefs.screenCleanColor = $0 })) {
                    Text("Black").tag("black")
                    Text("White").tag("white")
                }
                Stepper("Cleaning lock lasts \(prefs.keyboardCleanSeconds)s",
                        value: Binding(get: { prefs.keyboardCleanSeconds }, set: { prefs.keyboardCleanSeconds = $0 }),
                        in: 5...300, step: 5)
            }
            Section("Updates") {
                LabeledContent("Version", value: updater.currentVersion)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { prefs.autoCheckUpdates }, set: { prefs.autoCheckUpdates = $0 }))
                HStack {
                    Button("Check now") { updater.check() }
                        .disabled(updater.state == .checking)
                    if case .available = updater.state {
                        Button("Download") { updater.downloadLatest() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Release notes") { updater.openReleasePage() }
                    if updater.state == .checking { ProgressView().controlSize(.small) }
                }
                Text("This is the only feature that uses the network. It contacts GitHub, compares versions, and verifies the download against the release checksum. Perch never installs an update itself — you drag it across.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(AX.isTrusted(prompt: false) ? "Granted" : "Not granted")
                            .foregroundStyle(AX.isTrusted(prompt: false) ? .green : .red)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Text("Window management, the switcher, keyboard cleaning, and paste-on-pick all need Accessibility access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - Windows

private struct WindowSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var layouts = CustomLayout.builtins

    var body: some View {
        Form {
            Section {
                Stepper("Gap between windows: \(prefs.windowGap) px",
                        value: Binding(get: { prefs.windowGap }, set: { prefs.windowGap = $0 }), in: 0...40, step: 2)
                Toggle("Animate window moves", isOn: Binding(
                    get: { prefs.animateWindows }, set: { prefs.animateWindows = $0 }))
                Text("Animation adds a short delay because each frame is a separate Accessibility call.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ask which window goes in which pane", isOn: Binding(
                    get: { prefs.askBeforeTiling }, set: { prefs.askBeforeTiling = $0 }))
                Text("Layouts otherwise fill panes from the stacking order. Perch only asks "
                   + "when there is a choice to make — more windows open than the layout has "
                   + "panes. Holding Option while picking a layout flips this either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window switcher") {
                Picker("Alt-Tab shows", selection: Binding(
                    get: { prefs.switcherStyle }, set: { prefs.switcherStyle = $0 })) {
                    ForEach(SwitcherStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Separate title switcher on its own shortcut", isOn: Binding(
                    get: { prefs.listSwitcherEnabled }, set: { prefs.listSwitcherEnabled = $0 }))
                LabeledContent("Live previews") {
                    HStack {
                        Text(WindowThumbnails.shared.isAuthorized ? "Enabled" : "Needs permission")
                            .foregroundStyle(WindowThumbnails.shared.isAuthorized ? .green : .orange)
                        if !WindowThumbnails.shared.isAuthorized {
                            Button("Grant…") { WindowThumbnails.shared.requestAuthorization() }
                        }
                    }
                }
                Text("Thumbnails need Screen Recording permission — macOS has no other way to show you another app's window. Without it the switcher falls back to large app icons, and everything else keeps working. Perch captures a window only while the switcher is on screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layouts") {
                ForEach(layouts) { layout in
                    HStack(spacing: 12) {
                        LayoutPreview(panes: layout.panes).frame(width: 54, height: 34)
                        VStack(alignment: .leading) {
                            Text(layout.name)
                            Text("\(layout.panes.count) panes").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { WindowManager.shared.apply(layout: layout) }
                    }
                }
                Text("Applying a layout tiles your frontmost windows into its panes, in order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LayoutPreview: View {
    let panes: [Pane]
    /// Tighter gaps and a lighter frame, for use inside the popover.
    var compact = false

    var body: some View {
        let inset: CGFloat = compact ? 1 : 1.5
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                ForEach(panes) { pane in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(compact ? 0.75 : 0.6))
                        .frame(width: max(2, geo.size.width * pane.w - inset * 2),
                               height: max(2, geo.size.height * pane.h - inset * 2))
                        .offset(x: geo.size.width * pane.x + inset, y: geo.size.height * pane.y + inset)
                }
            }
        }
    }
}

// MARK: - Clipboard

private struct ClipboardSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var store = ClipboardStore.shared
    @State private var newIgnored = ""

    var body: some View {
        Form {
            Section {
                Toggle("Record clipboard history", isOn: Binding(
                    get: { prefs.clipboardEnabled },
                    set: { prefs.clipboardEnabled = $0; $0 ? store.start() : store.stop() }))
                Toggle("Store images", isOn: Binding(
                    get: { prefs.clipboardStoreImages }, set: { prefs.clipboardStoreImages = $0 }))
                Toggle("Skip things that look like keys or tokens", isOn: Binding(
                    get: { prefs.clipboardSkipSecrets }, set: { prefs.clipboardSkipSecrets = $0 }))
                Toggle("Paste immediately when picked", isOn: Binding(
                    get: { prefs.clipboardPasteOnPick }, set: { prefs.clipboardPasteOnPick = $0 }))
                Stepper("Keep \(prefs.clipboardLimit) entries",
                        value: Binding(get: { prefs.clipboardLimit }, set: { prefs.clipboardLimit = $0 }),
                        in: 20...2000, step: 20)
                Stepper(prefs.clipboardKeepDays == 0 ? "Keep forever" : "Expire after \(prefs.clipboardKeepDays) days",
                        value: Binding(get: { prefs.clipboardKeepDays }, set: { prefs.clipboardKeepDays = $0 }),
                        in: 0...365, step: 5)
            }
            Section("Never record from") {
                ForEach(prefs.clipboardIgnoredApps, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            prefs.clipboardIgnoredApps.removeAll { $0 == bundleID }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("com.example.app", text: $newIgnored)
                    Button("Add") {
                        let v = newIgnored.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        prefs.clipboardIgnoredApps.append(v)
                        newIgnored = ""
                    }
                }
                Text("Apps that mark content as concealed (most password managers) are skipped automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Entries", value: "\(store.items.count)")
                HStack {
                    Button("Clear unpinned") { store.clearAll(keepPinned: true) }
                    Button("Clear everything", role: .destructive) { store.clearAll(keepPinned: false) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Disk

private struct DiskSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var cleaner = DiskCleaner.shared
    @State private var confirming = false
    @State private var newName = ""
    @State private var newPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                GlyphBadge(symbol: "internaldrive", tint: .purple, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(SystemMonitor.bytes(cleaner.totalReclaimable))
                        .font(.system(size: 16, weight: .semibold))
                    Text("reclaimable from enabled targets")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if cleaner.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Scan") { cleaner.scan() }
                Button("Clean enabled…") { confirming = true }
                    .disabled(cleaner.totalReclaimable == 0)
            }

            Text("Everything is moved to the Trash, never deleted outright — check it before emptying.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(cleaner.results.isEmpty ? prefs.diskTargets.map { ScanResult(target: $0, size: 0, fileCount: 0, exists: true) } : cleaner.results) { result in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { targetBinding(result.target)?.enabled ?? false },
                            set: { setEnabled($0, for: result.target) }))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.target.name)
                            Text(result.target.path).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        if !result.exists {
                            Text("not present").font(.caption).foregroundStyle(.tertiary)
                        } else {
                            Text(SystemMonitor.bytes(result.size))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if !result.target.builtin {
                            Button(role: .destructive) {
                                prefs.diskTargets.removeAll { $0.id == result.target.id }
                                cleaner.scan()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                TextField("Name", text: $newName).frame(width: 130)
                TextField("~/path/to/folder", text: $newPath)
                Button("Choose…") { chooseFolder() }
                Button("Add target") { addTarget() }
                    .disabled(newName.isEmpty || newPath.isEmpty)
            }
            if let reason = pathWarning {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { if cleaner.results.isEmpty { cleaner.scan() } }
        .confirmationDialog("Move \(SystemMonitor.bytes(cleaner.totalReclaimable)) to the Trash?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                cleaner.clean(prefs.diskTargets) { freed, failures in
                    Notifier.show("Reclaimed \(SystemMonitor.bytes(freed))",
                                  failures.isEmpty ? "Moved to the Trash." : "\(failures.count) items could not be moved.")
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func targetBinding(_ t: DiskTarget) -> DiskTarget? {
        prefs.diskTargets.first { $0.id == t.id }
    }

    private func setEnabled(_ value: Bool, for t: DiskTarget) {
        var all = prefs.diskTargets
        guard let i = all.firstIndex(where: { $0.id == t.id }) else { return }
        all[i].enabled = value
        prefs.diskTargets = all
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if newName.isEmpty { newName = url.lastPathComponent }
    }

    /// Shown live under the add-target row.
    private var pathWarning: String? {
        guard !newPath.isEmpty else { return nil }
        return PathGuard.rejectionReason(for: newPath)
    }

    private func addTarget() {
        guard PathGuard.isSafe(newPath) else {
            Notifier.show("That folder can't be a cleaning target",
                          PathGuard.rejectionReason(for: newPath))
            return
        }
        prefs.diskTargets.append(DiskTarget(name: newName, path: newPath))
        newName = ""; newPath = ""
        cleaner.scan()
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var prefs = Prefs.shared

    private let rows: [(String, String)] = [
        ("panel", "Open Perch panel"),
        ("clipboard", "Clipboard history"),
        ("switcher", "Window switcher"),
        ("switcher.altTab", "Alt-Tab (hold to switch)"),
        ("nightMode", "Night mode"),
        ("screenClean", "Screen cleaning"),
        ("keyboardClean", "Keyboard cleaning"),
        ("trackpadClean", "Trackpad cleaning"),
        ("win.left", "Window: left half"),
        ("win.right", "Window: right half"),
        ("win.top", "Window: top half"),
        ("win.bottom", "Window: bottom half"),
        ("win.thirdL", "Window: left third"),
        ("win.thirdC", "Window: center third"),
        ("win.thirdR", "Window: right third"),
        ("win.maximize", "Window: maximize"),
        ("win.center", "Window: center"),
        ("win.restore", "Window: restore size"),
        ("win.nextScreen", "Window: next display"),
        ("win.prevScreen", "Window: previous display"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Click a shortcut, then press the new combination. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(rows, id: \.0) { id, label in
                    HStack(spacing: 10) {
                        GlyphBadge(symbol: symbol(for: id), tint: tint(for: id), size: 22)
                        Text(label).font(Theme.Font.body)
                        Spacer()
                        HotkeyField(id: id)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "panel": return "bird.fill"
        case "clipboard": return "doc.on.clipboard"
        case "switcher": return "macwindow.on.rectangle"
        case "screenClean": return "sparkles.tv"
        case "keyboardClean": return "keyboard"
        case "trackpadClean": return "rectangle.and.hand.point.up.left"
        case "switcher.altTab": return "arrow.left.arrow.right"
        case "nightMode": return "moon.fill"
        default: return "macwindow"
        }
    }

    private func tint(for id: String) -> Color {
        switch id {
        case "panel": return .accentColor
        case "clipboard": return .orange
        case "switcher": return .blue
        case "screenClean": return .cyan
        case "keyboardClean": return .mint
        case "trackpadClean": return .pink
        case "switcher.altTab": return .blue
        case "nightMode": return .orange
        default: return .gray
        }
    }
}

/// Click to arm, then the next key press becomes the shortcut.
private struct HotkeyField: View {
    let id: String
    @State private var recording = false
    @State private var monitor: Any?
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Text(recording ? "Press keys…" : (prefs.hotkey(id)?.display ?? "None"))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(minWidth: 96)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(recording ? Color.accentColor.opacity(0.18) : Theme.cardFill,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .strokeBorder(recording ? Color.accentColor.opacity(0.5) : Theme.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stopRecording(); return nil }   // Escape cancels
            guard !mods.isEmpty else { return nil }                  // require a modifier
            Prefs.shared.setHotkey(id, HotkeySpec(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue))
            HotkeyManager.shared.rebind(id)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
