import Foundation

/// Values a status line can show. All come from the status line payload Claude Code sends, from
/// Claude Pool's own per-profile context, or from `git` in the working directory. Missing values
/// hide their component; nothing is estimated.
public struct StatuslineValues: Sendable, Equatable {
    public struct GitStatus: Sendable, Equatable {
        public var staged = 0, modified = 0, untracked = 0, ahead = 0, behind = 0, conflicts = 0
        public init(staged: Int = 0, modified: Int = 0, untracked: Int = 0, ahead: Int = 0, behind: Int = 0, conflicts: Int = 0) {
            self.staged = staged; self.modified = modified; self.untracked = untracked
            self.ahead = ahead; self.behind = behind; self.conflicts = conflicts
        }
        public var isClean: Bool { staged == 0 && modified == 0 && untracked == 0 && conflicts == 0 }
    }

    public var model: String?
    public var account: String?
    public var plan: String?
    public var profile: String?
    public var cwd: String?
    public var gitBranch: String?
    public var gitStatus: GitStatus?
    public var contextPercent: Double?
    public var contextTokens: Int?
    public var contextSize: Int?
    public var lastInput: Int?
    public var lastOutput: Int?
    public var lastCacheRead: Int?
    public var lastCacheWrite: Int?
    public var costUSD: Double?
    public var durationMs: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var sessionName: String?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var effort: String?
    public var vimMode: String?
    public var outputStyle: String?
    public var version: String?
    public var originalStatusLine: String?
    public var now: Date

    public init(now: Date = Date()) { self.now = now }
}

/// A run of text with one style.
public struct StatuslineSegment: Sendable, Equatable {
    public var text: String
    public var foreground: StatuslineColor?
    public var background: StatuslineColor?
    public var bold: Bool

    public init(text: String, foreground: StatuslineColor? = nil, background: StatuslineColor? = nil, bold: Bool = false) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
    }
}

public struct StatuslineRenderer: Sendable {
    public let config: StatuslineConfig

    public init(config: StatuslineConfig) {
        self.config = config
    }

    // MARK: Values

    /// The text a widget shows, or nil when it has no value (the component is then hidden).
    public static func text(for widget: StatuslineWidget, values v: StatuslineValues) -> String? {
        let raw: String?
        switch widget.kind {
        case .model: raw = v.model
        case .account: raw = v.account
        case .plan: raw = v.plan
        case .profile: raw = v.profile
        case .cwd:
            raw = v.cwd.map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return name.isEmpty ? path : name
            }
        case .gitBranch: raw = v.gitBranch
        case .gitStatus:
            raw = v.gitStatus.map { s in
                var parts: [String] = []
                if s.conflicts > 0 { parts.append("!\(s.conflicts)") }
                if s.staged > 0 { parts.append("+\(s.staged)") }
                if s.modified > 0 { parts.append("~\(s.modified)") }
                if s.untracked > 0 { parts.append("?\(s.untracked)") }
                if s.ahead > 0 { parts.append("↑\(s.ahead)") }
                if s.behind > 0 { parts.append("↓\(s.behind)") }
                return parts.isEmpty ? "✓" : parts.joined(separator: " ")
            }
        case .contextPercent: raw = v.contextPercent.map { "\(Int($0.rounded()))%" }
        case .contextTokens:
            raw = v.contextTokens.map { tokens in
                if let size = v.contextSize, size > 0 { return "\(compact(tokens))/\(compact(size))" }
                return compact(tokens)
            }
        case .tokensInOut:
            if let input = v.lastInput, let output = v.lastOutput { raw = "↑\(compact(input)) ↓\(compact(output))" } else { raw = nil }
        case .cacheTokens:
            if let read = v.lastCacheRead, let write = v.lastCacheWrite { raw = "r \(compact(read)) w \(compact(write))" } else { raw = nil }
        case .sessionCost: raw = v.costUSD.map { String(format: "$%.2f", $0) }
        case .sessionDuration: raw = v.durationMs.map { duration(seconds: Int($0 / 1000)) }
        case .linesChanged:
            if let added = v.linesAdded, let removed = v.linesRemoved { raw = "+\(added) −\(removed)" } else { raw = nil }
        case .sessionName: raw = v.sessionName
        case .fiveHourUsage: raw = usage(v.fiveHour, now: v.now)
        case .sevenDayUsage: raw = usage(v.sevenDay, now: v.now)
        case .fiveHourReset: raw = reset(v.fiveHour, now: v.now)
        case .sevenDayReset: raw = reset(v.sevenDay, now: v.now)
        case .effort: raw = v.effort
        case .vimMode: raw = v.vimMode
        case .outputStyle: raw = v.outputStyle == "default" ? nil : v.outputStyle
        case .version: raw = v.version
        case .originalStatusLine: raw = v.originalStatusLine
        case .customText: raw = widget.text
        case .separator: raw = widget.text ?? "│"
        case .flexSpacer: raw = ""
        }
        guard let value = raw.map(sanitize), !value.isEmpty || widget.kind == .flexSpacer else { return nil }
        if widget.showLabel, !widget.kind.label.isEmpty {
            return "\(widget.kind.label) \(value)"
        }
        return value
    }

    /// Strips control characters so a value can never inject escape sequences or line breaks.
    public static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value: UInt32 = scalar.value
            let isControl: Bool = value < 0x20 || value == 0x7F || (value >= 0x80 && value <= 0x9F)
            if !isControl { scalars.append(scalar) }
        }
        return String(String(scalars).prefix(200))
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default: String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    static func duration(seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3_600)h" }
        if s >= 3_600 { return "\(s / 3_600)h \(s % 3_600 / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    private static func usage(_ window: UsageWindow?, now: Date) -> String? {
        guard let window, window.resetsAt > now else { return nil }
        return "\(Int(window.usedPercentage.rounded()))%"
    }

    private static func reset(_ window: UsageWindow?, now: Date) -> String? {
        guard let window, window.resetsAt > now else { return nil }
        return duration(seconds: Int(window.resetsAt.timeIntervalSince(now)))
    }

    // MARK: Layout

    /// Styled segments per line. Empty lines (all components hidden) are dropped.
    public func segments(values: StatuslineValues, width: Int? = nil) -> [[StatuslineSegment]] {
        let theme = StatuslineTheme.named(config.theme) ?? StatuslineTheme.all[0]
        return config.lines.compactMap { line in
            let rendered = renderLine(line, values: values, theme: theme, width: width)
            return rendered.isEmpty ? nil : rendered
        }
    }

    private struct Piece {
        var text: String
        var foreground: StatuslineColor?
        var background: StatuslineColor?
        var bold: Bool
        var isSeparator: Bool
        var isFlex: Bool
    }

    private func renderLine(_ line: [StatuslineWidget], values: StatuslineValues, theme: StatuslineTheme, width: Int?) -> [StatuslineSegment] {
        var pieces: [Piece] = []
        for widget in line {
            guard let text = Self.text(for: widget, values: values) else { continue }
            let role = widget.kind.role
            pieces.append(Piece(
                text: text,
                foreground: widget.foreground ?? (widget.kind == .separator ? theme.separatorColor : theme.foreground[role]),
                background: widget.background ?? (widget.kind.isLayout ? nil : theme.background[role]),
                bold: widget.bold || config.globalBold,
                isSeparator: widget.kind == .separator,
                isFlex: widget.kind == .flexSpacer
            ))
        }
        // Drop separators that would sit at an edge or next to another separator.
        var cleaned: [Piece] = []
        for piece in pieces {
            if piece.isSeparator, cleaned.isEmpty || cleaned.last?.isSeparator == true || cleaned.last?.isFlex == true { continue }
            cleaned.append(piece)
        }
        while cleaned.last?.isSeparator == true { cleaned.removeLast() }
        guard cleaned.contains(where: { !$0.isFlex }) else { return [] }

        // Split at flexible spaces into groups; each group is rendered on its own.
        var groups: [[Piece]] = [[]]
        for piece in cleaned {
            if piece.isFlex { groups.append([]) } else { groups[groups.count - 1].append(piece) }
        }
        let renderedGroups = groups.map(renderGroup).filter { !$0.isEmpty }
        guard !renderedGroups.isEmpty else { return [] }

        func length(_ segments: [StatuslineSegment]) -> Int { segments.reduce(0) { $0 + $1.text.count } }
        let contentWidth = renderedGroups.reduce(0) { $0 + length($1) }
        // Leave room for Claude Code's own padding and a safety margin.
        let available = width.map { max(0, $0 - 4) }

        var result: [StatuslineSegment] = []
        if let available, groups.count > 1, renderedGroups.count > 1 {
            let gaps = renderedGroups.count - 1
            let free = max(gaps, available - contentWidth)
            for (index, group) in renderedGroups.enumerated() {
                result += group
                if index < gaps {
                    let share = free / gaps + (index < free % gaps ? 1 : 0)
                    result.append(StatuslineSegment(text: String(repeating: " ", count: max(1, share))))
                }
            }
        } else {
            for (index, group) in renderedGroups.enumerated() {
                if index > 0 { result.append(StatuslineSegment(text: " ")) }
                result += group
            }
        }

        if let available, config.alignment != .left {
            let used = length(result)
            let free = max(0, available - used)
            let lead = config.alignment == .right ? free : free / 2
            if lead > 0 { result.insert(StatuslineSegment(text: String(repeating: " ", count: lead)), at: 0) }
        }
        return result
    }

    private func renderGroup(_ pieces: [Piece]) -> [StatuslineSegment] {
        guard !pieces.isEmpty else { return [] }
        let pad = String(repeating: " ", count: max(0, min(config.padding, 4)))
        var segments: [StatuslineSegment] = []

        if config.powerline.enabled {
            let content = pieces.filter { !$0.isSeparator }
            guard !content.isEmpty else { return [] }
            if !config.powerline.startCap.isEmpty, let first = content.first {
                segments.append(StatuslineSegment(text: config.powerline.startCap, foreground: first.background ?? first.foreground))
            }
            for (index, piece) in content.enumerated() {
                segments.append(StatuslineSegment(text: pad + piece.text + pad, foreground: piece.foreground, background: piece.background, bold: piece.bold))
                let next = index + 1 < content.count ? content[index + 1] : nil
                if let next {
                    // Arrow in this segment's colour on the next segment's background.
                    segments.append(StatuslineSegment(text: config.powerline.separator, foreground: piece.background ?? piece.foreground, background: next.background))
                } else if !config.powerline.endCap.isEmpty {
                    segments.append(StatuslineSegment(text: config.powerline.endCap, foreground: piece.background ?? piece.foreground))
                }
            }
            return segments
        }

        for (index, piece) in pieces.enumerated() {
            let previous = index > 0 ? pieces[index - 1] : nil
            if let previous, !piece.isSeparator, !previous.isSeparator, !config.separator.isEmpty {
                segments.append(StatuslineSegment(text: config.separator, foreground: (StatuslineTheme.named(config.theme) ?? StatuslineTheme.all[0]).separatorColor))
            }
            if piece.isSeparator {
                segments.append(StatuslineSegment(text: " \(piece.text) ", foreground: piece.foreground, bold: piece.bold))
            } else {
                let padded = piece.background != nil ? pad + piece.text + pad : piece.text
                segments.append(StatuslineSegment(text: padded, foreground: piece.foreground, background: piece.background, bold: piece.bold))
            }
        }
        return segments
    }

    // MARK: ANSI

    /// The final text for Claude Code: one line per status line row, with SGR colour codes.
    public func ansi(values: StatuslineValues, width: Int? = nil) -> String {
        segments(values: values, width: width).map { line in
            line.map { ansi($0) }.joined()
        }.joined(separator: "\n")
    }

    public func ansi(_ segment: StatuslineSegment) -> String {
        var codes: [String] = []
        if segment.bold { codes.append("1") }
        if let fg = segment.foreground, let code = colorCode(fg, background: false) { codes.append(code) }
        if let bg = segment.background, let code = colorCode(bg, background: true) { codes.append(code) }
        guard !codes.isEmpty else { return segment.text }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(segment.text)\u{1B}[0m"
    }

    public func colorCode(_ color: StatuslineColor, background: Bool) -> String? {
        if let index = color.ansiIndex {
            let base = index < 8 ? (background ? 40 : 30) + index : (background ? 100 : 90) + (index - 8)
            return "\(base)"
        }
        guard let (r, g, b) = color.rgb else { return nil }
        switch config.colorLevel {
        case .truecolor:
            return "\(background ? 48 : 38);2;\(r);\(g);\(b)"
        case .ansi256:
            return "\(background ? 48 : 38);5;\(Self.xterm256(r, g, b))"
        case .basic:
            let index = Self.nearestBasic(r, g, b)
            let base = index < 8 ? (background ? 40 : 30) + index : (background ? 100 : 90) + (index - 8)
            return "\(base)"
        }
    }

    static func xterm256(_ r: Int, _ g: Int, _ b: Int) -> Int {
        func level(_ v: Int) -> Int {
            if v < 48 { return 0 }
            if v < 115 { return 1 }
            return (v - 35) / 40
        }
        if r == g, g == b {
            if r < 8 { return 16 }
            if r > 248 { return 231 }
            let step: Int = (r - 8) * 24 / 247
            return 232 + step
        }
        let red: Int = 36 * level(r)
        let green: Int = 6 * level(g)
        return 16 + red + green + level(b)
    }

    static func nearestBasic(_ r: Int, _ g: Int, _ b: Int) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, name) in StatuslineColor.ansiNames.enumerated() {
            guard let (cr, cg, cb) = StatuslineColor.ansiRGB[name] else { continue }
            let dr: Int = r - cr
            let dg: Int = g - cg
            let db: Int = b - cb
            let distance: Int = dr * dr + dg * dg + db * db
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }
}
