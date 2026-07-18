import Foundation

/// Translates the plugin-internal MCP server representation into the Claude Code
/// project-scope `.mcp.json` format.
///
/// Reference: https://code.claude.com/docs/en/mcp (Project scope)
/// - stdio: `command` is a STRING, `args` an optional string array, `type` may be
///   omitted (an entry with no `type` is read as stdio); we emit it explicitly.
/// - remote: `type` is `"http"` (alias `"streamable-http"`), `"sse"`, or `"ws"`,
///   and `url` is required; `headers` is an optional string map.
/// - Claude Code has no per-server `enabled` switch and no `"local"` transport;
///   internal-only keys (`enabled`, `transport`, `cwd`, `args` on remote) must
///   never leak into the rendered file. Disabled servers are filtered by the
///   caller via `isEnabled` because exclusion is the only faithful mapping.
enum ClaudeCodeMCPServerProjection {
    enum ProjectionError: Error, Equatable {
        case notAnObject(String)
        case invalidCommand(String)
        case conflictingURL(String)
        case missingURL(String)
        case invalidURL(String)
        case unsupportedTransport(String)
        case invalidEnv(String)
        case invalidHeaders(String)
    }

    static func isEnabled(_ value: ACPJSON) -> Bool {
        guard case .bool(let enabled) = value.objectValue?["enabled"] else { return true }
        return enabled
    }

    static func serverJSON(name: String, value: ACPJSON) throws -> ACPJSON {
        guard let object = value.objectValue else { throw ProjectionError.notAnObject(name) }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        let url = object["url"]?.stringValue
        switch transport {
        case "local", "stdio":
            return .object(try stdioServer(name: name, url: url, object: object))
        case "http", "streamable-http":
            return .object(try remoteServer(name: name, type: "http", url: url, object: object))
        case "sse", "ws":
            return .object(try remoteServer(name: name, type: transport ?? "http", url: url, object: object))
        case nil:
            return url == nil
                ? .object(try stdioServer(name: name, url: nil, object: object))
                : .object(try remoteServer(name: name, type: "http", url: url, object: object))
        default:
            throw ProjectionError.unsupportedTransport(name)
        }
    }

    private static func stdioServer(name: String, url: String?, object: [String: ACPJSON]) throws -> [String: ACPJSON] {
        guard url == nil else { throw ProjectionError.conflictingURL(name) }
        guard let parts = ProjectCapabilityMCPResolver.commandParts(for: .object(object)),
              let command = parts.first else {
            throw ProjectionError.invalidCommand(name)
        }
        var server: [String: ACPJSON] = [
            "type": .string("stdio"),
            "command": .string(command),
        ]
        let args = parts.dropFirst()
        if !args.isEmpty { server["args"] = .array(args.map(ACPJSON.string)) }
        if let env = object["env"] {
            guard let values = env.objectValue, values.values.allSatisfy({ $0.stringValue != nil }) else {
                throw ProjectionError.invalidEnv(name)
            }
            if !values.isEmpty { server["env"] = env }
        }
        return server
    }

    private static func remoteServer(name: String, type: String, url: String?, object: [String: ACPJSON]) throws -> [String: ACPJSON] {
        guard let url else { throw ProjectionError.missingURL(name) }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            throw ProjectionError.invalidURL(name)
        }
        var server: [String: ACPJSON] = [
            "type": .string(type),
            "url": .string(url),
        ]
        if let headers = object["headers"] {
            guard let values = headers.objectValue, values.values.allSatisfy({ $0.stringValue != nil }) else {
                throw ProjectionError.invalidHeaders(name)
            }
            if !values.isEmpty { server["headers"] = headers }
        }
        return server
    }
}
