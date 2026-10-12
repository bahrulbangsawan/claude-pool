import Foundation

struct DiagnosticCheck: Identifiable, Hashable, Sendable {
    enum Status: Int, Comparable, Sendable {
        case pass, info, warn, fail

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    var title: String
    var status: Status
    var detail: String
    var fix: String?
    /// Profile name for per-profile rows; nil for global checks.
    var profileName: String?
}

/// Everything the checks need, gathered by the app model so the evaluation itself is pure.
struct DiagnosticsInput: Sendable {
    var binary: ClaudeBinary?
    var shellStatus: ShellIntegrationStatus
    var shellFunctionProbe: String?
    var conflictingVariables: [String]?
    var pointerValue: String?
    var pointerError: String?
    var profiles: [Profile]
    var authStatuses: [UUID: AuthStatus]
    var authErrors: [UUID: String]
    var trackingStates: [UUID: TrackingState]
    var collectorState: CollectorInstallState
}

struct DiagnosticsService: Sendable {
    /// Prints only the NAMES of variables that are set. Values never leave the shell.
    static let environmentProbe = #"for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR; do [[ -n "${(P)v}" ]] && print -r -- "CP_SET:$v"; done"# // static-check:allow

    let home: URL
    let loginShell: String
    var runner: ProcessRunner = .shared

    /// `whence -w claude` (zsh) or `type -t claude` (bash) in an interactive login shell.
    func probeShellFunction() async -> String? {
        let shellName = URL(fileURLWithPath: loginShell).lastPathComponent
        let (shell, command) = shellName == "bash"
            ? ("/bin/bash", "type -t claude")
            : ("/bin/zsh", "whence -w claude")
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-ilc", command],
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 5
        ), !result.timedOut else { return nil }
        let lines = result.stdoutText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { $0.hasPrefix("claude:") || ["function", "file", "alias", "builtin"].contains($0) }
            ?? lines.last
    }

    /// Names of credential/config variables exported by the user's interactive shell.
    func probeConflictingVariables() async -> [String]? {
        guard let result = try? await runner.run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-ilc", Self.environmentProbe],
            environment: ChildEnvironment.loginShell(home: home),
            timeout: 5
        ), !result.timedOut else { return nil }
        return result.stdoutText
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("CP_SET:") }
            .map { String($0.dropFirst("CP_SET:".count)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
    }

    static func evaluate(_ input: DiagnosticsInput) -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []

        // 1. Binary
        if let binary = input.binary {
            checks.append(DiagnosticCheck(
                id: "binary", title: "Claude Code binary", status: binary.version == nil ? .warn : .pass,
                detail: "\(binary.path) (\(binary.source.rawValue))" + (binary.version.map { " — \($0)" } ?? " — version unknown"),
                fix: binary.version == nil ? "Run the binary once in Terminal to check it works, or set the path in Settings." : nil
            ))
        } else {
            checks.append(DiagnosticCheck(
                id: "binary", title: "Claude Code binary", status: .fail,
                detail: "claude was not found in your login shell PATH or the usual install locations.",
                fix: "Install Claude Code, or set its path in Settings › Claude Code."
            ))
        }

        // 2. Shell integration
        let probe = input.shellFunctionProbe ?? "no answer"
        let isFunction = probe == "claude: function" || probe == "function"
        switch input.shellStatus {
        case .installed:
            checks.append(DiagnosticCheck(
                id: "shell", title: "Shell integration", status: isFunction ? .pass : .warn,
                detail: isFunction ? "Installed; new shells resolve claude to the Claude Pool function." : "Installed, but a new shell reports “\(probe)”.",
                fix: isFunction ? nil : "Open a new terminal window. If it persists, another alias or function named claude is defined after the block."
            ))
        case .outdated:
            checks.append(DiagnosticCheck(
                id: "shell", title: "Shell integration", status: .warn,
                detail: "The installed block differs from the current snippet.",
                fix: "Settings › Shell Integration › Install or Update."
            ))
        case .notInstalled:
            checks.append(DiagnosticCheck(
                id: "shell", title: "Shell integration", status: .warn,
                detail: "Not installed. Switching only affects Terminal launches from this app.",
                fix: "Settings › Shell Integration › Install or Update."
            ))
        case let .unsupportedShell(shell):
            checks.append(DiagnosticCheck(
                id: "shell", title: "Shell integration", status: isFunction ? .pass : .warn,
                detail: "Login shell \(shell) is not zsh or bash; the block must be added by hand.",
                fix: isFunction ? nil : "Settings › Shell Integration › Copy Snippet, then add it to your shell's startup file."
            ))
        }

        // 3. Conflicting environment variables (names only)
        if let names = input.conflictingVariables {
            let credentialNames = names.filter { $0 != "CLAUDE_CONFIG_DIR" }
            if !credentialNames.isEmpty {
                checks.append(DiagnosticCheck(
                    id: "env", title: "Shell environment", status: .fail,
                    detail: "Exported in your shell: \(credentialNames.joined(separator: ", ")). These override /login, so every profile uses that credential.",
                    fix: "Remove the export from your shell startup files, then open a new terminal."
                ))
            } else if names.contains("CLAUDE_CONFIG_DIR") {
                checks.append(DiagnosticCheck(
                    id: "env", title: "Shell environment", status: .warn,
                    detail: "CLAUDE_CONFIG_DIR is exported globally, so the active profile is ignored in new shells.",
                    fix: "Remove the global export; Claude Pool sets it per launch."
                ))
            } else {
                checks.append(DiagnosticCheck(
                    id: "env", title: "Shell environment", status: .pass,
                    detail: "No credential or config-directory variables are exported globally.", fix: nil
                ))
            }
        } else {
            checks.append(DiagnosticCheck(
                id: "env", title: "Shell environment", status: .warn,
                detail: "Could not run the zsh environment probe.",
                fix: "Make sure /bin/zsh -il starts without errors."
            ))
        }

        // 4. Pointer file
        if let error = input.pointerError {
            checks.append(DiagnosticCheck(id: "pointer", title: "Active profile pointer", status: .fail, detail: error, fix: "Select a profile in the menu to rewrite it."))
        } else if let value = input.pointerValue {
            let known = input.profiles.contains { !$0.isDefault && Paths.canonical($0.configDir) == Paths.canonical(value) }
            let exists = FileManager.default.fileExists(atPath: value)
            let ok = known && exists && value.hasPrefix("/")
            checks.append(DiagnosticCheck(
                id: "pointer", title: "Active profile pointer", status: ok ? .pass : .fail,
                detail: ok ? "Points to \(value)." : "Points to \(value), which is \(exists ? "not a registered profile" : "missing").",
                fix: ok ? nil : "Select a profile in the menu to rewrite it."
            ))
        } else {
            checks.append(DiagnosticCheck(id: "pointer", title: "Active profile pointer", status: .pass, detail: "Empty — Default is active.", fix: nil))
        }

        // 5. Profile directories
        let missing = input.profiles.filter { !FileManager.default.fileExists(atPath: $0.configDir) }
        checks.append(DiagnosticCheck(
            id: "dirs", title: "Profile directories", status: missing.isEmpty ? .pass : .fail,
            detail: missing.isEmpty ? "All \(input.profiles.count) directories exist." : "Missing: \(missing.map(\.name).joined(separator: ", ")).",
            fix: missing.isEmpty ? nil : "Open the profile, then choose Create Directory or change its directory."
        ))

        // 6. Collector helper
        let collector: (DiagnosticCheck.Status, String, String?) = switch input.collectorState {
        case .upToDate: (.pass, "Installed and matches the bundled helper.", nil)
        case .missing: (.fail, "Not installed in ~/.claude-pool/bin.", "Relaunch Claude Pool to reinstall it.")
        case .outdated: (.fail, "Installed copy differs from the bundled helper.", "Relaunch Claude Pool to refresh it.")
        case .bundledHelperMissing: (.fail, "The app bundle has no collector helper.", "Rebuild with make build or reinstall the app.")
        }
        checks.append(DiagnosticCheck(id: "collector", title: "Usage collector", status: collector.0, detail: collector.1, fix: collector.2))

        // 7. Per profile
        for profile in input.profiles {
            checks.append(contentsOf: profileChecks(profile, input: input))
        }

        // 8. Things that cannot be detected without reading settings the app must not read.
        checks.append(DiagnosticCheck(
            id: "info-limits", title: "Not checked automatically", status: .info,
            detail: "The status line only runs in folders where you accepted workspace trust; it is disabled by disableAllHooks, replaced under a managed allowManagedHooksOnly policy, and overridden by a project-level statusLine. Usage limits are shared with claude.ai and the desktop app, so a snapshot is accurate only when it was observed.",
            fix: "If a tracked profile never gets data, check those conditions in that project."
        ))
        return checks
    }

    private static func profileChecks(_ profile: Profile, input: DiagnosticsInput) -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        let prefix = "profile-\(profile.id.uuidString)"
        if let auth = input.authStatuses[profile.id] {
            checks.append(DiagnosticCheck(
                id: "\(prefix)-auth", title: "Sign-in", status: auth.signedIn ? .pass : .warn,
                detail: auth.signedIn ? "Signed in (\(auth.authMethodLabel))." : "Signed out.",
                fix: auth.signedIn ? nil : "Open the profile, choose Sign In / Verify, then run /login.", profileName: profile.name
            ))
            if auth.signedIn, !auth.reportsUsage {
                checks.append(DiagnosticCheck(
                    id: "\(prefix)-method", title: "Sign-in method", status: .warn,
                    detail: "Using \(auth.authMethodLabel). An exported API key, auth token, OAuth token or apiKeyHelper overrides /login, and usage windows are not reported.",
                    fix: "Remove the overriding variable or apiKeyHelper, then sign in with /login.", profileName: profile.name
                ))
            }
            if let reported = auth.configDirectory {
                let ok = Paths.canonical(reported) == Paths.canonical(profile.configDir)
                checks.append(DiagnosticCheck(
                    id: "\(prefix)-isolation", title: "Config isolation", status: ok ? .pass : .fail,
                    detail: ok ? "Claude Code uses \(reported)." : "Claude Code reports \(reported), expected \(profile.configDir).",
                    fix: ok ? nil : "Check for a global CLAUDE_CONFIG_DIR export or a wrapper script around claude.", profileName: profile.name
                ))
            }
        } else {
            checks.append(DiagnosticCheck(
                id: "\(prefix)-auth", title: "Sign-in", status: input.authErrors[profile.id] == nil ? .info : .warn,
                detail: input.authErrors[profile.id] ?? "Not checked yet.",
                fix: "Choose Refresh Sign-In Status on the Overview page.", profileName: profile.name
            ))
        }
        let tracking = input.trackingStates[profile.id] ?? .disabled
        checks.append(DiagnosticCheck(
            id: "\(prefix)-tracking", title: "Usage tracking",
            status: tracking == .overridden ? .warn : (tracking == .enabled ? .pass : .info),
            detail: tracking == .overridden
                ? "statusLine in settings.json no longer points to the collector (for example after /statusline)."
                : "Tracking \(tracking.label.lowercased()).",
            fix: tracking == .overridden ? "Open the profile, then choose Re-enable under Usage Tracking." : nil, profileName: profile.name
        ))
        return checks
    }
}
