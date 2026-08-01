// Renders the EchoScribe app icon at every AppIcon size straight into
// Assets.xcassets/AppIcon.appiconset (PNGs + Contents.json).
// Regenerate from macos-native/ with:  swift Packaging/IconGen.swift
// Pure AppKit so it has no dependencies beyond the macOS toolchain.
//
// Composition (authored on a 1024pt grid, scaled per size):
//   • macOS-style rounded plate, deep indigo→navy gradient, soft drop shadow
//   • white speech bubble with a tail (the "scribe")
//   • blue→violet waveform bars inside the bubble (the "echo")
import AppKit

let iconsetDir = "Assets.xcassets/AppIcon.appiconset"

func render(pixels: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not create bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let side = pixels
    let s = side / 1024.0

    // Rounded plate with shadow (Apple's Big Sur icon grid: ~852pt plate on 1024).
    let inset = 86 * s
    let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 196 * s, yRadius: 196 * s)
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 48 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    platePath.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let plateTop = NSColor(srgbRed: 0.18, green: 0.25, blue: 0.64, alpha: 1)
    let plateBottom = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.24, alpha: 1)
    NSGradient(colors: [plateTop, plateBottom])!.draw(in: platePath, angle: -90)

    // Soft cyan glow behind the bubble so the plate doesn't read flat.
    ctx.saveGState()
    platePath.addClip()
    let glowColors = [NSColor(srgbRed: 0.25, green: 0.75, blue: 1.0, alpha: 0.30),
                      NSColor(srgbRed: 0.25, green: 0.75, blue: 1.0, alpha: 0.0)]
    NSGradient(colors: glowColors)!.draw(
        fromCenter: NSPoint(x: side / 2, y: side * 0.55), radius: 0,
        toCenter: NSPoint(x: side / 2, y: side * 0.55), radius: 420 * s, options: [])
    // Glassy sheen across the top of the plate.
    let sheen = [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0.0)]
    NSGradient(colors: sheen)!.draw(
        in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
        angle: -90)
    ctx.restoreGState()

    // Speech bubble (rounded rect + tail as one filled path), slightly above center.
    let bw = 640 * s, bh = 460 * s
    let bx = (side - bw) / 2
    let by = (side - bh) / 2 + 40 * s
    let bubble = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh),
                              xRadius: 120 * s, yRadius: 120 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bx + 130 * s, y: by + 30 * s))
    tail.curve(to: NSPoint(x: bx + 60 * s, y: by - 100 * s),
               controlPoint1: NSPoint(x: bx + 120 * s, y: by - 30 * s),
               controlPoint2: NSPoint(x: bx + 95 * s, y: by - 75 * s))
    tail.curve(to: NSPoint(x: bx + 250 * s, y: by + 10 * s),
               controlPoint1: NSPoint(x: bx + 140 * s, y: by - 60 * s),
               controlPoint2: NSPoint(x: bx + 205 * s, y: by - 15 * s))
    tail.close()
    bubble.append(tail)

    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s,
                  color: NSColor.black.withAlphaComponent(0.30).cgColor)
    NSColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 1).setFill()
    bubble.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Waveform bars, vertically centered in the bubble, filled with one
    // horizontal blue→violet gradient across the group.
    let heights: [CGFloat] = [150, 260, 360, 260, 150]
    let barW = 58 * s, gap = 46 * s
    let groupW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (side - groupW) / 2
    let midY = by + bh / 2
    let bars = NSBezierPath()
    for h in heights {
        let hh = h * s
        bars.append(NSBezierPath(roundedRect:
            NSRect(x: x, y: midY - hh / 2, width: barW, height: hh),
            xRadius: barW / 2, yRadius: barW / 2))
        x += barW + gap
    }
    ctx.saveGState()
    bars.addClip()
    let barLeft = NSColor(srgbRed: 0.16, green: 0.50, blue: 0.98, alpha: 1)
    let barRight = NSColor(srgbRed: 0.52, green: 0.28, blue: 0.96, alpha: 1)
    NSGradient(colors: [barLeft, barRight])!.draw(
        in: NSRect(x: (side - groupW) / 2, y: midY - 200 * s, width: groupW, height: 400 * s),
        angle: 0)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// (point size, scale) pairs required by a macOS AppIcon set.
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    let rep = render(pixels: CGFloat(pt * scale))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed for \(name)")
    }
    try data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "scale": "\(scale)x", "filename": name])
    print("wrote \(iconsetDir)/\(name)")
}

let contents: [String: Any] = ["images": images,
                               "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(iconsetDir)/Contents.json"))
print("wrote \(iconsetDir)/Contents.json")
