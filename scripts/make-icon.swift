// Draws the InterLude app icon (a pause between radio waves) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        let ctx = NSGraphicsContext.current!.cgContext
        // macOS icon grid: 824 pt body centred in 1024, with a soft shadow.
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let colours = [NSColor(red: 0.16, green: 0.20, blue: 0.62, alpha: 1).cgColor,
                       NSColor(red: 0.38, green: 0.22, blue: 0.78, alpha: 1).cgColor,
                       NSColor(red: 0.05, green: 0.62, blue: 0.70, alpha: 1).cgColor] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        // Soft top highlight
        let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

        let c = CGPoint(x: 512 * s, y: 512 * s)
        // Pause bars
        ctx.setFillColor(NSColor.white.cgColor)
        for dx in [-52.0, 52.0] {
            let bar = CGRect(x: c.x + CGFloat(dx) * s - 30 * s, y: c.y - 120 * s, width: 60 * s, height: 240 * s)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil)); ctx.fillPath()
        }
        // Waves either side, fading outwards
        ctx.setLineCap(.round)
        for (i, r) in [180.0, 258.0, 336.0].enumerated() {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent([0.95, 0.7, 0.45][i]).cgColor)
            ctx.setLineWidth(40 * s)
            let span = CGFloat.pi / 4.6
            ctx.addArc(center: c, radius: CGFloat(r) * s, startAngle: -span, endAngle: span, clockwise: false); ctx.strokePath()
            ctx.addArc(center: c, radius: CGFloat(r) * s, startAngle: .pi - span, endAngle: .pi + span, clockwise: false); ctx.strokePath()
        }
        ctx.restoreGState()
        return true
    }
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set); try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let img = draw(size: px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.copyItem(at: set.appendingPathComponent("icon_512x512@2x.png"), to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-preview.png"))
print("wrote Resources/AppIcon.icns")
