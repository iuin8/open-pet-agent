import Foundation

/// opencode 投影落盘。ownership 判定走 `.open-pet-agent/state/generated-targets.json`
/// 清单(见 `ProjectionGeneratedManifest.swift`),不在工程根/技能目录写任何 bookkeeping 文件。
public struct OpencodeProjectionMaterializer: Sendable {
    public init() {}

    public func apply(_ plans: [ProjectionPlan]) throws {
        for plan in plans where plan.engineID == AgentEngineKind.openCode.rawValue {
            try apply(plan)
        }
    }

    public func apply(_ plan: ProjectionPlan) throws {
        guard plan.engineID == AgentEngineKind.openCode.rawValue else { return }
        for operation in plan.operations {
            try apply(operation, engineID: plan.engineID)
        }
    }

    private func apply(_ operation: ProjectionOperation, engineID: String) throws {
        switch operation {
        case .writeFile(let contents, let destination):
            let projectRoot = try ensureSafeDestination(destination)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard isOwned(destination, projectRoot: projectRoot) else {
                    throw OpencodeProjectionMaterializerError.unownedDestination(destination)
                }
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 先登记再写 payload(crash 也不会留下「自己写的文件没有 ownership 记录」的自锁);
            // 簿记失败静默放行,不阻断 materialize。
            if let projectRoot {
                ProjectionGeneratedManifestStore.claimBestEffort(destination, kind: .file, engineID: engineID, projectRoot: projectRoot)
            }
            try contents.write(to: destination, atomically: true, encoding: .utf8)

        case .copyDirectory(let source, let destination):
            try replaceGeneratedDirectory(destination, engineID: engineID) {
                if opencodeMaterializedRoot(for: destination) != nil {
                    try copyConfigData(from: source, to: destination)
                } else {
                    try copyDirectory(from: source, to: destination)
                }
            }

        case .symlinkDirectory(_, let destination):
            throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)

        case .removeGenerated(let url):
            let projectRoot = try ensureSafeDestination(url)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            if let projectRoot {
                ProjectionGeneratedManifestStore.releaseBestEffort(url, projectRoot: projectRoot)
            }
        }
    }

    private func replaceGeneratedDirectory(_ destination: URL, engineID: String, with write: () throws -> Void) throws {
        let projectRoot = try ensureSafeDestination(destination)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard isOwned(destination, projectRoot: projectRoot) else {
                throw OpencodeProjectionMaterializerError.unownedDestination(destination)
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write()
        // 目录落地后再登记;簿记失败静默放行,不阻断 materialize。
        if let projectRoot {
            ProjectionGeneratedManifestStore.claimBestEffort(destination, kind: .directory, engineID: engineID, projectRoot: projectRoot)
        }
    }

    private func isOwned(_ destination: URL, projectRoot: URL?) -> Bool {
        guard let projectRoot else { return false }
        return ProjectionGeneratedManifestStore.isGeneratedTarget(destination, projectRoot: projectRoot)
    }

    private func copyConfigData(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let lexicalSourceRoot = source.standardizedFileURL
        let sourceRoot = lexicalSourceRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(sourceRoot, inside: lexicalSourceRoot) else {
            throw OpencodeProjectionMaterializerError.sourceEscapesPlugin(source)
        }
        for item in ["plugin.json", "mcp", "skills"] {
            let sourceItem = source.appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: sourceItem.path) else { continue }
            try ensureSourceTree(sourceItem, staysInside: sourceRoot)
            try FileManager.default.copyItem(
                at: sourceItem,
                to: destination.appendingPathComponent(item)
            )
        }
    }

    private func copyDirectory(from source: URL, to destination: URL) throws {
        let lexicalSourceRoot = source.standardizedFileURL
        let sourceRoot = lexicalSourceRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(sourceRoot, inside: lexicalSourceRoot) else {
            throw OpencodeProjectionMaterializerError.sourceEscapesPlugin(source)
        }
        try ensureSourceTree(source, staysInside: sourceRoot)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func ensureSourceTree(_ sourceItem: URL, staysInside sourceRoot: URL) throws {
        try ensureSource(sourceItem, staysInside: sourceRoot)
        guard let enumerator = FileManager.default.enumerator(at: sourceItem, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return
        }
        for case let child as URL in enumerator {
            try ensureSource(child, staysInside: sourceRoot)
        }
    }

    private func ensureSource(_ url: URL, staysInside sourceRoot: URL) throws {
        if let target = try symlinkTarget(for: url), !ProjectionTrust.isPath(target, inside: sourceRoot) {
            throw OpencodeProjectionMaterializerError.sourceEscapesPlugin(url)
        }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedURL, inside: sourceRoot) else {
            throw OpencodeProjectionMaterializerError.sourceEscapesPlugin(url)
        }
    }

    private func ensureSafeDestination(_ destination: URL) throws -> URL? {
        guard let root = opencodeProjectRoot(for: destination) else {
            throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        try ensureExistingAncestorsStayInsideProject(for: destination, projectRoot: root, resolvedProjectRoot: resolvedRoot)

        let parent = destination.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolvedParent, inside: resolvedRoot) else {
                throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        if let resolvedLink = try symlinkTarget(for: destination) {
            guard ProjectionTrust.isPath(resolvedLink, inside: resolvedRoot) else {
                throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolvedDestination, inside: resolvedRoot) else {
                throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        return root
    }

    private func ensureExistingAncestorsStayInsideProject(
        for destination: URL,
        projectRoot: URL,
        resolvedProjectRoot: URL
    ) throws {
        let lexicalProjectRoot = projectRoot.standardizedFileURL
        var current = destination.deletingLastPathComponent().standardizedFileURL
        while ProjectionTrust.isPath(current, inside: lexicalProjectRoot), current.path != lexicalProjectRoot.path {
            if let target = try symlinkTarget(for: current), !ProjectionTrust.isPath(target, inside: resolvedProjectRoot) {
                throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
            if FileManager.default.fileExists(atPath: current.path) {
                let resolvedCurrent = current.resolvingSymlinksInPath()
                guard ProjectionTrust.isPath(resolvedCurrent, inside: resolvedProjectRoot) else {
                    throw OpencodeProjectionMaterializerError.destinationEscapesProject(destination)
                }
            }
            current = current.deletingLastPathComponent()
        }
    }

    private func symlinkTarget(for url: URL) throws -> URL? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let targetURL = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : url.deletingLastPathComponent().appendingPathComponent(target)
        return targetURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func opencodeProjectRoot(for destination: URL) -> URL? {
        if destination.lastPathComponent == "opencode.json",
           destination.deletingLastPathComponent().lastPathComponent != ".open-pet-agent" {
            return destination.deletingLastPathComponent()
        }

        let skills = destination.deletingLastPathComponent()
        let opencode = skills.deletingLastPathComponent()
        if skills.lastPathComponent == "skills", opencode.lastPathComponent == ".opencode" {
            return opencode.deletingLastPathComponent()
        }
        return opencodeMaterializedRoot(for: destination)?.projectRoot
    }

    private func opencodeMaterializedRoot(for destination: URL) -> (projectRoot: URL, materializedRoot: URL)? {
        let components = destination.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: ".open-pet-agent"),
              components.indices.contains(index + 4),
              components[index + 1] == "plugins",
              components[index + 2] == ".materialized",
              components[index + 3] == AgentEngineKind.openCode.rawValue,
              components[index + 4] == "plugins" else {
            return nil
        }
        let projectComponents = Array(components.prefix(index))
        let materializedComponents = Array(components.prefix(index + 5))
        return (
            URL(fileURLWithPath: NSString.path(withComponents: projectComponents), isDirectory: true),
            URL(fileURLWithPath: NSString.path(withComponents: materializedComponents), isDirectory: true)
        )
    }
}

public enum OpencodeProjectionMaterializerError: Error, Equatable, CustomStringConvertible {
    case destinationEscapesProject(URL)
    case sourceEscapesPlugin(URL)
    case unownedDestination(URL)

    public var description: String {
        switch self {
        case .destinationEscapesProject(let url): return "opencode projection destination escapes project: \(url.path)"
        case .sourceEscapesPlugin(let url): return "opencode projection source escapes plugin: \(url.path)"
        case .unownedDestination(let url): return "opencode projection destination is not generated by OpenPetAgent: \(url.path)"
        }
    }
}
