import CryptoKit
import Foundation

public struct ProjectCapabilityAuditStore: Sendable {
    private let sourceConfirmationsURL: @Sendable (AgentProject) -> URL

    public init(
        sourceConfirmationsURL: @escaping @Sendable (AgentProject) -> URL = { project in
            ProjectConfig.capabilitySourceConfirmationsURL(for: project)
        }
    ) {
        self.sourceConfirmationsURL = sourceConfirmationsURL
    }

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
            backups: state.backups,
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
            backups: state.backups,
            acknowledgedDiagnostics: state.acknowledgedDiagnostics
        ), project: project)
    }

    public func recordBackup(project: AgentProject, plans: [ProjectionPlan], date: Date = Date()) throws {
        let state = try load(project: project)
        let batchID = UUID().uuidString
        let backups = try plans.flatMap { plan in
            try plan.operations.compactMap { operation in
                try backup(for: operation, plan: plan, project: project, date: date, batchID: batchID)
            }
        }
        guard !backups.isEmpty else { return }
        let merged = state.backups + backups
        try save(CapabilityAuditState(
            lastValidationDescription: state.lastValidationDescription,
            lastSyncDescription: state.lastSyncDescription,
            generatedTargets: state.generatedTargets,
            backups: merged,
            acknowledgedDiagnostics: state.acknowledgedDiagnostics
        ), project: project)
    }

    public func restoreLatestBackup(project: AgentProject, date: Date = Date()) throws {
        let state = try load(project: project)
        guard let latest = state.backups.last else {
            throw ProjectCapabilityAuditError.backupUnavailable
        }
        let latestBatchID = Self.batchKey(latest)
        let backups = state.backups.filter { Self.batchKey($0) == latestBatchID }
        for backup in backups {
            try validateRestore(backup, project: project)
        }
        for backup in backups {
            let target = URL(fileURLWithPath: backup.targetPath)
            let source = URL(fileURLWithPath: backup.backupPath)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        try recordRestoredTargets(backups, state: state, project: project, date: date)
    }

    public func acknowledge(_ diagnostic: ProjectConfigDiagnostic, project: AgentProject) throws {
        let state = try load(project: project)
        var acknowledged = state.acknowledgedDiagnostics
        acknowledged.insert(Self.key(for: diagnostic))
        try save(CapabilityAuditState(
            lastValidationDescription: state.lastValidationDescription,
            lastSyncDescription: state.lastSyncDescription,
            generatedTargets: state.generatedTargets,
            backups: state.backups,
            acknowledgedDiagnostics: acknowledged
        ), project: project)
    }

    public func loadSourceConfirmations(project: AgentProject) throws -> CapabilitySourceConfirmationState {
        let url = sourceConfirmationsURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else { return CapabilitySourceConfirmationState() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CapabilitySourceConfirmationState.self, from: data)
    }

    public func confirmSource(
        project: AgentProject,
        pluginID: String,
        source: ProjectPluginSourceMetadata,
        date: Date = Date()
    ) throws {
        let state = try loadSourceConfirmations(project: project)
        let contentHash = try sourceContentHash(project: project, pluginID: pluginID)
        let confirmation = CapabilitySourceConfirmation(
            pluginID: pluginID,
            source: source,
            contentHash: contentHash,
            confirmedAtDescription: Self.isoString(date)
        )
        let confirmations = (state.confirmations.filter { $0.pluginID != pluginID } + [confirmation])
            .sorted { $0.pluginID < $1.pluginID }
        try saveSourceConfirmations(CapabilitySourceConfirmationState(confirmations: confirmations), project: project)
    }

    public func revokeSourceConfirmation(project: AgentProject, pluginID: String) throws {
        let state = try loadSourceConfirmations(project: project)
        let confirmations = state.confirmations.filter { $0.pluginID != pluginID }
        try saveSourceConfirmations(CapabilitySourceConfirmationState(confirmations: confirmations), project: project)
    }

    public func isSourceConfirmed(
        project: AgentProject,
        pluginID: String,
        source: ProjectPluginSourceMetadata
    ) throws -> Bool {
        let contentHash = try sourceContentHash(project: project, pluginID: pluginID)
        return try loadSourceConfirmations(project: project).confirmations.contains {
            $0.pluginID == pluginID && $0.source == source && $0.contentHash == contentHash
        }
    }

    public static func key(for diagnostic: ProjectConfigDiagnostic) -> String {
        "\(diagnostic.severity.rawValue)|\(diagnostic.path ?? "")|\(diagnostic.message)"
    }

    private static func batchKey(_ backup: CapabilityAuditState.Backup) -> String {
        backup.batchID ?? backup.recordedAtDescription
    }

    /// ownership 判定:以 `.open-pet-agent/state/generated-targets.json` 清单为准(fail-closed)。
    public static func isGeneratedTarget(_ url: URL, projectRoot: URL) -> Bool {
        ProjectionGeneratedManifestStore.isGeneratedTarget(url, projectRoot: projectRoot)
    }

    private func saveSourceConfirmations(_ state: CapabilitySourceConfirmationState, project: AgentProject) throws {
        let url = sourceConfirmationsURL(project)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    public func sourceContentHash(project: AgentProject, pluginID: String) throws -> String {
        guard !pluginID.isEmpty, !pluginID.contains("/"), pluginID != ".", pluginID != ".." else {
            throw ProjectCapabilityValidationError("Invalid plugin id: \(pluginID)")
        }
        let pluginRoot = ProjectConfig.pluginRoot(for: project).standardizedFileURL
        let pluginURL = ProjectConfig.pluginDirectory(for: project, pluginID: pluginID).standardizedFileURL
        guard ProjectionTrust.isPath(pluginURL, inside: pluginRoot),
              ProjectionTrust.isPath(pluginURL.resolvingSymlinksInPath(), inside: pluginRoot.resolvingSymlinksInPath()) else {
            throw ProjectCapabilityValidationError("Invalid plugin id: \(pluginID)")
        }
        guard let hash = ProjectCapabilityAuditHasher.hash(pluginURL) else {
            throw ProjectCapabilityValidationError("Cannot hash plugin source: \(pluginID)")
        }
        return hash
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

    private func validateRestore(_ backup: CapabilityAuditState.Backup, project: AgentProject) throws {
        let target = URL(fileURLWithPath: backup.targetPath)
        let source = URL(fileURLWithPath: backup.backupPath)
        let projectRoot = project.rootURL.standardizedFileURL
        let resolvedProjectRoot = projectRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(target.standardizedFileURL, inside: projectRoot),
              ProjectionTrust.isPath(target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(), inside: resolvedProjectRoot) else {
            throw ProjectCapabilityAuditError.unownedRestoreTarget(target)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ProjectCapabilityAuditError.backupUnavailable
        }
        guard !FileManager.default.fileExists(atPath: target.path) || Self.isGeneratedTarget(target, projectRoot: project.rootURL) else {
            throw ProjectCapabilityAuditError.unownedRestoreTarget(target)
        }
    }

    private func recordRestoredTargets(
        _ backups: [CapabilityAuditState.Backup],
        state: CapabilityAuditState,
        project: AgentProject,
        date: Date
    ) throws {
        var recordsByPath = Dictionary(uniqueKeysWithValues: state.generatedTargets.map { ($0.path, $0) })
        for backup in backups {
            let target = URL(fileURLWithPath: backup.targetPath)
            guard let hash = ProjectCapabilityAuditHasher.hash(target) else { continue }
            recordsByPath[backup.targetPath] = CapabilityAuditState.GeneratedTarget(
                engineID: backup.engineID,
                pluginID: backup.pluginID,
                path: backup.targetPath,
                hash: hash,
                recordedAtDescription: Self.isoString(date)
            )
        }
        try save(CapabilityAuditState(
            lastValidationDescription: state.lastValidationDescription,
            lastSyncDescription: Self.isoString(date),
            generatedTargets: recordsByPath.values.sorted { $0.path < $1.path },
            backups: state.backups,
            acknowledgedDiagnostics: state.acknowledgedDiagnostics
        ), project: project)
    }

    private func backup(
        for operation: ProjectionOperation,
        plan: ProjectionPlan,
        project: AgentProject,
        date: Date,
        batchID: String
    ) throws -> CapabilityAuditState.Backup? {
        guard let target = operation.auditTarget,
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        guard Self.isGeneratedTarget(target, projectRoot: project.rootURL) else { throw ProjectCapabilityAuditError.unownedRestoreTarget(target) }
        let backup = backupURL(project: project, target: target, date: date)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: target, to: backup)
        return CapabilityAuditState.Backup(
            engineID: plan.engineID,
            pluginID: plan.pluginID,
            targetPath: target.path,
            backupPath: backup.path,
            recordedAtDescription: Self.isoString(date),
            batchID: batchID
        )
    }

    private func backupURL(project: AgentProject, target: URL, date: Date) -> URL {
        let safeTarget = target.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return ProjectConfig.capabilityAuditStateURL(for: project)
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(Self.isoString(date), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(safeTarget, isDirectory: false)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum ProjectCapabilityAuditError: Error, Equatable, CustomStringConvertible {
    case backupUnavailable
    case unownedRestoreTarget(URL)

    public var description: String {
        switch self {
        case .backupUnavailable:
            return "没有可恢复的项目能力备份"
        case .unownedRestoreTarget(let url):
            return "恢复目标不是 OpenPetAgent 生成内容: \(url.path)"
        }
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
                guard !ProjectCapabilityAuditStore.isGeneratedTarget(target, projectRoot: project.rootURL) else { return nil }
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
}

private enum ProjectCapabilityAuditHasher {
    static func hash(_ url: URL) -> String? {
        var hasher = SHA256()
        let root = url.standardizedFileURL
        guard update(&hasher, with: root, relativePath: "") else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, with url: URL, relativePath: String) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
            updateEntry(&hasher, type: "symlink", relativePath: relativePath, payload: Data(target.utf8))
            return true
        }
        if values?.isDirectory == true {
            updateEntry(&hasher, type: "directory", relativePath: relativePath, payload: Data())
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { return false }
            for childURL in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let childRelativePath = relativePath.isEmpty
                    ? childURL.lastPathComponent
                    : "\(relativePath)/\(childURL.lastPathComponent)"
                guard update(&hasher, with: childURL, relativePath: childRelativePath) else { return false }
            }
            return true
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        updateEntry(&hasher, type: "file", relativePath: relativePath, payload: data)
        return true
    }

    private static func updateEntry(
        _ hasher: inout SHA256,
        type: String,
        relativePath: String,
        payload: Data
    ) {
        updateField(&hasher, type)
        updateField(&hasher, relativePath)
        updateField(&hasher, String(payload.count))
        hasher.update(data: payload)
    }

    private static func updateField(_ hasher: inout SHA256, _ value: String) {
        let data = Data(value.utf8)
        hasher.update(data: Data("\(data.count):".utf8))
        hasher.update(data: data)
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
