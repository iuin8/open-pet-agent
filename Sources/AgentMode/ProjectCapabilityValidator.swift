import Foundation

public struct ProjectCapabilityValidator: Sendable {
    public init() {}

    public func validate(project: AgentProject, catalog: ProjectPluginCatalog = ProjectPluginCatalog()) throws -> [ProjectConfigDiagnostic] {
        let plugins = try catalog.listPlugins(for: project)
        var diagnostics = plugins.flatMap { catalog.validate($0) }
        var skillIDs = Set<String>()
        var reportedSkillIDs = Set<String>()
        var mcpIDs = Set<String>()
        var reportedMCPIDs = Set<String>()

        for plugin in plugins {
            for ref in plugin.skills {
                let id = "\(plugin.id):\(ref)"
                if !skillIDs.insert(id).inserted, reportedSkillIDs.insert(id).inserted {
                    diagnostics.append(.error("Duplicate skill id: \(id)", path: plugin.rootURL.path))
                }
                validateSkill(ref, plugin: plugin, diagnostics: &diagnostics)
            }

            for ref in plugin.mcp {
                validateMCP(ref, plugin: plugin, seenIDs: &mcpIDs, reportedIDs: &reportedMCPIDs, diagnostics: &diagnostics)
            }
        }
        return diagnostics
    }

    private func validateSkill(_ ref: String, plugin: ProjectPluginDescriptor, diagnostics: inout [ProjectConfigDiagnostic]) {
        let pluginRoot = plugin.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalRoot = plugin.rootURL.appendingPathComponent("skills", isDirectory: true).standardizedFileURL
        let lexicalURL = plugin.rootURL.appendingPathComponent(ref, isDirectory: true).standardizedFileURL
        let escapeMessage = "Skill reference escapes plugin: \(ref)"
        guard ProjectionTrust.isPath(lexicalURL, inside: lexicalRoot) else {
            diagnostics.append(.error(escapeMessage, path: plugin.rootURL.path))
            return
        }

        if FileManager.default.fileExists(atPath: lexicalRoot.path) {
            let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolvedRoot, inside: pluginRoot) else {
                diagnostics.append(.error(escapeMessage, path: plugin.rootURL.path))
                return
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexicalURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            diagnostics.append(.error("Missing skill: \(ref)", path: lexicalURL.path))
            return
        }

        do {
            let url = try ProjectCapabilityPath.containedURL(ref: ref, subdirectory: "skills", plugin: plugin, isDirectory: true) { escapeMessage }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
                diagnostics.append(.error("Missing skill: \(ref)", path: url.path))
                return
            }
        } catch let error as ProjectCapabilityValidationError {
            diagnostics.append(.error(error.message, path: plugin.rootURL.path))
        } catch {
            diagnostics.append(.error("Missing skill: \(ref)", path: plugin.rootURL.path))
        }
    }

    private func validateMCP(_ ref: String, plugin: ProjectPluginDescriptor, seenIDs: inout Set<String>, reportedIDs: inout Set<String>, diagnostics: inout [ProjectConfigDiagnostic]) {
        do {
            let resolved = try ProjectCapabilityMCPResolver.resolve(ref, plugin: plugin)
            let id = "\(plugin.id):\(resolved.name)"
            if !seenIDs.insert(id).inserted, reportedIDs.insert(id).inserted {
                diagnostics.append(.error("Duplicate MCP server id: \(id)", path: plugin.rootURL.path))
            }
            if !ProjectCapabilityMCPResolver.isValidConfiguration(resolved.value) {
                if ProjectCapabilityMCPHealth.hasMalformedRemoteURL(resolved.value) {
                    diagnostics.append(contentsOf: ProjectCapabilityMCPHealth.diagnostics(name: resolved.name, value: resolved.value, pluginRoot: plugin.rootURL))
                } else {
                    diagnostics.append(.error("Malformed MCP command: \(resolved.name)", path: plugin.rootURL.path))
                }
            } else {
                diagnostics.append(contentsOf: ProjectCapabilityMCPHealth.diagnostics(name: resolved.name, value: resolved.value, pluginRoot: plugin.rootURL))
            }
        } catch let error as ProjectCapabilityValidationError {
            diagnostics.append(mcpDiagnostic(for: error.message, path: plugin.rootURL.path))
        } catch {
            diagnostics.append(.error("Malformed MCP reference: \(ref)", path: plugin.rootURL.path))
        }
    }

    private func mcpDiagnostic(for message: String, path: String?) -> ProjectConfigDiagnostic {
        let isRecoverableInputProblem = message.hasPrefix("Missing MCP server:")
            || message.hasPrefix("Missing MCP server file:")
        return ProjectConfigDiagnostic(
            severity: isRecoverableInputProblem ? .warning : .error,
            message: message,
            path: path
        )
    }
}

enum ProjectCapabilityMCPResolver {
    static func resolve(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (name: String, value: ACPJSON) {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ProjectCapabilityValidationError("Malformed MCP reference: \(ref)") }
        let fileURL = try ProjectCapabilityPath.containedURL(ref: parts[0], subdirectory: "mcp", plugin: plugin, isDirectory: false) {
            "MCP reference escapes plugin: \(ref)"
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProjectCapabilityValidationError("Missing MCP server file: \(ref)")
        }
        guard let object = try JSONDecoder().decode(ACPJSON.self, from: data).objectValue,
              let servers = object["mcpServers"]?.objectValue else {
            throw ProjectCapabilityValidationError("Malformed MCP server file: \(ref)")
        }
        let name = parts[1]
        guard let server = servers[name] else {
            throw ProjectCapabilityValidationError("Missing MCP server: \(name)")
        }
        guard server.objectValue != nil else {
            throw ProjectCapabilityValidationError("Malformed MCP command: \(name)")
        }
        return (name, server)
    }

    static func commandParts(for server: ACPJSON) -> [String]? {
        guard let object = server.objectValue else { return nil }
        var parts: [String]
        if let command = object["command"]?.stringValue, !command.isEmpty {
            parts = [command]
        } else if let command = object["command"]?.arrayValue {
            parts = command.compactMap(\.stringValue)
            guard parts.count == command.count, !parts.isEmpty else { return nil }
        } else {
            return nil
        }
        if let args = object["args"] {
            guard let array = args.arrayValue else { return nil }
            let values = array.compactMap(\.stringValue)
            guard values.count == array.count else { return nil }
            parts.append(contentsOf: values)
        }
        return parts
    }

    static func isValidConfiguration(_ server: ACPJSON) -> Bool {
        guard let object = server.objectValue else { return false }
        let transport = object["type"]?.stringValue ?? object["transport"]?.stringValue
        let validTransport: Bool
        switch transport {
        case "local", "stdio":
            validTransport = object["url"] == nil && commandParts(for: server) != nil
        case nil:
            validTransport = object["url"] == nil
                ? commandParts(for: server) != nil
                : validRemoteURL(object["url"]?.stringValue)
        case "http", "sse":
            validTransport = validRemoteURL(object["url"]?.stringValue)
        default:
            return false
        }
        guard validTransport else { return false }
        if let env = object["env"] {
            guard let values = env.objectValue,
                  values.values.allSatisfy({ $0.stringValue != nil }) else { return false }
        }
        if let cwd = object["cwd"], cwd.stringValue == nil { return false }
        return true
    }

    static func validRemoteURL(_ raw: String?) -> Bool {
        guard let raw,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum ProjectCapabilityPath {
    static func containedURL(ref: String, subdirectory: String, plugin: ProjectPluginDescriptor, isDirectory: Bool, escapeMessage: () -> String) throws -> URL {
        let pluginRoot = plugin.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalRoot = plugin.rootURL.appendingPathComponent(subdirectory, isDirectory: true).standardizedFileURL
        let lexicalURL = plugin.rootURL.appendingPathComponent(ref, isDirectory: isDirectory).standardizedFileURL
        guard ProjectionTrust.isPath(lexicalURL, inside: lexicalRoot) else {
            throw ProjectCapabilityValidationError(escapeMessage())
        }
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedRoot, inside: pluginRoot) else {
            throw ProjectCapabilityValidationError(escapeMessage())
        }
        let resolvedURL = lexicalURL.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedURL, inside: resolvedRoot) else {
            throw ProjectCapabilityValidationError(escapeMessage())
        }
        return resolvedURL
    }
}

struct ProjectCapabilityValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

extension ProjectConfigDiagnostic {
    static func error(_ message: String, path: String?) -> ProjectConfigDiagnostic {
        ProjectConfigDiagnostic(severity: .error, message: message, path: path)
    }

    static func warning(_ message: String, path: String?) -> ProjectConfigDiagnostic {
        ProjectConfigDiagnostic(severity: .warning, message: message, path: path)
    }
}
