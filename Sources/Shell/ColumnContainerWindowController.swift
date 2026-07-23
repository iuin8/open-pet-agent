import AgentSensing
import AppKit
import SwiftUI

/// 列容器窗口控制器（取代多窗口侧卡:`SideCardStack` + 3 个卡控制器 + beak）。
/// **一个** `.nonactivatingPanel` 贴主陪伴卡片空白侧,内含 `MillerColumnsView` 横滚列。
/// 主卡行点击 → `openRoot`（清栈置单列,同源 toggle 关）;列内行 → `drillIn`（截断 + 追加）;跟随主卡移动/层级。
@MainActor
public final class ColumnContainerWindowController {

    public var window: NSPanel? { panel }
    public var isVisible: Bool { panel?.isVisible == true }
    public let state = ColumnContainerState()
    /// 容器关闭时回调（清主卡行 halo 等）。
    public var onClosed: (() -> Void)?
    /// 主卡当前钉住态 provider（wiring 注入）—— 开容器时据它同步层级,使容器与主卡同层(否则主卡浮顶、容器 .normal 切 Space 消失)。
    public var mainPinnedProvider: (() -> Bool)?
    /// 即将打开根列时回调（wiring 注入）—— **同时只一张侧卡**:开列容器前关掉浏览历史 sheet(互斥)。
    public var onWillOpen: (() -> Void)?
    /// 列内 Workflow 工具行 pill 点击。App wiring 注入，避免把 workflow 行点击本身从 detail 改成导航。
    public var onOpenWorkflow: ((String) -> Void)?
    /// 窗口**置顶**态(根列置顶按钮)→ 点主卡不 dismiss(App `dismissSideCards` 据此豁免)+ 常驻浮顶。
    public var isPinned: Bool { state.isPinned }

    public init() {
        // 根列置顶按钮 → 翻 isPinned + 应用窗口层级(置顶=常驻;取消=回落跟主卡)。
        state.onTogglePin = { [weak self] in
            guard let self else { return }
            self.state.isPinned.toggle()
            if self.state.isPinned { WindowPinState.apply(self.panel, pinned: true) }
            else { self.applyMainPinned(self.mainPinnedProvider?() ?? false) }
        }
    }

    /// 从主卡某行打开根列。同 sourceKey + 容器可见 → toggle 关（`state.openRoot` 返回 false）。
    public func openRoot(_ kind: ColumnKind, sourceKey: String, besideMain: NSRect, screen: NSRect) {
        guard state.openRoot(kind, sourceKey: sourceKey) else { close(); return }
        onWillOpen?()   // 互斥:开列容器 → 关浏览 sheet(侧卡同时只一张)
        state.isPinned = false   // 新开根列 → 默认不置顶(可被点主卡 dismiss)
        if panel == nil { createPanel() }
        applyMainPinned(mainPinnedProvider?() ?? false)   // I-1:容器层级跟主卡(主卡默认钉住 → 容器也浮顶,跨 Space 常驻)
        repositionBesideMain(besideMain, screen: screen)
        panel?.orderFrontRegardless()   // accessory 下置前不抢焦点;未钉 .normal 切别 app 自然被盖
    }

    /// 列内行 drill-in:截断 + 追加 + 重定位（列总宽变了 → 容器宽随之变）。
    public func drillIn(columnId: Int, rowId: Int, into kind: ColumnKind) {
        state.drillIn(columnId: columnId, rowId: rowId, into: kind)
        if isVisible, let m = lastMainFrame { repositionBesideMain(m, screen: lastScreen) }
    }

    /// 会话流 rebuild 后，同步已打开 detail 列的 item 快照。
    public func replaceDetailItem(_ item: ConversationItem, sourceKey: String) {
        state.replaceDetailItem(item, sourceKey: sourceKey)
    }

    /// 关容器:清栈 + 收窗 + 回调。
    public func close() {
        state.close()
        panel?.orderOut(nil)
        onClosed?()
    }

    /// 贴主卡空白侧重定位(走 `BesideMainLayout` 单一真相,与浏览历史 sheet 同源)。
    /// 列总宽 > 可用宽 → 容器取可用宽,列在内部横向滚动(访达式超屏横滚);高 = 主卡高。
    public func repositionBesideMain(_ mainFrame: NSRect, screen: NSRect) {
        guard let panel, !state.stack.isEmpty else { return }
        lastMainFrame = mainFrame
        lastScreen = screen
        panel.setFrame(BesideMainLayout.frame(maxSize: NSSize(width: columnsTotalWidth, height: mainFrame.height),
                                              mainFrame: mainFrame, screen: screen), display: true)
    }

    /// 主卡钉住态 → 容器同步层级（钉住 floating+1 + .stationary 跨 Space 常驻;未钉 .normal + .transient 可被盖）。
    public func applyMainPinned(_ pinned: Bool) {
        WindowPinState.apply(panel, pinned: pinned)
    }

    // MARK: - 私有

    /// 所有列宽之和（每列 + 1pt Divider）—— 决定容器目标宽 / 是否横滚。
    private var columnsTotalWidth: CGFloat {
        state.stack.columns.reduce(0) { $0 + ColumnPaneView.width(for: $1.kind) + 1 }
    }

    private func createPanel() {
        let size = NSSize(width: 360, height: 480)   // 占位尺寸,首次 present 立即被 repositionBesideMain 覆盖
        let p = ColumnContainerPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.level = .normal
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let host = NSHostingView(rootView: MillerColumnsView(state: state, onOpenWorkflow: { [weak self] in self?.onOpenWorkflow?($0) }))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.appearance = NSAppearance(named: .aqua)
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        // 圆角与主卡一致(14, continuous)。用 host.layer.masksToBounds 而非 SwiftUI clipShape:
        // 列内是 AppKit NSTableView(TranscriptListView),layer 级裁切才能可靠收掉左下/右下方角;
        // 内容圆角外透明 → 窗口 hasShadow 按 alpha mask 沿圆角描边(同 PermissionCard)。
        host.wantsLayer = true
        host.layer?.cornerRadius = ChatCardTheme.cardRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        self.panel = p
    }

    private var panel: NSPanel?
    private var lastMainFrame: NSRect?
    private var lastScreen: NSRect = .zero
}

/// 列容器面板 —— `.nonactivatingPanel` 子类,override `canBecomeKey = true` 让侧卡
/// 能接收 ⌘C 等编辑键(选中文字 → 复制);`canBecomeMain = false` 保持不抢 app 焦点
/// (同 `ChatBubblePanel` 模式)。裸 `NSPanel` 默认 `canBecomeKey = false` → 侧卡选中
/// 文字后 ⌘C 不路由(2026-06-27 用户反馈「侧卡选中内容无法复制」根因)。
private final class ColumnContainerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
