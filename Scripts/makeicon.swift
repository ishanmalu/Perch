#!/usr/bin/env swift
// Draws the Perch app icon at every size macOS asks for and emits Perch.icns.
// Pure AppKit so the repo needs no design tooling to rebuild the artwork.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // Squircle background with a deep dusk gradient.
    let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.055, dy: s * 0.055),
                                xRadius: s * 0.225, yRadius: s * 0.225)
    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.55, blue: 0.53, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -60)

    // Faint window-grid motif in the upper area — the window-manager half of the app.
    NSColor.white.withAlphaComponent(0.10).setFill()
    let gx = s * 0.235, gy = s * 0.545, gw = s * 0.53, gh = s * 0.235, gap = s * 0.022
    NSBezierPath(roundedRect: CGRect(x: gx, y: gy, width: gw * 0.5 - gap, height: gh),
                 xRadius: s * 0.026, yRadius: s * 0.026).fill()
    NSBezierPath(roundedRect: CGRect(x: gx + gw * 0.5 + gap, y: gy + gh * 0.5 + gap * 0.5,
                                     width: gw * 0.5 - gap, height: gh * 0.5 - gap * 0.5),
                 xRadius: s * 0.026, yRadius: s * 0.026).fill()
    NSBezierPath(roundedRect: CGRect(x: gx + gw * 0.5 + gap, y: gy,
                                     width: gw * 0.5 - gap, height: gh * 0.5 - gap * 0.5),
                 xRadius: s * 0.026, yRadius: s * 0.026).fill()

    // The perch itself.
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: CGRect(x: s * 0.20, y: s * 0.275, width: s * 0.60, height: s * 0.045),
                 xRadius: s * 0.023, yRadius: s * 0.023).fill()

    // A bird, built from a body wedge, a wing, and a head.
    // Tail, then a body that runs up into the head so the bird reads as one shape.
    NSColor.white.setFill()
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: s * 0.360, y: s * 0.420))
    tail.line(to: CGPoint(x: s * 0.165, y: s * 0.545))
    tail.line(to: CGPoint(x: s * 0.235, y: s * 0.345))
    tail.close()
    tail.fill()

    let body = NSBezierPath()
    body.move(to: CGPoint(x: s * 0.300, y: s * 0.330))
    body.curve(to: CGPoint(x: s * 0.655, y: s * 0.430),
               controlPoint1: CGPoint(x: s * 0.420, y: s * 0.318),
               controlPoint2: CGPoint(x: s * 0.610, y: s * 0.340))
    body.curve(to: CGPoint(x: s * 0.430, y: s * 0.520),
               controlPoint1: CGPoint(x: s * 0.640, y: s * 0.520),
               controlPoint2: CGPoint(x: s * 0.530, y: s * 0.545))
    body.curve(to: CGPoint(x: s * 0.300, y: s * 0.330),
               controlPoint1: CGPoint(x: s * 0.340, y: s * 0.500),
               controlPoint2: CGPoint(x: s * 0.288, y: s * 0.415))
    body.close()
    body.fill()

    // Wing cut, tinted with the background so it reads as a fold.
    let wing = NSBezierPath()
    wing.move(to: CGPoint(x: s * 0.345, y: s * 0.372))
    wing.curve(to: CGPoint(x: s * 0.560, y: s * 0.418),
               controlPoint1: CGPoint(x: s * 0.410, y: s * 0.368),
               controlPoint2: CGPoint(x: s * 0.505, y: s * 0.378))
    wing.curve(to: CGPoint(x: s * 0.385, y: s * 0.478),
               controlPoint1: CGPoint(x: s * 0.520, y: s * 0.463),
               controlPoint2: CGPoint(x: s * 0.445, y: s * 0.487))
    wing.close()
    NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.52, alpha: 0.45).setFill()
    wing.fill()

    // Head and beak.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: s * 0.565, y: s * 0.455, width: s * 0.165, height: s * 0.165)).fill()
    let beak = NSBezierPath()
    beak.move(to: CGPoint(x: s * 0.722, y: s * 0.560))
    beak.line(to: CGPoint(x: s * 0.838, y: s * 0.524))
    beak.line(to: CGPoint(x: s * 0.719, y: s * 0.488))
    beak.close()
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 1).setFill()
    beak.fill()

    // Eye.
    NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: s * 0.648, y: s * 0.523, width: s * 0.034, height: s * 0.034)).fill()

    // Legs gripping the bar.
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 1).setStroke()
    let legs = NSBezierPath()
    legs.lineWidth = max(1, s * 0.020)
    legs.lineCapStyle = .round
    legs.move(to: CGPoint(x: s * 0.450, y: s * 0.330))
    legs.line(to: CGPoint(x: s * 0.450, y: s * 0.288))
    legs.move(to: CGPoint(x: s * 0.530, y: s * 0.330))
    legs.line(to: CGPoint(x: s * 0.530, y: s * 0.288))
    legs.stroke()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: out).appendingPathComponent("Perch.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in variants {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconset.appendingPathComponent("\(name).png"))
}

print("icons written to \(iconset.path)")
