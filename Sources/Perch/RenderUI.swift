import AppKit
import SwiftUI

/// `Perch --render-ui <dir>` renders the app's surfaces to PNGs offscreen and
/// prints their measured sizes. Layout bugs in a menu bar popover are otherwise
/// hard to catch — you cannot screenshot a popover from a script — so this
/// gives the panel a feedback loop that does not depend on clicking it.
enum RenderUI {
    @MainActor
    static func run(into directory: String) -> Never {
        RenderMode.isActive = true
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        SystemMonitor.shared.start()
        BrightnessController.shared.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(5.0))

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900

        // Prime the panel once and throw the result away. The observable
        // singletons only begin sampling when a view first appears, so without
        // this the earliest renders capture empty process lists.
        let primer = NSHostingView(rootView: MainPanelView(
            maxHeight: screenHeight - 40, onOpenSettings: {}, onQuit: {},
            flattened: true, initialTab: .system))
        primer.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        primer.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        print("main screen usable height: \(Int(screenHeight))pt\n")

        // Render each tab in both appearances so documentation images can match
        // whatever theme the reader is in.
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            for tab in MainPanelView.PanelTab.allCases {
                render(AnyView(MainPanelView(maxHeight: screenHeight - 40,
                                             onOpenSettings: {}, onQuit: {},
                                             flattened: true, initialTab: tab)),
                       width: 300, name: "panel-\(tab.rawValue)-\(suffix)",
                       into: dir, budget: 520)
            }
            // Each System metric, so the site can show the drill-down.
            for metric in SystemMetric.allCases {
                render(AnyView(MainPanelView(maxHeight: screenHeight - 40,
                                             onOpenSettings: {}, onQuit: {},
                                             flattened: true, initialTab: .system,
                                             initialMetric: metric)),
                       width: 300, name: "panel-system-\(metric.rawValue)-\(suffix)",
                       into: dir, budget: 520)
            }
        }
        NSApp.appearance = nil

        // A deliberately cramped display, to prove the cap engages.
        render(AnyView(MainPanelView(maxHeight: 520, onOpenSettings: {}, onQuit: {})),
               width: 300, name: "panel-small", into: dir, budget: 520)

        exit(0)
    }

    @MainActor
    private static func render(_ view: AnyView, width: CGFloat, name: String,
                               into dir: URL, budget: CGFloat) {
        // Measure through NSHostingView (fittingSize is the honest number)...
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        let height = max(host.fittingSize.height, 10)

        let verdict = height <= budget ? "fits" : "OVERFLOWS by \(Int(height - budget))pt"
        print("\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) "
              + "\(Int(width))x\(Int(height))  budget \(Int(budget))  → \(verdict)")

        // ...but draw through ImageRenderer, which renders SwiftUI text properly
        // where an offscreen view's cacheDisplay does not.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, isDark ? .dark : .light)
        )
        renderer.scale = 3
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
