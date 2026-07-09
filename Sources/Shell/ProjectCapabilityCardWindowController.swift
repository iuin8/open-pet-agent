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
    private var onCreatePlugin: (() -> ProjectCapabilityCardState)?
    private var onAddSkill: (() -> ProjectCapabilityCardState)?
    private var onAddMCP: (() -> ProjectCapabilityCardState)?

    public init() {}

    public func show(
        card: ProjectCapabilityCardState,
        petRect: NSRect,
        screen: NSRect,
        onSetEnabled: @escaping (String, Bool) -> ProjectCapabilityCardState,
        onCreatePlugin: @escaping () -> ProjectCapabilityCardState,
        onAddSkill: @escaping () -> ProjectCapabilityCardState,
        onAddMCP: @escaping () -> ProjectCapabilityCardState
    ) {
        currentCard = card
        lastPetRect = petRect
        lastScreen = screen
        self.onSetEnabled = onSetEnabled
        self.onCreatePlugin = onCreatePlugin
        self.onAddSkill = onAddSkill
        self.onAddMCP = onAddMCP
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

    private func createPlugin() {
        guard let onCreatePlugin else { return }
        currentCard = onCreatePlugin()
        renderAndPlace()
    }

    private func addSkill() {
        guard let onAddSkill else { return }
        let tab = currentCard.selectedTab
        let refreshed = onAddSkill()
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: refreshed.items)
        renderAndPlace()
    }

    private func addMCP() {
        guard let onAddMCP else { return }
        let tab = currentCard.selectedTab
        let refreshed = onAddMCP()
        currentCard = ProjectCapabilityCardState(selectedTab: tab, items: refreshed.items)
        renderAndPlace()
    }

    private func renderAndPlace() {
        guard let panel, let host else { return }
        host.rootView = rootView()
        host.layoutSubtreeIfNeeded()
        let width: CGFloat = 380
        let height = min(max(host.fittingSize.height, 220), min(520, lastScreen.height - 24))
        let size = NSSize(width: width, height: height)
        let placement = ChatCardAnchor.place(anchor: lastPetRect, in: lastScreen, cardSize: size)
        panel.setFrame(NSRect(origin: placement.origin, size: size), display: true)
    }

    private func rootView() -> AnyView {
        AnyView(
            ScrollView {
                ProjectCapabilityManagerView(
                    state: currentCard,
                    onSelectTab: { [weak self] tab in self?.selectTab(tab) },
                    onSetEnabled: { [weak self] pluginID, enabled in self?.setPluginEnabled(pluginID: pluginID, enabled: enabled) },
                    onCreatePlugin: { [weak self] in self?.createPlugin() },
                    onAddSkill: { [weak self] in self?.addSkill() },
                    onAddMCP: { [weak self] in self?.addMCP() },
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
