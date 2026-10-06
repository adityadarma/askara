// Generates the Askara app icon: Resources/AppIcon.icns (and a 1024 px preview PNG).
//
// "Askara" means a ray of light. The icon is a sun rising over still water, drawn like a
// hand-cut paper print: edges wobble slightly, rays differ in length and angle, the horizon and
// ripples taper like brush strokes, and a faint grain sits on the ground. Every "imperfection"
// comes from a fixed seed, so the output is identical on every run.
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

// Muted earth palette: dusk olive ground, a pale ochre sun, sand-colored rays, bone horizon.
let paperTop: UInt32 = 0x535A4B
let paperBottom: UInt32 = 0x40463A
let sunColor: UInt32 = 0xD6B36F
let rayColor: UInt32 = 0xB9A27A
let ink: UInt32 = 0xE6DDC8

/// Small deterministic PRNG so the hand-made jitter is stable between runs.
struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

/// A circle whose radius drifts a little, like a shape cut out with scissors.
func wobblyCircle(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let r = radius * (1 + 0.012 * sin(3 * t + 0.7) + 0.008 * sin(5 * t + 2.1) + 0.004 * sin(11 * t))
        let p = CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// A ray: wide at the base, narrowing to a rounded tip, with a slight bend along its length.
func ray(from base: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, bend: CGFloat) -> CGPath {
    let dir = CGPoint(x: cos(angle), y: sin(angle))
    let normal = CGPoint(x: -dir.y, y: dir.x)
    let tip = CGPoint(x: base.x + dir.x * length, y: base.y + dir.y * length)
    let mid = CGPoint(x: base.x + dir.x * length * 0.5 + normal.x * bend,
                      y: base.y + dir.y * length * 0.5 + normal.y * bend)
    let baseHalf = width / 2, tipHalf = width * 0.22
    func offset(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + normal.x * d, y: p.y + normal.y * d) }

    let path = CGMutablePath()
    path.move(to: offset(base, baseHalf))
    path.addQuadCurve(to: offset(tip, tipHalf), control: offset(mid, baseHalf * 0.62))
    path.addArc(center: tip, radius: tipHalf, startAngle: angle + .pi / 2, endAngle: angle - .pi / 2,
                clockwise: true)
    path.addQuadCurve(to: offset(base, -baseHalf), control: offset(mid, -baseHalf * 0.62))
    path.closeSubpath()
    return path
}

/// A horizontal brush stroke: thickest in the middle, tapering at both ends, with a gentle wave.
func brushStroke(fromX x0: CGFloat, toX x1: CGFloat, y: CGFloat, thickness: CGFloat, phase: CGFloat) -> CGPath {
    let steps = 200
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = x0 + (x1 - x0) * t
        let half = thickness / 2 * pow(sin(.pi * t), 0.45) * (1 + 0.06 * sin(7 * t + phase))
        let cy = y + 3.5 * sin(2.3 * .pi * t + phase)
        top.append(CGPoint(x: x, y: cy + half))
        bottom.append(CGPoint(x: x, y: cy - half * 0.85))
    }
    let path = CGMutablePath()
    path.addLines(between: top + bottom.reversed())
    path.closeSubpath()
    return path
}

func render() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: 824 px body centered on the 1024 canvas, with room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(color(paperBottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Warm paper.
    let paper = CGGradient(colorsSpace: space, colors: [color(paperTop), color(paperBottom)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY),
                           options: [])

    var rng = Seeded(state: 0xA5CA_2A)
    let horizonY: CGFloat = 404
    let sunCenter = CGPoint(x: 512, y: horizonY)
    let sunRadius: CGFloat = 168

    // Rays fan out above the horizon; lengths alternate long/short with a little jitter.
    let rayCount = 9
    for i in 0..<rayCount {
        let t = CGFloat(i) / CGFloat(rayCount - 1)
        let angle = (.pi * (0.06 + 0.88 * t)) + rng.range(-0.025, 0.025)
        let long = i % 2 == 0
        let length = (long ? 150 : 96) + rng.range(-12, 12)
        let start = sunRadius + 34 + rng.range(-5, 5)
        let base = CGPoint(x: sunCenter.x + cos(angle) * start, y: sunCenter.y + sin(angle) * start)
        let path = ray(from: base, angle: angle, length: length, width: long ? 50 : 40, bend: rng.range(-7, 7))
        ctx.addPath(path)
        ctx.setFillColor(color(rayColor))
        ctx.fillPath()
    }

    // Sun: only the half above the horizon is visible.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: horizonY, width: canvas, height: canvas))
    ctx.addPath(wobblyCircle(center: sunCenter, radius: sunRadius))
    ctx.setFillColor(color(sunColor))
    ctx.fillPath()
    ctx.restoreGState()

    // Horizon and reflections on the water, each a little shorter and offset like real brush marks.
    ctx.setFillColor(color(ink))
    ctx.addPath(brushStroke(fromX: 236, toX: 788, y: horizonY - 4, thickness: 30, phase: 0.4))
    ctx.fillPath()
    ctx.setFillColor(color(sunColor, 0.9))
    ctx.addPath(brushStroke(fromX: 372, toX: 664, y: horizonY - 74, thickness: 24, phase: 1.9))
    ctx.fillPath()
    ctx.setFillColor(color(sunColor, 0.65))
    ctx.addPath(brushStroke(fromX: 444, toX: 592, y: horizonY - 134, thickness: 20, phase: 3.1))
    ctx.fillPath()

    // Paper grain: sparse light and dark specks.
    for _ in 0..<5200 {
        let x = rng.range(body.minX, body.maxX), y = rng.range(body.minY, body.maxY)
        let dark = rng.next() < 0.55
        ctx.setFillColor(color(dark ? 0x5A4630 : 0xFFFFFF, rng.range(0.03, 0.08)))
        let s = rng.range(1.2, 2.6)
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
    }

    // Hairline edge so the light body separates from light wallpapers.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x000000, 0.08))
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
