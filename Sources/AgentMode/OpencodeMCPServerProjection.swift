import Foundation

/// Translates the plugin-internal MCP server representation into the opencode
/// `opencode.json` `mcp` format (official schema: https://opencode.ai/config.json).
///
/// - local:  `{ "type": "local", "command": ["cmd", "arg", ...], "environment": {...}, "enabled": bool }`
/// - remote: `{ "type": "remote", "url": "https://...", "headers": {...}, "enabled": bool }`
///
/// Internal-only keys (`env`, `args`, `transport`, `cwd`) and the
/// `stdio`/`http`/`sse` transport spellings must not leak; opencode has no `ws`
/// transport. Unlike Claude Code, opencode DOES understand per-server
/// `enabled`, so it is preserved verbatim instead of being dropped.
enum OpencodeMCPServerProjection {
    enum ProjectionError: Error, Equatable {
        case notAnObject(String)
        case invalidCommand(String)
        case conflictingURL(String)
        case missingURL(String)
        case invalidURL(String)
        case unsupportedTransport(String)
        case invalidEnvironment(String)
        case invalidHeaders(String)
    }

    static func serverJSON(name: String, value: ACPJSON) throws -> ACPJSON {
        guard let object = value.objectValue else { throw ProjectionError.notAnObject(name) }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        let url = object["url"]?.stringValue
        switch transport {
        case "local", "stdio":
            return .object(try localServer(name: name, url: url, object: object))
        case "remote", "http", "sse", "streamable-http":
            return .object(try remoteServer(name: name, url: url, object: object))
        case nil:
            return url == nil
                ? .object(try localServer(name: name, url: nil, object: object))
                : .object(try remoteServer(name: name, url: url, object: object))
        default:
            throw ProjectionError.unsupportedTransport(name)
        }
    }

    private static func localServer(name: String, url: String?, object: [String: ACPJSON]) throws -> [String: ACPJSON] {
        guard url == nil else { throw ProjectionError.conflictingURL(name) }
        guard let parts = ProjectCapabilityMCPResolver.commandParts(for: .object(object)),
              !parts.isEmpty else {
            throw ProjectionError.invalidCommand(name)
        }
        var server: [String: ACPJSON] = [
            "type": .string("local"),
            "command": .array(parts.map(ACPJSON.string)),
        ]
        if let environment = try environmentMap(name: name, object: object), !environment.isEmpty {
            server["environment"] = .object(environment)
        }
        if let enabled = object["enabled"], case .bool = enabled {
            server["enabled"] = enabled
        }
        return server
    }

    private static func remoteServer(name: String, url: String?, object: [String: ACPJSON]) throws -> [String: ACPJSON] {
        guard let url else { throw ProjectionError.missingURL(name) }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            throw ProjectionError.invalidURL(name)
        }
        var server: [String: ACPJSON] = [
            "type": .string("remote"),
            "url": .string(url),
        ]
        if let headers = object["headers"] {
            guard let values = headers.objectValue, values.values.allSatisfy({ $0.stringValue != nil }) else {
                throw ProjectionError.invalidHeaders(name)
            }
            if !values.isEmpty { server["headers"] = headers }
        }
        if let enabled = object["enabled"], case .bool = enabled {
            server["enabled"] = enabled
        }
        return server
    }

    /// opencode calls the env map `environment`; entries imported from an
    /// existing opencode.json may already carry that key — prefer it over the
    /// internal `env` spelling.
    private static func environmentMap(name: String, object: [String: ACPJSON]) throws -> [String: ACPJSON]? {
        guard let source = object["environment"] ?? object["env"] else { return nil }
        guard let values = source.objectValue, values.values.allSatisfy({ $0.stringValue != nil }) else {
            throw ProjectionError.invalidEnvironment(name)
        }
        return values
    }
}
