import AppKit
import Darwin

/// One process as the kernel reports it, plus whatever usage we are allowed to read.
struct ProcessInfoRow: Identifiable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let command: String
    var cpu: Double = 0          // percent of one core, averaged over the sample interval
    var memory: UInt64 = 0       // physical footprint
    var id: pid_t { pid }
}

/// A process and everything that belongs to it, presented as one row.
///
/// Chrome runs a dozen helpers and Xcode several more; listing them separately
/// is technically accurate and practically useless. Children are folded into
/// the app that owns them and their usage is summed.
struct ProcessGroup: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let pid: pid_t
    var cpu: Double
    var memory: UInt64
    var children: [ProcessInfoRow]
    /// True for the synthetic row covering processes owned by other users.
    var isSystem: Bool = false

    var childCount: Int { children.count }
}

/// Samples per-process CPU and memory, and groups children under their app.
///
/// macOS only lets an unprivileged process read resource usage for processes
/// owned by the same user — 473 of 757 here, and none of the root-owned ones.
/// Rather than show zeros for the rest, their combined cost is derived from the
/// system-wide total and presented as a single "System" row, which is both
/// honest and closer to what anyone actually wants to know.
final class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var isSampling = false

    private var previousCPUTime: [pid_t: Double] = [:]
    private var previousSampleAt: Date?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "perch.processes", qos: .utility)

    /// Sampling walks every process twice, so it only runs while something is
    /// actually showing the list.
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

    // MARK: - Sampling

    private func sample() {
        guard !isSampling else { return }
        isSampling = true

        queue.async { [weak self] in
            guard let self else { return }
            let rows = Self.enumerate()
            let now = Date()
            let elapsed = self.previousSampleAt.map { now.timeIntervalSince($0) } ?? 2

            var measured: [ProcessInfoRow] = []
            var cpuTimes: [pid_t: Double] = [:]
            measured.reserveCapacity(rows.count)

            for var row in rows {
                guard let usage = Self.usage(of: row.pid) else {
                    measured.append(row)
                    continue
                }
                cpuTimes[row.pid] = usage.cpuSeconds
                if let previous = self.previousCPUTime[row.pid], elapsed > 0 {
                    row.cpu = max(0, (usage.cpuSeconds - previous) / elapsed * 100)
                }
                row.memory = usage.footprint
                measured.append(row)
            }

            let grouped = self.group(measured)
            DispatchQueue.main.async {
                self.previousCPUTime = cpuTimes
                self.previousSampleAt = now
                self.groups = grouped
                self.isSampling = false
            }
        }
    }

    /// Every process the kernel will tell us about.
    private static func enumerate() -> [ProcessInfoRow] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map { entry in
            let comm = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: comm) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            return ProcessInfoRow(pid: entry.kp_proc.p_pid,
                                  ppid: entry.kp_eproc.e_ppid,
                                  uid: entry.kp_eproc.e_ucred.cr_uid,
                                  command: name)
        }
    }

    /// The .app bundle a process's executable lives inside, if any.
    ///
    /// Chromium and Electron helpers are routinely re-parented away from the
    /// app that spawned them, so walking parents alone leaves them stranded as
    /// their own rows. Their executable still sits inside the bundle.
    private static func bundlePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        // First match, not last: helpers live in nested bundles such as
        // Discord.app/Contents/Frameworks/Discord Helper (Renderer).app, and the
        // outermost bundle is the app the user actually recognises.
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    /// Returns nil when the process belongs to another user, which is the
    /// normal case for anything system-owned.
    private static func usage(of pid: pid_t) -> (cpuSeconds: Double, footprint: UInt64)? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return (Double(info.ri_user_time + info.ri_system_time) / 1e9, info.ri_phys_footprint)
    }

    // MARK: - Grouping

    private func group(_ rows: [ProcessInfoRow]) -> [ProcessGroup] {
        let me = getuid()
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })

        // Real applications, so helpers can be attributed to something with a
        // name and an icon rather than a truncated executable string.
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = app
        }

        // Bundle path -> the app's pid, so a stranded helper can be matched by
        // where its executable lives rather than by who spawned it.
        var appByBundle: [String: pid_t] = [:]
        for (pid, app) in apps {
            if let path = app.bundleURL?.path { appByBundle[path] = pid }
        }

        /// The app a process belongs to.
        ///
        /// The enclosing bundle is checked first, because helpers often register
        /// as applications in their own right — Discord Helper (Renderer) is a
        /// real NSRunningApplication — so a parent walk stops at the helper
        /// itself and never reaches Discord. The bundle path does not have that
        /// problem: the helper's executable still lives inside Discord.app.
        func owner(of row: ProcessInfoRow) -> pid_t {
            if let bundle = Self.bundlePath(of: row.pid), let owner = appByBundle[bundle] {
                return owner
            }
            var current = row
            var hops = 0
            while hops < 12 {
                if apps[current.pid] != nil { return current.pid }
                guard current.ppid > 1, let parent = byPID[current.ppid], parent.uid == current.uid
                else { break }
                current = parent
                hops += 1
            }
            return current.pid
        }

        var buckets: [pid_t: ProcessGroup] = [:]
        var systemCPU = 0.0
        var systemMemory: UInt64 = 0
        var systemCount = 0

        for row in rows {
            guard row.uid == me else {
                // Usage is unreadable for these; count them and account for
                // their CPU from the system-wide total instead.
                systemCount += 1
                systemMemory += row.memory
                continue
            }
            let ownerPID = owner(of: row)
            let app = apps[ownerPID]
            let name = app?.localizedName ?? byPID[ownerPID]?.command ?? row.command

            if var existing = buckets[ownerPID] {
                existing.cpu += row.cpu
                existing.memory += row.memory
                if row.pid != ownerPID { existing.children.append(row) }
                buckets[ownerPID] = existing
            } else {
                buckets[ownerPID] = ProcessGroup(
                    id: "\(ownerPID)", name: name, icon: app?.icon, pid: ownerPID,
                    cpu: row.cpu, memory: row.memory,
                    children: row.pid == ownerPID ? [] : [row])
            }
        }

        // Per-process usage is unreadable for other users, so the system row is
        // whatever the machine-wide figures have that our processes do not.
        let snapshot = SystemMonitor.shared.snapshot
        let accountedCPU = buckets.values.reduce(0) { $0 + $1.cpu }
        systemCPU = max(0, snapshot.cpuUsed - accountedCPU)
        // Deliberately left at zero. Physical footprints count shared memory
        // against every process holding it, so they sum to more than the machine
        // has -- subtracting them from the total produces a meaningless number.
        // The row shows a dash instead.
        systemMemory = 0

        var result = Array(buckets.values)
        if systemCount > 0 {
            result.append(ProcessGroup(
                id: "system", name: "System", icon: nil, pid: 0,
                cpu: systemCPU, memory: systemMemory,
                children: [], isSystem: true))
        }
        return result.sorted { $0.cpu > $1.cpu }
    }
}
