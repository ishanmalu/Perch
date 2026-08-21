import AppKit
import SwiftUI

/// `Perch --render-ui <dir>` renders the app's surfaces to PNGs offscreen and
/// prints their measured sizes. Layout bugs in a menu bar popover are otherwise
/// hard to catch — you cannot screenshot a popover from a script — so this
/// gives the panel a feedback loop that does not depend on clicking it.
enum RenderUI {
    @MainActor
    static func run(into directory: String) -> Never {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        print("main screen usable height: \(Int(screenHeight))pt\n")

        for tab in MainPanelView.PanelTab.allCases {
            render(AnyView(MainPanelView(maxHeight: screenHeight - 40,
                                         onOpenSettings: {}, onQuit: {},
                                         flattened: true, initialTab: tab)),
                   width: 300, name: "panel-\(tab.rawValue)", into: dir, budget: 420)
        }

        // A deliberately cramped display, to prove the cap engages.
        render(AnyView(MainPanelView(maxHeight: 420, onOpenSettings: {}, onQuit: {})),
               width: 300, name: "panel-small", into: dir, budget: 420)

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
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
