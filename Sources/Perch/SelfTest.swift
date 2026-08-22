import Foundation
import AppKit

/// `Perch --selftest` runs the safety-critical checks and exits non-zero on
/// failure. XCTest isn't available with Command Line Tools alone, so the checks
/// ship inside the binary and stay runnable on any machine, including CI.
enum SelfTest {
    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ what: String) {
        condition ? print("  ok   \(what)") : { failures.append(what); print("  FAIL \(what)") }()
    }

    /// `--probe-stats` dumps live readings so the collectors can be checked
    /// against Activity Monitor without building any UI first.
    static func probeStats() -> Never {
        SystemMonitor.shared.start()
        HardwareStats.shared.start()
        ProcessMonitor.shared.start()
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let hw = HardwareStats.shared
        print("CPU cores (\(hw.cores.count)):")
        for core in hw.cores {
            let bar = String(repeating: "█", count: Int(core.usage / 5)) 
            print(String(format: "  core %-2d %5.1f%%  %@", core.id, core.usage, bar))
        }
        print("\nGPU: \(hw.gpuName ?? "unknown") — "
              + (hw.gpuUsage.map { String(format: "%.0f%%", $0) } ?? "unreadable"))
        print(String(format: "Disk: read %@/s  write %@/s",
                     SystemMonitor.bytes(UInt64(hw.diskRead)),
                     SystemMonitor.bytes(UInt64(hw.diskWrite))))
        print("\nInterfaces:")
        for i in hw.interfaces.prefix(5) {
            print(String(format: "  %-16s in %@/s  out %@/s", (i.name as NSString).utf8String!,
                         SystemMonitor.bytes(UInt64(i.rateIn)), SystemMonitor.bytes(UInt64(i.rateOut))))
        }

        let groups = ProcessMonitor.shared.groups
        print("\nTop processes (\(groups.count) groups):")
        for g in groups.prefix(12) {
            let extra = g.childCount > 0 ? " +\(g.childCount)" : ""
            print(String(format: "  %-26s %5.2f%%  %@",
                         ((g.name + extra) as NSString).utf8String!, g.cpu,
                         SystemMonitor.bytes(g.memory)))
        }
        let total = groups.reduce(0.0) { $0 + $1.cpu }
        print(String(format: "\n  sum of groups: %.1f%%   system-wide: %.1f%%",
                     total, SystemMonitor.shared.snapshot.cpuUsed))
        exit(0)
    }

    static func run() -> Never {
        print("Perch self-test\n")

        print("PathGuard — refuses broad or sensitive locations")
        for path in ["/", "/System", "/Users", "/Library", "/etc", "/Volumes",
                     "~", "~/Documents", "~/Desktop", "~/.ssh", "~/Library",
                     "~/Library/Caches/../../../../System", "/private/var/db", "relative/path"] {
            expect(PathGuard.rejectionReason(for: path) != nil, "rejects \(path)")
        }

        print("\nPathGuard — allows ordinary cache folders")
        for path in ["~/Library/Caches/Homebrew", "~/.npm/_cacache", "/tmp/build-junk"] {
            expect(PathGuard.isSafe(path), "allows \(path)")
        }
        for target in DiskTarget.defaults {
            expect(PathGuard.isSafe(target.path), "built-in target is safe: \(target.name)")
        }

        print("\nClipboard — recognises credentials")
        for secret in ["sk-ant-api03-abcdefghijklmnop",
                       "ghp_0123456789abcdefghijklmnopqrstuvwxyz",
                       "AKIAIOSFODNN7EXAMPLE",
                       "xoxb-123-456-abcdef",
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc",
                       "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"] {
            expect(ClipboardStore.looksSecret(secret), "flags \(secret.prefix(14))…")
        }
        for ordinary in ["hello world", "https://example.com/page", "#FF8800", "let x = 1",
                         "AKIA is an AWS key prefix, worth knowing"] {
            expect(!ClipboardStore.looksSecret(ordinary), "leaves alone: \(ordinary.prefix(24))")
        }

        print("\nLayouts — panes stay on screen")
        for layout in CustomLayout.builtins {
            let ok = layout.panes.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.w <= 1.0001 && $0.y + $0.h <= 1.0001 }
            expect(ok, "layout fits: \(layout.name)")
        }
        for action in WindowAction.allCases {
            let ok = (0..<4).allSatisfy { step in
                let p = action.unitRect(step: step)
                return p.w > 0 && p.h > 0 && p.x + p.w <= 1.0001 && p.y + p.h <= 1.0001
            }
            expect(ok, "action fits at every cycle step: \(action.rawValue)")
        }

        print("\nUpdater — only trusts GitHub over TLS")
        for allowed in ["https://github.com/ishanmalu/Perch/releases/tag/v1.0.0",
                        "https://api.github.com/repos/ishanmalu/Perch/releases/latest",
                        "https://objects.githubusercontent.com/x/y.dmg"] {
            expect(MainActor.assumeIsolated { Updater.isTrusted(URL(string: allowed)!) },
                   "allows \(URL(string: allowed)!.host!)")
        }
        for blocked in ["http://github.com/x",                 // not TLS
                        "https://evil.example.com/perch.dmg",  // wrong host
                        "https://github.com.evil.test/x.dmg",  // lookalike host
                        "file:///tmp/perch.dmg",               // local file
                        "ftp://github.com/x.dmg"] {
            expect(!(MainActor.assumeIsolated { Updater.isTrusted(URL(string: blocked)!) }),
                   "refuses \(blocked)")
        }

        print("\nShortcuts — defaults are usable")
        var seen: [String: String] = [:]
        for (name, spec) in HotkeySpec.defaults.sorted(by: { $0.key < $1.key }) {
            let combo = "\(spec.keyCode)-\(spec.modifiers)"
            expect(seen[combo] == nil, "no duplicate binding for \(name)")
            seen[combo] = name
            expect(!spec.cocoaFlags.isEmpty, "\(name) requires a modifier")
        }

        print("\n\(failures.isEmpty ? "All checks passed." : "\(failures.count) check(s) failed:")")
        failures.forEach { print("  - \($0)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
