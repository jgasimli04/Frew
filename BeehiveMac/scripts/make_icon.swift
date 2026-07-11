#!/usr/bin/env swift
// make_icon.swift — renders the BeeDeck app icon and packs Resources/BeeDeck.icns.
// The artwork is the app itself in miniature: the honey hexagon (beehive) with
// the two-strand helix weaving through it and the white playhead bead at a
// crossing, glowing on near-black like the stage.
//
//   cd BeehiveMac && swift scripts/make_icon.swift
//
// Rerun after changing the drawing; the .icns is committed so normal builds
// don't need this script. Intermediate PNGs land in dist/BeeDeck.iconset
// (gitignored) so the per-size renders can be eyeballed.
import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = Double(px)
    // Apple icon grid: artwork inset from the canvas, transparent margin around
    let pad = 0.088 * s
    let plateRect = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let plate = NSBezierPath(roundedRect: plateRect,
                             xRadius: 0.185 * s, yRadius: 0.185 * s)
    NSGradient(colors: [rgb(0x1c1d24), rgb(0x0a0a0e)])!.draw(in: plate, angle: -90)
    plate.addClip()   // everything after stays on the plate

    let c = NSPoint(x: s / 2, y: s / 2)

    // honey hexagon, pointy-top
    let R = 0.30 * s
    let hex = NSBezierPath()
    for k in 0..<6 {
        let a = Double(k) * .pi / 3 + .pi / 2
        let p = NSPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))
        if k == 0 { hex.move(to: p) } else { hex.line(to: p) }
    }
    hex.close()
    hex.lineWidth = max(0.052 * s, 1)
    hex.lineJoinStyle = .round
    rgb(0xf6b136, 0.10).setFill(); hex.fill()
    rgb(0xf6b136).setStroke(); hex.stroke()

    // two helix strands weaving through the hexagon, with glow
    let x0 = pad + 0.02 * s, x1 = s - pad - 0.02 * s
    func strand(phase: Double, color: NSColor) {
        let path = NSBezierPath()
        let amp = 0.115 * s, cycles = 1.5, nSeg = 72
        for i in 0...nSeg {
            let t = Double(i) / Double(nSeg)
            let p = NSPoint(x: x0 + (x1 - x0) * t,
                            y: c.y + amp * sin(cycles * 2 * .pi * t + phase))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineWidth = max(0.034 * s, 1)
        path.lineCapStyle = .round
        NSGraphicsContext.current?.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.85)
        glow.shadowBlurRadius = 0.045 * s
        glow.set()
        color.setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    strand(phase: 0, color: rgb(0x5fe0ff))     // cyan
    strand(phase: .pi, color: rgb(0xff8bd8))   // magenta

    // playhead bead at a strand crossing (t = 2/3 → sin() = 0 for both)
    let bead = 0.05 * s
    let bx = x0 + (x1 - x0) * 2 / 3
    let beadPath = NSBezierPath(ovalIn: NSRect(x: bx - bead, y: c.y - bead,
                                               width: 2 * bead, height: 2 * bead))
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.9)
    glow.shadowBlurRadius = 0.05 * s
    glow.set()
    NSColor.white.setFill()
    beadPath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    return rep
}

// render the set, pack the icns
let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let setDir = cwd.appendingPathComponent("dist/BeeDeck.iconset")
let outDir = cwd.appendingPathComponent("Resources")
try? fm.removeItem(at: setDir)
try fm.createDirectory(at: setDir, withIntermediateDirectories: true)
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
for (name, px) in sizes {
    let rep = draw(px: px)
    try rep.representation(using: .png, properties: [:])!
        .write(to: setDir.appendingPathComponent("\(name).png"))
}
let icns = outDir.appendingPathComponent("BeeDeck.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", setDir.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path)")
