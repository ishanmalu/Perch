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
/// The battery floor's decision, separated from the timer and the assertion so
/// it can be tested without either.
enum BatteryFloor {
    struct State: Equatable {
        var tripped: Bool
        var stopSession: Bool
    }

    /// - Parameters:
    ///   - tripped: whether the floor has already ended a session.
    ///   - active: whether a session is running.
    ///   - floor: the percentage below which to end it, or nil when disabled.
    ///   - percent: current charge, or nil on a machine without a battery.
    ///   - charging: whether the charger is connected.
    static func evaluate(tripped: Bool, active: Bool, floor: Int?,
                         percent: Int?, charging: Bool) -> State {
        var tripped = tripped
        // Re-arm with a margin, so hovering on the threshold does not arm and
        // fire over and over.
        if tripped {
            if floor == nil || percent == nil { tripped = false }
            else if charging || percent! > floor! + 5 { tripped = false }
        }
        guard active, !tripped, let floor, let percent, !charging, percent <= floor else {
            return State(tripped: tripped, stopSession: false)
        }
        return State(tripped: true, stopSession: true)
    }
}

@MainActor
final class PreventSleep: ObservableObject {
    static let shared = PreventSleep()

    @Published private(set) var isActive = false
    /// When the current session ends. Nil while a session runs indefinitely.
    @Published private(set) var endsAt: Date?
    @Published private(set) var reason: WakeReason = .manual

    private var assertionID: IOPMAssertionID = 0
    private var ticker: Timer?
    /// Set when the battery floor ended a session. Without it a trigger whose
    /// condition still holds restarts the session on the very next tick, the
    /// floor ends it again, and the two fight once a second — a notification
    /// every two seconds and the assertion thrashing. Cleared once the battery
    /// recovers or the charger goes in, which re-arms the floor.
    private var batteryFloorTripped = false

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

    private init() { rescheduleTicker() }

    /// One timer covers both jobs: counting a session down and noticing when a
    /// trigger's condition starts or stops holding. It only runs when there is
    /// something to do — a permanent 1 Hz wake-up is a poor trade for an app
    /// that is idle most of the time, and most installs never set a trigger.
    private func rescheduleTicker() {
        let interval: TimeInterval?
        if isActive {
            interval = 1                       // a countdown has to tick
        } else if Prefs.shared.wakeTrigger != SleepTrigger.manual.rawValue {
            interval = 5                       // watching a condition, not a clock
        } else {
            interval = nil                     // nothing to watch
        }

        guard interval != ticker?.timeInterval else { return }
        ticker?.invalidate()
        ticker = nil
        guard let interval else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Called when the trigger preference changes, so the timer starts or stops
    /// to match without waiting for a session.
    func triggerChanged() { rescheduleTicker() }

    // MARK: - Starting and stopping

    /// Starts a session. `duration` of nil runs until stopped.
    func start(duration: TimeInterval? = nil, reason: WakeReason = .manual) {
        // Starting by hand overrules a floor that has already had its say; it
        // re-arms when the battery recovers rather than firing again at once.
        if reason == .manual { batteryFloorTripped = true }
        self.reason = reason
        endsAt = duration.map { Date().addingTimeInterval($0) }
        applyAssertion(true)
        rescheduleTicker()
    }

    func stop() {
        endsAt = nil
        reason = .manual
        applyAssertion(false)
        rescheduleTicker()
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

        let snap = SystemMonitor.shared.snapshot
        let verdict = BatteryFloor.evaluate(tripped: batteryFloorTripped,
                                            active: isActive,
                                            floor: Prefs.shared.endOnLowBattery,
                                            percent: snap.batteryPercent,
                                            charging: snap.batteryCharging)
        batteryFloorTripped = verdict.tripped
        if verdict.stopSession {
            stop()
            Notifier.show("Sleep allowed",
                          "Battery fell to \(snap.batteryPercent.map(String.init) ?? "?")%.",
                          duration: 3)
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
            // The floor has the last word until the battery recovers.
            guard !batteryFloorTripped else { return }
            start(reason: why)
        } else if !holds && isActive && reason != .manual {
            // Only retract what the trigger itself started; a manual hold stands.
            stop()
        }
    }

    /// Released automatically on quit; assertions do not outlive the process,
    /// but being explicit keeps the state readable.
    func shutdown() {
        // Order matters: stop() reschedules, so tearing the timer down first
        // would just rebuild it whenever a trigger is configured.
        stop()
        ticker?.invalidate()
        ticker = nil
    }
}
