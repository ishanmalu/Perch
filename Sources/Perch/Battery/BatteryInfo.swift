import Foundation
import IOKit
import IOKit.ps

/// Battery state and health, matching what macOS itself shows in
/// System Settings → Battery and System Information.
struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool          // actually taking charge, not merely on power
    var pluggedIn: Bool
    var fullyCharged: Bool
    var minutesRemaining: Int?  // to empty, or to full while charging
    var cycleCount: Int
    var designCycleCount: Int?
    var designCapacity: Int     // mAh
    var maxCapacity: Int        // mAh, what a full charge holds today
    var temperature: Double?    // °C, when the battery reports it
    /// "Maximum Capacity" as macOS reports it, 0...1.
    var health: Double
    /// macOS's verdict: "Normal" or "Service Recommended".
    var condition: String

    /// Live readings come straight from the battery's registry entry; the
    /// health figure comes from macOS (see `SystemHealth`), because the raw
    /// capacities swing with temperature and charge and undershoot what
    /// System Settings shows by several points.
    static func read() -> BatteryInfo? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let top = props?.takeRetainedValue() as? [String: Any] else { return nil }
        guard top["BatteryInstalled"] as? Bool ?? true else { return nil }
        // Newer macOS moves the capacities into a nested BatteryData dict;
        // top-level keys win where both exist.
        let d = (top["BatteryData"] as? [String: Any] ?? [:]).merging(top) { _, t in t }

        // On Apple Silicon "MaxCapacity" is always 100 and "CurrentCapacity"
        // is already the percentage. Intel reports both in mAh.
        let design = d["DesignCapacity"] as? Int ?? 0
        let rawMax = d["AppleRawMaxCapacity"] as? Int ?? d["FullChargeCapacity"] as? Int
        let maxField = d["MaxCapacity"] as? Int ?? 0
        let maxCap = rawMax ?? maxField
        let current = d["CurrentCapacity"] as? Int ?? 0
        let percent: Int = maxField > 0 && maxField <= 100
            ? Int((Double(current) / Double(maxField) * 100).rounded())
            : (maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100).rounded()) : current)

        let charging = d["IsCharging"] as? Bool ?? false
        let pluggedIn = d["ExternalConnected"] as? Bool ?? false
        // 65535 means "still calculating".
        func minutes(_ key: String) -> Int? {
            guard let m = d[key] as? Int, m > 0, m < 65535 else { return nil }
            return m
        }
        let remaining = charging ? minutes("AvgTimeToFull") : (pluggedIn ? nil : minutes("AvgTimeToEmpty"))

        let cycles = d["CycleCount"] as? Int ?? 0
        let system = SystemHealth.current(cycleCount: cycles)
        // Fallback when macOS gives no figure: nominal capacity is the
        // smoothed full-charge estimate, much closer to Apple's number than
        // the instantaneous raw max.
        let nominal = d["NominalChargeCapacity"] as? Int ?? maxCap
        let fallbackHealth = design > 0 ? min(1, Double(nominal) / Double(design)) : 0
        let failed = (d["PermanentFailureStatus"] as? Int ?? 0) != 0

        // Temperature is in hundredths of a degree; 0 means not reported.
        let temp = [d["Temperature"], d["VirtualTemperature"]]
            .compactMap { $0 as? Int }.first { $0 > 0 }.map { Double($0) / 100 }

        return BatteryInfo(
            percent: min(100, max(0, percent)),
            charging: charging,
            pluggedIn: pluggedIn,
            fullyCharged: d["FullyCharged"] as? Bool ?? false,
            minutesRemaining: remaining,
            cycleCount: cycles,
            designCycleCount: d["DesignCycleCount9C"] as? Int ?? system?.designCycles,
            designCapacity: design,
            maxCapacity: maxCap,
            temperature: temp,
            health: system?.maximumCapacity ?? fallbackHealth,
            condition: failed ? "Service Recommended" : (system?.condition ?? "Normal"))
    }

    var stateText: String {
        if charging { return "Charging" }
        if fullyCharged && pluggedIn { return "Fully charged" }
        if pluggedIn { return "On power, not charging" }
        return "On battery"
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// The battery-health figures macOS computes itself (the same ones System
/// Settings shows). Only `system_profiler` exposes them; it takes ~0.1 s, so
/// the result is cached and refreshed only when the cycle count moves or
/// after several hours — health changes over weeks, not minutes.
enum SystemHealth {
    struct Value { var maximumCapacity: Double?; var condition: String?; var designCycles: Int? }

    private static let lock = NSLock()
    /// `value` is nil when macOS gave no figure; that is cached too, so a Mac
    /// without one never re-runs system_profiler on every read.
    private static var cached: (value: Value?, cycles: Int, at: Date)?

    static func current(cycleCount: Int) -> Value? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.cycles == cycleCount, Date().timeIntervalSince(c.at) < 6 * 3600 {
            return c.value
        }
        let v = query() ?? cached?.value
        cached = (v, cycleCount, Date())
        return v
    }

    private static func query() -> Value? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            // "96 %" → 0.96
            let pct = (health["sppower_battery_health_maximum_capacity"] as? String)
                .flatMap { Double($0.filter(\.isNumber)) }.map { min(1, $0 / 100) }
            let condition: String? = (health["sppower_battery_health"] as? String).map {
                switch $0.lowercased() {
                case "good", "normal": return "Normal"
                case "fair": return "Fair"
                case "poor", "check battery", "service recommended": return "Service Recommended"
                default: return $0
                }
            }
            return Value(maximumCapacity: pct, condition: condition, designCycles: nil)
        }
        return nil
    }
}
