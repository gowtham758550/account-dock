// Usage: swift scripts/make-icon.swift <out.icns>
// Draws the AccountDock app icon (three overlapping profile-colour discs on a dark tile)
// at every macOS icon size and packs them into an .icns.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <out.icns>\n".utf8))
    exit(2)
}
let output = CommandLine.arguments[1]

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Draws the icon into the current context, sized for a `s` x `s` pixel canvas.
func draw(_ s: CGFloat) {
    // macOS icon grid: artwork fills ~80% of the canvas, rest is transparent margin.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let radius = tile.width * 0.2237
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    hex(0x1B2433).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [hex(0x2A3550), hex(0x141A28)])!.draw(in: path, angle: -90)

    // Three overlapping discs in the profile palette.
    let d = tile.width * 0.44
    let cx = tile.midX, cy = tile.midY
    let centres = [
        (NSPoint(x: cx - d * 0.30, y: cy + d * 0.20), hex(0x2F6FEB, 0.92)),   // blue
        (NSPoint(x: cx + d * 0.30, y: cy + d * 0.20), hex(0x2EA66A, 0.92)),   // green
        (NSPoint(x: cx,            y: cy - d * 0.32), hex(0xF08A24, 0.92)),   // orange
    ]
    for (c, colour) in centres {
        let r = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let disc = NSBezierPath(ovalIn: r)
        colour.setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        disc.lineWidth = max(1, s * 0.012)
        disc.stroke()
    }
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("appicon-\(UUID().uuidString)")
let set = tmp.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { try png(px).write(to: set.appendingPathComponent("\(name).png")) }

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", output]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output)")
