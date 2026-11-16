// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Perch",
            path: "Sources/Perch",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Warnings only: surfaces data races without Swift 6's hard errors.
                .enableExperimentalFeature("StrictConcurrency"),
            ],
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
