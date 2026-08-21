import AppKit
import Combine
import CoreGraphics

/// Warms the display by rewriting each screen's gamma ramp, the way f.lux and
/// Night Shift do. Gamma is applied by the window server below everything, so
/// it tints the whole screen without an overlay and without appearing in
/// screenshots or screen recordings.
///
/// macOS restores the system ramps when the process exits, so a crash can never
/// leave the display stuck orange.
final class NightMode: ObservableObject {
    static let shared = NightMode()

    enum Schedule: Int, CaseIterable, Identifiable {
        case manual = 0, sunsetToSunrise = 1, custom = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .manual: return "Manual"
            case .sunsetToSunrise: return "Sunset to sunrise"
            case .custom: return "Custom hours"
            }
        }
    }

    @Published private(set) var isActive = false
    /// Correlated colour temperature in kelvin. 6500 is neutral daylight.
    @Published var temperature: Double {
        didSet {
            Prefs.shared.nightTemperature = temperature
            if isActive { applyRamp() }
        }
    }

    private var timer: Timer?

    private init() {
        temperature = Prefs.shared.nightTemperature
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isActive else { return }
                self.applyRamp()
            }
    }

    // MARK: - Control

    func start() {
        // Re-evaluate every minute so a schedule can switch itself on and off.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateSchedule()
        }
        RunLoop.main.add(timer!, forMode: .common)
        evaluateSchedule()
    }

    func toggle() {
        setActive(!isActive)
        if Prefs.shared.nightSchedule != Schedule.manual.rawValue {
            // A manual flip while on a schedule would be undone a minute later.
            Prefs.shared.nightSchedule = Schedule.manual.rawValue
        }
        Notifier.show(isActive ? "Night mode on" : "Night mode off",
                      isActive ? "\(Int(temperature))K" : nil, duration: 1.5)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        active ? applyRamp() : resetRamp()
    }

    private func evaluateSchedule() {
        let schedule = Schedule(rawValue: Prefs.shared.nightSchedule) ?? .manual
        switch schedule {
        case .manual:
            break
        case .sunsetToSunrise, .custom:
            setActive(isWithinScheduledWindow(schedule))
        }
    }

    /// Both scheduled modes are a start/end minute-of-day pair; sunset mode just
    /// uses fixed civil-ish defaults rather than pulling in a solar calculation
    /// and a location permission.
    private func isWithinScheduledWindow(_ schedule: Schedule) -> Bool {
        let from: Int, to: Int
        if schedule == .custom {
            from = Prefs.shared.nightFromMinutes
            to = Prefs.shared.nightToMinutes
        } else {
            from = 20 * 60      // 20:00
            to = 7 * 60         // 07:00
        }
        let now = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        return from <= to ? (now >= from && now < to) : (now >= from || now < to)
    }

    // MARK: - Gamma

    private func applyRamp() {
        let (r, g, b) = Self.multipliers(forKelvin: temperature)
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            CGSetDisplayTransferByFormula(id,
                                          0, CGGammaValue(r), 1,
                                          0, CGGammaValue(g), 1,
                                          0, CGGammaValue(b), 1)
        }
    }

    private func resetRamp() {
        CGDisplayRestoreColorSyncSettings()
    }

    /// Tanner Helland's blackbody approximation, normalised so 6500K is a no-op.
    /// Returns per-channel maxima in 0...1.
    static func multipliers(forKelvin kelvin: Double) -> (Double, Double, Double) {
        let t = min(6500, max(1000, kelvin)) / 100

        let red: Double = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green: Double = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue: Double = t >= 66 ? 255
            : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)

        func clamp(_ v: Double) -> Double { min(1, max(0.1, v / 255)) }
        return (clamp(red), clamp(green), clamp(blue))
    }

    /// Called on quit so the display never stays warm after Perch is gone.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        if isActive { resetRamp() }
    }
}
