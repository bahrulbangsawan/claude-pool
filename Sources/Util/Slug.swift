import Foundation

enum Slug {
    static let maxLength = 32

    /// Derives a slug from a display name: lowercase ASCII letters, digits and single hyphens.
    static func make(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }

    static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= maxLength else { return false }
        guard !slug.hasPrefix("-"), !slug.hasSuffix("-") else { return false }
        return slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
