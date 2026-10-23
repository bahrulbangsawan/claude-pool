import Foundation

/// A remote MCP server that signs in through the browser, offered in Add Server so its address
/// doesn't have to be looked up. Every entry uses the provider's official hosted server.
struct McpPreset: Identifiable, Hashable, Sendable {
    /// Also the suggested server name.
    let id: String
    let title: String
    let summary: String
    /// The endpoint; `{region}` is replaced by the chosen region where `regions` is set.
    let url: String
    var transport: McpTransport = .http
    var note: String?
    var regions: [String] = []

    var defaultRegion: String? { regions.first }

    func url(region: String?) -> String {
        guard let region, !regions.isEmpty else { return url }
        return url.replacingOccurrences(of: "{region}", with: region)
    }
}

enum McpTransport: String, CaseIterable, Identifiable, Sendable {
    case http
    case sse

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum McpCatalog {
    static let presets: [McpPreset] = [
        McpPreset(id: "cloudflare-api", title: "Cloudflare",
                  summary: "The Cloudflare API: DNS, Workers, R2, D1 and the rest of your account.",
                  url: "https://mcp.cloudflare.com/mcp"),
        McpPreset(id: "aws-mcp", title: "AWS",
                  summary: "The AWS MCP Server: AWS APIs and documentation for your account.",
                  url: "https://aws-mcp.{region}.api.aws/mcp",
                  note: "Browser sign-in needs the AWSMCPSignInOAuthAccessPolicy managed policy on your IAM user or role.",
                  regions: ["us-east-1", "us-west-2", "eu-central-1", "eu-west-1", "eu-west-2",
                            "ap-southeast-1", "ap-southeast-2", "ap-northeast-1"]),
        McpPreset(id: "neon", title: "Neon",
                  summary: "Neon Postgres: projects, branches, schemas and queries.",
                  url: "https://mcp.neon.tech/mcp",
                  note: "Neon recommends its MCP server for development, not for production databases."),
        McpPreset(id: "polar", title: "Polar",
                  summary: "Polar: products, checkouts, customers and subscriptions.",
                  url: "https://mcp.polar.sh/mcp/polar-mcp"),
        McpPreset(id: "polar-sandbox", title: "Polar Sandbox",
                  summary: "The same Polar tools against the sandbox environment.",
                  url: "https://mcp.polar.sh/mcp/polar-sandbox"),
        McpPreset(id: "mobbin", title: "Mobbin",
                  summary: "Search real app screens and flows for design references.",
                  url: "https://api.mobbin.com/mcp"),
        McpPreset(id: "meta_social_technologies", title: "Meta Developer Tools",
                  summary: "Meta's hosted developer tools server.",
                  url: "https://mcp.facebook.com/devtools"),
        McpPreset(id: "whatsapp_business_tools", title: "WhatsApp Business",
                  summary: "WhatsApp Business tools from Meta.",
                  url: "https://mcp.facebook.com/whatsapp_business_tools"),
        McpPreset(id: "linear", title: "Linear",
                  summary: "Issues, projects and cycles in Linear.",
                  url: "https://mcp.linear.app/mcp"),
        McpPreset(id: "notion", title: "Notion",
                  summary: "Search, read and edit pages and databases in Notion.",
                  url: "https://mcp.notion.com/mcp"),
        McpPreset(id: "sentry", title: "Sentry",
                  summary: "Issues, events and releases in Sentry.",
                  url: "https://mcp.sentry.dev/mcp"),
    ]

    /// "Cloudflare" for a server added from the Cloudflare preset, else the server's own name.
    static func title(for serverName: String) -> String {
        presets.first { $0.id == serverName }?.title ?? McpServer.displayName(for: serverName)
    }

    /// Names `claude mcp add` accepts: letters, digits, "-" and "_".
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// https, or http only for this Mac (a server you run locally).
    static func isValidURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let host = components.host, !host.isEmpty, !text.contains(" ") else { return false }
        switch components.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        default: return false
        }
    }

    /// Two addresses name the same server when they match without query, fragment and trailing "/".
    static func sameEndpoint(_ a: String, _ b: String) -> Bool {
        func normalized(_ value: String) -> String {
            var text = McpOutputParser.displayURL(value.trimmingCharacters(in: .whitespaces)).lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return !a.isEmpty && normalized(a) == normalized(b)
    }
}
