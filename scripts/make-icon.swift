// Draws the Claude Pool app icon and writes Resources/AppIcon.icns (plus a 1024 px PNG preview).
// Original artwork: a retro pixel crab floating in a swim ring, in pool water with rising bubbles.
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

/// The mascot: a retro pixel crab. Keep in sync with `PixelCrab.rows` in Sources/Views/BrandMark.swift.
/// `#` body, `e` eye, `.` empty.
let crab = [
    "#.#........#.#",
    "###........###",
    ".#..........#.",
    ".############.",
    ".###e####e###.",
    ".###e####e###.",
    ".############.",
    ".############.",
    "..#.#....#.#..",
    "..#.#....#.#..",
]

/// Draws the icon into a 1024 x 1024 coordinate space.
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Apple's grid: an 824 pt body centred on the 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B3A66))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Pool water, lighter at the top.
    let background = CGGradient(colorsSpace: space, colors: [color(0x4CCBE6), color(0x1A86C4), color(0x0B4785)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // From here on, draw top-down on a pixel grid.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let cell: CGFloat = 44
    func pixel(_ x: CGFloat, _ y: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1, w: CGFloat = 1, h: CGFloat = 1) {
        ctx.setFillColor(color(hex, alpha))
        ctx.fill(CGRect(x: x, y: y, width: cell * w, height: cell * h))
    }

    // Pool tiles: faint grout lines.
    ctx.setFillColor(color(0xFFFFFF, 0.07))
    for i in stride(from: 100 as CGFloat, through: 924, by: cell * 2) {
        ctx.fill(CGRect(x: i, y: 100, width: 4, height: 824))
        ctx.fill(CGRect(x: 100, y: i, width: 824, height: 4))
    }

    // The crab, Claude orange with a lit top row and a shaded bottom row.
    let originX: CGFloat = 512 - cell * 7, originY: CGFloat = 292
    for (row, line) in crab.enumerated() {
        for (col, mark) in line.enumerated() {
            let x = originX + CGFloat(col) * cell, y = originY + CGFloat(row) * cell
            switch mark {
            case "#":
                let hex: UInt32 = row == 3 || row <= 1 ? 0xEE936F : (row == 7 || row >= 8 ? 0xB65A3C : 0xD97757)
                pixel(x, y, hex)
            case "e":
                pixel(x, y, 0x1A1410)
            default: break
            }
        }
    }
    // Eye shine.
    for col in [4, 9] { pixel(originX + CGFloat(col) * cell + cell * 0.5, originY + 4 * cell, 0xFFFFFF, 0.9, w: 0.5, h: 0.5) }

    // Swim ring around the belly: red and white stripes, one cell wider than the body on each side.
    let ringY = originY + 6 * cell
    for col in -1...14 {
        let stripe: UInt32 = ((col + 1) / 2) % 2 == 0 ? 0xF4F1EA : 0xE5484D
        pixel(originX + CGFloat(col) * cell, ringY, stripe, h: 2)
    }
    pixel(originX - cell, ringY, 0xFFFFFF, 0.35, w: 16, h: 0.25)

    // Water surface: gentle stepped waves over the lower ring and legs, with a foam crest.
    let waterTop = ringY + cell
    for i in 0..<20 {
        let x = 100 + CGFloat(i) * cell
        let top = waterTop + [0, 0, -0.25, -0.25, 0, 0, 0.25, 0.25][i % 8] * cell
        pixel(x, top, 0x0A4F8C, 0.5, h: (924 - top) / cell)
        pixel(x, top, 0xFFFFFF, 0.9, h: 0.22)
    }
    // Ripples below the surface.
    for (col, row) in [(0, 2.0), (1, 2.0), (12, 2.5), (13, 2.5), (6, 4.0), (7, 4.0), (8, 4.0)] as [(Int, CGFloat)] {
        pixel(originX + CGFloat(col) * cell, waterTop + row * cell, 0xFFFFFF, 0.28, h: 0.22)
    }

    // Bubbles rising from the pool: one per account in the pool.
    for (x, y, size) in [(800.0, 236.0, 0.75), (848.0, 330.0, 0.5), (744.0, 168.0, 0.5)] as [(CGFloat, CGFloat, CGFloat)] {
        pixel(x, y, 0xFFFFFF, 0.75, w: size, h: size)
    }
    ctx.restoreGState()

    // Thin highlight along the edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(6)
    ctx.strokePath()
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
