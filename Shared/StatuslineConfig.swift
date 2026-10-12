import Foundation

/// What a status line component shows. Every kind maps to a field Claude Code sends to status line
/// commands (or to Claude Pool's own per-profile context), so nothing here is estimated.
public enum StatuslineWidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case model
    case account
    case plan
    case profile
    case cwd
    case gitBranch
    case gitStatus
    case contextPercent
    case contextTokens
    case tokensInOut
    case cacheTokens
    case sessionCost
    case sessionDuration
    case linesChanged
    case sessionName
    case fiveHourUsage
    case sevenDayUsage
    case fiveHourReset
    case sevenDayReset
    case effort
    case vimMode
    case outputStyle
    case version
    case originalStatusLine
    case customText
    case separator
    case flexSpacer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .model: "Model"
        case .account: "Account"
        case .plan: "Plan"
        case .profile: "Profile"
        case .cwd: "Working directory"
        case .gitBranch: "Git branch"
        case .gitStatus: "Git status"
        case .contextPercent: "Context used %"
        case .contextTokens: "Context tokens"
        case .tokensInOut: "Last request in/out"
        case .cacheTokens: "Last request cache"
        case .sessionCost: "Session cost"
        case .sessionDuration: "Session duration"
        case .linesChanged: "Lines changed"
        case .sessionName: "Session name"
        case .fiveHourUsage: "5-hour usage"
        case .sevenDayUsage: "7-day usage"
        case .fiveHourReset: "5-hour reset"
        case .sevenDayReset: "7-day reset"
        case .effort: "Effort"
        case .vimMode: "Vim mode"
        case .outputStyle: "Output style"
        case .version: "Claude Code version"
        case .originalStatusLine: "Original status line"
        case .customText: "Custom text"
        case .separator: "Separator"
        case .flexSpacer: "Flexible space"
        }
    }

    /// Short label printed before the value when "Show label" is on.
    public var label: String {
        switch self {
        case .model: "Model"
        case .account: "Account"
        case .plan: "Plan"
        case .profile: "Profile"
        case .cwd: "cwd"
        case .gitBranch: "⎇"
        case .gitStatus: "git"
        case .contextPercent, .contextTokens: "Ctx"
        case .tokensInOut: "Tok"
        case .cacheTokens: "Cache"
        case .sessionCost: "Cost"
        case .sessionDuration: "Time"
        case .linesChanged: "Lines"
        case .sessionName: "Session"
        case .fiveHourUsage: "5h"
        case .sevenDayUsage: "7d"
        case .fiveHourReset: "5h reset"
        case .sevenDayReset: "7d reset"
        case .effort: "Effort"
        case .vimMode: "Vim"
        case .outputStyle: "Style"
        case .version: "v"
        case .originalStatusLine, .customText, .separator, .flexSpacer: ""
        }
    }

    public var detail: String {
        switch self {
        case .model: "Model display name from Claude Code."
        case .account: "Signed-in email of this profile (from Claude Pool)."
        case .plan: "Subscription plan of this profile, e.g. Max 20x (from Claude Pool)."
        case .profile: "Claude Pool profile name."
        case .cwd: "Current working directory (last folder name)."
        case .gitBranch: "Current branch; hidden outside a repository."
        case .gitStatus: "Staged, modified, untracked, ahead/behind counts; hidden outside a repository."
        case .contextPercent: "Share of the context window in use."
        case .contextTokens: "Tokens currently in the context window."
        case .tokensInOut: "Input and output tokens of the most recent request."
        case .cacheTokens: "Cache read and write tokens of the most recent request."
        case .sessionCost: "Session cost in USD as calculated by Claude Code."
        case .sessionDuration: "Wall-clock time since the session started."
        case .linesChanged: "Lines added and removed this session."
        case .sessionName: "Session name, when set."
        case .fiveHourUsage: "5-hour subscription window used %, as reported by Claude Code."
        case .sevenDayUsage: "7-day subscription window used %, as reported by Claude Code."
        case .fiveHourReset: "Time until the 5-hour window resets."
        case .sevenDayReset: "Time until the 7-day window resets."
        case .effort: "Reasoning effort level, when the model supports it."
        case .vimMode: "Vim mode, when vim mode is on."
        case .outputStyle: "Active output style."
        case .version: "Claude Code version."
        case .originalStatusLine: "First line of the status line command you had before Claude Pool (if any)."
        case .customText: "Any text you type."
        case .separator: "A separator character between components."
        case .flexSpacer: "Pushes the following components to the right edge (needs the terminal width)."
        }
    }

    /// Palette groups shown in the editor.
    public var group: String {
        switch self {
        case .model, .effort, .vimMode, .outputStyle, .version: "Session"
        case .account, .plan, .profile: "Account"
        case .cwd, .gitBranch, .gitStatus: "Location"
        case .contextPercent, .contextTokens, .tokensInOut, .cacheTokens: "Tokens & context"
        case .sessionCost, .sessionDuration, .linesChanged, .sessionName: "Session"
        case .fiveHourUsage, .sevenDayUsage, .fiveHourReset, .sevenDayReset: "Usage windows"
        case .originalStatusLine, .customText, .separator, .flexSpacer: "Layout & text"
        }
    }

    /// Theme slot that colours this kind by default.
    public var role: StatuslineRole {
        switch self {
        case .model, .effort, .outputStyle, .version, .vimMode: .model
        case .account, .plan, .profile: .identity
        case .cwd: .location
        case .gitBranch, .gitStatus: .git
        case .contextPercent, .contextTokens, .tokensInOut, .cacheTokens: .context
        case .sessionCost, .sessionDuration, .linesChanged, .sessionName: .session
        case .fiveHourUsage, .sevenDayUsage, .fiveHourReset, .sevenDayReset: .usage
        case .originalStatusLine, .customText, .separator, .flexSpacer: .text
        }
    }

    /// Kinds whose look is not themed per segment.
    public var isLayout: Bool { self == .separator || self == .flexSpacer }
}

public enum StatuslineRole: String, Codable, CaseIterable, Sendable {
    case model, identity, location, git, context, session, usage, text
}

/// A colour: one of the 16 ANSI names, or `#RRGGBB`. `nil` in a widget means "use the theme".
public struct StatuslineColor: Codable, Hashable, Sendable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    /// Standard xterm RGB for the 16 names (also used for the preview).
    public static let ansiRGB: [String: (Int, Int, Int)] = [
        "black": (0, 0, 0), "red": (205, 49, 49), "green": (13, 188, 121), "yellow": (229, 229, 16),
        "blue": (36, 114, 200), "magenta": (188, 63, 188), "cyan": (17, 168, 205), "white": (229, 229, 229),
        "brightBlack": (118, 118, 118), "brightRed": (241, 76, 76), "brightGreen": (35, 209, 139), "brightYellow": (245, 245, 67),
        "brightBlue": (59, 142, 234), "brightMagenta": (214, 112, 214), "brightCyan": (41, 184, 219), "brightWhite": (255, 255, 255),
    ]

    public var ansiIndex: Int? { Self.ansiNames.firstIndex(of: rawValue) }

    /// RGB components, or nil if the value is not understood.
    public var rgb: (Int, Int, Int)? {
        if let named = Self.ansiRGB[rawValue] { return named }
        let hex = rawValue.hasPrefix("#") ? String(rawValue.dropFirst()) : (rawValue.hasPrefix("hex:") ? String(rawValue.dropFirst(4)) : "")
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    public var isValid: Bool { rgb != nil }
}

/// One component on a status line.
public struct StatuslineWidget: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: StatuslineWidgetKind
    public var foreground: StatuslineColor?
    public var background: StatuslineColor?
    public var bold: Bool
    public var showLabel: Bool
    /// Text for `customText`, the character for `separator`.
    public var text: String?

    public init(id: UUID = UUID(), kind: StatuslineWidgetKind, foreground: StatuslineColor? = nil, background: StatuslineColor? = nil,
                bold: Bool = false, showLabel: Bool = false, text: String? = nil) {
        self.id = id
        self.kind = kind
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.showLabel = showLabel
        self.text = text
    }
}

public enum StatuslineColorLevel: String, Codable, CaseIterable, Sendable {
    case basic = "16"
    case ansi256 = "256"
    case truecolor = "truecolor"

    public var title: String {
        switch self {
        case .basic: "16 colours"
        case .ansi256: "256 colours"
        case .truecolor: "True colour"
        }
    }
}

public enum StatuslineAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

public struct PowerlineOptions: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Between segments. U+E0B0 is the Powerline arrow (needs a Powerline/Nerd font).
    public var separator: String
    public var startCap: String
    public var endCap: String

    public init(enabled: Bool = false, separator: String = "\u{E0B0}", startCap: String = "", endCap: String = "\u{E0B0}") {
        self.enabled = enabled
        self.separator = separator
        self.startCap = startCap
        self.endCap = endCap
    }

    public static let styles: [(name: String, separator: String, start: String, end: String)] = [
        ("Arrow", "\u{E0B0}", "", "\u{E0B0}"),
        ("Rounded", "\u{E0B4}", "\u{E0B6}", "\u{E0B4}"),
        ("Slant", "\u{E0BC}", "", "\u{E0BC}"),
        ("Flame", "\u{E0C0}", "", "\u{E0C0}"),
        ("Blocks (no special font)", "▌", "", "▌"),
    ]
}

/// The whole status line layout. Stored at `~/.claude-pool/statusline/config.json` when applied.
public struct StatuslineConfig: Codable, Hashable, Sendable {
    public static let currentSchema = 1
    public static let maxLines = 4
    public static let maxWidgetsPerLine = 24

    public var schema: Int
    public var lines: [[StatuslineWidget]]
    public var theme: String
    /// Printed between components when Powerline is off. Ignored around `separator` widgets.
    public var separator: String
    /// Spaces inside each segment that has a background colour.
    public var padding: Int
    public var powerline: PowerlineOptions
    public var colorLevel: StatuslineColorLevel
    public var alignment: StatuslineAlignment
    public var globalBold: Bool

    public init(schema: Int = StatuslineConfig.currentSchema, lines: [[StatuslineWidget]], theme: String = StatuslineTheme.defaultID,
                separator: String = " │ ", padding: Int = 1, powerline: PowerlineOptions = PowerlineOptions(),
                colorLevel: StatuslineColorLevel = .truecolor, alignment: StatuslineAlignment = .left, globalBold: Bool = false) {
        self.schema = schema
        self.lines = lines
        self.theme = theme
        self.separator = separator
        self.padding = padding
        self.powerline = powerline
        self.colorLevel = colorLevel
        self.alignment = alignment
        self.globalBold = globalBold
    }

    /// Tolerates unknown widget kinds (from a newer version) by dropping them, and missing keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        let rawLines = try c.decodeIfPresent([[LossyWidget]].self, forKey: .lines) ?? []
        lines = rawLines.map { $0.compactMap(\.widget) }
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? StatuslineTheme.defaultID
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? " │ "
        padding = try c.decodeIfPresent(Int.self, forKey: .padding) ?? 1
        powerline = try c.decodeIfPresent(PowerlineOptions.self, forKey: .powerline) ?? PowerlineOptions()
        colorLevel = try c.decodeIfPresent(StatuslineColorLevel.self, forKey: .colorLevel) ?? .truecolor
        alignment = try c.decodeIfPresent(StatuslineAlignment.self, forKey: .alignment) ?? .left
        globalBold = try c.decodeIfPresent(Bool.self, forKey: .globalBold) ?? false
    }

    private struct LossyWidget: Decodable {
        let widget: StatuslineWidget?
        init(from decoder: Decoder) throws { widget = try? StatuslineWidget(from: decoder) }
    }

    /// Problems that would make the layout unusable. Empty means valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if schema > Self.currentSchema { errors.append("Made by a newer version of Claude Pool (schema \(schema)).") }
        if lines.isEmpty || lines.allSatisfy(\.isEmpty) { errors.append("Add at least one component.") }
        if lines.count > Self.maxLines { errors.append("At most \(Self.maxLines) lines are supported.") }
        if lines.contains(where: { $0.count > Self.maxWidgetsPerLine }) { errors.append("At most \(Self.maxWidgetsPerLine) components per line.") }
        if !(0...4).contains(padding) { errors.append("Padding must be between 0 and 4.") }
        if separator.count > 8 { errors.append("The separator can be at most 8 characters.") }
        for widget in lines.joined() {
            for color in [widget.foreground, widget.background].compactMap({ $0 }) where !color.isValid {
                errors.append("“\(color.rawValue)” isn't a colour name or #RRGGBB value.")
            }
            if let text = widget.text, text.count > 120 { errors.append("Custom text can be at most 120 characters.") }
            if let text = widget.text, text.contains(where: { $0.isNewline || $0 == "\u{1B}" }) {
                errors.append("Custom text can't contain line breaks or escape characters.")
            }
        }
        if StatuslineTheme.named(theme) == nil { errors.append("Unknown theme “\(theme)”.") }
        return errors
    }

    public var isValid: Bool { validationErrors().isEmpty }

    public var usesGit: Bool { lines.joined().contains { $0.kind == .gitBranch || $0.kind == .gitStatus } }
    public var usesOriginal: Bool { lines.joined().contains { $0.kind == .originalStatusLine } }
}

/// A named colour scheme: foreground (and optional background) per role.
public struct StatuslineTheme: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let foreground: [StatuslineRole: StatuslineColor]
    public let background: [StatuslineRole: StatuslineColor]
    /// Colour of the plain-text separator.
    public let separatorColor: StatuslineColor

    public static let defaultID = "classic"

    public static func named(_ id: String) -> StatuslineTheme? { all.first { $0.id == id } }

    private static func colors(_ pairs: [StatuslineRole: String]) -> [StatuslineRole: StatuslineColor] {
        pairs.mapValues(StatuslineColor.init(rawValue:))
    }

    public static let all: [StatuslineTheme] = [
        StatuslineTheme(id: "classic", name: "Classic",
                        foreground: colors([.model: "cyan", .identity: "magenta", .location: "blue", .git: "green",
                                            .context: "yellow", .session: "white", .usage: "brightYellow", .text: "brightBlack"]),
                        background: [:], separatorColor: StatuslineColor("brightBlack")),
        StatuslineTheme(id: "minimal", name: "Minimal",
                        foreground: colors([.model: "white", .identity: "brightBlack", .location: "brightBlack", .git: "brightBlack",
                                            .context: "brightBlack", .session: "brightBlack", .usage: "white", .text: "brightBlack"]),
                        background: [:], separatorColor: StatuslineColor("brightBlack")),
        StatuslineTheme(id: "ocean", name: "Ocean",
                        foreground: colors([.model: "#E6F1FF", .identity: "#E6F1FF", .location: "#0B1E2D", .git: "#0B1E2D",
                                            .context: "#0B1E2D", .session: "#E6F1FF", .usage: "#0B1E2D", .text: "#E6F1FF"]),
                        background: colors([.model: "#1F4E79", .identity: "#2E6FA7", .location: "#6CB4EE", .git: "#7FD1B9",
                                            .context: "#A9DEF9", .session: "#3D5A80", .usage: "#98C1D9", .text: "#293241"]),
                        separatorColor: StatuslineColor("#6CB4EE")),
        StatuslineTheme(id: "sunset", name: "Sunset",
                        foreground: colors([.model: "#FFF4E6", .identity: "#FFF4E6", .location: "#2B1A12", .git: "#2B1A12",
                                            .context: "#2B1A12", .session: "#FFF4E6", .usage: "#2B1A12", .text: "#FFF4E6"]),
                        background: colors([.model: "#9C2C3C", .identity: "#C8553D", .location: "#F28F3B", .git: "#FFD5C2",
                                            .context: "#F6BD60", .session: "#6D2E46", .usage: "#F7EDE2", .text: "#3D2B1F"]),
                        separatorColor: StatuslineColor("#F28F3B")),
        StatuslineTheme(id: "nord", name: "Nord",
                        foreground: colors([.model: "#88C0D0", .identity: "#B48EAD", .location: "#81A1C1", .git: "#A3BE8C",
                                            .context: "#EBCB8B", .session: "#D8DEE9", .usage: "#D08770", .text: "#4C566A"]),
                        background: [:], separatorColor: StatuslineColor("#4C566A")),
        StatuslineTheme(id: "mono", name: "Monochrome",
                        foreground: colors([.model: "white", .identity: "white", .location: "white", .git: "white",
                                            .context: "white", .session: "white", .usage: "white", .text: "white"]),
                        background: colors([.model: "#3A3A3A", .identity: "#4A4A4A", .location: "#5A5A5A", .git: "#4A4A4A",
                                            .context: "#3A3A3A", .session: "#4A4A4A", .usage: "#5A5A5A", .text: "#2A2A2A"]),
                        separatorColor: StatuslineColor("brightBlack")),
    ]
}

/// Built-in starting points. "Restore defaults" uses `essentials`.
public enum StatuslinePresets {
    public static var essentials: StatuslineConfig {
        StatuslineConfig(lines: [[
            StatuslineWidget(kind: .model, bold: true),
            StatuslineWidget(kind: .cwd),
            StatuslineWidget(kind: .gitBranch),
            StatuslineWidget(kind: .contextPercent, showLabel: true),
            StatuslineWidget(kind: .fiveHourUsage, showLabel: true),
            StatuslineWidget(kind: .account),
        ]])
    }

    public static var powerline: StatuslineConfig {
        StatuslineConfig(lines: [[
            StatuslineWidget(kind: .model, bold: true),
            StatuslineWidget(kind: .cwd),
            StatuslineWidget(kind: .gitBranch),
            StatuslineWidget(kind: .gitStatus),
            StatuslineWidget(kind: .contextPercent, showLabel: true),
        ]], theme: "ocean", padding: 1, powerline: PowerlineOptions(enabled: true))
    }

    public static var detailed: StatuslineConfig {
        StatuslineConfig(lines: [
            [StatuslineWidget(kind: .model, bold: true), StatuslineWidget(kind: .effort, showLabel: true), StatuslineWidget(kind: .cwd),
             StatuslineWidget(kind: .gitBranch), StatuslineWidget(kind: .gitStatus)],
            [StatuslineWidget(kind: .account), StatuslineWidget(kind: .plan), StatuslineWidget(kind: .fiveHourUsage, showLabel: true),
             StatuslineWidget(kind: .fiveHourReset, showLabel: true), StatuslineWidget(kind: .sevenDayUsage, showLabel: true),
             StatuslineWidget(kind: .contextTokens, showLabel: true), StatuslineWidget(kind: .sessionCost, showLabel: true)],
        ], theme: "nord")
    }

    public static var minimal: StatuslineConfig {
        StatuslineConfig(lines: [[
            StatuslineWidget(kind: .model), StatuslineWidget(kind: .contextPercent), StatuslineWidget(kind: .fiveHourUsage, showLabel: true),
        ]], theme: "minimal", separator: " · ")
    }

    public static let all: [(name: String, config: StatuslineConfig)] = [
        ("Essentials", essentials), ("Powerline", powerline), ("Detailed (two lines)", detailed), ("Minimal", minimal),
    ]
}
