import AppKit
import Combine

/// Stop charging at a set level to slow battery wear.
///
/// Charging can only be inhibited by writing to the SMC, which needs root.
/// Rather than ask for a password every time the battery crosses the line, a
/// small root helper is installed once (a copy of Perch's own binary, run as
/// a LaunchDaemon with `--charge-daemon`). It reads the limit from a file the
/// app writes and flips charging on and off around it.
///
/// Fail-safe by design: uninstalling, or the helper exiting for any reason,
/// re-enables charging first. A limit of 100 means "off".
enum ChargeControl {
    /// Apple Silicon firmware from macOS 13+: one ui32, non-zero inhibits.
    static let modernKey = "CHTE"
    /// Older firmware: two ui8 keys, 0x02 inhibits.
    static let legacyKeys = ["CH0B", "CH0C"]

    enum Method: Equatable { case modern, legacy, unsupported }

    static func method(_ smc: SMC) -> Method {
        if smc.info(modernKey)?.size == 4 { return .modern }
        if legacyKeys.allSatisfy({ smc.info($0)?.size == 1 }) { return .legacy }
        return .unsupported
    }

    @discardableResult
    static func setCharging(_ allowed: Bool, _ smc: SMC) -> Bool {
        switch method(smc) {
        case .modern: return smc.write(modernKey, allowed ? [0, 0, 0, 0] : [1, 0, 0, 0])
        case .legacy: return legacyKeys.allSatisfy { smc.write($0, [allowed ? 0x00 : 0x02]) }
        case .unsupported: return false
        }
    }

    /// Pure, self-tested hysteresis: stop at the limit, resume a few points
    /// below it, so the battery isn't toggled every percent.
    static func shouldCharge(percent: Int, limit: Int, currentlyAllowed: Bool, band: Int = 3) -> Bool {
        if limit >= 100 { return true }
        if percent >= limit { return false }
        if percent <= limit - band { return true }
        return currentlyAllowed
    }

    // MARK: - Shared config between app and helper

    static let configDir = URL(fileURLWithPath: "/Users/Shared/Perch")
    static let configFile = configDir.appendingPathComponent("charge-limit")
    static let helperDir = URL(fileURLWithPath: "/Library/Application Support/Perch")
    static let helperPath = helperDir.appendingPathComponent("perch-charge").path
    static let plistPath = "/Library/LaunchDaemons/com.ishanmalu.perch.charge.plist"
    static let label = "com.ishanmalu.perch.charge"

    static func readLimit() -> Int {
        guard let s = try? String(contentsOf: configFile, encoding: .utf8), let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 100 }
        return min(100, max(50, v))
    }

    static func writeLimit(_ v: Int) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? String(min(100, max(50, v))).write(to: configFile, atomically: true, encoding: .utf8)
    }

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    // MARK: - Helper process (runs as root)

    static func runDaemon() -> Never {
        guard let smc = SMC() else { fputs("perch-charge: no SMC\n", stderr); exit(1) }
        guard method(smc) != .unsupported else { fputs("perch-charge: charging keys not found\n", stderr); exit(1) }

        // Whatever ends this process, charging must come back on. Signals are
        // routed through dispatch sources so the cleanup runs as ordinary
        // code, not inside a signal handler where IOKit isn't safe to call.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                setCharging(true, smc)
                exit(0)
            }
            src.resume()
            sources.append(src)
        }

        var allowed = true
        setCharging(true, smc)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 20)
        timer.setEventHandler {
            let limit = readLimit()
            guard let b = BatteryInfo.read() else { return }
            let want = shouldCharge(percent: b.percent, limit: limit, currentlyAllowed: allowed)
            if want != allowed, setCharging(want, smc) { allowed = want }
        }
        timer.resume()
        withExtendedLifetime((sources, timer)) { dispatchMain() }
    }

    // MARK: - Install / remove (one admin prompt each)

    static func installHelper() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(helperPath)</string><string>--charge-daemon</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict></plist>
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perch-charge.plist")
        guard (try? plist.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        if !FileManager.default.fileExists(atPath: configFile.path) { writeLimit(80) }
        let script = [
            "mkdir -p \(q(helperDir.path))",
            "cp \(q(exe)) \(q(helperPath))",
            "chown root:wheel \(q(helperPath))", "chmod 755 \(q(helperPath))",
            "cp \(q(tmp.path)) \(q(plistPath))",
            "chown root:wheel \(q(plistPath))", "chmod 644 \(q(plistPath))",
            "launchctl bootout system/\(label) 2>/dev/null; launchctl bootstrap system \(q(plistPath))",
        ].joined(separator: " && ")
        return runAsAdmin(script, prompt: "Perch needs to install a small helper to control battery charging.")
    }

    static func removeHelper() -> Bool {
        // bootout sends SIGTERM, which re-enables charging before it exits.
        let script = "launchctl bootout system/\(label) 2>/dev/null; rm -f \(q(plistPath)) \(q(helperPath))"
        return runAsAdmin(script, prompt: "Perch will remove its battery helper and turn normal charging back on.")
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ shell: String, prompt: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }
}

/// App-side state for the battery settings page.
final class BatteryModel: ObservableObject {
    static let shared = BatteryModel()
    @Published private(set) var info: BatteryInfo?
    @Published private(set) var helperInstalled = ChargeControl.helperInstalled
    @Published private(set) var supported: Bool = {
        guard let smc = SMC() else { return false }
        return ChargeControl.method(smc) != .unsupported
    }()
    @Published var limit: Int = ChargeControl.readLimit() {
        didSet { ChargeControl.writeLimit(limit) }
    }

    func refresh() {
        info = BatteryInfo.read()
        helperInstalled = ChargeControl.helperInstalled
        // The installer may have written a default; show what the helper uses.
        let onDisk = ChargeControl.readLimit()
        if onDisk != limit { limit = onDisk }
    }

    func install() {
        let ok = ChargeControl.installHelper()
        refresh()
        if ok { Notifier.show("Charge limit on", "Charging stops at \(limit)%.", duration: 3) }
    }

    func remove() {
        if ChargeControl.removeHelper() {
            Notifier.show("Charge limit off", "Normal charging is back on.", duration: 3)
        }
        refresh()
    }
}
