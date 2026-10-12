import Foundation

enum ShellQuote {
    /// Single-quotes `value` for sh/zsh/bash: wraps in '…' and replaces ' with '\''.
    /// Every value interpolated into a generated script goes through here.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
