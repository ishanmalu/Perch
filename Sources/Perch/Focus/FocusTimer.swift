import AppKit
import Combine

/// A Pomodoro-style focus timer that lives in the menu bar.
///
/// macOS has no public API to switch Do Not Disturb, but Shortcuts does. If
/// the user has shortcuts named "Perch Focus On" / "Perch Focus Off" (one
/// action each: Set Focus), Perch runs them at the start and end of each
/// work block. Without them the timer still works; it just doesn't silence.
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum Phase: Equatable { case idle, work, rest }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var endsAt: Date?
    @Published private(set) var completedToday = 0
    @Published private(set) var paused: TimeInterval?   // remaining while paused

    private var ticker: Timer?
    static let onShortcut = "Perch Focus On"
    static let offShortcut = "Perch Focus Off"

    var remaining: TimeInterval {
        if let paused { return paused }
        return max(0, endsAt?.timeIntervalSinceNow ?? 0)
    }

    /// "24:13" — what the menu bar shows.
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var label: String? { phase == .idle ? nil : Self.clock(remaining) }

    init() {
        let d = UserDefaults.standard
        if Calendar.current.isDateInToday(d.object(forKey: "focus.day") as? Date ?? .distantPast) {
            completedToday = d.integer(forKey: "focus.count")
        }
    }

    func startWork() { begin(.work, minutes: Prefs.shared.focusMinutes) }
    func startRest() { begin(.rest, minutes: Prefs.shared.breakMinutes) }

    func stop() {
        if phase == .work { Self.runShortcut(Self.offShortcut) }
        phase = .idle; endsAt = nil; paused = nil
        ticker?.invalidate(); ticker = nil
    }

    func togglePause() {
        guard phase != .idle else { return }
        if let p = paused {
            endsAt = Date().addingTimeInterval(p); paused = nil
        } else {
            paused = remaining
        }
    }

    private func begin(_ p: Phase, minutes: Int) {
        if phase == .work && p != .work { Self.runShortcut(Self.offShortcut) }
        if p == .work && phase != .work { Self.runShortcut(Self.onShortcut) }
        phase = p
        paused = nil
        endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func tick() {
        guard paused == nil else { return }
        objectWillChange.send()
        guard remaining <= 0 else { return }
        NSSound(named: "Glass")?.play()
        if phase == .work {
            completedToday += 1
            UserDefaults.standard.set(Date(), forKey: "focus.day")
            UserDefaults.standard.set(completedToday, forKey: "focus.count")
            Notifier.show("Focus block done", "Take \(Prefs.shared.breakMinutes) minutes.", duration: 4)
            startRest()
        } else {
            Notifier.show("Break's over", "Start the next block from the menu bar.", duration: 4)
            stop()
        }
    }

    static var hasShortcuts: Bool {
        let names = (try? shortcutNames()) ?? []
        return names.contains(onShortcut) && names.contains(offShortcut)
    }

    private static func shortcutNames() throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        // Drain before waiting: a long list fills the pipe, and a child blocked
        // on a full pipe never exits.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    private static func runShortcut(_ name: String) {
        guard Prefs.shared.focusUsesShortcuts else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run()
        }
    }
}
