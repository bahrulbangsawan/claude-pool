import Foundation

/// One MCP server as Claude Code reports it for one profile (`claude mcp list` / `claude mcp get`).
///
/// Only display-safe parts are kept: a URL without its query or user info, and a command without
/// its arguments, so a key passed in a URL or an argument is never shown or stored.
struct McpServer: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// An HTTP or SSE server added with `claude mcp add`.
        case remote
        /// A stdio server: a command that runs on this Mac.
        case local
        /// Comes with an installed plugin ("plugin:<plugin>:<server>").
        case plugin
        /// A claude.ai connector of the signed-in account ("claude.ai <Name>").
        case connector
    }

    enum Health: Hashable, Sendable {
        case connected
        case needsSignIn
        case failed(String?)
        case notConfigured
        case pendingApproval
        case other(String)
    }

    var name: String
    /// URL without query, or the command's executable name. Empty when Claude Code shows none.
    var target: String
    /// "HTTP" or "SSE" when Claude Code names the transport.
    var transport: String?
    var health: Health

    var id: String { name }

    var kind: Kind {
        if name.hasPrefix(Self.connectorPrefix) { return .connector }
        if name.hasPrefix(Self.pluginPrefix) { return .plugin }
        return isRemote ? .remote : .local
    }

    var isRemote: Bool {
        transport != nil || target.hasPrefix("https://") || target.hasPrefix("http://")
    }

    /// `claude mcp login` works for HTTP and SSE servers (yours or a plugin's) and claude.ai connectors.
    var supportsSignIn: Bool {
        guard health != .notConfigured else { return false }
        return kind == .connector || isRemote
    }

    /// A connector's sign-in lives on claude.ai, so only the others can be signed out here.
    var supportsSignOut: Bool { supportsSignIn && kind != .connector }

    /// Servers you added can be removed; plugin servers and connectors belong to their source.
    var isRemovable: Bool { kind == .remote || kind == .local }

    /// "linear" for "plugin:engineering:linear", "Mobbin" for "claude.ai Mobbin".
    var displayName: String { Self.displayName(for: name) }

    static let connectorPrefix = "claude.ai "
    static let pluginPrefix = "plugin:"

    static func displayName(for name: String) -> String {
        if name.hasPrefix(connectorPrefix) { return String(name.dropFirst(connectorPrefix.count)) }
        if name.hasPrefix(pluginPrefix) { return String(name.split(separator: ":").last ?? Substring(name)) }
        return name
    }

    /// "engineering plugin" for "plugin:engineering:linear".
    static func pluginName(for name: String) -> String? {
        let parts = name.split(separator: ":")
        guard name.hasPrefix(pluginPrefix), parts.count >= 3 else { return nil }
        return String(parts[1])
    }
}

/// Reads the text Claude Code prints for `claude mcp list` and `claude mcp get`.
///
/// Formats verified against Claude Code 2.1.309:
/// - list: `<name>: <url or command>[ (HTTP|SSE)] - <symbol> <status>`, for example
///   `linear: https://mcp.linear.app/mcp (HTTP) - ! Needs authentication`.
/// - get: `<name>:` followed by indented `Status:`, `Type:`, `URL:` or `Command:` lines.
enum McpOutputParser {
    static let statusSymbols: Set<Character> = ["✔", "✓", "!", "✘", "✗", "⏸", "⚠", "-"]

    static func parseList(_ text: String) -> [McpServer] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let server = parseListLine(String(line)), seen.insert(server.name).inserted else { return nil }
            return server
        }
    }

    static func parseListLine(_ rawLine: String) -> McpServer? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let colon = line.range(of: ": ") else { return nil }
        let name = String(line[..<colon.lowerBound])
        guard !name.isEmpty, !name.hasPrefix(" ") else { return nil }
        let rest = line[colon.upperBound...]
        guard let separator = statusSeparator(in: rest) else { return nil }
        var targetPart = rest[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let status = rest[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        var transport: String?
        if let match = targetPart.firstMatch(of: /\s*\((HTTP|SSE|WS|HTTPS)\)$/) {
            transport = String(match.1)
            targetPart = String(targetPart[..<match.range.lowerBound])
        }
        return McpServer(name: name, target: displayTarget(targetPart), transport: transport, health: health(fromStatus: status))
    }

    /// The first " - " followed by a status symbol and a space.
    private static func statusSeparator(in text: Substring) -> Range<Substring.Index>? {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: " - ", range: search) {
            let after = range.upperBound
            if after < text.endIndex, statusSymbols.contains(text[after]) {
                let next = text.index(after: after)
                if next == text.endIndex || text[next] == " " { return range }
            }
            search = range.upperBound..<text.endIndex
        }
        return nil
    }

    /// `claude mcp get <name>`; nil when the output has no status line.
    static func parseGet(_ text: String, name: String) -> McpServer? {
        var status: String?, type: String?, url: String?, command: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value(_ key: String) -> String? {
                line.hasPrefix(key + ":") ? line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) : nil
            }
            if status == nil, let v = value("Status") { status = v }
            else if type == nil, let v = value("Type") { type = v }
            else if url == nil, let v = value("URL") { url = v }
            else if command == nil, let v = value("Command") { command = v }
        }
        guard let status else { return nil }
        let transport = type.flatMap { ["http", "sse"].contains($0.lowercased()) ? $0.uppercased() : nil }
        return McpServer(name: name, target: displayTarget(url ?? command ?? ""), transport: transport, health: health(fromStatus: status))
    }

    static func health(fromStatus raw: String) -> McpServer.Health {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let first = text.first, statusSymbols.contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("connected") { return .connected }
        if lower.contains("needs authentication") || lower.contains("needs auth") { return .needsSignIn }
        if lower.hasPrefix("not configured") { return .notConfigured }
        if lower.hasPrefix("pending approval") { return .pendingApproval }
        if lower.hasPrefix("failed") {
            let reason = text.firstRange(of: "—").map { text[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
            return .failed(reason.flatMap { $0.isEmpty ? nil : cleanReason($0) })
        }
        return .other(cleanReason(text))
    }

    /// A URL without query, fragment or user info, or a command's executable name.
    static func displayTarget(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("https://") || value.hasPrefix("http://") {
            return displayURL(value)
        }
        guard let executable = value.split(separator: " ").first else { return "" }
        return String(executable.split(separator: "/").last ?? executable)
    }

    static func displayURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.host != nil else {
            return String(raw.prefix { $0 != "?" && $0 != "#" })
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    /// Error text from Claude Code, with URLs shortened to their display form and a length cap.
    static func cleanReason(_ text: String) -> String {
        let shortened = text.replacing(/https?:\/\/[^\s'"]+/) { displayURL(String($0.output)) }
        return String(shortened.prefix(240))
    }
}
