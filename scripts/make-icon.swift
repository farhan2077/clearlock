#!/usr/bin/env swift
// Renders the app icon into Clearlock/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Clearlock/Resources/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824 pt squircle centred in a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night sky gradient.
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.33, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.13, alpha: 1)])!.draw(in: shape, angle: -90)

    // Warm "awake" glow behind the lock.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let glowCenter = NSPoint(x: 512 * s, y: 512 * s)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 0.95),
                        NSColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 0.35),
                        NSColor(red: 1.0, green: 0.4, blue: 0.1, alpha: 0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 360 * s, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Lock glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 430 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = lock.size
        lock.draw(in: NSRect(x: 512 * s - size.width / 2, y: 512 * s - size.height / 2, width: size.width, height: size.height))
    }

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(output.path)")
