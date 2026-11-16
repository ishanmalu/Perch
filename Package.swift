// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Perch",
            path: "Sources/Perch",
            // Strict concurrency checking is left off: as warnings it adds
            // hundreds of AppKit main-actor notices, and the Xcode 16.4
            // compiler used in CI crashes (signal 11) with it enabled.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Metal"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
