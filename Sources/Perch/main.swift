import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
