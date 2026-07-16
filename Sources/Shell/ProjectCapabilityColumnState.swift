import AgentMode
import Combine
import Foundation

public struct ProjectCapabilitySnapshot: Sendable, Equatable {
    public let catalog: ProjectCapabilityCatalogModel
    public let card: ProjectCapabilityCardState

    public init(catalog: ProjectCapabilityCatalogModel, card: ProjectCapabilityCardState) {
        self.catalog = catalog
        self.card = card
    }
}

@MainActor
public final class ProjectCapabilityColumnState: ObservableObject {
    public static let importRowID = -1
    public static let addRowID = -2
    public static let diagnosticsRowID = -3

    @Published public private(set) var card: ProjectCapabilityCardState
    @Published public private(set) var catalog: ProjectCapabilityCatalogModel?
    @Published public private(set) var syncMessages: [String]
    public var onOpenSkillDetail: ((Int, ProjectCapabilitySkillDetailState) -> Void)?
    public var onOpenMCPDetail: ((Int, ProjectCapabilityMCPDetailState) -> Void)?
    public var onOpenImport: ((Int, ProjectCapabilityImportState) -> Void)?
    public var onOpenAdd: ((Int, ProjectCapabilityColumnState) -> Void)?
    public var onOpenDiagnostics: ((Int, ProjectCapabilityPanelState) -> Void)?

    private let onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)?
    private let onSetTargetEnabled: ((String, CapabilityTarget, Bool) -> ProjectCapabilityCardState)?
    private let onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)?
    private let onAddSkill: ((String, String, String, String) -> ProjectCapabilityCardState)?
    private let onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)?
    private let onUpdateSkillBody: ((String, String, String) throws -> ProjectCapabilitySnapshot?)?
    private let onUpdateMCPServer: ((String, String, String, ACPJSON) throws -> ProjectCapabilitySnapshot?)?
    private let onDeleteMCPServer: ((String, String, String) throws -> ProjectCapabilitySnapshot?)?
    private let onScanImports: (() -> ProjectCapabilityImportScan)?
    private let onImportCandidates: (([ProjectCapabilityImportCandidate], String, String) throws -> ProjectCapabilityImportOutcome)?
    private let onRefreshCard: (() -> ProjectCapabilityCardState)?
    private let onRefreshCatalog: (() -> ProjectCapabilityCatalogModel?)?
    private let onShowDiagnostics: (() -> ProjectCapabilityPanelState)?
    private let onSyncCodex: (() -> String)?
    private let onSyncClaudeCode: (() -> String)?
    private let onSyncOpencode: (() -> String)?

    public init(
        card: ProjectCapabilityCardState,
        catalog: ProjectCapabilityCatalogModel? = nil,
        syncMessages: [String] = [],
        onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)? = nil,
        onSetTargetEnabled: ((String, CapabilityTarget, Bool) -> ProjectCapabilityCardState)? = nil,
        onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)? = nil,
        onAddSkill: ((String, String, String, String) -> ProjectCapabilityCardState)? = nil,
        onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)? = nil,
        onUpdateSkillBody: ((String, String, String) throws -> ProjectCapabilitySnapshot?)? = nil,
        onUpdateMCPServer: ((String, String, String, ACPJSON) throws -> ProjectCapabilitySnapshot?)? = nil,
        onDeleteMCPServer: ((String, String, String) throws -> ProjectCapabilitySnapshot?)? = nil,
        onScanImports: (() -> ProjectCapabilityImportScan)? = nil,
        onImportCandidates: (([ProjectCapabilityImportCandidate], String, String) throws -> ProjectCapabilityImportOutcome)? = nil,
        onRefreshCard: (() -> ProjectCapabilityCardState)? = nil,
        onRefreshCatalog: (() -> ProjectCapabilityCatalogModel?)? = nil,
        onShowDiagnostics: (() -> ProjectCapabilityPanelState)? = nil,
        onSyncCodex: (() -> String)? = nil,
        onSyncClaudeCode: (() -> String)? = nil,
        onSyncOpencode: (() -> String)? = nil
    ) {
        self.card = card
        self.catalog = catalog
        self.syncMessages = syncMessages
        self.onSetEnabled = onSetEnabled
        self.onSetTargetEnabled = onSetTargetEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onAddSkill = onAddSkill
        self.onAddMCP = onAddMCP
        self.onUpdateSkillBody = onUpdateSkillBody
        self.onUpdateMCPServer = onUpdateMCPServer
        self.onDeleteMCPServer = onDeleteMCPServer
        self.onScanImports = onScanImports
        self.onImportCandidates = onImportCandidates
        self.onRefreshCard = onRefreshCard
        self.onRefreshCatalog = onRefreshCatalog
        self.onShowDiagnostics = onShowDiagnostics
        self.onSyncCodex = onSyncCodex
        self.onSyncClaudeCode = onSyncClaudeCode
        self.onSyncOpencode = onSyncOpencode
    }

    public func selectTab(_ tab: ProjectCapabilityCardState.Tab) {
        card = ProjectCapabilityCardState(
            selectedTab: tab,
            items: card.items,
            auditSummary: card.auditSummary
        )
    }

    public func setPluginEnabled(pluginID: String, enabled: Bool) {
        guard let onSetEnabled else { return }
        refreshPreservingTab(onSetEnabled(pluginID, enabled))
    }

    public func setTargetEnabled(pluginID: String, target: CapabilityTarget, enabled: Bool) {
        guard let onSetTargetEnabled else { return }
        refreshPreservingTab(onSetTargetEnabled(pluginID, target, enabled))
    }

    public func createPlugin(pluginID: String, name: String) {
        guard let onCreatePlugin else { return }
        refreshPreservingTab(onCreatePlugin(pluginID, name))
    }

    public func addSkill(pluginID: String, skillName: String, skillDescription: String, body: String) {
        guard let onAddSkill else { return }
        refreshPreservingTab(onAddSkill(pluginID, skillName, skillDescription, body))
    }

    public func addMCP(pluginID: String, serverName: String, command: [String]) {
        guard let onAddMCP else { return }
        refreshPreservingTab(onAddMCP(pluginID, serverName, command))
    }

    public func skillDetail(pluginID: String, skillRef: String) -> ProjectCapabilitySkillDetailState? {
        guard let plugin = catalog?.plugins.first(where: { $0.id == pluginID }),
              var skill = plugin.skills.first(where: { $0.relativePath == skillRef }),
              let sourcePath = sourcePath(pluginID: pluginID, skillRef: skillRef) else { return nil }
        skill.diagnostics += plugin.diagnostics.filter { !skill.diagnostics.contains($0) }
        return ProjectCapabilitySkillDetailState(
            pluginID: pluginID,
            sourcePath: sourcePath,
            skill: skill,
            onSave: { [weak self] body in
                guard let self, let onUpdateSkillBody = self.onUpdateSkillBody else {
                    throw ProjectCapabilitySkillDetailError.savingUnavailable
                }
                let snapshot = try onUpdateSkillBody(pluginID, skillRef, body)
                guard let snapshot else {
                    var refreshed = skill
                    refreshed.body = body
                    refreshed.bodyPreview = String(body.prefix(240))
                    self.patchCatalog(pluginID: pluginID, skill: refreshed)
                    return refreshed
                }
                guard let refreshed = snapshot.catalog.plugins
                    .first(where: { $0.id == pluginID })?.skills
                    .first(where: { $0.relativePath == skillRef }) else {
                    throw ProjectCapabilitySkillDetailError.missingSkill(skillRef)
                }
                self.apply(snapshot)
                return refreshed
            }
        )
    }

    public func mcpDetail(pluginID: String, serverName: String) -> ProjectCapabilityMCPDetailState? {
        guard let plugin = catalog?.plugins.first(where: { $0.id == pluginID }),
              var server = plugin.mcpServers.first(where: { $0.name == serverName }),
              case .local(let root) = plugin.source else { return nil }
        server.diagnostics += plugin.diagnostics.filter { !server.diagnostics.contains($0) }
        let sourcePath = URL(fileURLWithPath: root)
            .appendingPathComponent(server.fileRef, isDirectory: false).path + "#\(server.name)"
        return ProjectCapabilityMCPDetailState(
            pluginID: pluginID,
            sourcePath: sourcePath,
            server: server,
            onSave: { [weak self] value in
                guard let self, let onUpdateMCPServer = self.onUpdateMCPServer else {
                    throw ProjectCapabilityMCPDetailError.savingUnavailable
                }
                let snapshot = try onUpdateMCPServer(pluginID, server.fileRef, server.name, value)
                if let snapshot,
                   let refreshed = snapshot.catalog.plugins
                    .first(where: { $0.id == pluginID })?.mcpServers
                    .first(where: { $0.name == serverName }) {
                    self.apply(snapshot)
                    return refreshed
                }
                let refreshed = try ProjectCapabilityMCPDetailState.updatedServer(server, with: value)
                self.patchCatalog(pluginID: pluginID, server: refreshed)
                return refreshed
            },
            onDelete: { [weak self] in
                guard let self, let onDeleteMCPServer = self.onDeleteMCPServer else {
                    throw ProjectCapabilityMCPDetailError.savingUnavailable
                }
                let snapshot = try onDeleteMCPServer(pluginID, server.fileRef, server.name)
                if let snapshot {
                    self.apply(snapshot)
                    return
                }
                self.removeMCPServer(pluginID: pluginID, serverName: server.name)
            }
        )
    }

    public func openItem(_ item: ProjectCapabilityCardState.Item, rowID: Int) {
        switch item.kind {
        case .skill:
            guard let skillRef = skillRef(matching: item),
                  let detail = skillDetail(pluginID: item.pluginID, skillRef: skillRef) else { return }
            onOpenSkillDetail?(rowID, detail)
        case .mcp:
            guard let detail = mcpDetail(pluginID: item.pluginID, serverName: item.name) else { return }
            onOpenMCPDetail?(rowID, detail)
        case .profile:
            return
        }
    }

    public func openImport() {
        guard let onScanImports, let onImportCandidates else { return }
        let state = ProjectCapabilityImportState(
            scan: onScanImports(),
            onImport: onImportCandidates,
            onApply: { [weak self] outcome in
                self?.applyImport(outcome)
            }
        )
        onOpenImport?(Self.importRowID, state)
    }

    public func openAdd() {
        onOpenAdd?(Self.addRowID, self)
    }

    public func showDiagnostics() {
        guard let panel = onShowDiagnostics?() else { return }
        onOpenDiagnostics?(Self.diagnosticsRowID, panel)
    }

    public func syncCodex() {
        guard let onSyncCodex else { return }
        syncMessages.append(onSyncCodex())
        refreshCardAfterSync()
    }

    public func syncClaudeCode() {
        guard let onSyncClaudeCode else { return }
        syncMessages.append(onSyncClaudeCode())
        refreshCardAfterSync()
    }

    public func syncOpencode() {
        guard let onSyncOpencode else { return }
        syncMessages.append(onSyncOpencode())
        refreshCardAfterSync()
    }

    private func refreshCardAfterSync() {
        guard let refreshed = onRefreshCard?() else { return }
        refreshPreservingTab(refreshed)
    }

    private func applyImport(_ outcome: ProjectCapabilityImportOutcome) {
        switch outcome {
        case .snapshot(let snapshot):
            apply(snapshot)
        case .partial(let projectID, let plugin, let items):
            var plugins = catalog?.plugins ?? []
            plugins.removeAll { $0.id == plugin.id }
            plugins.append(plugin)
            plugins.sort { $0.id < $1.id }
            let previous = catalog
            catalog = ProjectCapabilityCatalogModel(
                projectID: previous?.projectID ?? projectID,
                plugins: plugins,
                diagnostics: previous?.diagnostics ?? [],
                targets: previous?.targets ?? [],
                audit: previous?.audit
            )
            let retained = card.items.filter { $0.pluginID != plugin.id }
            card = ProjectCapabilityCardState(
                selectedTab: card.selectedTab,
                items: retained + items,
                auditSummary: card.auditSummary
            )
        }
    }

    private func apply(_ snapshot: ProjectCapabilitySnapshot) {
        catalog = snapshot.catalog
        card = ProjectCapabilityCardState(
            selectedTab: card.selectedTab,
            items: snapshot.card.items,
            auditSummary: snapshot.card.auditSummary
        )
    }

    private func refreshPreservingTab(_ refreshed: ProjectCapabilityCardState) {
        card = ProjectCapabilityCardState(
            selectedTab: card.selectedTab,
            items: refreshed.items,
            auditSummary: refreshed.auditSummary
        )
        if let refreshedCatalog = onRefreshCatalog?() { catalog = refreshedCatalog }
    }

    private func patchCatalog(pluginID: String, skill: CapabilitySkill) {
        guard let catalog,
              let pluginIndex = catalog.plugins.firstIndex(where: { $0.id == pluginID }),
              let skillIndex = catalog.plugins[pluginIndex].skills.firstIndex(where: { $0.id == skill.id }) else { return }
        var plugins = catalog.plugins
        plugins[pluginIndex].skills[skillIndex] = skill
        self.catalog = ProjectCapabilityCatalogModel(
            projectID: catalog.projectID,
            plugins: plugins,
            diagnostics: catalog.diagnostics,
            targets: catalog.targets,
            audit: catalog.audit
        )
    }

    private func patchCatalog(pluginID: String, server: CapabilityMCPServer) {
        guard let catalog,
              let pluginIndex = catalog.plugins.firstIndex(where: { $0.id == pluginID }),
              let serverIndex = catalog.plugins[pluginIndex].mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        var plugins = catalog.plugins
        plugins[pluginIndex].mcpServers[serverIndex] = server
        self.catalog = ProjectCapabilityCatalogModel(
            projectID: catalog.projectID,
            plugins: plugins,
            diagnostics: catalog.diagnostics,
            targets: catalog.targets,
            audit: catalog.audit
        )
    }

    private func removeMCPServer(pluginID: String, serverName: String) {
        guard let catalog,
              let pluginIndex = catalog.plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        var plugins = catalog.plugins
        plugins[pluginIndex].mcpServers.removeAll { $0.name == serverName }
        self.catalog = ProjectCapabilityCatalogModel(
            projectID: catalog.projectID,
            plugins: plugins,
            diagnostics: catalog.diagnostics,
            targets: catalog.targets,
            audit: catalog.audit
        )
        card = ProjectCapabilityCardState(
            selectedTab: card.selectedTab,
            items: card.items.filter { !($0.kind == .mcp && $0.pluginID == pluginID && $0.name == serverName) },
            auditSummary: card.auditSummary
        )
    }

    private func sourcePath(pluginID: String, skillRef: String) -> String? {
        guard let source = catalog?.plugins.first(where: { $0.id == pluginID })?.source,
              case .local(let root) = source else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(skillRef, isDirectory: true).path
    }

    private func skillRef(matching item: ProjectCapabilityCardState.Item) -> String? {
        guard let plugin = catalog?.plugins.first(where: { $0.id == item.pluginID }),
              case .local(let root) = plugin.source else { return nil }
        let itemPath = URL(fileURLWithPath: item.sourcePath).standardizedFileURL.path
        return plugin.skills.first { skill in
            URL(fileURLWithPath: root)
                .appendingPathComponent(skill.relativePath, isDirectory: true)
                .standardizedFileURL.path == itemPath
        }?.relativePath
    }
}
