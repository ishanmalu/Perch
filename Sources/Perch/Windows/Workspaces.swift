import AppKit
import Combine

/// A saved arrangement of apps and their windows: "Coding" opens the editor,
/// terminal and browser and puts each where it was. With auto-restore on, a
/// workspace also acts as a per-app layout for a desk — plugging into the
/// same displays puts every window back.
struct Workspace: Codable, Identifiable, Equatable {
    struct Placement: Codable, Equatable {
        var bundleID: String
        var appName: String
        /// Which of the app's windows, front to back. Window titles change too
        /// often (open documents, tabs) to match on.
        var index: Int
        var pane: Pane
        /// The display it was on; falls back to the main display if absent.
        var display: DisplayKey?
    }

    var id = UUID()
    var name: String
    var placements: [Placement]
    var launchApps = true
    /// Restore whenever this set of displays connects.
    var autoRestore = false
    var displays: Set<DisplayKey> = []

    var apps: [String] {
        var seen = Set<String>()
        return placements.compactMap { seen.insert($0.bundleID).inserted ? $0.appName : nil }
    }
}

final class Workspaces: ObservableObject {
    static let shared = Workspaces()

    @Published var all: [Workspace] = [] { didSet { save() } }
    @Published private(set) var restoring = false

    private let storeKey = "workspaces"
    private var lastConnected = DisplayKey.connected

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let v = try? JSONDecoder().decode([Workspace].self, from: data) { all = v }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: storeKey) }

    // MARK: - Capture

    func captureCurrent(named name: String) {
        guard AX.isTrusted(prompt: true) else {
            Notifier.show("Accessibility needed", "Workspaces read window positions through Accessibility.")
            return
        }
        var perApp: [pid_t: Int] = [:]
        var placements: [Workspace.Placement] = []
        for win in WindowManager.shared.orderedWindows() {
            guard let app = NSRunningApplication(processIdentifier: win.pid),
                  let bundle = app.bundleIdentifier, let f = win.frame else { continue }
            let index = perApp[win.pid, default: 0]
            perApp[win.pid] = index + 1
            let (pane, screen) = WindowManager.shared.unitPane(of: f)
            placements.append(.init(bundleID: bundle, appName: app.localizedName ?? bundle, index: index,
                                    pane: pane, display: screen.displayID.map(DisplayKey.init)))
        }
        guard !placements.isEmpty else {
            Notifier.show("No windows to save", "Open the apps you want in this workspace first.")
            return
        }
        all.append(Workspace(name: name, placements: placements, displays: DisplayKey.connected))
        Notifier.show("Saved “\(name)”", "\(placements.count) windows across \(Set(placements.map(\.bundleID)).count) apps",
                      duration: 2.5)
    }

    func update(_ ws: Workspace) {
        guard let i = all.firstIndex(where: { $0.id == ws.id }) else { return }
        all[i] = ws
    }

    func delete(_ ws: Workspace) { all.removeAll { $0.id == ws.id } }

    // MARK: - Restore

    func restore(_ ws: Workspace) {
        guard !restoring else { return }
        restoring = true
        let bundles = Array(Set(ws.placements.map(\.bundleID)))
        if ws.launchApps {
            for b in bundles where NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { continue }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        }
        // Freshly launched apps take a moment to open their windows. Retry a
        // few times, placing whatever has appeared each pass.
        place(ws, attempt: 0)
    }

    private func place(_ ws: Workspace, attempt: Int) {
        var missing = 0
        let windowsByPID = Dictionary(grouping: WindowManager.shared.orderedWindows(), by: \.pid)
        for p in ws.placements {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).first,
                  let wins = windowsByPID[app.processIdentifier], p.index < wins.count else {
                missing += 1; continue
            }
            let screen = p.display.flatMap { key in NSScreen.screens.first { $0.displayID.map(DisplayKey.init) == key } }
                ?? NSScreen.main ?? NSScreen.screens[0]
            WindowManager.shared.place(wins[p.index], pane: p.pane, on: screen)
        }
        if missing > 0 && attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.place(ws, attempt: attempt + 1)
            }
            return
        }
        restoring = false
        Notifier.show("“\(ws.name)” restored",
                      missing > 0 ? "\(missing) window\(missing == 1 ? "" : "s") didn't open in time." : nil,
                      duration: 2)
    }

    private func screensChanged() {
        let now = DisplayKey.connected
        guard now != lastConnected else { return }
        lastConnected = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, DisplayKey.connected == now,
                  let ws = Self.autoMatch(self.all, connected: now) else { return }
            self.restore(ws)
        }
    }

    /// Pure, self-tested: the workspace to auto-restore for a display set.
    static func autoMatch(_ list: [Workspace], connected: Set<DisplayKey>) -> Workspace? {
        list.first { $0.autoRestore && $0.displays == connected }
    }
}
