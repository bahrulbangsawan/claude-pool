import Foundation

/// One separately signed-in Claude Code account, identified by its config directory.
struct Profile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String               // unique, 1–32 chars, kebab-case (see `normalizedName`)
    var slug: String               // [a-z0-9-], unique
    var configDir: String          // absolute; Default = $HOME/.claude
    var colorHex: String
    var isDefault: Bool            // exactly one; runs with CLAUDE_CONFIG_DIR unset
    var trackingEnabled: Bool      // statusLine points to collector
    var originalStatusLine: String? // verbatim JSON of the pre-existing statusLine value, if any
    var sortIndex: Int             // user-defined order only
    var createdAt: Date

    static let maxNameLength = 32

    /// Names are kebab-case like slugs: lowercase letters, digits and single hyphens. Whatever is
    /// typed is converted rather than refused: "My Work!" → "my-work".
    static func normalizedName(_ text: String) -> String {
        Slug.kebab(text)
    }

    static func makeDefault(home: URL, now: Date = Date()) -> Profile {
        Profile(
            id: UUID(),
            name: "default",
            slug: "default",
            configDir: home.appendingPathComponent(".claude").path,
            colorHex: ProfileColor.presets[0].hex,
            isDefault: true,
            trackingEnabled: false,
            originalStatusLine: nil,
            sortIndex: 0,
            createdAt: now
        )
    }

    var configURL: URL { URL(fileURLWithPath: configDir, isDirectory: true) }

    /// `CLAUDE_CONFIG_DIR` for this profile; nil for Default, which must run with it unset.
    var configDirEnvironmentValue: String? { isDefault ? nil : configDir }
}

struct ProfileColor: Hashable, Sendable, Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let presets: [ProfileColor] = [
        ProfileColor(name: "Blue", hex: "#0A84FF"),
        ProfileColor(name: "Green", hex: "#30D158"),
        ProfileColor(name: "Orange", hex: "#FF9F0A"),
        ProfileColor(name: "Pink", hex: "#FF375F"),
        ProfileColor(name: "Purple", hex: "#BF5AF2"),
        ProfileColor(name: "Teal", hex: "#40C8E0"),
        ProfileColor(name: "Yellow", hex: "#FFD60A"),
        ProfileColor(name: "Graphite", hex: "#8E8E93"),
    ]
}
