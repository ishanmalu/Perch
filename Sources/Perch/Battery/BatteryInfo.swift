import Foundation
import IOKit
import IOKit.ps

/// Battery health, read from the AppleSmartBattery registry entry — the same
/// numbers System Information shows, without a shell-out.
struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var cycleCount: Int
    var designCapacity: Int     // mAh
    var maxCapacity: Int        // mAh, what a full charge holds today
    var temperature: Double?    // °C
    var condition: String?

    var health: Double { designCapacity > 0 ? min(1, Double(maxCapacity) / Double(designCapacity)) : 0 }

    static func read() -> BatteryInfo? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let top = props?.takeRetainedValue() as? [String: Any] else { return nil }
        // Newer macOS moves the capacities into a nested BatteryData dict;
        // top-level keys win where both exist.
        let d = (top["BatteryData"] as? [String: Any] ?? [:]).merging(top) { _, t in t }

        // On Apple Silicon "MaxCapacity" is a percentage; the raw mAh lives in
        // AppleRawMaxCapacity. Intel reports mAh in MaxCapacity directly.
        let design = d["DesignCapacity"] as? Int ?? 0
        let rawMax = d["AppleRawMaxCapacity"] as? Int ?? d["FullChargeCapacity"] as? Int
        let maxCap = rawMax ?? (d["MaxCapacity"] as? Int ?? 0)
        let current = d["CurrentCapacity"] as? Int ?? 0
        let percent: Int = {
            if let m = d["MaxCapacity"] as? Int, m <= 100 { return current }   // already a percentage
            return maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100).rounded()) : current
        }()
        return BatteryInfo(
            percent: min(100, percent),
            charging: d["IsCharging"] as? Bool ?? false,
            pluggedIn: d["ExternalConnected"] as? Bool ?? false,
            cycleCount: d["CycleCount"] as? Int ?? 0,
            designCapacity: design,
            maxCapacity: maxCap,
            temperature: (d["Temperature"] as? Int ?? d["VirtualTemperature"] as? Int).map { Double($0) / 100 },
            condition: (d["BatteryData"] as? [String: Any])?["Condition"] as? String
                ?? d["PermanentFailureStatus"].flatMap { ($0 as? Int) == 0 ? nil : "Service" })
    }
}
