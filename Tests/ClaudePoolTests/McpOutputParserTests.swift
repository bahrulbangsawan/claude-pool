import Foundation
import Testing
@testable import ClaudePool

/// `claude mcp list` / `get` output as printed by Claude Code 2.1.309.
struct McpOutputParserTests {
    static let listOutput = """
    Checking MCP server health…

    claude.ai Claude Docs: https://api.anthropic.example/v1/pages/mcp - ✔ Connected
    claude.ai Mobbin: https://api.mobbin.com/mcp - ! Needs authentication
    plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ! Needs authentication
    plugin:engineering:linear: https://mcp.linear.app/mcp (HTTP) - ! Needs authentication
    plugin:engineering:google calendar:  (HTTP) - - Not configured
    cap: cap mcp serve - ✔ Connected
    cloudflare-api: https://mcp.cloudflare.com/mcp (HTTP) - ! Needs authentication
    keyed: https://user:pass@example.com/mcp?apiKey=sk-secret#frag (SSE) - ✔ Connected
    pencil: /Applications/Pen.app/Contents/Resources/mcp-server-darwin-arm64 --app desktop - ✘ Failed to connect — ENOENT: no such file or directory, posix_spawn '/Applications/Pen.app/x'
    rea: npx -y rea-agents@6.3.0 --token abc - ✘ Failed to connect — MCP server "rea" connection timed out after 30000ms
    approve: https://example.com/mcp (HTTP) - ⏸ Pending approval
    """

    @Test func parsesEveryKindOfLine() {
        let servers = McpOutputParser.parseList(Self.listOutput)
        #expect(servers.map(\.name) == [
            "claude.ai Claude Docs", "claude.ai Mobbin", "plugin:figma:figma", "plugin:engineering:linear",
            "plugin:engineering:google calendar", "cap", "cloudflare-api", "keyed", "pencil", "rea", "approve",
        ])
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })

        #expect(byName["claude.ai Mobbin"]?.kind == .connector)
        #expect(byName["claude.ai Mobbin"]?.health == .needsSignIn)
        #expect(byName["claude.ai Mobbin"]?.displayName == "Mobbin")
        #expect(byName["claude.ai Mobbin"]?.supportsSignIn == true)
        #expect(byName["claude.ai Mobbin"]?.supportsSignOut == false)

        let linear = byName["plugin:engineering:linear"]
        #expect(linear?.kind == .plugin)
        #expect(linear?.transport == "HTTP")
        #expect(linear?.target == "https://mcp.linear.app/mcp")
        #expect(linear?.displayName == "linear")
        #expect(McpServer.pluginName(for: "plugin:engineering:linear") == "engineering")
        #expect(linear?.isRemovable == false)

        let calendar = byName["plugin:engineering:google calendar"]
        #expect(calendar?.health == .notConfigured)
        #expect(calendar?.target == "")
        #expect(calendar?.supportsSignIn == false)

        let cap = byName["cap"]
        #expect(cap?.kind == .local)
        #expect(cap?.target == "cap")
        #expect(cap?.health == .connected)
        #expect(cap?.supportsSignIn == false)
        #expect(cap?.isRemovable == true)

        let cloudflare = byName["cloudflare-api"]
        #expect(cloudflare?.kind == .remote)
        #expect(cloudflare?.supportsSignIn == true)
        #expect(cloudflare?.supportsSignOut == true)

        #expect(byName["approve"]?.health == .pendingApproval)
    }

    @Test func neverKeepsKeysFromAddressesOrArguments() {
        let servers = McpOutputParser.parseList(Self.listOutput)
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        #expect(byName["keyed"]?.target == "https://example.com/mcp")
        #expect(byName["keyed"]?.transport == "SSE")
        #expect(byName["rea"]?.target == "npx")
        #expect(byName["pencil"]?.target == "mcp-server-darwin-arm64")
        for server in servers {
            #expect(!server.target.contains("secret") && !server.target.contains("abc") && !server.target.contains("pass"))
        }
    }

    @Test func failureReasonsAreKept() {
        let servers = McpOutputParser.parseList(Self.listOutput)
        let rea = servers.first { $0.name == "rea" }
        #expect(rea?.health == .failed("MCP server \"rea\" connection timed out after 30000ms"))
        #expect(McpOutputParser.health(fromStatus: "✘ Failed to connect") == .failed(nil))
        #expect(McpOutputParser.health(fromStatus: "✘ Failed to connect — https://x.example/a?token=1 refused")
                == .failed("https://x.example/a refused"))
    }

    @Test func ignoresNoiseAndEmptyOutput() {
        #expect(McpOutputParser.parseList("").isEmpty)
        #expect(McpOutputParser.parseList("No MCP servers configured. Use `claude mcp add` to add a server.").isEmpty)
        #expect(McpOutputParser.parseListLine("Checking MCP server health…") == nil)
        // A dash inside the command is not the status separator.
        let line = McpOutputParser.parseListLine("tool: my-tool - x --flag - ✔ Connected")
        #expect(line?.target == "my-tool")
        #expect(line?.health == .connected)
    }

    @Test func parsesGet() {
        let remote = """
        cloudflare-api:
          Scope: User config (available in all your projects)
          Status: ! Needs authentication
          Type: http
          URL: https://mcp.cloudflare.com/mcp?k=v

        To remove this server, run: claude mcp remove cloudflare-api -s user
        """
        let server = McpOutputParser.parseGet(remote, name: "cloudflare-api")
        #expect(server?.health == .needsSignIn)
        #expect(server?.transport == "HTTP")
        #expect(server?.target == "https://mcp.cloudflare.com/mcp")
        #expect(server?.kind == .remote)

        let local = """
        cap:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
          Type: stdio
          Command: cap
          Args: mcp serve --key hidden
        """
        let cap = McpOutputParser.parseGet(local, name: "cap")
        #expect(cap?.health == .connected)
        #expect(cap?.kind == .local)
        #expect(cap?.target == "cap")

        let connector = "claude.ai Claude Docs:\n  Scope: claude.ai config\n  Status: ✔ Connected\n"
        #expect(McpOutputParser.parseGet(connector, name: "claude.ai Claude Docs")?.kind == .connector)
        #expect(McpOutputParser.parseGet("No MCP server named \"x\".", name: "x") == nil)
    }
}

struct McpCatalogTests {
    @Test func namesAndAddresses() {
        #expect(McpCatalog.isValidName("cloudflare-api"))
        #expect(McpCatalog.isValidName("whatsapp_business_tools"))
        #expect(!McpCatalog.isValidName(""))
        #expect(!McpCatalog.isValidName("has space"))
        #expect(!McpCatalog.isValidName("plugin:x"))
        #expect(!McpCatalog.isValidName("é"))

        #expect(McpCatalog.isValidURL("https://mcp.neon.tech/mcp"))
        #expect(McpCatalog.isValidURL("https://aws-mcp.us-east-1.api.aws/mcp?oauth=initialize"))
        #expect(McpCatalog.isValidURL("http://127.0.0.1:47613/mcp"))
        #expect(!McpCatalog.isValidURL("http://example.com/mcp"))
        #expect(!McpCatalog.isValidURL("ftp://example.com"))
        #expect(!McpCatalog.isValidURL("https:// example.com"))
        #expect(!McpCatalog.isValidURL("mcp.neon.tech"))
    }

    @Test func presetsAreValid() {
        #expect(Set(McpCatalog.presets.map(\.id)).count == McpCatalog.presets.count)
        for preset in McpCatalog.presets {
            #expect(McpCatalog.isValidName(preset.id), "\(preset.id)")
            #expect(McpCatalog.isValidURL(preset.url(region: preset.defaultRegion)), "\(preset.id)")
            #expect(!preset.url(region: preset.defaultRegion).contains("{"), "\(preset.id)")
        }
        let aws = McpCatalog.presets.first { $0.id == "aws-mcp" }
        #expect(aws?.url(region: "eu-west-1") == "https://aws-mcp.eu-west-1.api.aws/mcp")
    }

    @Test func sameEndpointIgnoresQueryAndSlash() {
        #expect(McpCatalog.sameEndpoint("https://mcp.neon.tech/mcp/", "https://MCP.neon.tech/mcp?x=1"))
        #expect(!McpCatalog.sameEndpoint("https://mcp.neon.tech/mcp", "https://mcp.neon.tech/sse"))
        #expect(!McpCatalog.sameEndpoint("", ""))
    }
}

@MainActor
struct McpStoreTests {
    private func profile(_ name: String, index: Int) -> Profile {
        Profile(id: UUID(), name: name, slug: name.lowercased(), configDir: "/tmp/\(name)", colorHex: "#0A84FF", isDefault: index == 0,
                trackingEnabled: false, originalStatusLine: nil, sortIndex: index, createdAt: Date())
    }

    @Test func rowsMergeProfilesAndListPendingSignIns() {
        let store = McpStore(service: McpService(home: URL(fileURLWithPath: "/tmp"), loginShell: "/bin/zsh"))
        let work = profile("Work", index: 0), personal = profile("Personal", index: 1)
        let neon = { (health: McpServer.Health) in McpServer(name: "neon", target: "https://mcp.neon.tech/mcp", transport: "HTTP", health: health) }
        let cap = McpServer(name: "cap", target: "cap", transport: nil, health: .connected)
        store.record([neon(.connected), cap], for: work.id)
        // A connector waiting for a sign-in is not part of "Sign In to All".
        store.record([neon(.needsSignIn), McpServer(name: "claude.ai Slack", target: "https://mcp.slack.com/mcp", transport: nil, health: .needsSignIn)],
                     for: personal.id)

        let rows = store.rows(for: [work, personal])
        #expect(rows.map(\.name) == ["cap", "neon", "claude.ai Slack"])
        #expect(rows[1].profilesNeedingSignIn([work, personal]).map(\.name) == ["Personal"])
        #expect(rows[1].profilesSignedIn([work, personal]).map(\.name) == ["Work"])
        #expect(rows[2].profilesNeedingSignIn([work, personal]).map(\.name) == ["Personal"])
        #expect(rows[0].entry(for: personal) == nil)
        #expect(store.pendingSignIns(for: [work, personal]) == [McpSignInStep(profile: personal, serverName: "neon")])
        #expect(store.hasServer(named: "other", orURL: "https://mcp.neon.tech/mcp/"))
        #expect(!store.hasServer(named: "other", orURL: "https://example.com/mcp"))

        store.apply(neon(.connected), named: "neon", for: personal.id)
        #expect(store.pendingSignIns(for: [work, personal]).isEmpty)
        store.apply(nil, named: "neon", for: personal.id)
        #expect(store.entry("neon", for: personal.id) == nil)
        store.forget(work.id)
        #expect(store.rows(for: [work, personal]).map(\.name) == ["claude.ai Slack"])
    }
}
