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
    @Published public private(set) var card: ProjectCapabilityCardState
    @Published public private(set) var catalog: ProjectCapabilityCatalogModel?
    @Published public private(set) var syncMessages: [String]

    public var onOpenSkillDetail: ((Int, ProjectCapabilitySkillDetailState) -> Void)?

    private let onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)?
    private let onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)?
    private let onAddSkill: ((String, String) -> ProjectCapabilityCardState)?
    private let onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)?
    private let onUpdateSkillBody: ((String, String, String) throws -> ProjectCapabilitySnapshot?)?
    private let onRefreshCatalog: (() -> ProjectCapabilityCatalogModel?)?
    private let onSyncCodex: (() -> String)?
    private let onSyncClaudeCode: (() -> String)?
    private let onSyncOpencode: (() -> String)?

    public init(
        card: ProjectCapabilityCardState,
        catalog: ProjectCapabilityCatalogModel? = nil,
        syncMessages: [String] = [],
        onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)? = nil,
        onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)? = nil,
        onAddSkill: ((String, String) -> ProjectCapabilityCardState)? = nil,
        onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)? = nil,
        onUpdateSkillBody: ((String, String, String) throws -> ProjectCapabilitySnapshot?)? = nil,
        onRefreshCatalog: (() -> ProjectCapabilityCatalogModel?)? = nil,
        onSyncCodex: (() -> String)? = nil,
        onSyncClaudeCode: (() -> String)? = nil,
        onSyncOpencode: (() -> String)? = nil
    ) {
        self.card = card
        self.catalog = catalog
        self.syncMessages = syncMessages
        self.onSetEnabled = onSetEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onAddSkill = onAddSkill
        self.onAddMCP = onAddMCP
        self.onUpdateSkillBody = onUpdateSkillBody
        self.onRefreshCatalog = onRefreshCatalog
        self.onSyncCodex = onSyncCodex
        self.onSyncClaudeCode = onSyncClaudeCode
        self.onSyncOpencode = onSyncOpencode
    }

    public func selectTab(_ tab: ProjectCapabilityCardState.Tab) {
        card = ProjectCapabilityCardState(selectedTab: tab, items: card.items)
    }

    public func setPluginEnabled(pluginID: String, enabled: Bool) {
        guard let onSetEnabled else { return }
        refreshPreservingTab(onSetEnabled(pluginID, enabled))
    }

    public func createPlugin(pluginID: String, name: String) {
        guard let onCreatePlugin else { return }
        refreshPreservingTab(onCreatePlugin(pluginID, name))
    }

    public func addSkill(pluginID: String, skillName: String) {
        guard let onAddSkill else { return }
        refreshPreservingTab(onAddSkill(pluginID, skillName))
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

    public func openItem(_ item: ProjectCapabilityCardState.Item, rowID: Int) {
        guard item.kind == .skill,
              let skillRef = skillRef(matching: item),
              let detail = skillDetail(pluginID: item.pluginID, skillRef: skillRef) else { return }
        onOpenSkillDetail?(rowID, detail)
    }

    public func syncCodex() {
        guard let onSyncCodex else { return }
        syncMessages.append(onSyncCodex())
    }

    public func syncClaudeCode() {
        guard let onSyncClaudeCode else { return }
        syncMessages.append(onSyncClaudeCode())
    }

    public func syncOpencode() {
        guard let onSyncOpencode else { return }
        syncMessages.append(onSyncOpencode())
    }

    private func apply(_ snapshot: ProjectCapabilitySnapshot) {
        catalog = snapshot.catalog
        card = ProjectCapabilityCardState(selectedTab: card.selectedTab, items: snapshot.card.items)
    }

    private func refreshPreservingTab(_ refreshed: ProjectCapabilityCardState) {
        card = ProjectCapabilityCardState(selectedTab: card.selectedTab, items: refreshed.items)
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
