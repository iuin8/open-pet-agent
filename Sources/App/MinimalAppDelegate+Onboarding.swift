import AppKit
import SwiftUI
import Rendering
import Shell

// MARK: - MinimalAppDelegate + 开箱 onboarding

extension MinimalAppDelegate {

    // MARK: 社区弹窗（CommunityPetsSheet）

    /// 用 NSPanel 托管 `CommunityPetsSheet`，照搬 SessionBrowse 无边框浮层模式。
    /// `onInstalled` 复用 SettingsWindowController.rebuildPetListForOnboarding()。
    @MainActor
    func showCommunitySheet(initialTab: CommunityTab) {
        // 全新启动用户从未开过设置 → settingsWindowController 为 nil;懒建(不显示窗口)拿到其封装的 sheet。
        ensureSettingsWindowController()
        guard let settingsCtrl = settingsWindowController else { return }

        // 已有面板时关旧的，防止多开。
        onboardingCommunityPanel?.close()
        onboardingCommunityPanel = nil

        let sheet = settingsCtrl.makeCommunityPetsSheet(
            initialTab: initialTab,
            // NSPanel 托管下 @Environment(\.dismiss) 是 no-op,「完成」须经此回调关面板。
            onClose: { [weak self] in
                self?.onboardingCommunityPanel?.close()
                self?.onboardingCommunityPanel = nil
            },
            // 经 self 重解析当前控制器:用户在面板开着时打开设置会重建控制器,捕获旧实例会失效(列表不刷新)。
            onInstalled: { [weak self] in
                self?.settingsWindowController?.rebuildPetListForOnboarding()
            }
        )
        let panel = makeFloatingPanel(hosting: sheet, size: NSSize(width: 480, height: 580))
        panel.makeKeyAndOrderFront(nil)
        onboardingCommunityPanel = panel
    }

    // MARK: 开箱推荐卡判定 + 弹出

    /// discover 之后调：空社区库 + 未 dismissed → 延迟弹开箱推荐卡。
    @MainActor
    func maybeShowStarterOnboarding() {
        // 调试入口(env `PETAGENT_DEBUG_COMMUNITY`):启动后直接弹社区桌宠弹窗 —— 绕开「满库
        // onboarding 不触发」+「设置→管理库→获取社区桌宠」多步导航,供真机截图验证社区获取功能
        //(computer-use 解析不到 .accessory 菜单栏 app,用此 + CLI 截窗)。登记见 development-guide.md。
        if ProcessInfo.processInfo.environment["PETAGENT_DEBUG_COMMUNITY"] != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.showCommunitySheet(initialTab: .codex)
            }
            return
        }
        let communityCount = CodexSpritePackLoader.discover().count
                           + Live2DModelPackLoader.discover().count
        let dismissed = userDefaults.bool(forKey: OnboardingStarters.dismissedKey)

        guard OnboardingStarters.shouldShow(
            communityPetCount: communityCount,
            dismissed: dismissed
        ) else { return }

        // 延迟 1 秒让 app 完全就绪（窗口渲染 / 状态栏 / 权限弹窗）再弹。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.showStarterOnboardingPanel()
        }
    }

    // MARK: 推荐卡 NSPanel

    @MainActor
    private func showStarterOnboardingPanel() {
        // 懒建 settingsWindowController(不显示窗口)—— 全新启动用户没开过设置时,onboarding 仍能
        // 经它拿到 CommunityPetsSheet。这正是 onboarding 的目标场景,不能因 controller 缺失而不弹卡。
        ensureSettingsWindowController()

        let view = OnboardingStartersView(
            onSelectShimeji: { [weak self] in
                self?.starterOnboardingPanel?.close()
                self?.starterOnboardingPanel = nil
                self?.showCommunitySheet(initialTab: .shimeji)
            },
            onSelectCodex: { [weak self] in
                self?.starterOnboardingPanel?.close()
                self?.starterOnboardingPanel = nil
                self?.showCommunitySheet(initialTab: .codex)
            },
            onDismiss: { [weak self] in
                self?.starterOnboardingPanel?.close()
                self?.starterOnboardingPanel = nil
                self?.userDefaults.set(true, forKey: OnboardingStarters.dismissedKey)
            }
        )
        // 宽度固定 400（OnboardingStartersView 内部约束），高度给足让 SwiftUI 自适应。
        let panel = makeFloatingPanel(hosting: view, size: NSSize(width: 400, height: 320))
        panel.makeKeyAndOrderFront(nil)
        starterOnboardingPanel = panel
    }

    // MARK: NSPanel 工厂（照搬 SessionBrowse 无边框浮层模式）

    /// 构造标准无边框浮层 NSPanel，托管任意 SwiftUI View。居中显示。
    @MainActor
    private func makeFloatingPanel<V: View>(hosting view: V, size: NSSize) -> NSPanel {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.center()
        return panel
    }
}
