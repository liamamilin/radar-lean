// Draws assets/AppIcon.icns (radar rings + sweep + a blip). Run: swift scripts/make_icon.swift
import AppKit

func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.08, box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(starting: NSColor(red: 0.05, green: 0.16, blue: 0.20, alpha: 1), ending: NSColor(red: 0.02, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
    bg.addClip()
    let c = CGPoint(x: s / 2, y: s / 2), r = box.width * 0.40
    let green = NSColor(red: 0.20, green: 0.90, blue: 0.62, alpha: 1)
    // sweep wedge
    ctx.saveGState()
    ctx.move(to: c); ctx.addArc(center: c, radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.62, clockwise: false); ctx.closePath()
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [green.withAlphaComponent(0.55).cgColor, green.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: c.x + r * 0.5, y: c.y + r * 0.5), end: CGPoint(x: c.x - r * 0.5, y: c.y + r * 0.6), options: [])
    ctx.restoreGState()
    // rings
    green.withAlphaComponent(0.85).setStroke()
    for k in 1...3 {
        let rr = r * CGFloat(k) / 3
        let p = NSBezierPath(ovalIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)); p.lineWidth = s * 0.012; p.stroke()
    }
    // sweep line
    let l = NSBezierPath(); l.move(to: c); l.line(to: CGPoint(x: c.x + r * cos(.pi * 0.25), y: c.y + r * sin(.pi * 0.25))); l.lineWidth = s * 0.02; l.lineCapStyle = .round; l.stroke()
    // blip
    let b = CGPoint(x: c.x - r * 0.38, y: c.y + r * 0.50), br = s * 0.032
    NSColor(red: 1, green: 0.78, blue: 0.25, alpha: 0.3).setFill()
    NSBezierPath(ovalIn: CGRect(x: b.x - br * 2, y: b.y - br * 2, width: br * 4, height: br * 4)).fill()
    NSColor(red: 1, green: 0.78, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: b.x - br, y: b.y - br, width: br * 2, height: br * 2)).fill()
    NSBezierPath(ovalIn: CGRect(x: c.x - br * 0.8, y: c.y - br * 0.8, width: br * 1.6, height: br * 1.6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "assets"
let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(n).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", out + "/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
