import AppKit
import SwiftUI

/// The Claude Pool mark: three account segments in a ring around the active dot. Same geometry as
/// the app icon (scripts/make-icon.swift), drawn as a monochrome template so the menu bar tints it.
enum BrandMark {
    @MainActor static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.4, width: CGFloat = 2.6
            let gap = 22.0 + Double(width / radius) * 180 / .pi   // degrees, including the round caps
            NSColor.black.setStroke()
            for index in 0..<3 {
                let middle = 90.0 - Double(index) * 120
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: middle + (120 - gap) / 2, endAngle: middle - (120 - gap) / 2, clockwise: true)
                path.lineWidth = width
                path.lineCapStyle = .round
                path.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Pool"
        return image
    }()
}

/// The app icon at a given size, for About and empty states. Unbundled runs show the menu bar mark.
struct AppIconView: View {
    var size: CGFloat = 48

    var body: some View {
        Group {
            if Bundle.main.bundleURL.pathExtension == "app" {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
            } else {
                Image(nsImage: BrandMark.menuBarImage)
                    .resizable()
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
