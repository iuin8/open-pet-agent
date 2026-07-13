import CryptoKit
import Foundation

public struct ProjectCapabilityAuditStore: Sendable {
    public init() {}

    public func load(project: AgentProject) throws -> CapabilityAuditState {
        let url = ProjectConfig.capabilityAuditStateURL(for: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return CapabilityAuditState() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CapabilityAuditState.self, from: data)
    }

    public func recordValidation(
        project: AgentProject,
        diagnostics _: [ProjectConfigDiagnostic],
        date: Date = Date()
    ) throws {
        let state = try load(project: project)
        try save(CapabilityAuditState(
            lastValidationDescription: Self.isoString(date),
            lastSyncDescription: state.lastSyncDescription,
            generatedTargets: state.generatedTargets,
            acknowledgedDiagnostics: state.acknowledgedDiagnostics
        ), project: project)
    }

    public func recordSync(project: AgentProject, plans: [ProjectionPlan], date: Date = Date()) throws {
        let state = try load(project: project)
        var recordsByPath = Dictionary(uniqueKeysWithValues: state.generatedTargets.map { ($0.path, $0) })
        for plan in plans {
            for operation in plan.operations {
                guard let record = record(for: operation, plan: plan, date: date) else { continue }
                recordsByPath[record.path] = record
            }
        }
        let records = recordsByPath.values.sorted { $0.path < $1.path }
        try save(CapabilityAuditState(
            lastValidationDescription: state.lastValidationDescription,
            lastSyncDescription: Self.isoString(date),
            generatedTargets: records,
            acknowledgedDiagnostics: state.acknowledgedDiagnostics
        ), project: project)
    }

    public func acknowledge(_ diagnostic: ProjectConfigDiagnostic, project: AgentProject) throws {
        let state = try load(project: project)
        var acknowledged = state.acknowledgedDiagnostics
        acknowledged.insert(Self.key(for: diagnostic))
        try save(CapabilityAuditState(
            lastValidationDescription: state.lastValidationDescription,
            lastSyncDescription: state.lastSyncDescription,
            generatedTargets: state.generatedTargets,
            acknowledgedDiagnostics: acknowledged
        ), project: project)
    }

    public static func key(for diagnostic: ProjectConfigDiagnostic) -> String {
        "\(diagnostic.severity.rawValue)|\(diagnostic.path ?? "")|\(diagnostic.message)"
    }

    private func save(_ state: CapabilityAuditState, project: AgentProject) throws {
        let url = ProjectConfig.capabilityAuditStateURL(for: project)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func record(
        for operation: ProjectionOperation,
        plan: ProjectionPlan,
        date: Date
    ) -> CapabilityAuditState.GeneratedTarget? {
        guard let target = operation.auditTarget,
              let hash = ProjectCapabilityAuditHasher.hash(target) else { return nil }
        return CapabilityAuditState.GeneratedTarget(
            engineID: plan.engineID,
            pluginID: plan.pluginID,
            path: target.path,
            hash: hash,
            recordedAtDescription: Self.isoString(date)
        )
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public struct ProjectCapabilityAuditor: Sendable {
    private let store: ProjectCapabilityAuditStore

    public init(store: ProjectCapabilityAuditStore = ProjectCapabilityAuditStore()) {
        self.store = store
    }

    public func diagnostics(project: AgentProject, plans: [ProjectionPlan]) throws -> [ProjectConfigDiagnostic] {
        let state = try store.load(project: project)
        let records = Dictionary(uniqueKeysWithValues: state.generatedTargets.map { ($0.path, $0) })
        let diagnostics = plans.flatMap { plan in
            plan.operations.compactMap { operation -> ProjectConfigDiagnostic? in
                guard let target = operation.auditTarget,
                      FileManager.default.fileExists(atPath: target.path) else { return nil }
                if let record = records[target.path] {
                    return driftDiagnostic(target: target, record: record)
                }
                guard !Self.isGeneratedTarget(target) else { return nil }
                return ProjectConfigDiagnostic(
                    severity: .error,
                    message: "用户自有目标冲突: \(target.path)",
                    path: target.path
                )
            }
        }
        return diagnostics.filter { !state.acknowledgedDiagnostics.contains(ProjectCapabilityAuditStore.key(for: $0)) }
    }

    private func driftDiagnostic(
        target: URL,
        record: CapabilityAuditState.GeneratedTarget
    ) -> ProjectConfigDiagnostic? {
        guard let hash = ProjectCapabilityAuditHasher.hash(target), hash != record.hash else { return nil }
        return ProjectConfigDiagnostic(
            severity: .warning,
            message: "生成目标漂移: \(target.path)",
            path: target.path
        )
    }

    private static func isGeneratedTarget(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".open-pet-agent-generated").path) {
            return true
        }
        if url.lastPathComponent == ".mcp.json" {
            let marker = url.deletingLastPathComponent().appendingPathComponent(".open-pet-agent-generated.mcp")
            return FileManager.default.fileExists(atPath: marker.path)
        }
        if url.lastPathComponent == "config.toml",
           url.deletingLastPathComponent().lastPathComponent == ".codex",
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.hasPrefix("# Generated by OpenPetAgent Codex projection. Do not edit by hand.")
        }
        return false
    }
}

private enum ProjectCapabilityAuditHasher {
    static func hash(_ url: URL) -> String? {
        var hasher = SHA256()
        guard update(&hasher, with: url) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, with url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
            hasher.update(data: Data("symlink:\(target)".utf8))
            return true
        }
        if values?.isDirectory == true {
            guard let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            let childURLs = children.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
            for childURL in childURLs {
                hasher.update(data: Data(childURL.path.replacingOccurrences(of: url.path, with: "").utf8))
                guard update(&hasher, with: childURL) else { return false }
            }
            return true
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        hasher.update(data: data)
        return true
    }
}

private extension ProjectionOperation {
    var auditTarget: URL? {
        switch self {
        case .writeFile(_, let destination),
             .copyDirectory(_, let destination),
             .symlinkDirectory(_, let destination):
            return destination
        case .removeGenerated:
            return nil
        }
    }
}
