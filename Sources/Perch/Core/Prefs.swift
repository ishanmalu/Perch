import Foundation
import Combine

/// Lightweight UserDefaults-backed settings store.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private func get<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }
    private func set<T>(_ key: String, _ value: T) { d.set(value, forKey: key); objectWillChange.send() }

    // MARK: Clipboard
    var clipboardEnabled: Bool { get { get("clip.enabled", true) } set { set("clip.enabled", newValue) } }
    var clipboardLimit: Int { get { get("clip.limit", 200) } set { set("clip.limit", newValue) } }
    var clipboardKeepDays: Int { get { get("clip.keepDays", 30) } set { set("clip.keepDays", newValue) } }
    var clipboardStoreImages: Bool { get { get("clip.images", true) } set { set("clip.images", newValue) } }
    /// Skip anything that pattern-matches an API key, token, or private key.
    var clipboardSkipSecrets: Bool { get { get("clip.skipSecrets", true) } set { set("clip.skipSecrets", newValue) } }
    var clipboardPasteOnPick: Bool { get { get("clip.pasteOnPick", true) } set { set("clip.pasteOnPick", newValue) } }
    /// Bundle IDs we never record from (password managers etc).
    var clipboardIgnoredApps: [String] {
        get { get("clip.ignored", ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"]) }
        set { set("clip.ignored", newValue) }
    }

    // MARK: Windows
    var windowGap: Int { get { get("win.gap", 0) } set { set("win.gap", newValue) } }
    var respectStageManager: Bool { get { get("win.stage", true) } set { set("win.stage", newValue) } }
    var animateWindows: Bool { get { get("win.animate", false) } set { set("win.animate", newValue) } }

    // MARK: System
    /// Icon-only by default — a narrow status item is far less likely to get
    /// pushed off a crowded menu bar or hidden behind the notch.
    var menuBarStat: String { get { get("sys.menuStat", "none") } set { set("sys.menuStat", newValue) } }
    var sampleInterval: Double { get { get("sys.interval", 2.0) } set { set("sys.interval", newValue) } }

    // MARK: Updates
    /// Off by default — the network check is opt-in, not assumed.
    var autoCheckUpdates: Bool { get { get("update.auto", false) } set { set("update.auto", newValue) } }

    // MARK: Switcher
    /// What Alt-Tab shows: live thumbnails, or a compact title list.
    var switcherStyle: SwitcherStyle {
        get { SwitcherStyle(rawValue: get("switcher.style", "thumbnails")) ?? .thumbnails }
        set { set("switcher.style", newValue.rawValue) }
    }
    /// The separate title-list switcher on its own shortcut. Can be turned off
    /// entirely for anyone who only wants Alt-Tab.
    var listSwitcherEnabled: Bool { get { get("switcher.listEnabled", true) } set { set("switcher.listEnabled", newValue) } }

    // MARK: Night mode
    var nightTemperature: Double { get { get("night.kelvin", 3600.0) } set { set("night.kelvin", newValue) } }
    var nightSchedule: Int { get { get("night.schedule", 0) } set { set("night.schedule", newValue) } }
    var nightFromMinutes: Int { get { get("night.from", 20 * 60) } set { set("night.from", newValue) } }
    var nightToMinutes: Int { get { get("night.to", 7 * 60) } set { set("night.to", newValue) } }

    // MARK: Screen clean
    var screenCleanColor: String { get { get("screen.color", "black") } set { set("screen.color", newValue) } }
    var keyboardCleanSeconds: Int { get { get("kb.seconds", 30) } set { set("kb.seconds", newValue) } }

    // MARK: Disk clean targets (JSON-encoded)
    var diskTargets: [DiskTarget] {
        get {
            guard let raw = d.data(forKey: "disk.targets"),
                  let v = try? JSONDecoder().decode([DiskTarget].self, from: raw) else { return DiskTarget.defaults }
            return v
        }
        set {
            d.set(try? JSONEncoder().encode(newValue), forKey: "disk.targets")
            objectWillChange.send()
        }
    }

    // MARK: Hotkeys
    func hotkey(_ id: String) -> HotkeySpec? {
        guard let raw = d.data(forKey: "hk.\(id)"),
              let v = try? JSONDecoder().decode(HotkeySpec.self, from: raw) else { return HotkeySpec.defaults[id] }
        return v
    }
    func setHotkey(_ id: String, _ spec: HotkeySpec?) {
        if let spec, let data = try? JSONEncoder().encode(spec) { d.set(data, forKey: "hk.\(id)") }
        else { d.set(Data(), forKey: "hk.\(id)") }
        objectWillChange.send()
    }
}
