import Foundation
import Combine
import IOKit.ps

/// When Perch's battery saver applies.
enum SaverMode: String, CaseIterable, Identifiable {
    case off, onBattery, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .onBattery: return "On battery or Low Power Mode"
        case .always: return "Always"
        }
    }
}

/// Perch battery saver: trims Perch's own background work. While active,
/// - the menu-bar CPU / memory / network figure stops updating,
/// - the panel's live stats sample every 6 s instead of 2 s,
/// - clipboard history checks for new copies every 2 s instead of 0.75 s,
/// - the window switcher shows app icons instead of capturing previews,
/// - window moves skip their animation.
final class EnergySaver: ObservableObject {
    static let shared = EnergySaver()

    @Published private(set) var isActive = false

    var mode: SaverMode {
        get { SaverMode(rawValue: Prefs.shared.batterySaver) ?? .off }
        set {
            Prefs.shared.batterySaver = newValue.rawValue
            objectWillChange.send()   // the picker reflects the new mode even if the state holds
            evaluate()
        }
    }

    private var powerSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?

    /// Starts watching power state. Cheap: both are push notifications.
    func start() {
        if powerSource == nil {
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            powerSource = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<EnergySaver>.fromOpaque(ctx).takeUnretainedValue().evaluate()
            }, ctx)?.takeRetainedValue()
            if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        }
        if lowPowerObserver == nil {
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                    self?.evaluate()
                }
        }
        evaluate()
    }

    static var onBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return type == kIOPSBatteryPowerValue
    }

    func evaluate() {
        let active: Bool
        switch mode {
        case .off: active = false
        case .always: active = true
        case .onBattery: active = Self.onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        guard active != isActive else { return }
        isActive = active
        apply()
    }

    /// Re-times everything that polls so the new state takes effect now.
    private func apply() {
        SystemMonitor.shared.reschedule()
        HardwareStats.shared.restartIfRunning()
        ProcessMonitor.shared.restartIfRunning()
        if Prefs.shared.clipboardEnabled { ClipboardStore.shared.start() }
    }
}
