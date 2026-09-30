// Generates the Askara app icon: Resources/AppIcon.icns (and a 1024 px preview PNG).
//
// "Askara" comes from Sanskrit akṣara: "imperishable, that which does not wear away".
// The icon shows that meaning: an infinity sign in soft champagne gold on muted indigo. One strand passes over
// the other at the crossing, so it reads as a single endless ribbon.
//
// Run: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
try? fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: 824 px body centered on the 1024 canvas, with room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x23213F))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep indigo, lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x3B3668), color(0x23213F)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY),
                           options: [])
    // Soft warm glow behind the letter.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xE8C890, 0.14), color(0xE8C890, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 400, options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let gold = CGGradient(colorsSpace: space, colors: [color(0xF3E1BC), color(0xDDBA83), color(0xB88F5A)] as CFArray,
                          locations: [0, 0.55, 1])!

    // Lemniscate of Bernoulli, stretched vertically so the loops are rounder.
    let a: CGFloat = 300, stretch: CGFloat = 1.4, width: CGFloat = 92
    func point(_ t: CGFloat) -> CGPoint {
        let d = 1 + sin(t) * sin(t)
        return CGPoint(x: center.x + a * cos(t) / d, y: center.y + stretch * a * sin(t) * cos(t) / d)
    }
    func curve(from start: CGFloat, to end: CGFloat, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        let steps = 600
        for i in 0...steps {
            let p = point(start + (end - start) * CGFloat(i) / CGFloat(steps))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        if closed { path.closeSubpath() }
        return path
    }
    func fillGold(_ shape: CGPath) {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // Same gradient everywhere, so the over-strand joins the rest without a seam.
        ctx.drawLinearGradient(gold, start: CGPoint(x: 512, y: 700), end: CGPoint(x: 512, y: 324),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    let full = curve(from: 0, to: 2 * .pi, closed: true)
        .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    // The strand that passes over the crossing (the curve crosses itself at t = π/2 and 3π/2).
    let over = curve(from: .pi / 2 - 0.5, to: .pi / 2 + 0.5, closed: false)
    let overBand = over.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 1)

    // Whole ribbon with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0E0C24, 0.45))
    ctx.addPath(full)
    ctx.setFillColor(color(0xCFA873))
    ctx.fillPath()
    ctx.restoreGState()
    fillGold(full)

    // Crossing: a soft shadow cast by the over-strand onto the strand beneath. Limited to a small
    // circle around the crossing so no straight edges show elsewhere on the ribbon.
    let crossing = CGPath(ellipseIn: CGRect(x: center.x - width * 1.1, y: center.y - width * 1.1,
                                            width: width * 2.2, height: width * 2.2), transform: nil)
    ctx.saveGState()
    ctx.addPath(full)
    ctx.clip()
    ctx.addPath(crossing)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 22, color: color(0x3A2A18, 0.5))
    ctx.addPath(overBand)
    ctx.setFillColor(color(0xCFA873))
    ctx.fillPath()
    ctx.restoreGState()
    fillGold(overBand)

    // Soft highlight along the ribbon's centerline for a rounded, metallic look. Skipped where the
    // under-strand passes the crossing, so the highlight follows only the visible strand there.
    func drawShine(_ path: CGPath) {
        let band = path.copy(strokingWithWidth: width * 0.24, lineCap: .round, lineJoin: .round, miterLimit: 1)
        ctx.saveGState()
        ctx.addPath(band)
        ctx.clip()
        let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                                   locations: [0, 1])!
        ctx.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 720), end: CGPoint(x: 512, y: 470), options: [])
        ctx.restoreGState()
    }
    // Loops only (away from the crossing), then the over-strand.
    ctx.saveGState()
    let outside = CGMutablePath()
    outside.addRect(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    outside.addPath(crossing)
    ctx.addPath(outside)
    ctx.clip(using: .evenOdd)
    drawShine(curve(from: 0, to: 2 * .pi, closed: true))
    ctx.restoreGState()
    drawShine(over)

    // Thin highlight along the body's top edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = render()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(image, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(image, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(image, size: 1024, to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
