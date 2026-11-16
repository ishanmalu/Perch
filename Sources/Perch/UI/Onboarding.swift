import AppKit
import SwiftUI
import Combine
import EventKit

// MARK: - Live permission status

/// What Perch has been granted, re-read whenever Perch comes back to the front
/// (the usual moment after a trip to System Settings) and once a second while
/// a permission view is on screen, so rows never show a stale answer.
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = AX.isTrusted(prompt: false)
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var calendar = EKEventStore.authorizationStatus(for: .event)

    private var timer: Timer?
    private var watchers = 0
    private var observer: Any?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
    }

    func refresh() {
        let ax = AX.isTrusted(prompt: false)
        let sr = CGPreflightScreenCaptureAccess()
        let cal = EKEventStore.authorizationStatus(for: .event)
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
        if cal != calendar { calendar = cal }
    }

    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    var calendarGranted: Bool { calendar == .fullAccess }

    static func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func grantAccessibility() {
        // Shows the system prompt the first time; after that it only opens the pane.
        if !AX.isTrusted(prompt: true) { Self.openPane("Privacy_Accessibility") }
    }

    func grantScreenRecording() {
        WindowThumbnails.shared.requestAuthorization()
    }

    func grantCalendar() {
        if calendar == .notDetermined {
            Prefs.shared.calendarEnabled = true
            CalendarPeek.shared.requestAccess()
        } else {
            Self.openPane("Privacy_Calendars")
        }
    }
}

/// One row per permission: what it is for, whether it is granted, and a
/// button that gets the user there.
struct PermissionRows: View {
    @ObservedObject var permissions = Permissions.shared
    var includeCalendar = true

    var body: some View {
        VStack(spacing: 0) {
            row("Accessibility", "hand.raised.fill", .blue,
                "Window tiling, snapping, the switcher, keyboard cleaning and paste-on-pick.",
                granted: permissions.accessibility, required: true) { permissions.grantAccessibility() }
            Divider()
            row("Screen Recording", "rectangle.dashed.badge.record", .red,
                "Live switcher thumbnails, screenshots and screen recording.",
                granted: permissions.screenRecording, required: false) { permissions.grantScreenRecording() }
            if includeCalendar {
                Divider()
                row("Calendar", "calendar", .orange,
                    "Shows your next meeting with a Join button beside the focus timer.",
                    granted: permissions.calendarGranted, required: false) { permissions.grantCalendar() }
            }
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color, _ purpose: String,
                     granted: Bool, required: Bool, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            GlyphBadge(symbol: symbol, tint: tint, size: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    if !required {
                        Text("Optional").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Button("Grant…", action: grant)
                    .accessibilityLabel("Grant \(title) access")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(granted ? "granted" : "not granted")")
    }
}

// MARK: - First-run window

final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OnboardingView(onDone: { [weak self] in self?.close() }))
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to Perch"
        w.styleMask = [.titled, .closable]
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        // Seen once is enough; it stays one click away in the status menu.
        Prefs.shared.onboardingDone = true
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        Prefs.shared.onboardingDone = true
        window?.close()
    }
}

private struct OnboardingView: View {
    @ObservedObject var prefs = Prefs.shared
    var onDone: () -> Void

    private let highlights: [(String, String)] = [
        ("panel", "Open the Perch panel"),
        ("switcher.altTab", "Switch windows (hold ⌥, tap ⇥)"),
        ("clipboard", "Clipboard history"),
        ("win.left", "Tile left (press again: ½ → ⅓ → ⅔)"),
        ("screenshot", "Screenshot"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Perch").font(.title2.weight(.semibold))
                    Text("A few permissions make everything work. You can change any of this later in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GroupBox("Permissions") {
                PermissionRows().padding(.horizontal, 4)
            }

            GroupBox("Shortcuts worth knowing") {
                VStack(spacing: 6) {
                    ForEach(highlights, id: \.0) { id, label in
                        HStack {
                            Text(label).font(.callout)
                            Spacer()
                            Text(prefs.hotkey(id)?.display ?? "Off")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(prefs.hotkey(id) == nil ? .tertiary : .primary)
                        }
                    }
                    Divider()
                    Toggle("Use ⌥⇥ for the window switcher", isOn: Binding(
                        get: { prefs.hotkey("switcher.altTab") != nil },
                        set: { on in
                            prefs.setHotkey("switcher.altTab", on ? HotkeySpec.defaults["switcher.altTab"] : nil)
                            HotkeyManager.shared.rebind("switcher.altTab")
                        }))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Some apps use ⌥⇥ or ⌘⇧V themselves. Change or turn off any shortcut in Settings → Shortcuts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(4)
            }

            HStack {
                Button("Open Shortcuts Settings") {
                    SettingsWindow.shared.show(tab: .shortcuts)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
