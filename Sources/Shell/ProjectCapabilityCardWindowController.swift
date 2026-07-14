import AppKit
import SwiftUI

@MainActor
public final class ProjectCapabilityCardWindowController {
    public var window: NSPanel? { panel }
    public var card: ProjectCapabilityCardState { currentCard }

    private var panel: ProjectCapabilityCardPanel?
    private var host: NSHostingView<AnyView>?
    private var currentCard = ProjectCapabilityCardState(selectedTab: .skills, items: [])
    private var lastPetRect: NSRect = .zero
    private var lastScreen: NSRect = .zero
    private var onSetEnabled: ((String, Bool) -> ProjectCapabilityCardState)?
    private var onCreatePlugin: ((String, String) -> ProjectCapabilityCardState)?
    private var onAddSkill: ((String, String, String, String) -> ProjectCapabilityCardState)?
    private var onAddMCP: ((String, String, [String]) -> ProjectCapabilityCardState)?
    private var onSyncCodex: (() -> String)?
    private var onSyncClaudeCode: (() -> String)?
    private var onSyncOpencode: (() -> String)?
    private(set) public var syncMessages: [String] = []

    public init() {}

    public func show(
        card: ProjectCapabilityCardState,
        petRect: NSRect,
        screen: NSRect,
        onSetEnabled: @escaping (String, Bool) -> ProjectCapabilityCardState,
        onCreatePlugin: @escaping (String, String) -> ProjectCapabilityCardState,
        onAddSkill: @escaping (String, String, String, String) -> ProjectCapabilityCardState,
        onAddMCP: @escaping (String, String, [String]) -> ProjectCapabilityCardState,
        onSyncCodex: @escaping () -> String,
        onSyncClaudeCode: @escaping () -> String,
        onSyncOpencode: @escaping () -> String
    ) {
        currentCard = card
        lastPetRect = petRect
        lastScreen = screen
        self.onSetEnabled = onSetEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onAddSkill = onAddSkill
        self.onAddMCP = onAddMCP
        self.onSyncCodex = onSyncCodex
        self.onSyncClaudeCode = onSyncClaudeCode
        self.onSyncOpencode = onSyncOpencode
        if panel == nil { createPanel() }
        renderAndPlace()
        panel?.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func selectTab(_ tab: ProjectCapabilityCardState.Tab) {
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: currentCard.items)
        renderAndPlace()
    }

    public func setPluginEnabled(pluginID: String, enabled: Bool) {
        guard let onSetEnabled else { return }
        let tab = currentCard.selectedTab
        let refreshed = onSetEnabled(pluginID, enabled)
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: refreshed.items)
        renderAndPlace()
    }

    private func createPlugin(pluginID: String, name: String) {
        guard let onCreatePlugin else { return }
        currentCard = onCreatePlugin(pluginID, name)
        renderAndPlace()
    }

    private func addSkill(pluginID: String, skillName: String, skillDescription: String, body: String) {
        guard let onAddSkill else { return }
        let tab = currentCard.selectedTab
        let refreshed = onAddSkill(pluginID, skillName, skillDescription, body)
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: refreshed.items)
        renderAndPlace()
    }

    private func addMCP(pluginID: String, serverName: String, command: [String]) {
        guard let onAddMCP else { return }
        let tab = currentCard.selectedTab
        let refreshed = onAddMCP(pluginID, serverName, command)
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: refreshed.items)
        renderAndPlace()
    }

    public func syncCodex() {
        guard let onSyncCodex else { return }
        syncMessages.append(onSyncCodex())
        renderAndPlace()
    }

    public func syncClaudeCode() {
        guard let onSyncClaudeCode else { return }
        syncMessages.append(onSyncClaudeCode())
        renderAndPlace()
    }

    public func syncOpencode() {
        guard let onSyncOpencode else { return }
        syncMessages.append(onSyncOpencode())
        renderAndPlace()
    }

    private func renderAndPlace() {
        guard let panel, let host else { return }
        host.rootView = rootView()
        host.layoutSubtreeIfNeeded()
        let width: CGFloat = 380
        let height = min(max(host.fittingSize.height, 220), min(520, lastScreen.height - 24))
        let size = NSSize(width: width, height: height)
        let origin = panel.isVisible
            ? panel.frame.origin
            : ChatCardAnchor.place(anchor: lastPetRect, in: lastScreen, cardSize: size).origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func rootView() -> AnyView {
        AnyView(
            ScrollView {
                ProjectCapabilityManagerView(
                    state: currentCard,
                    syncMessages: syncMessages,
                    onSelectTab: { [weak self] tab in self?.selectTab(tab) },
                    onSetEnabled: { [weak self] pluginID, enabled in self?.setPluginEnabled(pluginID: pluginID, enabled: enabled) },
                    onCreatePlugin: { [weak self] pluginID, name in self?.createPlugin(pluginID: pluginID, name: name) },
                    onAddSkill: { [weak self] pluginID, skillName, skillDescription, body in self?.addSkill(pluginID: pluginID, skillName: skillName, skillDescription: skillDescription, body: body) },
                    onAddMCP: { [weak self] pluginID, serverName, command in self?.addMCP(pluginID: pluginID, serverName: serverName, command: command) },
                    onSyncCodex: { [weak self] in self?.syncCodex() },
                    onSyncClaudeCode: { [weak self] in self?.syncClaudeCode() },
                    onSyncOpencode: { [weak self] in self?.syncOpencode() },
                    onClose: { [weak self] in self?.hide() }
                )
                .frame(width: 360)
                .padding(6)
            }
            .frame(width: 380)
            .frame(maxHeight: 520)
        )
    }

    private func createPanel() {
        let p = ProjectCapabilityCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let h = NSHostingView(rootView: rootView())
        h.appearance = NSAppearance(named: .aqua)
        if #available(macOS 13.0, *) { h.sizingOptions = [] }
        p.contentView = h
        panel = p
        host = h
    }
}

final class ProjectCapabilityCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
