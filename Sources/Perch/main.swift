import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

if CommandLine.arguments.contains("--probe-windows") {
    _ = NSApplication.shared
    MainActor.assumeIsolated { SelfTest.probeWindows() }
}

if let i = CommandLine.arguments.firstIndex(of: "--probe-layout") {
    _ = NSApplication.shared
    let wanted = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "Focus"
    MainActor.assumeIsolated {
        guard let layout = CustomLayout.builtins.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
            print("no builtin named \(wanted); have: "
                + CustomLayout.builtins.map(\.name).joined(separator: ", "))
            exit(1)
        }
        print("accessibility trusted: \(AXIsProcessTrusted())")
        print("layout \(layout.name): \(layout.panes.count) pane(s)")
        for p in layout.panes { print(String(format: "  pane x=%.2f y=%.2f w=%.2f h=%.2f", p.x, p.y, p.w, p.h)) }

        let before = WindowManager.shared.orderedWindows()
        print("\nwindows in z-order (\(before.count)):")
        for w in before.prefix(6) {
            print("  pid \(w.pid)  \(w.frame.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "no frame")  \(w.title)")
        }
        guard !before.isEmpty else { print("\nno windows to tile"); exit(0) }

        print("\napplying...")
        WindowManager.shared.apply(layout: layout)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        print("\nafter:")
        for w in WindowManager.shared.orderedWindows().prefix(6) {
            print("  pid \(w.pid)  \(w.frame.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "no frame")  \(w.title)")
        }
        exit(0)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--probe-update") {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        print("running from : \(Bundle.main.bundleURL.path)")
        print("in-place ok  : \(UpdateInstaller.canInstallInPlace)")
        if CommandLine.arguments.indices.contains(i + 1) {
            let candidate = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            print("candidate    : \(candidate.path)")
            if candidate.pathExtension == "dmg",
               CommandLine.arguments.indices.contains(i + 2) {
                // Swap a throwaway copy instead of the running app, so the
                // whole path can be exercised without relaunching anything.
                let target = URL(fileURLWithPath: CommandLine.arguments[i + 2])
                do {
                    try UpdateInstaller.swap(from: candidate, replacing: target)
                    print("swap         : ok")
                } catch {
                    print("swap         : FAILED — \(error.localizedDescription)")
                    exit(1)
                }
            } else {
                print("same signer  : \(UpdateInstaller.probeRequirement(candidate))")
            }
        }
        exit(0)
    }
}

if CommandLine.arguments.contains("--probe-stats") {
    _ = NSApplication.shared
    MainActor.assumeIsolated { SelfTest.probeStats() }
}

let app = NSApplication.shared

if CommandLine.arguments.contains("--probe-network") {
    MainActor.assumeIsolated {
        if let w = WiFiStats.read() {
            print("Wi-Fi \(w.interfaceName): \(Int(w.linkRateMbps)) Mbps link, "
                + "\(w.standard), ch \(w.channel) \(w.band) @ \(w.widthMHz) MHz, "
                + "\(w.security)")
            print("signal \(w.rssi) dBm, noise \(w.noise) dBm, SNR \(w.snr) dB "
                + "-> \(w.quality) (\(w.bars)/4)")
        } else {
            print("no active Wi-Fi link")
        }
        let test = SpeedTest.shared
        print("\nrunning speed test...")
        test.start()
        // Wait on a terminal state, not on isRunning: the task has not been
        // scheduled yet at this point, so isRunning is still false.
        let deadline = Date().addingTimeInterval(90)
        var finished = false
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            switch test.state {
            case .done, .failed: finished = true
            default: break
            }
        }
        switch test.state {
        case .done(let down, let latency):
            print(String(format: "download %.1f Mbps, latency %.0f ms", down, latency))
        case .failed(let why): print("failed: \(why)")
        default: print("timed out")
        }
        exit(0)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-ui") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { RenderUI.run(into: CommandLine.arguments.indices.contains(i + 1)
                 ? CommandLine.arguments[i + 1] : ".") }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
