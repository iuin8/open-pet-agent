import Combine
import Foundation

@MainActor
public final class ProjectCapabilityColumnState: ObservableObject {
    @Published public private(set) var card: ProjectCapabilityCardState
    @Published public private(set) var syncMessages: [String]

    private let onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)?
    private let onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)?
    private let onAddSkill: ((String, String) -> ProjectCapabilityCardState)?
    private let onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)?
    private let onSyncCodex: (() -> String)?
    private let onSyncClaudeCode: (() -> String)?
    private let onSyncOpencode: (() -> String)?

    public init(
        card: ProjectCapabilityCardState,
        syncMessages: [String] = [],
        onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)? = nil,
        onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)? = nil,
        onAddSkill: ((String, String) -> ProjectCapabilityCardState)? = nil,
        onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)? = nil,
        onSyncCodex: (() -> String)? = nil,
        onSyncClaudeCode: (() -> String)? = nil,
        onSyncOpencode: (() -> String)? = nil
    ) {
        self.card = card
        self.syncMessages = syncMessages
        self.onSetEnabled = onSetEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onAddSkill = onAddSkill
        self.onAddMCP = onAddMCP
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

    private func refreshPreservingTab(_ refreshed: ProjectCapabilityCardState) {
        card = ProjectCapabilityCardState(selectedTab: card.selectedTab, items: refreshed.items)
    }
}
