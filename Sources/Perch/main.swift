import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

if CommandLine.arguments.contains("--probe-windows") {
    _ = NSApplication.shared
    MainActor.assumeIsolated { SelfTest.probeWindows() }
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
