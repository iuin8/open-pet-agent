import Foundation

public struct ClaudeCodeProjectionMaterializer: Sendable {
    private static let fileMarker = ".open-pet-agent-generated.mcp"
    private static let directoryMarker = ".open-pet-agent-generated"

    public init() {}

    public func apply(_ plans: [ProjectionPlan]) throws {
        for plan in plans where plan.engineID == AgentEngineKind.claudeCode.rawValue {
            try apply(plan)
        }
    }

    public func apply(_ plan: ProjectionPlan) throws {
        guard plan.engineID == AgentEngineKind.claudeCode.rawValue else { return }
        for operation in plan.operations {
            try apply(operation)
        }
    }

    private func apply(_ operation: ProjectionOperation) throws {
        switch operation {
        case .writeFile(let contents, let destination):
            try ensureSafeDestination(destination)
            if itemExistsOrSymlink(destination) {
                guard isGeneratedFile(destination) else {
                    throw ClaudeCodeProjectionMaterializerError.unownedDestination(destination)
                }
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: destination, atomically: true, encoding: .utf8)
            try "generated".write(to: fileMarkerURL(for: destination), atomically: true, encoding: .utf8)

        case .copyDirectory(let source, let destination):
            try replaceGeneratedDirectory(destination) {
                try FileManager.default.copyItem(at: source, to: destination)
            }

        case .symlinkDirectory(let source, let destination):
            try replaceGeneratedDirectory(destination) {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            }

        case .removeGenerated(let url):
            try ensureSafeDestination(url)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let marker = fileMarkerURL(for: url)
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
        }
    }

    private func replaceGeneratedDirectory(_ destination: URL, with write: () throws -> Void) throws {
        try ensureSafeDestination(destination)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard isGeneratedDirectory(destination) else {
                throw ClaudeCodeProjectionMaterializerError.unownedDestination(destination)
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write()
        try "generated".write(
            to: destination.appendingPathComponent(Self.directoryMarker),
            atomically: true,
            encoding: .utf8
        )
    }

    private func isGeneratedFile(_ destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileMarkerURL(for: destination).path)
    }

    private func isGeneratedDirectory(_ destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.appendingPathComponent(Self.directoryMarker).path)
    }

    private func fileMarkerURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(Self.fileMarker)
    }

    private func ensureSafeDestination(_ destination: URL) throws {
        guard let root = claudeCodeProjectRoot(for: destination) else { return }
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
