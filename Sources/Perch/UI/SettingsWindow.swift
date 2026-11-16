import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, displays, windows, menuBar, clipboard, battery, apps, disk, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "Menu Bar & Focus"
        case .clipboard: return "Clipboard & Snippets"
        default: return rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .displays: return "display"
        case .windows: return "macwindow"
        case .menuBar: return "menubar.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .battery: return "battery.75percent"
        case .apps: return "trash"
        case .disk: return "internaldrive"
        case .shortcuts: return "keyboard"
        }
    }
    /// Same tints the panel uses for these tools, so the two read as one app.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .displays: return .teal
        case .windows: return .blue
        case .menuBar: return .pink
        case .clipboard: return .orange
        case .battery: return .green
        case .apps: return .red
        case .disk: return .purple
        case .shortcuts: return .indigo
        }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    /// With no tab given, reopens on the page the user last looked at.
    func show(tab: SettingsTab? = nil) {
        selection.tab = tab ?? SettingsTab(rawValue: Prefs.shared.settingsTab) ?? .general
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsRoot(selection: selection))
        let w = SettingsNSWindow(contentViewController: host)
        w.title = "Perch Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.setContentSize(CGSize(width: 780, height: 560))
        w.contentMinSize = CGSize(width: 700, height: 460)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general {
        didSet { Prefs.shared.settingsTab = tab.rawValue }
    }
}

/// Perch has no main menu (it is a menu bar app), so the standard window
/// shortcuts have nothing to route through. Handle ⌘W and ⌘M here.
private final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "w": performClose(nil); return true
            case "m": performMiniaturize(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct SettingsRoot: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(
                get: { selection.tab }, set: { if let t = $0 { selection.tab = t } })) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    GlyphBadge(symbol: tab.symbol, tint: tab.tint, size: 20)
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            page(selection.tab)
                .navigationTitle(selection.tab.title)
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .displays: DisplaySettings()
        case .windows: WindowSettings()
        case .menuBar: MenuBarSettings()
        case .clipboard: ClipboardSettings()
        case .battery: BatterySettings()
        case .apps: AppsSettings()
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
                    get: { prefs.menuBarStat }, set: { prefs.menuBarStat = $0; SystemMonitor.shared.reschedule() })) {
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
                // Live: re-checked on return from System Settings and every
                // second while this page is open.
                PermissionRows()
                Button("Show Welcome Window…") { OnboardingWindow.shared.show() }
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
                Toggle("Drag a window to a screen edge to tile it", isOn: Binding(
                    get: { prefs.snapEnabled },
                    set: { prefs.snapEnabled = $0; WindowSnapping.shared.sync() }))
                Text("Left or right edge for halves, top to fill, corners for quarters. "
                   + "A preview shows where it will land; let go anywhere else and nothing happens.")
                    .font(.caption).foregroundStyle(.secondary)
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
            ExcludedAppsSection()
            WorkspaceSection()
            Section("Screenshots") {
                Toggle("Stay armed for another after each capture", isOn: Binding(
                    get: { prefs.screenshotBurst }, set: { prefs.screenshotBurst = $0 }))
                Text("The reason this exists next to the built-in tool: several captures "
                   + "in a row are one drag each, rather than a trip to the keyboard between "
                   + "them. Escape finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Save a PNG", isOn: Binding(
                    get: { prefs.screenshotToFile }, set: { prefs.screenshotToFile = $0 }))
                Toggle("Copy to the clipboard", isOn: Binding(
                    get: { prefs.screenshotToClipboard }, set: { prefs.screenshotToClipboard = $0 }))
                HStack {
                    Text("Saved to \(Screenshot.saveFolder().path)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseScreenshotFolder() }
                    Button("Show") {
                        NSWorkspace.shared.open(Screenshot.saveFolder())
                    }
                }
            }

            Section("Keep awake") {
                Toggle("Let the display sleep during a session", isOn: Binding(
                    get: { prefs.allowDisplaySleep },
                    set: { prefs.allowDisplaySleep = $0; PreventSleep.shared.refreshAssertionType() }))
                Text("The Mac keeps working but the screen can turn off — right for a long "
                   + "download, wrong for a presentation.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Start a session", selection: Binding(
                    get: { prefs.wakeTrigger },
                    set: { prefs.wakeTrigger = $0; PreventSleep.shared.triggerChanged() })) {
                    ForEach(SleepTrigger.allCases) { t in Text(t.title).tag(t.rawValue) }
                }

                if prefs.wakeTrigger == SleepTrigger.appRunning.rawValue {
                    Picker("Watch for", selection: Binding(
                        get: { prefs.wakeTriggerApp }, set: { prefs.wakeTriggerApp = $0 })) {
                        Text("Choose an app").tag("")
                        ForEach(RunningApps.list, id: \.0) { app in Text(app.1).tag(app.0) }
                    }
                    Text("Listed from what is running now. The session lasts as long as it does.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if prefs.wakeTrigger == SleepTrigger.cpuBusy.rawValue {
                    Stepper("Busy above \(prefs.wakeTriggerCPU)% CPU", value: Binding(
                        get: { prefs.wakeTriggerCPU }, set: { prefs.wakeTriggerCPU = $0 }),
                        in: 5...95, step: 5)
                }

                Stepper(prefs.endOnLowBattery.map { "End the session below \($0)% battery" }
                          ?? "Never end on low battery",
                        value: Binding(get: { prefs.endOnLowBattery ?? 0 },
                                       set: { prefs.endOnLowBattery = $0 }),
                        in: 0...50, step: 5)
                Text("Only applies on battery. Set to zero to keep going regardless.")
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
            SnippetSection()
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
    @State private var query = ""
    @State private var confirmReset = false

    static let groups: [(String, [(String, String)])] = [
        ("General", [
            ("panel", "Open Perch Panel"),
            ("clipboard", "Clipboard History"),
            ("switcher", "Window Switcher"),
            ("switcher.altTab", "Alt-Tab (Hold to Switch)"),
            ("screenshot", "Screenshot"),
            ("focus", "Start / Stop Focus Timer"),
            ("menuHider", "Show / Hide Menu Bar Icons"),
        ]),
        ("Windows", [
            ("win.left", "Left Half"),
            ("win.right", "Right Half"),
            ("win.top", "Top Half"),
            ("win.bottom", "Bottom Half"),
            ("win.topLeft", "Top Left Quarter"),
            ("win.topRight", "Top Right Quarter"),
            ("win.bottomLeft", "Bottom Left Quarter"),
            ("win.bottomRight", "Bottom Right Quarter"),
            ("win.thirdL", "Left Third"),
            ("win.thirdC", "Center Third"),
            ("win.thirdR", "Right Third"),
            ("win.maximize", "Maximize"),
            ("win.center", "Center"),
            ("win.restore", "Restore Size"),
            ("win.nextScreen", "Next Display"),
            ("win.prevScreen", "Previous Display"),
        ]),
        ("Display", [
            ("nightMode", "Night Mode"),
            ("brightness.up", "Brightness Up"),
            ("brightness.down", "Brightness Down"),
        ]),
        ("Cleaning", [
            ("screenClean", "Screen Cleaning"),
            ("keyboardClean", "Keyboard Cleaning"),
            ("trackpadClean", "Trackpad Cleaning"),
        ]),
    ]

    /// Human name for a shortcut id, for conflict messages.
    static func label(for id: String) -> String {
        groups.flatMap(\.1).first { $0.0 == id }?.1 ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Click a shortcut, then press the new combination. Esc cancels, ⌫ clears.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("Restore Defaults…") { confirmReset = true }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            List {
                ForEach(Self.groups, id: \.0) { group in
                    let rows = group.1.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }
                    if !rows.isEmpty {
                        Section(group.0) {
                            ForEach(rows, id: \.0) { id, label in
                                HStack(spacing: 10) {
                                    GlyphBadge(symbol: symbol(for: id), tint: tint(for: id), size: 22)
                                        .accessibilityHidden(true)
                                    Text(label).font(Theme.Font.body)
                                    Spacer()
                                    HotkeyField(id: id, label: label)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Restore all shortcuts to their defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) {
                prefs.resetHotkeys()
                HotkeyManager.shared.rebindAll()
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
        case "win.topLeft", "win.topRight", "win.bottomLeft", "win.bottomRight":
            return "square.grid.2x2"
        case "screenshot": return "camera.viewfinder"
        case "switcher.altTab": return "arrow.left.arrow.right"
        case "nightMode": return "moon.fill"
        case "brightness.up": return "sun.max.fill"
        case "brightness.down": return "sun.min"
        case "focus": return "timer"
        case "menuHider": return "menubar.arrow.up.rectangle"
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
        case "win.topLeft", "win.topRight", "win.bottomLeft", "win.bottomRight": return .blue
        case "screenshot": return .pink
        case "switcher.altTab": return .blue
        case "nightMode": return .orange
        case "brightness.up", "brightness.down": return .yellow
        case "focus": return .orange
        case "menuHider": return .gray
        default: return .gray
        }
    }
}

/// Click to arm, then the next key press becomes the shortcut.
private struct HotkeyField: View {
    let id: String
    let label: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var conflict: (spec: HotkeySpec, owner: String)?
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var manager = HotkeyManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if manager.failed.contains(id) {
                Label("In use", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("macOS refused this shortcut — another app already uses it. Pick a different one.")
            }
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press keys…" : (prefs.hotkey(id)?.display ?? "None"))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor)
                                     : prefs.hotkey(id) == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
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
            .accessibilityLabel("\(label) shortcut")
            .accessibilityValue(recording ? "Recording" : (prefs.hotkey(id)?.display ?? "None"))
            .accessibilityHint("Press to record a new shortcut")

            Button {
                clear()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(prefs.hotkey(id) == nil ? 0 : 1)
            .disabled(prefs.hotkey(id) == nil)
            .help("Turn this shortcut off")
            .accessibilityLabel("Clear \(label) shortcut")
        }
        .onDisappear { stopRecording() }
        .alert("Shortcut already in use",
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { c in
            Button("Use Here, Clear the Other") {
                Prefs.shared.setHotkey(c.owner, nil)
                HotkeyManager.shared.rebind(c.owner)
                assign(c.spec)
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text("\(c.spec.display) is already assigned to “\(ShortcutSettings.label(for: c.owner))”.")
        }
    }

    private func clear() {
        stopRecording()
        Prefs.shared.setHotkey(id, nil)
        HotkeyManager.shared.rebind(id)
    }

    private func assign(_ spec: HotkeySpec) {
        Prefs.shared.setHotkey(id, spec)
        HotkeyManager.shared.rebind(id)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stopRecording(); return nil }                 // Escape cancels
            if event.keyCode == 51 || event.keyCode == 117, mods.isEmpty {          // ⌫ / ⌦ clears
                clear(); return nil
            }
            // Shift alone would steal capitals from every app, so a shortcut
            // needs ⌘, ⌥ or ⌃ — except function keys, which are free to use bare.
            let isFunctionKey = event.specialKey.map { (0xF704...0xF726).contains(Int($0.rawValue)) } ?? false
            guard !mods.intersection([.command, .option, .control]).isEmpty || isFunctionKey else {
                NSSound.beep(); return nil
            }
            let spec = HotkeySpec(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue)
            stopRecording()
            if let owner = Prefs.shared.hotkeyOwner(of: spec, except: id) {
                conflict = (spec, owner)
            } else {
                assign(spec)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Asks for a folder to write captures into. An empty preference means the
/// default, so cancelling changes nothing.
@MainActor
func chooseScreenshotFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Folder"
    panel.directoryURL = Screenshot.saveFolder()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Prefs.shared.screenshotFolder = url.path
}

/// Apps with a window and a bundle id, for the "while an app is running"
/// keep-awake trigger. Read on demand: the list is only as good as the moment
/// the menu opens, and the trigger matches on the identifier afterwards.
enum RunningApps {
    static var list: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

// MARK: - Excluded apps

/// Apps Perch keeps its hands off: no snapping, no window shortcuts, not in
/// the switcher, and ⌥⇥ passes straight through while they are in front.
private struct ExcludedAppsSection: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Section("Excluded apps") {
            if prefs.excludedApps.isEmpty {
                Text("None. Add games, virtual machines or remote desktops that need these keys themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(prefs.excludedApps, id: \.self) { id in
                HStack {
                    Text(Self.name(for: id))
                    Text(id).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        prefs.excludedApps.removeAll { $0 == id }
                        AppDelegate.syncExclusions()
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(Self.name(for: id))")
                }
            }
            Menu("Add Running App") {
                ForEach(RunningApps.list.filter { !prefs.excludedApps.contains($0.0) }, id: \.0) { id, name in
                    Button(name) {
                        prefs.excludedApps.append(id)
                        AppDelegate.syncExclusions()
                    }
                }
            }
            .fixedSize()
            Text("Excluded apps are skipped by edge snapping, window shortcuts and the switcher, and get ⌥⇥ and the window shortcuts back while they are in front.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func name(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }
}
