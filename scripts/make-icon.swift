// Draws the Claude Pool app icon and writes Resources/AppIcon.icns (plus a 1024 px PNG preview).
// Original artwork: a ring of three account segments around the active dot, on deep indigo.
// Usage: swift scripts/make-icon.swift [output-directory]   (default: Resources)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS-style continuous rounded square (superellipse, n = 5).
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0, a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...360 {
        let t = Double(i) * .pi / 180
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Draws the icon into a 1024 x 1024 coordinate space.
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Apple's grid: an 824 pt body centred on the 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B1130))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Deep indigo, lighter at the top.
    let background = CGGradient(colorsSpace: space, colors: [color(0x2A3A7A), color(0x141B45), color(0x0A0F2C)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft light behind the ring.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x6D8BFF, 0.30), color(0x6D8BFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
    // Thin top highlight along the edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // Three account segments, clockwise from the top, with round caps and even gaps.
    let center = CGPoint(x: 512, y: 512), radius: CGFloat = 238, width: CGFloat = 88
    let segments: [(UInt32, UInt32)] = [(0x5EEAD4, 0x2DD4BF), (0x7DB4FF, 0x4F8DFB), (0xC4A5FF, 0x9B7BF7)]
    let gap = 10.0 * .pi / 180 + Double(width / radius)   // 10° gap after the round caps
    for (index, (light, dark)) in segments.enumerated() {
        let middle = .pi / 2 - Double(index) * 2 * .pi / 3
        let start = middle + (2 * .pi / 3 - gap) / 2
        let end = middle - (2 * .pi / 3 - gap) / 2
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        let stroke = arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: color(dark, 0.55))
        ctx.addPath(stroke)
        ctx.setFillColor(color(dark))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(stroke)
        ctx.clip()
        let mid = (start + end) / 2
        let outer = CGPoint(x: center.x + cos(mid) * (radius + width), y: center.y + sin(mid) * (radius + width))
        let segmentGradient = CGGradient(colorsSpace: space, colors: [color(light), color(dark)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(segmentGradient, start: outer, end: center, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // The active account: a bright dot in the middle.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: color(0xFFFFFF, 0.55))
    ctx.addEllipse(in: CGRect(x: center.x - 64, y: center.y - 64, width: 128, height: 128))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    let dot = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xDCE6FF)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - 64, y: center.y - 64, width: 128, height: 128))
    ctx.clip()
    ctx.drawLinearGradient(dot, start: CGPoint(x: 512, y: 576), end: CGPoint(x: 512, y: 448), options: [])
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outDir.path)/AppIcon.icns and AppIcon-1024.png")
