import Foundation

public struct ProjectCapabilityWriter: Sendable {
    public init() {}

    public func updateSkillBody(project: AgentProject, pluginID: String, skillRef: String, body: String) throws {
        let plugin = try descriptor(project: project, pluginID: pluginID)
        let skillURL = try skillDirectory(skillRef, plugin: plugin)
        let skillFile = skillURL.appendingPathComponent("SKILL.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            throw ProjectCapabilityValidationError("Missing skill: \(skillRef)")
        }
        try Data(body.utf8).write(to: skillFile, options: .atomic)
    }

    public func upsertMCPServer(project: AgentProject, pluginID: String, fileRef: String, serverName: String, value: ACPJSON) throws {
        guard !serverName.isEmpty else {
            throw ProjectCapabilityValidationError("Missing MCP server name")
        }
        guard ProjectCapabilityMCPResolver.isValidConfiguration(value) else {
            throw ProjectCapabilityValidationError("Malformed MCP configuration: \(serverName)")
        }
        let plugin = try descriptor(project: project, pluginID: pluginID)
        let fileURL = try ProjectCapabilityPath.containedURL(ref: fileRef, subdirectory: "mcp", plugin: plugin, isDirectory: false) {
            "MCP reference escapes plugin: \(fileRef)#\(serverName)"
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root = try readJSONObject(fileURL)
        var servers = try mcpServers(in: root, fileURL: fileURL)
        servers[serverName] = value.jsonObject
        root["mcpServers"] = servers
        try writeJSONObject(root, to: fileURL)
        try updateManifest(project: project, pluginID: pluginID) { manifest in
            appendUnique(ProjectPluginCapability.mcp.rawValue, to: "capabilities", in: &manifest)
            appendUnique("\(fileRef)#\(serverName)", to: "mcp", in: &manifest)
        }
    }

    public func deleteMCPServer(project: AgentProject, pluginID: String, fileRef: String, serverName: String) throws {
        guard !serverName.isEmpty else {
            throw ProjectCapabilityValidationError("Missing MCP server name")
        }
        let plugin = try descriptor(project: project, pluginID: pluginID)
        let fileURL = try ProjectCapabilityPath.containedURL(ref: fileRef, subdirectory: "mcp", plugin: plugin, isDirectory: false) {
            "MCP reference escapes plugin: \(fileRef)#\(serverName)"
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProjectCapabilityValidationError("Missing MCP server file: \(fileRef)")
        }
        let manifestURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("plugin.json")
        let originalFile = try Data(contentsOf: fileURL)
        let originalManifest = try Data(contentsOf: manifestURL)
        var root = try readJSONObject(fileURL)
        var servers = try mcpServers(in: root, fileURL: fileURL)
        guard servers.removeValue(forKey: serverName) != nil else {
            throw ProjectCapabilityValidationError("Missing MCP server: \(serverName)")
        }
        try backup(project: project, plugin: plugin, including: fileURL)
        do {
            root["mcpServers"] = servers
            try writeJSONObject(root, to: fileURL)
            try updateManifest(project: project, pluginID: pluginID) { manifest in
                var mcp = manifest["mcp"] as? [String] ?? []
                mcp.removeAll { $0 == "\(fileRef)#\(serverName)" }
                manifest["mcp"] = mcp
            }
        } catch {
            try? originalFile.write(to: fileURL, options: .atomic)
            try? originalManifest.write(to: manifestURL, options: .atomic)
            throw error
        }
    }

    public func deleteSkill(project: AgentProject, pluginID: String, skillRef: String) throws {
        let plugin = try descriptor(project: project, pluginID: pluginID)
        let skillURL = try deletableSkillDirectory(skillRef, plugin: plugin)
        try backup(project: project, plugin: plugin, including: skillURL)
        try FileManager.default.removeItem(at: skillURL)
        try updateManifest(project: project, pluginID: pluginID) { manifest in
            var skills = manifest["skills"] as? [String] ?? []
            skills.removeAll { $0 == skillRef }
            manifest["skills"] = skills
        }
    }

    private func descriptor(project: AgentProject, pluginID: String) throws -> ProjectPluginDescriptor {
        try validatePluginID(pluginID)
        let pluginRoot = ProjectConfig.pluginRoot(for: project)
        let pluginURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).standardizedFileURL
        guard ProjectionTrust.isPath(pluginURL, inside: pluginRoot),
              ProjectionTrust.isPath(pluginURL.resolvingSymlinksInPath(), inside: pluginRoot.resolvingSymlinksInPath()) else {
            throw ProjectCapabilityValidationError("Invalid plugin id: \(pluginID)")
        }
        let manifest = try readJSONObject(pluginURL.appendingPathComponent("plugin.json"))
        guard manifest["id"] as? String == pluginID else {
            throw ProjectCapabilityValidationError("Invalid plugin manifest: \(pluginID)")
        }
        return ProjectPluginDescriptor(
            id: pluginID,
            name: manifest["name"] as? String ?? pluginID,
            version: manifest["version"] as? String,
            enabled: manifest["enabled"] as? Bool ?? false,
            capabilities: capabilities(in: manifest),
            unknownCapabilities: unknownCapabilities(in: manifest),
            executableCapabilities: ProjectExecutableCapabilities(),
            rootURL: pluginURL,
            mcp: manifest["mcp"] as? [String] ?? [],
            skills: manifest["skills"] as? [String] ?? [],
            prompts: manifest["prompts"] as? [String] ?? [],
            enginePolicies: enginePolicies(in: manifest)
        )
    }

    private func skillDirectory(_ ref: String, plugin: ProjectPluginDescriptor) throws -> URL {
        try validateNestedRef(ref, subdirectory: "skills", plugin: plugin)
        let url = try ProjectCapabilityPath.containedURL(ref: ref, subdirectory: "skills", plugin: plugin, isDirectory: true) {
            "Skill reference escapes plugin: \(ref)"
        }
        try validateExistingDirectory(url, ref: ref)
        return url
    }

    private func deletableSkillDirectory(_ ref: String, plugin: ProjectPluginDescriptor) throws -> URL {
        try validateNestedRef(ref, subdirectory: "skills", plugin: plugin)
        let lexicalRoot = plugin.rootURL.appendingPathComponent("skills", isDirectory: true).standardizedFileURL
        let lexicalURL = plugin.rootURL.appendingPathComponent(ref, isDirectory: true).standardizedFileURL
        _ = try ProjectCapabilityPath.containedURL(ref: ref, subdirectory: "skills", plugin: plugin, isDirectory: true) {
            "Skill reference escapes plugin: \(ref)"
        }
        guard !isSymbolicLink(lexicalRoot), !isSymbolicLink(lexicalURL) else {
            throw ProjectCapabilityValidationError("Skill reference is symbolic link: \(ref)")
        }
        try validateExistingDirectory(lexicalURL, ref: ref)
        return lexicalURL
    }

    private func validateNestedRef(_ ref: String, subdirectory: String, plugin: ProjectPluginDescriptor) throws {
        let root = plugin.rootURL.appendingPathComponent(subdirectory, isDirectory: true).standardizedFileURL
        let url = plugin.rootURL.appendingPathComponent(ref, isDirectory: true).standardizedFileURL
        guard ProjectionTrust.isPath(url, inside: root), url.path != root.path else {
            throw ProjectCapabilityValidationError("\(subdirectory) reference escapes plugin: \(ref)")
        }
    }

    private func validateExistingDirectory(_ url: URL, ref: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectCapabilityValidationError("Missing skill: \(ref)")
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func validatePluginID(_ pluginID: String) throws {
        guard !pluginID.isEmpty, !pluginID.contains("/"), pluginID != ".", pluginID != ".." else {
            throw ProjectCapabilityValidationError("Invalid plugin id: \(pluginID)")
        }
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return ["mcpServers": [String: Any]()] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectCapabilityValidationError("Malformed JSON file: \(url.lastPathComponent)")
        }
        return object
    }

    private func mcpServers(in root: [String: Any], fileURL: URL) throws -> [String: Any] {
        guard let existing = root["mcpServers"] else { return [:] }
        guard let servers = existing as? [String: Any] else {
            throw ProjectCapabilityValidationError("Malformed MCP server file: \(fileURL.lastPathComponent)")
        }
        return servers
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func updateManifest(project: AgentProject, pluginID: String, mutate: (inout [String: Any]) -> Void) throws {
        let manifestURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("plugin.json")
        var object = try readJSONObject(manifestURL)
        guard object["id"] as? String == pluginID else {
            throw ProjectCapabilityValidationError("Invalid plugin manifest: \(pluginID)")
        }
        mutate(&object)
        try writeJSONObject(object, to: manifestURL)
    }

    private func appendUnique(_ value: String, to key: String, in object: inout [String: Any]) {
        var values = object[key] as? [String] ?? []
        if !values.contains(value) { values.append(value) }
        object[key] = values
    }

    private func backup(project: AgentProject, plugin: ProjectPluginDescriptor, including url: URL) throws {
        let backupRoot = project.rootURL
            .appendingPathComponent(".open-pet-agent/backups/capabilities", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(plugin.id, isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: plugin.rootURL.appendingPathComponent("plugin.json"),
            to: backupRoot.appendingPathComponent("plugin.json")
        )
        let rootComponents = plugin.rootURL.standardizedFileURL.pathComponents
        let relativeComponents = url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
        let destination = relativeComponents.reduce(backupRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    private func capabilities(in manifest: [String: Any]) -> Set<ProjectPluginCapability> {
        Set((manifest["capabilities"] as? [String] ?? []).compactMap(ProjectPluginCapability.init(rawValue:)))
    }

    private func unknownCapabilities(in manifest: [String: Any]) -> [String] {
        (manifest["capabilities"] as? [String] ?? []).filter { ProjectPluginCapability(rawValue: $0) == nil }
    }

    private func enginePolicies(in manifest: [String: Any]) -> [String: ProjectionPolicy] {
        let engines = manifest["engines"] as? [String: Any] ?? [:]
        return engines.compactMapValues { value in
            guard let object = value as? [String: Any] else { return nil }
            if object["enabled"] as? Bool == false { return .disabled }
            guard let raw = object["projection"] as? String else { return .disabled }
            return ProjectionPolicy(rawValue: raw) ?? .disabled
        }
    }
}

private extension ACPJSON {
    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.jsonObject)
        case .object(let values): return values.mapValues(\.jsonObject)
        }
    }
}
