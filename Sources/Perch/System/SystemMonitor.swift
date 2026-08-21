import Foundation
import AppKit
import Combine
import IOKit.ps
import Darwin

struct SystemSnapshot {
    var cpuUser = 0.0, cpuSystem = 0.0, cpuIdle = 100.0
    var cpuUsed: Double { min(100, max(0, 100 - cpuIdle)) }

    var memUsed: UInt64 = 0, memTotal: UInt64 = 1
    var memPressure = 0.0          // 0...1, based on compressed + wired
    var memPercent: Double { Double(memUsed) / Double(memTotal) * 100 }

    var swapUsed: UInt64 = 0

    var diskFree: UInt64 = 0, diskTotal: UInt64 = 1
    var diskPercent: Double { Double(diskTotal - diskFree) / Double(diskTotal) * 100 }

    var netIn: Double = 0, netOut: Double = 0   // bytes/sec

    var batteryPercent: Int? = nil
    var batteryCharging = false
    var batteryTimeMinutes: Int? = nil
    var batteryCycles: Int? = nil
    var batteryHealth: Int? = nil               // % of design capacity

    var uptime: TimeInterval = 0
    var loadAverage: [Double] = [0, 0, 0]
    var thermalPressure: String = "Nominal"
}

/// Samples CPU / memory / disk / network / battery on a timer.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot = SystemSnapshot()
    /// Rolling history for the sparklines in the panel.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []

    private var timer: Timer?
    private var previousCPU: [UInt32] = []
    private var previousNet: (inB: UInt64, outB: UInt64, at: Date)?

    func start() {
        stop()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.shared.sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        var s = SystemSnapshot()
        readCPU(into: &s)
        readMemory(into: &s)
        readDisk(into: &s)
        readNetwork(into: &s)
        readBattery(into: &s)
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.loadAverage = Self.loadAverage()
        s.thermalPressure = Self.thermalState()

        DispatchQueue.main.async {
            self.snapshot = s
            self.cpuHistory = Array((self.cpuHistory + [s.cpuUsed]).suffix(60))
            self.memHistory = Array((self.memHistory + [s.memPercent]).suffix(60))
        }
    }

    // MARK: - CPU

    private func readCPU(into s: inout SystemSnapshot) {
        var count = mach_msg_type_number_t(0)
        var info: processor_info_array_t?
        var cpus = natural_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * 4) }

        var ticks = [UInt32](repeating: 0, count: Int(count))
        for i in 0..<Int(count) { ticks[i] = UInt32(bitPattern: info[i]) }

        guard previousCPU.count == ticks.count else { previousCPU = ticks; return }

        var user = 0.0, sys = 0.0, idle = 0.0, nice = 0.0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            func delta(_ state: Int) -> Double {
                Double(ticks[base + state] &- previousCPU[base + state])
            }
            user += delta(Int(CPU_STATE_USER))
            sys  += delta(Int(CPU_STATE_SYSTEM))
            idle += delta(Int(CPU_STATE_IDLE))
            nice += delta(Int(CPU_STATE_NICE))
        }
        previousCPU = ticks
        let total = user + sys + idle + nice
        guard total > 0 else { return }
        s.cpuUser = (user + nice) / total * 100
        s.cpuSystem = sys / total * 100
        s.cpuIdle = idle / total * 100
    }

    // MARK: - Memory

    private func readMemory(into s: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let page = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let active = UInt64(stats.active_count) * page
        // Matches Activity Monitor's "Memory Used" reasonably closely.
        s.memUsed = active + wired + compressed
        s.memTotal = total
        s.memPressure = min(1, Double(wired + compressed) / Double(total))

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 { s.swapUsed = xsw.xsu_used }
    }

    // MARK: - Disk

    private func readDisk(into s: inout SystemSnapshot) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey]) else { return }
        s.diskFree = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
        s.diskTotal = UInt64(v.volumeTotalCapacity ?? 1)
    }

    // MARK: - Network

    private func readNetwork(into s: inout SystemSnapshot) {
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name != "lo0" else { continue }
            guard let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        if let prev = previousNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                s.netIn = Double(inBytes &- prev.inB) / dt
                s.netOut = Double(outBytes &- prev.outB) / dt
            }
        }
        previousNet = (inBytes, outBytes, now)
    }

    // MARK: - Battery

    private func readBattery(into s: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            s.batteryPercent = Int((Double(current) / Double(max)) * 100)
            s.batteryCharging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let key = s.batteryCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let mins = d[key] as? Int, mins > 0 { s.batteryTimeMinutes = mins }
        }
        readBatteryHealth(into: &s)
    }

    private func readBatteryHealth(into s: inout SystemSnapshot) {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        s.batteryCycles = int("CycleCount")
        if let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"),
           let design = int("DesignCapacity"), design > 0 {
            s.batteryHealth = Int(Double(nominal) / Double(design) * 100)
        }
    }

    // MARK: - Misc

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Formatting

    static func bytes(_ v: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        // Otherwise zero renders as the word "Zero".
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(v))
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1024 * 1024 { return String(format: "%.0f KB/s", v / 1024) }
        return String(format: "%.1f MB/s", v / 1024 / 1024)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let d = Int(seconds) / 86400, h = (Int(seconds) % 86400) / 3600, m = (Int(seconds) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
