import AppKit
import SwiftUI

// One set of tokens for every screen: spacing, radius, type and surface colours.
// Views use these instead of literal values so containers line up across pages.

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    /// Cards. Content sits `Space.md` inside, so nested shapes use `Radius.inner`.
    static let card: CGFloat = 12
    static let inner: CGFloat = 6
}

enum Metrics {
    /// Every page shares this content width, so containers line up between screens.
    static let pageMaxWidth: CGFloat = 880
    static let minHitTarget: CGFloat = 24
    static let menuWidth: CGFloat = 340
}

extension Font {
    static let pageTitle = Font.title2.weight(.semibold)
    static let sectionTitle = Font.headline
    static let rowTitle = Font.body
    static let rowDetail = Font.callout
    static let meta = Font.caption
    static let metricLarge = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    static let metric = Font.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()
}

extension Color {
    /// Card surface: white on the light window background, a faint lift in dark mode.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.white
    })
    static let cardStroke = Color(nsColor: .separatorColor)
    static let statusOK = Color.green
    static let statusWarn = Color.orange
    static let statusFail = Color.red

    /// "#RRGGBB" → Color; falls back to gray.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Relative luminance (WCAG) of a "#RRGGBB" colour, for choosing legible text on it.
    static func luminance(hex: String) -> Double {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return 0.5 }
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

// MARK: - Containers

/// The one page container: scrolls, caps content at `Metrics.pageMaxWidth`, consistent insets.
struct Page<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header
                content
            }
            .frame(maxWidth: Metrics.pageMaxWidth, alignment: .leading)
            .padding(Space.lg)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Standard page header: title, one line of context, trailing actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.md)
            actions
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The one card surface. Optional title row with a trailing accessory.
struct Card<Accessory: View, Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    if let title {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.sectionTitle).accessibilityAddTraits(.isHeader)
                            if let subtitle {
                                Text(subtitle).font(.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: Space.xs)
                    accessory
                }
            }
            content
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 0.5)
        )
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Label and description on the leading edge, the control on the trailing edge.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rowTitle)
                if let detail {
                    Text(detail)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.md)
            control
        }
        .accessibilityElement(children: .contain)
    }
}

/// Two-column fact row: label leading, value trailing.
struct FactRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: Space.md)
            value.multilineTextAlignment(.trailing)
        }
        .font(.rowDetail)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small components

/// Coloured circle with the profile's initial. Decorative: the name is always shown beside it.
struct ProfileAvatar: View {
    let name: String
    let colorHex: String
    var size: CGFloat = 24

    var body: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        Circle()
            .fill(Color(hex: colorHex).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    // Dark initial on light swatches (yellow, teal), white on the rest.
                    .foregroundStyle(Color.luminance(hex: colorHex) > 0.45 ? Color.black.opacity(0.75) : Color.white)
            )
            .accessibilityHidden(true)
    }
}

/// Icon + text capsule. Meaning never rests on the tint alone.
struct StatusBadge: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.meta.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// A path shown in one line with the full value always reachable (tooltip and selection).
struct PathText: View {
    let path: String
    let paths: Paths
    var font: Font = .meta

    var body: some View {
        Text(paths.abbreviate(path))
            .font(font.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
            .accessibilityLabel("Directory \(path)")
    }
}

enum MessageKind {
    case info, warning, error

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .statusWarn
        case .error: .statusFail
        }
    }
}

/// Inline message: icon + text (+ optional action, + optional dismiss).
struct InlineMessage<Action: View>: View {
    var kind: MessageKind = .warning
    let text: String
    var onDismiss: (() -> Void)?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.rowDetail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            action
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss message")
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension InlineMessage where Action == EmptyView {
    init(kind: MessageKind = .warning, text: String, onDismiss: (() -> Void)? = nil) {
        self.init(kind: kind, text: text, onDismiss: onDismiss) { EmptyView() }
    }
}

/// Colour picker made of preset swatches, each a 24pt target.
struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(ProfileColor.presets) { color in
                let selected = selection == color.hex
                Button { selection = color.hex } label: {
                    Circle()
                        .fill(Color(hex: color.hex))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .frame(width: Metrics.minHitTarget + 2, height: Metrics.minHitTarget + 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Shared layout for sheets: title, optional subtitle, content, trailing buttons.
struct SheetScaffold<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(Space.lg)
            Divider()
            HStack(spacing: Space.xs) {
                Spacer()
                buttons
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .frame(width: width)
    }
}

// MARK: - Panels

@MainActor
enum Panels {
    static func chooseDirectory(startingAt path: String?, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let path { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExecutable(startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use This Binary"
        if let path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Shown wherever Claude Code is required but was not found.
struct MissingBinaryBanner: View {
    var body: some View {
        InlineMessage(kind: .error, text: "Claude Code wasn't found. Install it, or set its path in Settings › Claude Code.")
    }
}
