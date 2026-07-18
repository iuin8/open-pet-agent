import Foundation

/// Translates the plugin-internal MCP server representation into the ACP v1
/// `session/new` `mcpServers` wire format.
///
/// Reference: https://agentclientprotocol.com/protocol/session-setup and
/// schema/v1/schema.json (agentclientprotocol/agent-client-protocol).
/// - stdio (NO `type` field): `{ name, command: string, args: [string], env: [{name, value}] }`
/// - http/sse: `{ name, type: "http"|"sse", url, headers: [{name, value}] }`
/// `args`/`env`/`headers` are required by the schema (empty arrays allowed) —
/// strict agents (opencode ≥ 1.17 via @agentclientprotocol/sdk zod) answer
/// -32602 when they are missing or shaped as maps. Internal-only keys
/// (`enabled`, `transport`, `cwd`) never leak; ACP has no per-server `enabled`,
/// so disabled servers are excluded by the caller.
enum ACPMCPServerProjection {
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

    static func serverJSON(name: String, value: ACPJSON) throws -> ACPJSON {
        guard let object = value.objectValue else { throw ProjectionError.notAnObject(name) }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        let url = object["url"]?.stringValue
        switch transport {
        case "local", "stdio":
            return .object(try stdioServer(name: name, url: url, object: object))
        case "http", "streamable-http":
            return .object(try remoteServer(name: name, type: "http", url: url, object: object))
        case "sse":
            return .object(try remoteServer(name: name, type: "sse", url: url, object: object))
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
        return [
            "name": .string(name),
            "command": .string(command),
            "args": .array(parts.dropFirst().map(ACPJSON.string)),
            "env": .array(try namedValues(object["env"], error: { ProjectionError.invalidEnv(name) })),
        ]
    }

    private static func remoteServer(name: String, type: String, url: String?, object: [String: ACPJSON]) throws -> [String: ACPJSON] {
        guard let url else { throw ProjectionError.missingURL(name) }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            throw ProjectionError.invalidURL(name)
        }
        return [
            "name": .string(name),
            "type": .string(type),
            "url": .string(url),
            "headers": .array(try namedValues(object["headers"], error: { ProjectionError.invalidHeaders(name) })),
        ]
    }

    /// ACP v1 shapes `env`/`headers` as `[{name, value}]` arrays (empty allowed),
    /// sorted by key for deterministic output.
    private static func namedValues(_ value: ACPJSON?, error: () -> ProjectionError) throws -> [ACPJSON] {
        guard let value else { return [] }
        guard let map = value.objectValue else { throw error() }
        return try map.sorted { $0.key < $1.key }.map { key, item in
            guard let string = item.stringValue else { throw error() }
            return .object(["name": .string(key), "value": .string(string)])
        }
    }
}
