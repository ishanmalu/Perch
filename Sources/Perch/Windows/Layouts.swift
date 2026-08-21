import Foundation
import CoreGraphics

/// A pane expressed in unit coordinates (0...1) of a screen's usable area,
/// origin top-left to match how people read a layout grid.
struct Pane: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double, y: Double, w: Double, h: Double

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

struct CustomLayout: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var panes: [Pane]

    static let builtins: [CustomLayout] = [
        .init(name: "Halves", panes: [Pane(0, 0, 0.5, 1), Pane(0.5, 0, 0.5, 1)]),
        .init(name: "Thirds", panes: [Pane(0, 0, 1.0/3, 1), Pane(1.0/3, 0, 1.0/3, 1), Pane(2.0/3, 0, 1.0/3, 1)]),
        .init(name: "Main + Stack", panes: [Pane(0, 0, 0.62, 1), Pane(0.62, 0, 0.38, 0.5), Pane(0.62, 0.5, 0.38, 0.5)]),
        .init(name: "Quarters", panes: [Pane(0, 0, 0.5, 0.5), Pane(0.5, 0, 0.5, 0.5), Pane(0, 0.5, 0.5, 0.5), Pane(0.5, 0.5, 0.5, 0.5)]),
        .init(name: "Focus", panes: [Pane(0.15, 0.05, 0.7, 0.9)]),
    ]
}

/// One-shot window placements. Directional actions cycle through several
/// widths on repeated presses, the way Rectangle/Magnet do.
enum WindowAction: String, CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case thirdLeft, thirdCenter, thirdRight
    case twoThirdsLeft, twoThirdsRight
    case maximize, center, almostMaximize

    var title: String {
        switch self {
        case .left: return "Left Half";           case .right: return "Right Half"
        case .top: return "Top Half";             case .bottom: return "Bottom Half"
        case .topLeft: return "Top Left";         case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left";   case .bottomRight: return "Bottom Right"
        case .thirdLeft: return "Left Third";     case .thirdCenter: return "Center Third"
        case .thirdRight: return "Right Third";   case .twoThirdsLeft: return "Left Two Thirds"
        case .twoThirdsRight: return "Right Two Thirds"
        case .maximize: return "Maximize";        case .center: return "Center"
        case .almostMaximize: return "Almost Maximize"
        }
    }

    /// `step` advances each time the same action fires in quick succession.
    func unitRect(step: Int) -> Pane {
        switch self {
        case .left:   return Pane(0, 0, [0.5, 1.0/3, 2.0/3][step % 3], 1)
        case .right:
            let w = [0.5, 1.0/3, 2.0/3][step % 3]; return Pane(1 - w, 0, w, 1)
        case .top:    return Pane(0, 0, 1, [0.5, 1.0/3, 2.0/3][step % 3])
        case .bottom:
            let h = [0.5, 1.0/3, 2.0/3][step % 3]; return Pane(0, 1 - h, 1, h)
        case .topLeft:      return Pane(0, 0, 0.5, 0.5)
        case .topRight:     return Pane(0.5, 0, 0.5, 0.5)
        case .bottomLeft:   return Pane(0, 0.5, 0.5, 0.5)
        case .bottomRight:  return Pane(0.5, 0.5, 0.5, 0.5)
        case .thirdLeft:    return Pane(0, 0, 1.0/3, 1)
        case .thirdCenter:  return Pane(1.0/3, 0, 1.0/3, 1)
        case .thirdRight:   return Pane(2.0/3, 0, 1.0/3, 1)
        case .twoThirdsLeft:  return Pane(0, 0, 2.0/3, 1)
        case .twoThirdsRight: return Pane(1.0/3, 0, 2.0/3, 1)
        case .maximize:     return Pane(0, 0, 1, 1)
        case .almostMaximize: return Pane(0.05, 0.05, 0.9, 0.9)
        case .center:       return Pane(0.2, 0.15, 0.6, 0.7)
        }
    }

    /// Only these cycle; the rest are absolute placements.
    var cycles: Bool { [.left, .right, .top, .bottom].contains(self) }
}
