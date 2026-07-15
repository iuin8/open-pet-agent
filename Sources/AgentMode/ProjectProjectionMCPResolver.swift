import Foundation

enum ProjectProjectionMCPResolutionError: Error, Equatable {
    case invalidRef(String)
    case unreadableServer(String)
    case missingServer(String)
    case invalidServer(String)
    case refEscapesPlugin(String)
}

enum ProjectProjectionMCPResolver {
    static func resolve(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (name: String, value: ACPJSON) {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ProjectProjectionMCPResolutionError.invalidRef(ref) }
        let fileURL = try readableMCPFileURL(ref: parts[0], fullRef: ref, plugin: plugin)
        let serverName = parts[1]
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProjectProjectionMCPResolutionError.unreadableServer(ref)
        }
        let object: [String: ACPJSON]
        do {
            object = try JSONDecoder().decode(ACPJSON.self, from: data).objectValue ?? [:]
        } catch {
            throw ProjectProjectionMCPResolutionError.unreadableServer(ref)
        }
        guard let servers = object["mcpServers"]?.objectValue,
              let server = servers[serverName] else {
            throw ProjectProjectionMCPResolutionError.missingServer(serverName)
        }
        guard server.objectValue != nil else {
            throw ProjectProjectionMCPResolutionError.invalidServer(serverName)
        }
        return (serverName, server)
    }

    private static func readableMCPFileURL(ref: String, fullRef: String, plugin: ProjectPluginDescriptor) throws -> URL {
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.first == "mcp",
              parts.count > 1,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectProjectionMCPResolutionError.refEscapesPlugin(fullRef)
        }

        let pluginRoot = plugin.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalRoot = plugin.rootURL.appendingPathComponent("mcp", isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lexicalRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectProjectionMCPResolutionError.unreadableServer(fullRef)
        }
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        if (try? lexicalRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            guard ProjectionTrust.isPath(resolvedRoot, inside: pluginRoot) else {
                throw ProjectProjectionMCPResolutionError.refEscapesPlugin(fullRef)
            }
        }

        let lexicalURL = parts.dropFirst().reduce(lexicalRoot) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        guard FileManager.default.fileExists(atPath: lexicalURL.path) else {
            throw ProjectProjectionMCPResolutionError.unreadableServer(fullRef)
        }
        let resolvedURL = lexicalURL.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedURL, inside: resolvedRoot) else {
            throw ProjectProjectionMCPResolutionError.refEscapesPlugin(fullRef)
        }
        return resolvedURL
    }
}
