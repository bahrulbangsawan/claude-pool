import Foundation

/// Kebab-case text, used for slugs and profile names: lowercase ASCII letters, digits and single
/// hyphens ("my-work").
enum Slug {
    static let maxLength = 32

    /// Derives a slug from a display name, at most `maxLength` characters.
    static func make(from name: String) -> String {
        truncated(kebab(name))
    }

    /// Converts anything to kebab-case: accents and capitals are dropped, every run of other
    /// characters (spaces, symbols, letters outside a–z) becomes one hyphen, and there is no hyphen
    /// at either end. "Client — Northwind" → "client-northwind". Not truncated.
    static func kebab(_ text: String) -> String {
        kebab(text, keepTrailingHyphen: false)
    }

    /// What a name field shows while typing: like `make`, but one trailing hyphen stays, so a space
    /// typed between two words survives until the next word starts.
    static func typing(_ text: String) -> String {
        let result = kebab(text, keepTrailingHyphen: true)
        return result.count > maxLength ? truncated(result) : result
    }

    static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= maxLength else { return false }
        guard !slug.hasPrefix("-"), !slug.hasSuffix("-") else { return false }
        return slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private static func kebab(_ text: String, keepTrailingHyphen: Bool) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var lastWasHyphen = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen, !result.isEmpty {
                result.append("-")
                lastWasHyphen = true
            }
        }
        if !keepTrailingHyphen {
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        var result = String(text.prefix(maxLength))
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
