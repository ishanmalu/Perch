import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

let app = NSApplication.shared

if let i = CommandLine.arguments.firstIndex(of: "--render-ui") {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { RenderUI.run(into: CommandLine.arguments.indices.contains(i + 1)
                 ? CommandLine.arguments[i + 1] : ".") }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
