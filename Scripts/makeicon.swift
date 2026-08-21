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

    let ink = NSColor.white                                   // the bird and the perch
    let ground = NSColor(calibratedWhite: 0.07, alpha: 1)     // the squircle

    // Squircle, near-black with just enough gradient to avoid looking flat.
    let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.055, dy: s * 0.055),
                                xRadius: s * 0.225, yRadius: s * 0.225)
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(calibratedWhite: 0.13, alpha: 1), ground])!.draw(in: rect, angle: -90)

    // Window tiles, kept very faint — a texture, not a second subject.
    ink.withAlphaComponent(0.11).setFill()
    let gx = s * 0.255, gy = s * 0.585, gw = s * 0.49, gh = s * 0.195, gap = s * 0.024
    NSBezierPath(roundedRect: CGRect(x: gx, y: gy, width: gw * 0.5 - gap, height: gh),
                 xRadius: s * 0.022, yRadius: s * 0.022).fill()
    NSBezierPath(roundedRect: CGRect(x: gx + gw * 0.5 + gap, y: gy + gh * 0.5 + gap * 0.5,
                                     width: gw * 0.5 - gap, height: gh * 0.5 - gap * 0.5),
                 xRadius: s * 0.022, yRadius: s * 0.022).fill()
    NSBezierPath(roundedRect: CGRect(x: gx + gw * 0.5 + gap, y: gy,
                                     width: gw * 0.5 - gap, height: gh * 0.5 - gap * 0.5),
                 xRadius: s * 0.022, yRadius: s * 0.022).fill()

    // The perch.
    ink.setFill()
    NSBezierPath(roundedRect: CGRect(x: s * 0.195, y: s * 0.268, width: s * 0.61, height: s * 0.040),
                 xRadius: s * 0.020, yRadius: s * 0.020).fill()

    // Legs, drawn before the body so the body caps them cleanly.
    let legs = NSBezierPath()
    legs.lineWidth = s * 0.022
    legs.lineCapStyle = .round
    legs.move(to: CGPoint(x: s * 0.452, y: s * 0.395))
    legs.line(to: CGPoint(x: s * 0.452, y: s * 0.300))
    legs.move(to: CGPoint(x: s * 0.532, y: s * 0.395))
    legs.line(to: CGPoint(x: s * 0.532, y: s * 0.300))
    ink.setStroke()
    legs.stroke()

    // One continuous silhouette: tail, body, head, beak.
    let bird = NSBezierPath()
    bird.move(to: CGPoint(x: s * 0.180, y: s * 0.560))                 // tail tip
    bird.line(to: CGPoint(x: s * 0.372, y: s * 0.432))
    bird.curve(to: CGPoint(x: s * 0.575, y: s * 0.398),                // underside
               controlPoint1: CGPoint(x: s * 0.330, y: s * 0.372),
               controlPoint2: CGPoint(x: s * 0.462, y: s * 0.358))
    bird.curve(to: CGPoint(x: s * 0.688, y: s * 0.470),                // breast up into head
               controlPoint1: CGPoint(x: s * 0.652, y: s * 0.410),
               controlPoint2: CGPoint(x: s * 0.688, y: s * 0.424))
    bird.line(to: CGPoint(x: s * 0.836, y: s * 0.512))                 // beak
    bird.line(to: CGPoint(x: s * 0.690, y: s * 0.556))
    bird.curve(to: CGPoint(x: s * 0.500, y: s * 0.548),                // crown
               controlPoint1: CGPoint(x: s * 0.676, y: s * 0.636),
               controlPoint2: CGPoint(x: s * 0.566, y: s * 0.612))
    bird.curve(to: CGPoint(x: s * 0.180, y: s * 0.560),                // back into the tail
               controlPoint1: CGPoint(x: s * 0.404, y: s * 0.492),
               controlPoint2: CGPoint(x: s * 0.300, y: s * 0.520))
    bird.close()
    ink.setFill()
    bird.fill()

    // Eye punched out of the silhouette in the background colour.
    ground.setFill()
    NSBezierPath(ovalIn: CGRect(x: s * 0.648, y: s * 0.492, width: s * 0.042, height: s * 0.042)).fill()

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
