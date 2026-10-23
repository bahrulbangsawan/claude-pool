import Foundation

/// One `claude-pool` invocation, parsed. Parsing is pure; `CommandLineTool` carries it out.
enum CLICommand: Equatable {
    case help(String?)
    case version
    case list(json: Bool)
    case current
    case open(OpenRequest)
    case use(String)
    case add(AddRequest)
    case login(String, arguments: [String])
    case logout(String)
    case status(String?)
    case usage(String?, check: Bool)
    case rename(String, to: String, slug: String?)
    case remove(String, trash: Bool, confirmed: Bool)
    case env(String?)
    case projects
    case sessions
}

/// Where `open` starts claude.
enum OpenPlace: Equatable {
    /// In this terminal or herdr pane: claude-pool replaces itself with claude.
    case here
    /// A new Terminal window or herdr tab; nil follows Settings › Terminal › Open in.
    case new(TerminalHost?)
}

struct OpenRequest: Equatable {
    var account: String?
    var folder: String?
    var place: OpenPlace = .here
    var claudeArguments: [String] = []
    /// Typed as `claude-pool <account>`, so an unknown name may be a mistyped command.
    var shorthand = false
}

struct AddRequest: Equatable {
    var name: String
    var email: String?
    var slug: String?
    var directory: String?
    var color: String?
    var trackUsage = true
    var signIn = true
    var makeActive = false
}

struct CLIError: Error, Equatable, LocalizedError {
    var message: String
    /// 2 for a mistake in the command line, like most tools; 1 for everything else.
    var exitCode: Int32 = 1

    var errorDescription: String? { message }

    static func usage(_ message: String) -> CLIError { CLIError(message: message, exitCode: 2) }
}

enum CommandLineArguments {
    /// Command names, then aliases. A first word that is none of these is an account (`open`).
    static let commandNames: Set<String> = [
        "help", "version", "list", "current", "open", "use", "add", "login", "logout", "status",
        "usage", "rename", "remove", "env", "projects", "sessions",
        "ls", "switch", "rm",
    ]

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help(nil) }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "help", "-h", "--help":
            return .help(rest.first)
        case "version", "-v", "--version":
            return .version
        case "open":
            return try parseOpen(rest, shorthand: false)
        default:
            break
        }
        if first.hasPrefix("-") {
            throw CLIError.usage("Unknown option \(first). Run claude-pool help.")
        }
        guard commandNames.contains(first) else { return try parseOpen(arguments, shorthand: true) }
        let command = canonical(first)
        if rest.contains("-h") || rest.contains("--help") { return .help(command) }

        switch command {
        case "list":
            let options = try Options.parse(rest, command: command, flags: ["--json"])
            try options.expect(0, command: command)
            return .list(json: options.has("--json"))
        case "current":
            try Options.parse(rest, command: command).expect(0, command: command)
            return .current
        case "use":
            let options = try Options.parse(rest, command: command)
            try options.expect(1, command: command)
            return .use(options.positionals[0])
        case "add":
            let options = try Options.parse(rest, command: command,
                                            flags: ["--no-track", "--no-login", "--use"],
                                            values: ["--email", "--slug", "--dir", "--color"])
            try options.expect(1, command: command)
            return .add(AddRequest(
                name: options.positionals[0],
                email: options.values["--email"],
                slug: options.values["--slug"],
                directory: options.values["--dir"],
                color: options.values["--color"],
                trackUsage: !options.has("--no-track"),
                signIn: !options.has("--no-login"),
                makeActive: options.has("--use")
            ))
        case "login":
            // Everything after the account goes to `claude auth login` (--email, --sso, --console).
            guard let account = rest.first, !account.hasPrefix("-") else {
                throw CLIError.usage("Name the account to sign in. Usage: \(Help.usage(command))")
            }
            return .login(account, arguments: Array(rest.dropFirst()))
        case "logout":
            let options = try Options.parse(rest, command: command)
            try options.expect(1, command: command)
            return .logout(options.positionals[0])
        case "status":
            let options = try Options.parse(rest, command: command)
            try options.expect(0...1, command: command)
            return .status(options.positionals.first)
        case "usage":
            let options = try Options.parse(rest, command: command, flags: ["--check"])
            try options.expect(0...1, command: command)
            return .usage(options.positionals.first, check: options.has("--check"))
        case "rename":
            let options = try Options.parse(rest, command: command, values: ["--slug"])
            try options.expect(2, command: command)
            return .rename(options.positionals[0], to: options.positionals[1], slug: options.values["--slug"])
        case "remove":
            let options = try Options.parse(rest, command: command, flags: ["--trash", "--yes", "-y"])
            try options.expect(1, command: command)
            return .remove(options.positionals[0], trash: options.has("--trash"),
                           confirmed: options.has("--yes") || options.has("-y"))
        case "env":
            let options = try Options.parse(rest, command: command)
            try options.expect(0...1, command: command)
            return .env(options.positionals.first)
        case "projects":
            try Options.parse(rest, command: command).expect(0, command: command)
            return .projects
        case "sessions":
            try Options.parse(rest, command: command).expect(0, command: command)
            return .sessions
        default:
            throw CLIError.usage("Unknown command \(first). Run claude-pool help.")
        }
    }

    static func canonical(_ name: String) -> String {
        switch name {
        case "ls": "list"
        case "switch": "use"
        case "rm": "remove"
        default: name
        }
    }

    /// `[account] [folder] [options] [claude options]`. claude-pool's own options may come anywhere
    /// before the claude options, which start at `--` or at the first option it doesn't know.
    static func parseOpen(_ arguments: [String], shorthand: Bool) throws -> CLICommand {
        var request = OpenRequest(shorthand: shorthand)
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--":
                request.claudeArguments = Array(arguments[index...])
                index = arguments.count
            case "-t", "--terminal":
                request.place = .new(.terminal)
            case "--herdr":
                request.place = .new(.herdr)
            case "--new":
                request.place = .new(nil)
            case "-h", "--help":
                return .help("open")
            default:
                if argument.hasPrefix("-") {
                    request.claudeArguments = Array(arguments[(index - 1)...])
                    index = arguments.count
                } else {
                    positionals.append(argument)
                }
            }
        }
        guard positionals.count <= 2 else {
            throw CLIError.usage("Too many arguments: \(positionals.dropFirst(2).joined(separator: " ")). To give claude a prompt, put it after --.")
        }
        request.account = positionals.first
        request.folder = positionals.count > 1 ? positionals[1] : nil
        return .open(request)
    }
}

/// Options and positional arguments of one command. Options take `--name value` or `--name=value`.
private struct Options {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positionals: [String] = []

    static func parse(_ arguments: [String], command: String, flags: Set<String> = [], values valueNames: Set<String> = []) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                options.positionals += arguments[index...]
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                options.positionals.append(argument)
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0]
            if flags.contains(name), parts.count == 1 {
                options.flags.insert(name)
            } else if valueNames.contains(name) {
                if parts.count == 2 {
                    options.values[name] = parts[1]
                } else if index < arguments.count {
                    options.values[name] = arguments[index]
                    index += 1
                } else {
                    throw CLIError.usage("\(name) needs a value. Usage: \(Help.usage(command))")
                }
            } else {
                throw CLIError.usage("Unknown option \(argument) for \(command). Usage: \(Help.usage(command))")
            }
        }
        return options
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func expect(_ count: Int, command: String) throws {
        try expect(count...count, command: command)
    }

    func expect(_ range: ClosedRange<Int>, command: String) throws {
        guard range.contains(positionals.count) else {
            let problem = positionals.count < range.lowerBound ? "Missing an argument" : "Too many arguments"
            throw CLIError.usage("\(problem). Usage: \(Help.usage(command))")
        }
    }
}

enum AccountQueryError: Error, LocalizedError, Equatable {
    case notFound(String, accounts: [String])
    case ambiguous(String, matches: [String])

    var errorDescription: String? {
        switch self {
        case let .notFound(query, accounts): "No account “\(query)”. Accounts: \(accounts.joined(separator: ", "))."
        case let .ambiguous(query, matches): "“\(query)” could be \(matches.joined(separator: ", ")). Type more of the name."
        }
    }
}

/// Finds the profile someone typed: its slug, its name in any case, its number in `list`, or the
/// start of a name or slug that only one profile has.
enum AccountQuery {
    static func resolve(_ query: String, in profiles: [Profile]) throws -> Profile {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let lowered = typed.lowercased()
        if let match = profiles.first(where: { $0.slug == lowered }) { return match }
        if let match = profiles.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) { return match }
        if let number = Int(typed), profiles.indices.contains(number - 1) { return profiles[number - 1] }
        let matches = lowered.isEmpty ? [] : profiles.filter { $0.slug.hasPrefix(lowered) || $0.name.lowercased().hasPrefix(lowered) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw AccountQueryError.ambiguous(typed, matches: matches.map(\.name)) }
        throw AccountQueryError.notFound(typed, accounts: profiles.map(\.name))
    }
}
