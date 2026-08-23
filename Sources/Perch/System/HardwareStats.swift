import Foundation
import IOKit
import Darwin

/// Hardware detail behind the summary gauges: per-core CPU, GPU utilisation,
/// disk throughput and per-interface network.
///
/// Everything here is read through public interfaces and works unprivileged.
/// Die temperature is the one thing that is not reachable — the SMC keys are
/// private and `powermetrics` needs root — so the thermal *state* macOS
/// publishes is used instead, which is coarse but true.
final class HardwareStats: ObservableObject {
    struct Core: Identifiable {
        let id: Int
        let usage: Double        // 0...100
    }

    struct Interface: Identifiable {
        let id: String
        let name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
        var rateIn: Double = 0
        var rateOut: Double = 0
    }

    static let shared = HardwareStats()

    @Published private(set) var cores: [Core] = []
    @Published private(set) var gpuUsage: Double?          // nil when unreadable
    @Published private(set) var gpuName: String?
    @Published private(set) var diskRead: Double = 0       // bytes/sec
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var interfaces: [Interface] = []
    /// Rolling history for the detail sparklines.
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var diskHistory: [Double] = []
    @Published private(set) var netHistory: [Double] = []

    private var previousCoreTicks: [UInt32] = []
    private var previousDisk: (read: UInt64, write: UInt64, at: Date)?
    /// Last raw counter reading, kept at the kernel's own 32-bit width.
    private var previousInterfaces: [String: (UInt32, UInt32)] = [:]
    /// Wrap-corrected lifetime totals, accumulated from each delta.
    private var interfaceTotals: [String: (UInt64, UInt64)] = [:]
    private var previousInterfaceAt: Date?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let cores = readCores()
        let gpu = readGPU()
        let disk = readDisk()
        let nets = readInterfaces()
        DispatchQueue.main.async {
            self.cores = cores
            if let gpu {
                self.gpuUsage = gpu.usage
                self.gpuName = gpu.name
                self.gpuHistory = Array((self.gpuHistory + [gpu.usage]).suffix(60))
            }
            if let disk {
                self.diskRead = disk.read
                self.diskWrite = disk.write
                // Scaled so the sparkline is readable next to percentage traces.
                let mbps = (disk.read + disk.write) / 1_048_576
                self.diskHistory = Array((self.diskHistory + [min(100, mbps * 2)]).suffix(60))
            }
            self.interfaces = nets
            let netTotal = nets.reduce(0.0) { $0 + $1.rateIn + $1.rateOut } / 1_048_576
            self.netHistory = Array((self.netHistory + [min(100, netTotal * 20)]).suffix(60))
        }
    }

    // MARK: - CPU cores

    private func readCores() -> [Core] {
        var count = mach_msg_type_number_t(0)
        var info: processor_info_array_t?
        var cpus = natural_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return cores }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * 4) }

        var ticks = [UInt32](repeating: 0, count: Int(count))
        for i in 0..<Int(count) { ticks[i] = UInt32(bitPattern: info[i]) }

        guard previousCoreTicks.count == ticks.count else {
            previousCoreTicks = ticks
            return cores
        }

        var result: [Core] = []
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            func delta(_ state: Int) -> Double {
                Double(ticks[base + state] &- previousCoreTicks[base + state])
            }
            let user = delta(Int(CPU_STATE_USER)) + delta(Int(CPU_STATE_NICE))
            let system = delta(Int(CPU_STATE_SYSTEM))
            let idle = delta(Int(CPU_STATE_IDLE))
            let total = user + system + idle
            result.append(Core(id: cpu, usage: total > 0 ? (user + system) / total * 100 : 0))
        }
        previousCoreTicks = ticks
        return result
    }

    // MARK: - GPU

    /// Apple's accelerator drivers publish a utilisation percentage in the
    /// IORegistry. It needs no entitlement, unlike anything in the SMC.
    private func readGPU() -> (usage: Double, name: String)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            let usage = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue
            guard let usage else { continue }

            var name = "GPU"
            if let model = dict["model"] as? Data,
               let decoded = String(data: model, encoding: .utf8) {
                name = decoded.trimmingCharacters(in: .controlCharacters)
            } else if let model = dict["model"] as? String {
                name = model
            }
            return (usage, name)
        }
        return nil
    }

    // MARK: - Disk throughput

    private func readDisk() -> (read: Double, write: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            totalRead += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            totalWrite += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = Date()
        defer { previousDisk = (totalRead, totalWrite, now) }
        guard let previous = previousDisk else { return nil }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        return (Double(totalRead &- previous.read) / elapsed,
                Double(totalWrite &- previous.write) / elapsed)
    }

    // MARK: - Network interfaces

    private func readInterfaces() -> [Interface] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return interfaces }
        defer { freeifaddrs(addrs) }

        var totals: [String: (UInt32, UInt32)] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name != "lo0" else { continue }
            guard let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let existing = totals[name] ?? (0, 0)
            totals[name] = (existing.0 &+ data.pointee.ifi_ibytes,
                            existing.1 &+ data.pointee.ifi_obytes)
        }

        let now = Date()
        let elapsed = previousInterfaceAt.map { now.timeIntervalSince($0) } ?? 0
        var result: [Interface] = []
        for (name, bytes) in totals {
            // ifi_ibytes and ifi_obytes are 32-bit and wrap every 4.29 GB, which
            // on a fast link is minutes. Subtracting at 32 bits gives the right
            // delta across a wrap; widening first would turn it into ~1.8e19.
            // Two wraps in one interval would need >17 Gbps, so one is enough.
            var running = interfaceTotals[name] ?? (0, 0)
            if let previous = previousInterfaces[name] {
                running.0 &+= UInt64(bytes.0 &- previous.0)
                running.1 &+= UInt64(bytes.1 &- previous.1)
            }
            interfaceTotals[name] = running

            var iface = Interface(id: name, name: Self.friendlyName(name),
                                  bytesIn: running.0, bytesOut: running.1)
            if let previous = previousInterfaces[name], elapsed > 0 {
                iface.rateIn = Double(bytes.0 &- previous.0) / elapsed
                iface.rateOut = Double(bytes.1 &- previous.1) / elapsed
            }
            result.append(iface)
        }
        previousInterfaces = totals
        previousInterfaceAt = now
        // Idle VPN tunnels have lifetime bytes but no current traffic, and
        // listing five of them buries the interface actually in use.
        return result
            .filter { $0.rateIn + $0.rateOut > 0 || $0.bytesIn + $0.bytesOut > 1_000_000 }
            .sorted { ($0.rateIn + $0.rateOut) > ($1.rateIn + $1.rateOut) }
    }

    private static func friendlyName(_ bsd: String) -> String {
        switch bsd {
        case "en0": return "Wi-Fi"
        case "en1", "en2", "en3": return "Ethernet (\(bsd))"
        case let n where n.hasPrefix("utun") || n.hasPrefix("ipsec"): return "VPN (\(bsd))"
        case let n where n.hasPrefix("bridge"): return "Bridge (\(bsd))"
        case let n where n.hasPrefix("awdl"): return "AirDrop"
        case let n where n.hasPrefix("anpi"): return "Internal (\(bsd))"
        default: return bsd
        }
    }
}
