import Foundation

/// Claude Code 投影落盘。ownership 判定走 `.open-pet-agent/state/generated-targets.json`
/// 清单(见 `ProjectionGeneratedManifest.swift`),不在工程根/技能目录写任何 bookkeeping 文件。
public struct ClaudeCodeProjectionMaterializer: Sendable {
    public init() {}

    public func apply(_ plans: [ProjectionPlan]) throws {
        for plan in plans where plan.engineID == AgentEngineKind.claudeCode.rawValue {
            try apply(plan)
        }
    }

    public func apply(_ plan: ProjectionPlan) throws {
        guard plan.engineID == AgentEngineKind.claudeCode.rawValue else { return }
        for operation in plan.operations {
            try apply(operation, engineID: plan.engineID)
        }
    }

    private func apply(_ operation: ProjectionOperation, engineID: String) throws {
        switch operation {
        case .writeFile(let contents, let destination):
            let projectRoot = try ensureSafeDestination(destination)
            if itemExistsOrSymlink(destination) {
                guard isOwned(destination, projectRoot: projectRoot) else {
                    throw ClaudeCodeProjectionMaterializerError.unownedDestination(destination)
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
                try FileManager.default.copyItem(at: source, to: destination)
            }

        case .symlinkDirectory(let source, let destination):
            try replaceGeneratedDirectory(destination, engineID: engineID) {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            }

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
                throw ClaudeCodeProjectionMaterializerError.unownedDestination(destination)
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

    private func ensureSafeDestination(_ destination: URL) throws -> URL? {
        guard let root = claudeCodeProjectRoot(for: destination) else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolvedParent, inside: resolvedRoot) else {
                throw ClaudeCodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        if let resolvedLink = try symlinkTarget(for: destination) {
            guard ProjectionTrust.isPath(resolvedLink, inside: resolvedRoot) else {
                throw ClaudeCodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard ProjectionTrust.isPath(resolvedDestination, inside: resolvedRoot) else {
                throw ClaudeCodeProjectionMaterializerError.destinationEscapesProject(destination)
            }
        }
        return root
    }

    private func itemExistsOrSymlink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    private func symlinkTarget(for url: URL) throws -> URL? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let targetURL = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : url.deletingLastPathComponent().appendingPathComponent(target)
        return targetURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func claudeCodeProjectRoot(for destination: URL) -> URL? {
        if destination.lastPathComponent == ".mcp.json" {
            return destination.deletingLastPathComponent()
        }

        let skills = destination.deletingLastPathComponent()
        let claude = skills.deletingLastPathComponent()
        if skills.lastPathComponent == "skills", claude.lastPathComponent == ".claude" {
            return claude.deletingLastPathComponent()
        }
        return nil
    }
}

public enum ClaudeCodeProjectionMaterializerError: Error, Equatable, CustomStringConvertible {
    case destinationEscapesProject(URL)
    case unownedDestination(URL)

    public var description: String {
        switch self {
        case .destinationEscapesProject(let url): return "Claude Code projection destination escapes project: \(url.path)"
        case .unownedDestination(let url): return "Claude Code projection destination is not generated by OpenPetAgent: \(url.path)"
        }
    }
}
