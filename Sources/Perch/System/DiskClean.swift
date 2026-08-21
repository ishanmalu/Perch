import Foundation

struct DiskTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String                 // supports a leading ~
    var enabled: Bool = true
    /// Delete the directory's contents but keep the directory itself.
    var contentsOnly: Bool = true
    /// Only remove entries older than this many days (0 = no age filter).
    var olderThanDays: Int = 0
    /// Glob-ish suffix filters; empty means "everything".
    var matching: [String] = []
    var builtin: Bool = false

    var expandedPath: String { (path as NSString).expandingTildeInPath }
    var url: URL { URL(fileURLWithPath: expandedPath) }

    static let defaults: [DiskTarget] = [
        .init(name: "User caches", path: "~/Library/Caches", builtin: true),
        .init(name: "Xcode DerivedData", path: "~/Library/Developer/Xcode/DerivedData", builtin: true),
        .init(name: "Xcode device support", path: "~/Library/Developer/Xcode/iOS DeviceSupport", builtin: true),
        .init(name: "Xcode archives", path: "~/Library/Developer/Xcode/Archives", olderThanDays: 30, builtin: true),
        .init(name: "npm cache", path: "~/.npm/_cacache", builtin: true),
        .init(name: "Yarn cache", path: "~/Library/Caches/Yarn", builtin: true),
        .init(name: "pip cache", path: "~/Library/Caches/pip", builtin: true),
        .init(name: "Homebrew cache", path: "~/Library/Caches/Homebrew", builtin: true),
        .init(name: "Go build cache", path: "~/Library/Caches/go-build", builtin: true),
        .init(name: "Gradle caches", path: "~/.gradle/caches", builtin: true),
        .init(name: "CocoaPods cache", path: "~/Library/Caches/CocoaPods", builtin: true),
        .init(name: "Docker build logs", path: "~/Library/Containers/com.docker.docker/Data/log", builtin: true),
        .init(name: "Old downloads", path: "~/Downloads", enabled: false, olderThanDays: 90, builtin: true),
        .init(name: "Trash", path: "~/.Trash", builtin: true),
        .init(name: "Crash reports", path: "~/Library/Logs/DiagnosticReports", builtin: true),
        .init(name: "iOS software updates", path: "~/Library/iTunes/iPhone Software Updates", builtin: true),
    ]
}

/// Paths a cleaning target must never resolve to. A typo like `~` or `/`
/// in a custom target would otherwise trash the user's whole home folder.
enum PathGuard {
    private static let forbidden: Set<String> = {
        let home = NSHomeDirectory()
        var set: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users",
                                "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/Volumes"]
        set.insert(home)
        for name in ["Documents", "Desktop", "Pictures", "Music", "Movies", "Library",
                     "Applications", "Developer", "Public", ".ssh", ".gnupg", ".aws", ".config"] {
            set.insert((home as NSString).appendingPathComponent(name))
        }
        return set
    }()

    /// nil when the path is safe to clean, otherwise the reason it was rejected.
    static func rejectionReason(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        // Check before URL resolution — otherwise a relative path silently
        // becomes cwd-relative and could land inside an allowed root.
        guard expanded.hasPrefix("/") else { return "Path must be absolute." }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if forbidden.contains(normalized) { return "\(normalized) is too broad to clean safely." }
        // A target has to sit somewhere under the home folder or a temp area.
        let allowedRoots = [NSHomeDirectory(), "/tmp", "/private/tmp", NSTemporaryDirectory()]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowedRoots.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) else {
            return "Only folders inside your home directory or a temp directory can be cleaned."
        }
        return nil
    }

    static func isSafe(_ path: String) -> Bool { rejectionReason(for: path) == nil }
}

struct ScanResult: Identifiable {
    var id: UUID { target.id }
    var target: DiskTarget
    var size: UInt64
    var fileCount: Int
    var exists: Bool
}

/// Measures and reclaims space from a list of targets. Everything goes through
/// `FileManager.trashItem` so nothing is destroyed outright.
final class DiskCleaner: ObservableObject {
    static let shared = DiskCleaner()

    @Published private(set) var results: [ScanResult] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastReclaimed: UInt64 = 0

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "perch.diskclean", qos: .utility)

    var totalReclaimable: UInt64 {
        results.filter { $0.target.enabled }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        let targets = Prefs.shared.diskTargets
        queue.async {
            let out = targets.map { t -> ScanResult in
                guard PathGuard.isSafe(t.path) else {
                    return ScanResult(target: t, size: 0, fileCount: 0, exists: false)
                }
                guard self.fm.fileExists(atPath: t.expandedPath) else {
                    return ScanResult(target: t, size: 0, fileCount: 0, exists: false)
                }
                let entries = self.entries(for: t)
                let size = entries.reduce(0) { $0 + self.size(of: $1) }
                return ScanResult(target: t, size: size, fileCount: entries.count, exists: true)
            }
            DispatchQueue.main.async {
                self.results = out.sorted { $0.size > $1.size }
                self.scanning = false
            }
        }
    }

    /// Moves the matching entries of every enabled target to the Trash.
    func clean(_ targets: [DiskTarget], completion: @escaping (UInt64, [String]) -> Void) {
        queue.async {
            var freed: UInt64 = 0
            var failures: [String] = []
            for t in targets where t.enabled {
                guard PathGuard.isSafe(t.path) else {
                    failures.append("\(t.name) — unsafe path, skipped")
                    continue
                }
                for url in self.entries(for: t) {
                    let s = self.size(of: url)
                    do {
                        try self.fm.trashItem(at: url, resultingItemURL: nil)
                        freed += s
                    } catch {
                        failures.append(url.lastPathComponent)
                    }
                }
                if !t.contentsOnly, self.fm.fileExists(atPath: t.expandedPath) {
                    try? self.fm.trashItem(at: t.url, resultingItemURL: nil)
                }
            }
            DispatchQueue.main.async {
                self.lastReclaimed = freed
                completion(freed, failures)
                self.scan()
            }
        }
    }

    // MARK: - Internals

    /// The concrete files/folders a target refers to, after age and name filters.
    private func entries(for t: DiskTarget) -> [URL] {
        guard let children = try? fm.contentsOfDirectory(at: t.url,
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = t.olderThanDays > 0
            ? Date().addingTimeInterval(-Double(t.olderThanDays) * 86400) : nil

        return children.filter { url in
            if let cutoff {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff else { return false }
            }
            if !t.matching.isEmpty {
                let name = url.lastPathComponent.lowercased()
                guard t.matching.contains(where: { name.hasSuffix($0.lowercased().replacingOccurrences(of: "*", with: "")) })
                else { return false }
            }
            return true
        }
    }

    private func size(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory == true {
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                        options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return 0 }
            var total: UInt64 = 0
            for case let child as URL in e {
                let v = try? child.resourceValues(forKeys: Set(keys))
                total += UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
            return total
        }
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
