import Foundation

/// What `claude-pool help` prints.
enum Help {
    struct Entry {
        var name: String
        var aliases: [String] = []
        var usage: String
        var summary: String
        var details: String
    }

    static let entries: [Entry] = [
        Entry(name: "list", aliases: ["ls"], usage: "claude-pool list [--json]",
              summary: "List accounts with sign-in and usage",
              details: """
              Lists every account in the order Claude Pool shows them. * marks the active account.
              The number in the first column also works wherever an <account> is asked for.
              Sign-in and usage are what Claude Code last reported; run status to check sign-in now.

                --json   Print the list as JSON
              """),
        Entry(name: "open", usage: "claude-pool open [account] [folder] [options] [-- claude options]",
              summary: "Start claude as an account, right here",
              details: """
              Starts claude signed in as <account> in this terminal or herdr pane, or in a new
              window or tab. Without an account it uses the active one. [folder] is a path or the
              name (or start of the name) of a folder in your projects folder.

                -t, --terminal   Open a new Terminal window instead
                    --herdr      Open a new herdr tab instead
                    --new        Open a new window or tab, as set in Settings › Terminal › Open in

              Everything after -- goes to claude, as does everything from the first option
              claude-pool doesn't know. claude-pool <account> is short for claude-pool open <account>.

                claude-pool open work
                claude-pool work ~/projects/api
                claude-pool work api --herdr
                claude-pool work -c
                claude-pool open work -- "fix the failing test"
              """),
        Entry(name: "use", aliases: ["switch"], usage: "claude-pool use <account>",
              summary: "Make an account the active one",
              details: """
              Makes <account> active, as choosing it in the menu does: a plain claude started
              afterwards uses it (with the shell integration from Settings › Shell Integration).
              Running sessions keep their account.
              """),
        Entry(name: "current", usage: "claude-pool current",
              summary: "Print the active account",
              details: "Prints the name of the active account."),
        Entry(name: "add", usage: "claude-pool add <name> [options]",
              summary: "Add an account and sign it in",
              details: """
              Adds an account with its own Claude Code folder (~/.claude-<slug> unless --dir says
              otherwise), turns on usage tracking for a new folder, then runs Claude Code's sign-in
              in this terminal. An existing folder is added as it is, like Adopt in the app.

                --email <email>   Pre-fill the sign-in page
                --dir <folder>    Use this folder instead of ~/.claude-<slug>
                --slug <slug>     Short name: a-z, 0-9 and hyphens (made from the name otherwise)
                --color <color>   blue, green, orange, pink, purple, teal, yellow, graphite or #RRGGBB
                --no-track        Don't turn on usage tracking
                --no-login        Don't sign in now (claude-pool login <account> later)
                --use             Make it the active account afterwards
              """),
        Entry(name: "login", usage: "claude-pool login <account> [--email <email>] [--sso] [--console]",
              summary: "Sign an account in",
              details: """
              Runs Claude Code's own sign-in (claude auth login) for <account> in this terminal.
              Options after the account go to claude auth login.
              """),
        Entry(name: "logout", usage: "claude-pool logout <account>",
              summary: "Sign an account out",
              details: "Runs claude auth logout for <account>. The account stays in Claude Pool."),
        Entry(name: "status", usage: "claude-pool status [account]",
              summary: "Check sign-in now",
              details: """
              Asks Claude Code (claude auth status) whether each account, or just <account>, is
              signed in, and as whom. Exits with 1 if any of them is signed out.
              """),
        Entry(name: "usage", usage: "claude-pool usage [account] [--check]",
              summary: "Show 5-hour and 7-day usage",
              details: """
              Shows the 5-hour and 7-day usage each account last reported, and when they reset.

                --check   Ask for current numbers first. Claude Code sends one tiny request per
                          account, which costs a few hundred tokens of that account.
              """),
        Entry(name: "sessions", usage: "claude-pool sessions",
              summary: "List running claude sessions",
              details: "Lists the claude sessions running now, with their account and folder."),
        Entry(name: "projects", usage: "claude-pool projects",
              summary: "List folders in the projects folder",
              details: "Lists the folders in the projects folder from Settings › Terminal, for open."),
        Entry(name: "env", usage: "claude-pool env [account]",
              summary: "Print commands that pin this shell to an account",
              details: """
              Prints the export (or unset, for the account that uses ~/.claude) that makes claude
              in this shell use <account>:

                eval "$(claude-pool env work)"
              """),
        Entry(name: "rename", usage: "claude-pool rename <account> <new name> [--slug <slug>]",
              summary: "Rename an account",
              details: "Changes the name, and with --slug the slug. Its folder and sign-in stay."),
        Entry(name: "remove", aliases: ["rm"], usage: "claude-pool remove <account> [--trash] [--yes]",
              summary: "Remove an account from Claude Pool",
              details: """
              Removes <account> from Claude Pool and restores its status line setting. Its folder
              and sign-in are kept unless --trash moves the folder to the Trash.

                --trash      Move the account's folder to the Trash
                -y, --yes    Don't ask first
              """),
    ]

    static func entry(_ name: String) -> Entry? {
        let name = CommandLineArguments.canonical(name)
        return entries.first { $0.name == name }
    }

    static func usage(_ command: String) -> String {
        entry(command)?.usage ?? "claude-pool \(command)"
    }

    static var overview: String {
        let commands = entries.map { (label($0), $0.summary) } + [("help [command]", "Show help for a command"), ("version", "Show the version")]
        let width = commands.map(\.0.count).max() ?? 0
        let rows = commands.map { "  " + $0.0.padding(toLength: width + 3, withPad: " ", startingAt: 0) + $0.1 }
        return """
        claude-pool: your Claude Pool accounts from any terminal or herdr pane.

        Usage:
          claude-pool <command> [arguments]
          claude-pool <account> [folder] [claude options]   (same as open)

        Commands:
        \(rows.joined(separator: "\n"))

        An <account> is its name, its slug, its number in list, or the start of its name.

        """
    }

    private static func label(_ entry: Entry) -> String {
        ([entry.name] + entry.aliases).joined(separator: ", ")
    }

    static func text(for command: String) -> String? {
        guard let entry = entry(command) else { return nil }
        let aliases = entry.aliases.isEmpty ? "" : "\nAlso: " + entry.aliases.map { "claude-pool \($0)" }.joined(separator: ", ") + "\n"
        return "Usage: \(entry.usage)\n\n\(entry.details)\n\(aliases)"
    }
}
