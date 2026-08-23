import AppKit
import Foundation

/// Switches the UI into a state suitable for documentation images.
///
/// Only `--render-ui` turns this on; the shipping app never does. Three things
/// need it. `ImageRenderer` cannot draw a live `TextField`, so the process
/// search box comes out as an empty placeholder bar. The harness runs from a
/// loose binary rather than an app bundle, so the version reads `0.0.0`. And
/// the process list would otherwise name whatever happens to be running on the
/// machine that produced the screenshot.
enum RenderMode {
    /// True only while `--render-ui` is drawing.
    static var isActive = false

    /// Version shown in place of the bundle's, which is absent under the harness.
    static var version = "1.6.0"

    /// A representative process list, so screenshots do not expose the apps
    /// running on the machine that rendered them.
    static let demoProcesses: [(name: String, bundleID: String, cpu: Double,
                                memory: UInt64, children: Int)] = [
        ("System",  "",                          11.01,             0,  0),
        ("Safari",  "com.apple.Safari",           6.42, 1_180_000_000, 14),
        ("Mail",    "com.apple.mail",             3.18,   940_000_000,  6),
        ("Music",   "com.apple.Music",            1.27,   612_000_000,  4),
        ("Notes",   "com.apple.Notes",            0.44,   288_000_000,  0),
        ("Perch",   "com.ishanmalu.perch",        0.08,    41_000_000,  0),
    ]

    /// A plausible 60-sample trace, so documentation images show the shape the
    /// sparklines take in use rather than the flat line a few seconds of
    /// sampling produces.
    static func demoHistory(seed: Int, base: Double, swing: Double) -> [Double] {
        (0..<60).map { i in
            let t = Double(i) / 6.0 + Double(seed)
            let wave = sin(t) * 0.55 + sin(t * 2.7 + 1.3) * 0.30 + sin(t * 0.6) * 0.15
            return max(2, min(100, base + wave * swing))
        }
    }

    /// Resolves an installed app's icon, falling back to the generic
    /// application icon rather than the blank document one.
    static func icon(forBundleID id: String) -> NSImage? {
        if !id.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
