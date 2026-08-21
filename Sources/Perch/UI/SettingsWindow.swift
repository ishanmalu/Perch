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
            Section("Screen cleaning") {
                Picker("Start color", selection: Binding(
                    get: { prefs.screenCleanColor }, set: { prefs.screenCleanColor = $0 })) {
                    Text("Black").tag("black")
                    Text("White").tag("white")
                }
                Stepper("Keyboard lock: \(prefs.keyboardCleanSeconds)s",
                        value: Binding(get: { prefs.keyboardCleanSeconds }, set: { prefs.keyboardCleanSeconds = $0 }),
                        in: 5...300, step: 5)
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
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07))
                ForEach(panes) { pane in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: geo.size.width * pane.w - 3, height: geo.size.height * pane.h - 3)
                        .offset(x: geo.size.width * pane.x + 1.5, y: geo.size.height * pane.y + 1.5)
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
            HStack {
                Text("Reclaimable: \(SystemMonitor.bytes(cleaner.totalReclaimable))")
                    .font(.system(size: 13, weight: .semibold))
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
        ("screenClean", "Screen cleaning"),
        ("keyboardClean", "Keyboard cleaning"),
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
            Text("Click a shortcut, then press the new combination.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(rows, id: \.0) { id, label in
                    HStack {
                        Text(label)
                        Spacer()
                        HotkeyField(id: id)
                    }
                }
            }
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
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 90)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(recording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 5))
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
