import AppKit
import SwiftUI

/// The Claude Pool mascot: a retro pixel crab. Same grid as the app icon (scripts/make-icon.swift).
enum PixelCrab {
    /// `#` body, `e` eye, `.` empty; row 0 is the top.
    static let rows = [
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
    static let columns = 14
    static let height = 10

    /// Body cells as (column, row). Eyes are left out, so they show as holes.
    static let bodyCells: [(column: Int, row: Int)] = rows.enumerated().flatMap { row, line in
        line.enumerated().compactMap { column, mark in mark == "#" ? (column, row) : nil }
    }

    /// Cell rectangles for the crab centred in `rect`, top-left origin.
    static func cellRects(in rect: CGRect) -> [CGRect] {
        let cell = min(rect.width / CGFloat(columns), rect.height / CGFloat(height))
        let originX = rect.midX - cell * CGFloat(columns) / 2
        let originY = rect.midY - cell * CGFloat(height) / 2
        return bodyCells.map {
            CGRect(x: originX + CGFloat($0.column) * cell, y: originY + CGFloat($0.row) * cell, width: cell, height: cell)
        }
    }
}

/// The pixel crab as a SwiftUI shape, with the eyes cut out.
struct PixelCrabShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRects(PixelCrab.cellRects(in: rect))
        return path
    }
}

enum BrandMark {
    /// The crab as a monochrome template so the menu bar tints it.
    @MainActor static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            PixelCrab.cellRects(in: rect.insetBy(dx: 0.5, dy: 2)).forEach { $0.fill() }
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
