import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

/// What started the current session, so the UI can say why the Mac is awake
/// and a trigger can end what a trigger began without cancelling a manual hold.
enum WakeReason: Equatable {
    case manual
    case power
    case app(String)
    case cpu
}

/// The condition that starts a session on its own.
enum SleepTrigger: String, CaseIterable, Identifiable {
    case manual, onPower, appRunning, cpuBusy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual:     return "Only when I ask"
        case .onPower:    return "While plugged in"
        case .appRunning: return "While an app is running"
        case .cpuBusy:    return "While the CPU is busy"
        }
    }
}

/// Holds a power assertion so the Mac stays awake — the equivalent of leaving
/// `caffeinate` running, without spawning a process.
///
/// A session can run indefinitely, for a set time, or for as long as some
/// condition holds. Two assertion types matter: one keeps the display on, the
/// other lets the screen sleep while the machine keeps working, which is what
/// you want for a long download or an export.
@MainActor
final class PreventSleep: ObservableObject {
    static let shared = PreventSleep()

    @Published private(set) var isActive = false
    /// When the current session ends. Nil while a session runs indefinitely.
    @Published private(set) var endsAt: Date?
    @Published private(set) var reason: WakeReason = .manual

    private var assertionID: IOPMAssertionID = 0
    private var ticker: Timer?

    /// Seconds left, or nil when the session has no end.
    var remaining: TimeInterval? {
        guard let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    /// "1:04" or "12m" — short enough for a menu bar.
    var remainingLabel: String? {
        guard let r = remaining else { return nil }
        let mins = Int(r) / 60, secs = Int(r) % 60
        if mins >= 60 { return String(format: "%d:%02d", mins / 60, mins % 60) }
        if mins >= 1 { return "\(mins)m" }
        return "\(secs)s"
    }

    private init() {
        // One timer covers both jobs: counting a session down and noticing when
        // a trigger's condition starts or stops holding.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Starting and stopping

    /// Starts a session. `duration` of nil runs until stopped.
    func start(duration: TimeInterval? = nil, reason: WakeReason = .manual) {
        self.reason = reason
        endsAt = duration.map { Date().addingTimeInterval($0) }
        applyAssertion(true)
    }

    func stop() {
        endsAt = nil
        reason = .manual
        applyAssertion(false)
    }

    /// The panel's switch: off turns it off, on starts an open-ended session.
    func toggle() {
        if isActive { stop() } else { start() }
        Notifier.show(isActive ? "Sleep prevented" : "Sleep allowed",
                      isActive ? assertionBlurb : nil, duration: 2)
    }

    private var assertionBlurb: String {
        Prefs.shared.allowDisplaySleep
            ? "The Mac stays awake. The display may still sleep."
            : "Your Mac and display stay awake."
    }

    private func applyAssertion(_ active: Bool) {
        // Rebuild rather than early-return: the assertion type depends on a
        // preference that can change while a session is running.
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        guard active else {
            isActive = false
            return
        }
        let type = Prefs.shared.allowDisplaySleep
            ? kIOPMAssertionTypeNoIdleSleep
            : kIOPMAssertionTypeNoDisplaySleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            // ASCII only: pmset renders this string in a context that mangles
            // anything outside it.
            "Perch: sleep prevented" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            Notifier.show("Could not prevent sleep", "macOS refused the power assertion.")
            isActive = false
            return
        }
        assertionID = id
        isActive = true
    }

    /// Re-applies the assertion so a changed display-sleep preference takes
    /// effect on a session that is already running.
    func refreshAssertionType() {
        guard isActive else { return }
        applyAssertion(true)
    }

    // MARK: - The once-a-second pass

    private func tick() {
        if isActive, let endsAt, Date() >= endsAt {
            stop()
            Notifier.show("Sleep allowed", "The keep-awake session ended.", duration: 2)
            return
        }

        if isActive, let floor = Prefs.shared.endOnLowBattery,
           let pct = SystemMonitor.shared.snapshot.batteryPercent,
           !SystemMonitor.shared.snapshot.batteryCharging, pct <= floor {
            stop()
            Notifier.show("Sleep allowed", "Battery fell to \(pct)%.", duration: 3)
            return
        }

        evaluateTrigger()
        // Republish so a countdown in the UI advances; `remaining` is derived.
        if isActive && endsAt != nil { objectWillChange.send() }
    }

    private func evaluateTrigger() {
        let prefs = Prefs.shared
        guard let trigger = SleepTrigger(rawValue: prefs.wakeTrigger), trigger != .manual else { return }

        let holds: Bool
        let why: WakeReason
        switch trigger {
        case .manual:
            return
        case .onPower:
            holds = SystemMonitor.shared.snapshot.batteryCharging
                 || SystemMonitor.shared.snapshot.batteryPercent == nil   // desktop Mac
            why = .power
        case .appRunning:
            let wanted = prefs.wakeTriggerApp
            guard !wanted.isEmpty else { return }
            holds = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == wanted
            }
            why = .app(wanted)
        case .cpuBusy:
            holds = SystemMonitor.shared.snapshot.cpuUsed >= Double(prefs.wakeTriggerCPU)
            why = .cpu
        }

        if holds && !isActive {
            start(reason: why)
        } else if !holds && isActive && reason != .manual {
            // Only retract what the trigger itself started; a manual hold stands.
            stop()
        }
    }

    /// Released automatically on quit; assertions do not outlive the process,
    /// but being explicit keeps the state readable.
    func shutdown() { stop() }
}
