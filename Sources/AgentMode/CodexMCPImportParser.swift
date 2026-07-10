import Foundation

enum CodexMCPImportParser {
    private struct TableContext {
        let serverName: String
        let nestedField: String?
    }

    static func parse(_ text: String) throws -> [(String, ACPJSON)] {
        var servers: [String: [String: ACPJSON]] = [:]
        var context: TableContext?

        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                context = try tableContext(line)
                continue
            }
            guard let context else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ProjectCapabilityValidationError(
                    "Malformed Codex MCP import"
                )
            }
            let key = canonicalKey(parts[0])
            let value = try parseValue(parts[1])
            if let nestedField = context.nestedField {
                guard case .string = value else {
                    throw ProjectCapabilityValidationError(
                        "Malformed Codex MCP table: \(nestedField)"
                    )
                }
                var object = servers[context.serverName]?[nestedField]?
                    .objectValue ?? [:]
                object[key] = value
                servers[context.serverName, default: [:]][nestedField] =
                    .object(object)
            } else {
                servers[context.serverName, default: [:]][key] = value
            }
        }

        return try servers.keys.sorted().map { name in
            let value = ACPJSON.object(servers[name] ?? [:])
            guard ProjectCapabilityMCPResolver
                .isValidConfiguration(value) else {
                throw ProjectCapabilityValidationError(
                    "Malformed Codex MCP import: \(name)"
                )
            }
            return (name, value)
        }
    }

    private static func tableContext(_ line: String) throws -> TableContext? {
        let body = String(line.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("mcp_servers.") else { return nil }
        let raw = String(body.dropFirst("mcp_servers.".count))
        let components = try dottedComponents(raw)
        guard let name = components.first,
              !name.isEmpty,
              components.count <= 2 else {
            throw ProjectCapabilityValidationError(
                "Unsupported Codex MCP table: \(body)"
            )
        }
        let nested = components.dropFirst().first.map(canonicalKey)
        if let nested, nested != "env", nested != "headers" {
            throw ProjectCapabilityValidationError(
                "Unsupported Codex MCP table: \(body)"
            )
        }
        return TableContext(serverName: name, nestedField: nested)
    }

    private static func dottedComponents(_ raw: String) throws -> [String] {
        var components: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quoted {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                continue
            }
            if character == ".", !quoted {
                components.append(try tableComponent(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP table"
            )
        }
        components.append(try tableComponent(current))
        return components
    }

    private static func tableComponent(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP table"
            )
        }
        return value.hasPrefix("\"") ? try string(value) : value
    }

    private static func parseValue(_ raw: String) throws -> ACPJSON {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") { return .string(try string(value)) }
        if value.hasPrefix("[") {
            return .array(try simpleArray(value))
        }
        if value.hasPrefix("{") {
            return .object(try inlineTable(value))
        }
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if let integer = Int(value) { return .int(integer) }
        if let double = Double(value) { return .double(double) }
        throw ProjectCapabilityValidationError(
            "Unsupported Codex MCP value: \(value)"
        )
    }

    private static func simpleArray(_ raw: String) throws -> [ACPJSON] {
        guard raw.first == "[", raw.last == "]" else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP array"
            )
        }
        let body = String(raw.dropFirst().dropLast())
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return try splitTopLevel(body).map(parseValue)
    }

    private static func inlineTable(_ raw: String) throws -> [String: ACPJSON] {
        guard raw.first == "{", raw.last == "}" else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP table"
            )
        }
        let body = String(raw.dropFirst().dropLast())
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return [:] }
        var object: [String: ACPJSON] = [:]
        for entry in try splitTopLevel(body) {
            let parts = entry.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ProjectCapabilityValidationError(
                    "Malformed Codex MCP inline table"
                )
            }
            let key = parts[0].hasPrefix("\"")
                ? try string(parts[0]) : parts[0]
            let value = try parseValue(parts[1])
            guard case .string = value else {
                throw ProjectCapabilityValidationError(
                    "Unsupported Codex MCP inline table value"
                )
            }
            object[key] = value
        }
        return object
    }

    private static func splitTopLevel(_ raw: String) throws -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var depth = 0
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quoted {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                continue
            }
            if !quoted {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == ",", depth == 0 {
                    values.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        guard !quoted, depth == 0 else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP value"
            )
        }
        values.append(current.trimmingCharacters(in: .whitespaces))
        return values
    }

    private static func string(_ raw: String) throws -> String {
        guard raw.count >= 2,
              raw.first == "\"",
              raw.last == "\"" else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP string"
            )
        }
        let data = Data("[\(raw)]".utf8)
        guard let values = try JSONSerialization.jsonObject(with: data)
                as? [String],
              let value = values.first else {
            throw ProjectCapabilityValidationError(
                "Malformed Codex MCP string"
            )
        }
        return value
    }

    private static func canonicalKey(_ key: String) -> String {
        switch key {
        case "http_headers": return "headers"
        default: return key
        }
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quoted {
                escaped = true
                continue
            }
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character == "#", !quoted {
                return String(line[..<index])
            }
        }
        return line
    }
}
