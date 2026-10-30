#!/usr/bin/env swift
// Draws the app icon — two overlapping agents — into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // macOS icon grid: an 824pt rounded square centered on a 1024pt canvas.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.18, green: 0.19, blue: 0.25, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: tile, angle: -90)

    let r = 196 * s, dx = 116 * s, c = 512 * s
    let claude = NSBezierPath(ovalIn: NSRect(x: c - dx - r, y: c - r, width: 2 * r, height: 2 * r))
    let codex = NSBezierPath(ovalIn: NSRect(x: c + dx - r, y: c - r, width: 2 * r, height: 2 * r))
    NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
    claude.fill()
    NSColor(red: 0.31, green: 0.48, blue: 0.98, alpha: 1).setFill()
    codex.fill()
    claude.addClip()  // where they overlap: one place for both
    NSColor.white.setFill()
    codex.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(out.path)")
