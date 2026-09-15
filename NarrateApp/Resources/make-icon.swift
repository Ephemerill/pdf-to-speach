// Draws the app icon (a warm book with sound waves on the macOS rounded-square) and writes
// the PNG sizes iconutil needs. Run by build.sh: swift make-icon.swift <out.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt rounded square centred on a 1024 canvas, corner radius ≈ 22.4%.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Soft drop shadow behind the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()

    // Background: deep warm gradient (dark plum → ember).
    ctx.saveGState()
    shape.addClip()
    let bg = NSGradient(colors: [NSColor(red: 0.16, green: 0.10, blue: 0.14, alpha: 1),
                                 NSColor(red: 0.44, green: 0.16, blue: 0.14, alpha: 1),
                                 NSColor(red: 0.93, green: 0.48, blue: 0.22, alpha: 1)],
                        atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    bg.draw(in: tile, angle: 60)
    // Subtle glow top-right.
    let glow = NSGradient(colors: [NSColor(red: 1, green: 0.85, blue: 0.55, alpha: 0.45), NSColor.clear])!
    glow.draw(in: NSBezierPath(ovalIn: CGRect(x: 380, y: 420, width: 760, height: 760)), relativeCenterPosition: .zero)
    ctx.restoreGState()

    // Open book: two pages with a gentle curve, in warm ivory.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let ivory = NSColor(red: 0.99, green: 0.95, blue: 0.88, alpha: 1)
    let cx: CGFloat = 512, baseY: CGFloat = 300, topY: CGFloat = 610, halfW: CGFloat = 250
    func page(dir: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: cx, y: baseY))
        p.line(to: CGPoint(x: cx + dir * halfW, y: baseY + 40))
        p.line(to: CGPoint(x: cx + dir * halfW, y: topY + 30))
        p.curve(to: CGPoint(x: cx, y: topY),
                controlPoint1: CGPoint(x: cx + dir * halfW * 0.6, y: topY + 30),
                controlPoint2: CGPoint(x: cx + dir * halfW * 0.25, y: topY - 4))
        p.close()
        return p
    }
    ivory.setFill()
    page(dir: -1).fill(); page(dir: 1).fill()
    ctx.restoreGState()
    // Spine shading and text lines.
    NSColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 0.9).setFill()
    NSBezierPath(rect: CGRect(x: cx - 5, y: baseY + 4, width: 10, height: topY - baseY - 6)).fill()
    NSColor(red: 0.62, green: 0.40, blue: 0.32, alpha: 0.55).setStroke()
    for (i, y) in stride(from: topY - 70, to: baseY + 60, by: -46).enumerated() {
        let l = NSBezierPath(); l.lineWidth = 12; l.lineCapStyle = .round
        let w: CGFloat = i % 3 == 2 ? 120 : 170
        l.move(to: CGPoint(x: cx - 205, y: y)); l.line(to: CGPoint(x: cx - 205 + w, y: y - CGFloat(i) * 1.5)); l.stroke()
        l.removeAllPoints()
        l.move(to: CGPoint(x: cx + 40, y: y)); l.line(to: CGPoint(x: cx + 40 + w, y: y + CGFloat(i) * 1.5)); l.stroke()
    }

    // Sound waves rising from the book, in amber.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: NSColor(red: 1, green: 0.75, blue: 0.35, alpha: 0.7).cgColor)
    NSColor(red: 1, green: 0.86, blue: 0.55, alpha: 1).setStroke()
    for (i, r) in [70.0, 130.0, 190.0].enumerated() {
        let arc = NSBezierPath()
        arc.lineWidth = 26 - CGFloat(i) * 2
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: CGPoint(x: cx, y: topY + 30), radius: r, startAngle: 38, endAngle: 142)
        arc.stroke()
    }
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func png(_ image: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! png(render(px), px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("icon set written to \(outDir)")
