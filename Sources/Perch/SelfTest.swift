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

    /// `--probe-windows` reports what the layout code sees, which is otherwise
    /// invisible when a layout silently does nothing.
    static func probeWindows() -> Never {
        guard AX.isTrusted(prompt: false) else {
            print("Accessibility not granted — nothing to see."); exit(1)
        }
        let all = WindowManager.shared.orderedWindows()
        print("orderedWindows(): \(all.count)")
        for w in all.prefix(12) {
            let app = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "?"
            let f = w.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "no frame"
            print("  \(app) — \(w.title.isEmpty ? "(untitled)" : w.title) — \(f)")
        }
        print("\nscreens: \(NSScreen.screens.count), main = \(NSScreen.main?.frame ?? .zero)")
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

        print("\nBrightness steps stay in range")
        let step = BrightnessController.stepSize
        expect(BrightnessController.stepped(0.5, by: step) == 0.5625,
               "one press moves a sixteenth")
        expect(BrightnessController.stepped(1.0, by: step) == 1.0,
               "stepping up from full stays at full")
        expect(BrightnessController.stepped(0.05, by: -step) == step,
               "stepping down floors at one step, never black")
        expect(BrightnessController.stepped(0.0, by: -step) == step,
               "a display already at zero comes back rather than sticking")

        print("\nDisplay modes group and pick sanely")
        typealias DM = DisplayModeController
        let modeSample: [DM.Mode] = [
            .init(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refresh: 120, isNative: true),
            .init(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refresh: 60),
            .init(width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338, refresh: 60),
            .init(width: 1800, height: 1169, pixelWidth: 1800, pixelHeight: 1169, refresh: 60),
            .init(width: 1800, height: 1169, pixelWidth: 1800, pixelHeight: 1169, refresh: 120),
        ]
        let res = DM.resolutions(in: modeSample)
        expect(res.map(\.id) == ["1800x1169@2x", "1800x1169", "1512x982@2x"],
               "largest first, HiDPI before low-res of the same size")
        expect(DM.refreshRates(in: modeSample, for: res[2]) == [120, 60], "rates fastest first")
        expect(DM.best(in: modeSample, resolution: res[0], refresh: 120)?.refresh == 60,
               "falls back to the fastest rate a resolution has")
        expect(DM.best(in: modeSample, resolution: res[1], refresh: 60)?.refresh == 60,
               "keeps the current rate when the new resolution offers it")
        expect(DM.rateLabel(59.94) == "59.94 Hz" && DM.rateLabel(120) == "120 Hz",
               "fractional rates keep their decimals")

        print("\nVersion ordering")
        expect(Updater.isNewer("1.10.0", than: "1.9.2"), "1.10.0 is newer than 1.9.2, not older")
        expect(!Updater.isNewer("1.9.2", than: "1.10.0"), "and never the other way round")

        print("\nDisplay presets and arrangement")
        let kA = DisplayKey(vendor: 1, model: 2, serial: 3), kB = DisplayKey(vendor: 4, model: 5, serial: 6)
        let entry = { (k: DisplayKey) in DisplayPreset.Entry(key: k, name: "", mode: nil, brightness: 1, origin: .zero) }
        var desk = DisplayPreset(name: "Desk", entries: [entry(kA), entry(kB)]); desk.autoApply = true
        let solo = DisplayPreset(name: "Solo", entries: [entry(kA)], autoApply: true)
        expect(DisplayPreset.autoMatch([solo, desk], connected: [kA, kB])?.name == "Desk",
               "auto-apply needs the exact set of displays")
        expect(DisplayPreset.autoMatch([desk], connected: [kA]) == nil,
               "a missing display means no match")
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expect(DisplayArrangement.origin(for: CGSize(width: 2560, height: 1440), beside: main, .left)
               == CGPoint(x: -2560, y: -229), "left of main sits flush and centred")
        expect(DisplayArrangement.origin(for: CGSize(width: 1920, height: 1080), beside: main, .above)
               == CGPoint(x: -204, y: -1080), "above main sits flush and centred")

        print("\nDDC packets")
        let w = DDC.writePacket(0x10, 50)
        let wantChk: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x32
        expect(w == [0x84, 0x03, 0x10, 0x00, 0x32, wantChk],
               "brightness write packet and checksum")
        let readChk: UInt8 = 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10
        expect(DDC.readRequest(0x10).last == readChk, "read request checksum")
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x46, 0x00]
        expect(DDC.parseReply(reply, code: 0x10).map { $0.0 == 70 && $0.1 == 100 } == true,
               "reply parses current and max")
        expect(DDC.parseReply(reply, code: 0x62) == nil, "a reply for another code is rejected")
        var bad = reply; bad[3] = 0x01
        expect(DDC.parseReply(bad, code: 0x10) == nil, "an unsupported-code reply is rejected")

        print("\nXDR gain never dims or clips")
        expect(XDRBoost.gain(headroom: 1.6, amount: 0) == 1, "zero boost is a no-op")
        expect(XDRBoost.gain(headroom: 1.6, amount: 1) == 1.6, "full boost stops at the headroom")
        expect(XDRBoost.gain(headroom: 0.8, amount: 1) == 1, "no headroom never dims")

        print("\nSnap zones")
        let scr = CGRect(x: 0, y: 0, width: 1000, height: 800)
        typealias Z = WindowSnapping
        expect(Z.zone(for: CGPoint(x: 0, y: 400), in: scr) == .left, "left edge halves")
        expect(Z.zone(for: CGPoint(x: 999, y: 400), in: scr) == .right, "right edge halves")
        expect(Z.zone(for: CGPoint(x: 500, y: 799), in: scr) == .top, "top edge fills")
        expect(Z.zone(for: CGPoint(x: 0, y: 790), in: scr) == .topLeft, "top-left corner quarters")
        expect(Z.zone(for: CGPoint(x: 999, y: 5), in: scr) == .bottomRight, "bottom-right corner quarters")
        expect(Z.zone(for: CGPoint(x: 0, y: 713), in: scr) == .topLeft,
               "a corner is big enough to hit: 87 pt down the left edge still counts")
        expect(Z.zone(for: CGPoint(x: 0, y: 650), in: scr) == .left, "further down it's a half again")
        let nat: [DM.Mode] = [
            .init(width: 2560, height: 1664, pixelWidth: 2560, pixelHeight: 1664, refresh: 60, isNative: true),
            .init(width: 1280, height: 832, pixelWidth: 2560, pixelHeight: 1664, refresh: 60, isNative: true),
            .init(width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912, refresh: 60),
        ]
        expect(DM.nativeResolution(in: nat)?.id == "1280x832@2x", "only one resolution is labelled native")
        let ext: [DM.Mode] = [
            .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refresh: 144, isNative: true),
            .init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refresh: 60, isNative: true),
            .init(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refresh: 60),
        ]
        expect(DM.nativeResolution(in: ext)?.id == "1920x1080", "a 1080p monitor's native is its plain mode")
        let ext30 = ext + [.init(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refresh: 30)]
        expect(DM.resolutions(in: ext30).first?.id == "1920x1080",
               "a 30 Hz HiDPI mode on a 144 Hz monitor isn't offered")
        let slow = DM.Resolution(width: 1920, height: 1080, hiDPI: true)
        expect(DM.resolutions(in: ext30, keeping: slow).contains(slow),
               "but if the display is already in it, it stays listed")
        expect(DM.refreshRates(in: ext, for: DM.resolutions(in: ext)[0]) == [144, 60], "144 Hz is offered at 1080p")
        expect(Z.zone(for: CGPoint(x: 500, y: 400), in: scr) == nil, "the middle does nothing")
        expect(Z.zone(for: CGPoint(x: 500, y: 0), in: scr) == nil, "the bottom edge alone does nothing")

        print("\nWorkspaces")
        var ws = Workspace(name: "Desk", placements: [], displays: [kA, kB]); ws.autoRestore = true
        expect(Workspaces.autoMatch([ws], connected: [kA, kB])?.name == "Desk", "restores on its displays")
        expect(Workspaces.autoMatch([ws], connected: [kA]) == nil, "not on a different set")

        print("\nFocus and calendar")
        expect(FocusTimer.clock(1500) == "25:00" && FocusTimer.clock(59.2) == "1:00", "timer clock rounds up")
        expect(CalendarPeek.joinLink(in: [nil, "Room 4", "Join: https://zoom.us/j/123?pwd=x"])?.host == "zoom.us",
               "finds a Zoom link in the notes")
        expect(CalendarPeek.joinLink(in: ["https://example.com/agenda"]) == nil, "ignores ordinary links")

        print("\nBattery charge limit")
        typealias CC = ChargeControl
        expect(CC.shouldCharge(percent: 80, limit: 80, currentlyAllowed: true) == false, "stops at the limit")
        expect(CC.shouldCharge(percent: 79, limit: 80, currentlyAllowed: false) == false, "stays off inside the band")
        expect(CC.shouldCharge(percent: 77, limit: 80, currentlyAllowed: false) == true, "resumes below the band")
        expect(CC.shouldCharge(percent: 99, limit: 100, currentlyAllowed: false) == true, "100 means no limit")
        expect(SMC.fourCC("CHTE") == 0x43485445, "SMC key encoding")

        print("\nUninstaller only matches exact names")
        typealias U = AppUninstaller
        expect(U.isLeftover("com.acme.Notes.plist", bundleID: "com.acme.Notes", appName: "Notes"), "plist by bundle id")
        expect(U.isLeftover("ABCDE12345.com.acme.Notes", bundleID: "com.acme.Notes", appName: "Notes"), "group container")
        expect(U.isLeftover("Notes", bundleID: "com.acme.Notes", appName: "Notes"), "folder named for the app")
        expect(!U.isLeftover("NotesSync", bundleID: "com.acme.Notes", appName: "Notes"), "no prefix match on names")
        expect(!U.isLeftover("com.acme.NotesHelper", bundleID: "com.acme.Notes", appName: "Notes"), "no prefix match on ids")
        expect(!U.isLeftover("Go", bundleID: "com.x.go", appName: "Go"), "very short names aren't trusted")

        print("\nSnippets")
        let snips = [Snippet(trigger: ";sig", text: "A"), Snippet(trigger: ";sig2", text: "B")]
        expect(SnippetStore.match("hello ;sig", in: snips)?.text == "A", "trigger at the end expands")
        expect(SnippetStore.match("hello ;sig2", in: snips)?.text == "B", "longest trigger wins")
        expect(SnippetStore.match(";sig and more", in: snips) == nil, "only a trigger at the end counts")
        expect(SnippetStore.render("x{clipboard}y", clipboard: "Z") == "xZy", "clipboard placeholder")

        // OCR runs over whatever was captured, so it can be checked without
        // the screen: render known text, read it back.
        let sample = NSImage(size: NSSize(width: 640, height: 90))
        sample.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 90).fill()
        ("brew install --cask perch" as NSString).draw(
            at: NSPoint(x: 14, y: 30),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                             .foregroundColor: NSColor.black])
        sample.unlockFocus()
        if let tiff = sample.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
            let read = Screenshot.recognizeText(in: cg)
            expect(read.contains("brew install"), "text is recognised in a capture")
            // Vision turns a double hyphen into an em dash, which silently
            // breaks any command line put through it.
            expect(!read.contains("\u{2014}"), "the em dash Vision substitutes for -- is undone")
            expect(read.contains("--cask"), "a command survives OCR intact")
        } else {
            expect(false, "could not build the OCR sample image")
        }

        // Hex is what a sampled colour is wanted as.
        expect(Screenshot.hex(.white) == "#FFFFFF", "white converts to hex")
        expect(Screenshot.hex(.black) == "#000000", "black converts to hex")
        expect(Screenshot.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000",
               "a mid channel rounds rather than truncates")

        // Screenshot geometry. AppKit hands the selection back with a
        // bottom-left origin; CoreGraphics captures top-left. Getting the flip
        // wrong looks fine on the main display and mirrors on a second one, so
        // both cases are pinned here.
        let primaryMaxY: CGFloat = 900

        // Main display, selection 100pt up from the bottom of a 900pt screen:
        // its top edge is 200 from the bottom, so 700 from the top.
        let onPrimary = Screenshot.globalRect(
            local: CGRect(x: 50, y: 100, width: 300, height: 100),
            windowFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            primaryMaxY: primaryMaxY)
        expect(onPrimary == CGRect(x: 50, y: 700, width: 300, height: 100),
               "selection on the primary display converts to top-left space")

        // A display sitting above the primary spans negative y once flipped:
        // its top edge is at -900, its bottom edge at 0. A selection at the
        // view's origin is at the *bottom* of that display, so it ends up in
        // the 100pt band immediately above the primary, not at the far top.
        let aboveBottom = Screenshot.globalRect(
            local: CGRect(x: 0, y: 0, width: 100, height: 100),
            windowFrame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            primaryMaxY: primaryMaxY)
        expect(aboveBottom == CGRect(x: 0, y: -100, width: 100, height: 100),
               "a selection at the foot of an upper display sits just above the primary")

        // And one at the top of that display reaches the far edge of the desktop.
        let aboveTop = Screenshot.globalRect(
            local: CGRect(x: 0, y: 800, width: 100, height: 100),
            windowFrame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            primaryMaxY: primaryMaxY)
        expect(aboveTop == CGRect(x: 0, y: -900, width: 100, height: 100),
               "a selection at the head of an upper display reaches the top of the desktop")

        // A display to the right keeps its x offset and its own flip.
        let right = Screenshot.globalRect(
            local: CGRect(x: 10, y: 10, width: 20, height: 30),
            windowFrame: CGRect(x: 1440, y: 0, width: 1000, height: 600),
            primaryMaxY: primaryMaxY)
        expect(right == CGRect(x: 1450, y: 860, width: 20, height: 30),
               "a display beside the primary keeps its offset")

        // Size must survive untouched; a flip that scales is a flip that is wrong.
        expect(onPrimary.size == CGSize(width: 300, height: 100)
               && right.size == CGSize(width: 20, height: 30),
               "conversion never changes the size of the selection")

        // The battery floor and a still-true trigger used to fight once a
        // second: the floor ended the session, the trigger restarted it, and a
        // notification fired every two seconds. These pin the latch that fixed it.
        let low = BatteryFloor.evaluate(tripped: false, active: true, floor: 10,
                                        percent: 8, charging: false)
        expect(low.stopSession && low.tripped, "battery floor ends a session below the floor")

        let again = BatteryFloor.evaluate(tripped: true, active: true, floor: 10,
                                          percent: 8, charging: false)
        expect(!again.stopSession && again.tripped, "floor stays latched, so it fires once")

        let hovering = BatteryFloor.evaluate(tripped: true, active: false, floor: 10,
                                             percent: 12, charging: false)
        expect(hovering.tripped, "latch holds inside the margin above the floor")

        let recovered = BatteryFloor.evaluate(tripped: true, active: false, floor: 10,
                                              percent: 16, charging: false)
        expect(!recovered.tripped, "latch clears once the battery recovers past the margin")

        let plugged = BatteryFloor.evaluate(tripped: true, active: false, floor: 10,
                                            percent: 8, charging: true)
        expect(!plugged.tripped, "latch clears when the charger goes in")

        let plentiful = BatteryFloor.evaluate(tripped: false, active: true, floor: 10,
                                              percent: 80, charging: false)
        expect(!plentiful.stopSession, "a healthy battery leaves the session alone")

        let desktop = BatteryFloor.evaluate(tripped: false, active: true, floor: 10,
                                            percent: nil, charging: true)
        expect(!desktop.stopSession, "a machine with no battery is never cut off")

        let disabled = BatteryFloor.evaluate(tripped: false, active: true, floor: nil,
                                             percent: 3, charging: false)
        expect(!disabled.stopSession, "floor off means no cut-off at any charge")

        print("\n\(failures.isEmpty ? "All checks passed." : "\(failures.count) check(s) failed:")")
        failures.forEach { print("  - \($0)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
