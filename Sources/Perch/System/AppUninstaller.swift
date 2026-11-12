import AppKit
import Combine

/// Removes an app together with what it leaves behind in ~/Library.
///
/// Everything goes to the Trash, never straight to deletion, so a wrong guess
/// is one drag away from undone. Only folders named after the app's exact
/// bundle identifier, or exactly after the app, are offered — and each one is
/// a checkbox the user can untick before anything moves.
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    struct Leftover: Identifiable, Hashable {
        var url: URL
        var size: Int64
        var selected = true
        var id: URL { url }
        var kind: String { url.deletingLastPathComponent().lastPathComponent }
    }

    @Published private(set) var app: (url: URL, name: String, bundleID: String, icon: NSImage, size: Int64)?
    @Published var leftovers: [Leftover] = []
    @Published private(set) var scanning = false

    static let searchRoots = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", "LaunchAgents",
        "Application Scripts", "Cookies",
    ]

    /// Pure, self-tested. A leftover must be named for the bundle id itself
    /// (optionally with a suffix like `.plist`, `.savedState` or a team
    /// prefix for group containers), or exactly for the app. Never a prefix
    /// match on the name: "Notes" must not catch "NotesSync".
    static func isLeftover(_ filename: String, bundleID: String, appName: String) -> Bool {
        let f = filename.lowercased(), b = bundleID.lowercased(), n = appName.lowercased()
        guard !b.isEmpty else { return false }
        if f == b || f.hasPrefix(b + ".") { return true }
        // Group containers: "TEAMID.com.vendor.app" / "group.com.vendor.app".
        if f.hasSuffix("." + b) { return true }
        if n.count >= 3, f == n { return true }
        return false
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose"
        panel.message = "Choose an app to uninstall"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            Notifier.show("Not an app", url.lastPathComponent)
            return
        }
        if id.hasPrefix("com.apple.") || url.path.hasPrefix("/System") {
            Notifier.show("That's part of macOS", "System apps can't be removed.")
            return
        }
        if id == Bundle.main.bundleIdentifier {
            Notifier.show("That's Perch", "Quit it and drag it to the Trash instead.")
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        app = (url, name, id, NSWorkspace.shared.icon(forFile: url.path), 0)
        leftovers = []
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appSize = Self.size(of: url)
            let found = Self.scan(bundleID: id, appName: name)
            DispatchQueue.main.async {
                guard let self, self.app?.url == url else { return }
                self.app?.size = appSize
                self.leftovers = found
                self.scanning = false
            }
        }
    }

    func clear() { app = nil; leftovers = [] }

    var totalSelected: Int64 {
        (app?.size ?? 0) + leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
    }

    func uninstall() {
        guard let app else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        // Give a running app a moment to quit (and stop rewriting its caches)
        // without freezing the settings window while it does.
        let delay: TimeInterval = running.isEmpty ? 0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.trash(app) }
    }

    private func trash(_ app: (url: URL, name: String, bundleID: String, icon: NSImage, size: Int64)) {
        let urls = [app.url] + leftovers.filter(\.selected).map(\.url)
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            DispatchQueue.main.async {
                if let error {
                    Notifier.show("Couldn't move everything", error.localizedDescription, duration: 4)
                } else {
                    Notifier.show("\(app.name) moved to the Trash",
                                  "\(trashed.count) item\(trashed.count == 1 ? "" : "s"), \(SystemMonitor.bytes(UInt64(max(0, self?.totalSelected ?? 0))))",
                                  duration: 3)
                }
                self?.clear()
            }
        }
    }

    private static func scan(bundleID: String, appName: String) -> [Leftover] {
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var out: [Leftover] = []
        for root in searchRoots {
            let dir = lib.appendingPathComponent(root)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for item in items where isLeftover(item.lastPathComponent, bundleID: bundleID, appName: appName) {
                out.append(Leftover(url: item, size: size(of: item)))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
