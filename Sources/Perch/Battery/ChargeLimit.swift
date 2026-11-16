import AppKit
import Combine
import IOKit.ps

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
        // /Users/Shared is writable by every account. When running as root,
        // only trust a plain file in a directory that nobody else can write,
        // both owned by the same user; anything else means "no limit".
        if geteuid() == 0, !configIsTrustworthy() { return 100 }
        guard let s = try? String(contentsOf: configFile, encoding: .utf8), let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 100 }
        return min(100, max(50, v))
    }

    static func writeLimit(_ v: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir.path)
        try? String(min(100, max(50, v))).write(to: configFile, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configFile.path)
    }

    /// No symlinks, a regular file and a directory with the same owner, and
    /// neither writable by group or others.
    static func configIsTrustworthy() -> Bool {
        var d = stat(), f = stat()
        guard lstat(configDir.path, &d) == 0, lstat(configFile.path, &f) == 0,
              (d.st_mode & S_IFMT) == S_IFDIR, (f.st_mode & S_IFMT) == S_IFREG,
              d.st_uid == f.st_uid,
              expectedOwner.map { d.st_uid == $0 } ?? true,
              d.st_mode & (S_IWGRP | S_IWOTH) == 0, f.st_mode & (S_IWGRP | S_IWOTH) == 0
        else { return false }
        return true
    }

    /// The account that installed the helper, passed as `--owner <uid>`.
    /// The root daemon trusts only a config that account owns, so another
    /// local user can't pre-create /Users/Shared/Perch and set the limit.
    static let expectedOwner: uid_t? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--owner"), args.indices.contains(i + 1) else { return nil }
        return uid_t(args[i + 1])
    }()

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    // MARK: - Helper process (runs as root)

    static func runDaemon() -> Never {
        guard let smc = SMC() else { fputs("perch-charge: no SMC\n", stderr); exit(1) }
        // Exit 0 so launchd (KeepAlive: SuccessfulExit=false) does not respawn
        // a helper that can never do anything on this hardware.
        guard method(smc) != .unsupported else { fputs("perch-charge: charging keys not found\n", stderr); exit(0) }

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
          <key>ProgramArguments</key><array><string>\(helperPath)</string><string>--charge-daemon</string><string>--owner</string><string>\(getuid())</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
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
        guard let script = NSAppleScript(source: src) else { return false }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
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

    private var powerSource: CFRunLoopSource?

    /// Live updates while the Battery tab is open, driven by macOS's own
    /// power-source notifications rather than a polling timer.
    func watch(_ on: Bool) {
        if on, powerSource == nil {
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            powerSource = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue().refresh()
            }, ctx)?.takeRetainedValue()
            if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        } else if !on, let src = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            powerSource = nil
        }
    }

    func refresh() {
        // The health figure may need a (cached) system_profiler call; keep it
        // off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fresh = BatteryInfo.read()
            DispatchQueue.main.async { if self?.info != fresh { self?.info = fresh } }
        }
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
