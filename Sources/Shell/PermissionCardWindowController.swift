import AgentSensing
import AppKit
import SwiftUI

/// pet 旁权限侧卡的**尖角几何**(controller 据锚定结果驱动:pet 模式尖角指 pet,row 模式指会话消息行)。
@MainActor
public final class PermissionCardState: ObservableObject {
    @Published var tailSide: SpeechBubbleTailSide = .bottom
    @Published var tailPercent: CGFloat = 0.5
}

/// pet 旁的**权限侧卡**控制器(2026-06-16):待答队列非空时弹一张带**尖角**的自适应高度 NSPanel
/// (`PermissionStackView` 堆叠队列),空时收起。陪伴卡片关着也能显示 —— 默认锚 **pet**(`ChatCardAnchor`)。
///
/// 两种锚定模式(尖角随之改向):
/// - **pet 模式**(默认):尖角指 pet,贴 pet 旁(同对话卡片选边/clamp)。
/// - **row 模式**(点卡上「定位会话」后):贴陪伴卡片空白侧 + 尖角对准触发请求的那条消息行(类 `AgentDetailCardWindowController`)。
///   再点「定位」切回 pet 模式。row 模式的行 Y 实时取 `store.highlightedRowMidY`(行可见时上报)→ 行滚动/卡片移动时尖角跟随。
@MainActor
public final class PermissionCardWindowController {

    public var isVisible: Bool { panel?.isVisible == true }
    /// 当前是否 row 模式(尖角指消息行)。App 据此把「定位」做成 toggle。
    public var isRowAnchored: Bool { rowAnchored }

    private let store: AgentSessionStore
    private let card = PermissionCardState()
    private var panel: PermissionPanel?
    private var host: NSHostingView<PermissionStackView>?

    /// App 注入:陪伴卡片窗口 frame(row 模式贴它旁 + 对齐消息行)。缺席/zero → 退回 pet 模式。
    public var companionCardFrameProvider: (() -> NSRect?)?

    private var rowAnchored = false
    private var lastPetRect: NSRect = .zero
    private var lastScreen: NSRect = .zero

    public init(store: AgentSessionStore) { self.store = store }

    /// 切到 row 模式(尖角重锚到陪伴卡片里高亮的消息行)。App 须先 `highlightedItemId = 行id` 让行上报 midY。
    /// 行 midY 写链跨多个主队列 hop(highlightedItemId→SwiftUI updateNSView→coordinator async),冷启动首渲染
    /// 可能 >固定延迟才就绪 → **有限重试**(~1.6s)轮询到 midY 就绪再 row 锚,避免踩空后静默回退 pet。
    public func anchorToRow() { rowAnchored = true; relayoutAwaitingRow(attempt: 0) }
    /// 切回 pet 模式(尖角指 pet)。
    public func returnToPet() { rowAnchored = false; relayout() }

    private func relayoutAwaitingRow(attempt: Int) {
        relayout()
        guard rowAnchored, store.highlightedRowMidY == 0, attempt < 16 else { return }   // midY 未就绪 → 重试
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.rowAnchored else { return }
            self.relayoutAwaitingRow(attempt: attempt + 1)
        }
    }

    /// 据队列同步:非空 → 在合适位置弹/重排;空 → 收起(并复位回 pet 模式)。
    /// 调用方应在**队列变化后下一拍**调(让 SwiftUI 先按新队列重排,measure 才准)。
    public func sync(petRect: NSRect, screen: NSRect) {
        guard !store.pendingQueue(for: .claudeCode).isEmpty else { rowAnchored = false; hide(); return }
        if panel == nil { createPanel() }
        lastPetRect = petRect
        lastScreen = screen
        relayout()
    }

    public func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }

    // MARK: - 布局

    /// 按当前模式重新定位 + 驱动尖角。row 模式拿得到陪伴卡片 frame + 行 midY → 贴卡旁指行;否则 pet 模式。
    private func relayout() {
        guard let panel, let host, !store.pendingQueue(for: .claudeCode).isEmpty else { return }
        host.layoutSubtreeIfNeeded()
        let rowMidY = store.highlightedRowMidY
        if rowAnchored, rowMidY != 0, let cardFrame = companionCardFrameProvider?(), cardFrame != .zero {
            placeBesideCard(panel: panel, host: host, cardFrame: cardFrame, rowMidY: rowMidY, screen: lastScreen)
        } else {
            placeBesidePet(panel: panel, host: host, petRect: lastPetRect, screen: lastScreen)
        }
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    /// pet 模式:`ChatCardAnchor` 选边 + clamp,尖角指 pet。beak 换轴(竖↔横)会改 fittingSize → 换轴后复测一次,
    /// **origin / tailPercent / setFrame 全用同一个 `size`**(避免 origin 用旧尺寸、frame 用新尺寸的不一致)。
    private func placeBesidePet(panel: PermissionPanel, host: NSHostingView<PermissionStackView>, petRect: NSRect, screen: NSRect) {
        var size = host.fittingSize
        var place = ChatCardAnchor.place(anchor: petRect, in: screen, cardSize: size)
        let side = ChatCardAnchor.tailSide(for: place.edge)
        if side != card.tailSide {                       // beak 换轴 → 复测 + 用新尺寸重算 origin
            card.tailSide = side
            host.layoutSubtreeIfNeeded()
            size = host.fittingSize
            place = ChatCardAnchor.place(anchor: petRect, in: screen, cardSize: size)
            card.tailSide = ChatCardAnchor.tailSide(for: place.edge)
        }
        card.tailPercent = ChatCardAnchor.tailPercent(edge: place.edge, petRect: petRect, cardOrigin: place.origin, cardSize: size)
        panel.setFrame(NSRect(origin: place.origin, size: size), display: true)
    }

    /// row 模式:贴陪伴卡片空白侧(右优先,不够贴左)+ 垂直对齐消息行 + 尖角横向指行(类 `AgentDetailCardWindowController`)。
    private func placeBesideCard(panel: PermissionPanel, host: NSHostingView<PermissionStackView>, cardFrame: NSRect, rowMidY: CGFloat, screen: NSRect) {
        let gap: CGFloat = 4, margin: CGFloat = 12
        let estWidth = PermissionStackView.width + PermissionStackView.beak
        let onRight = (screen.maxX - cardFrame.maxX) >= estWidth + gap
        card.tailSide = onRight ? .left : .right    // 贴右 → 左尖角(指向卡);贴左 → 右尖角
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let x = onRight ? cardFrame.maxX + gap : cardFrame.minX - gap - size.width
        let rowScreenY = cardFrame.maxY - rowMidY   // top-down 窗口 midY → 屏幕 Y-up
        let rawY = rowScreenY - size.height / 2
        let y = Swift.min(Swift.max(rawY, screen.minY + margin), screen.maxY - size.height - margin)
        // 尖角纵向比例:卡身屏幕跨 [y, y+h](Y-up),顶 = y+h;clamp 后即便卡身中心 ≠ 行 Y,尖角仍精确指行 Y。
        let pct = (y + size.height - rowScreenY) / size.height
        card.tailPercent = Swift.max(0.08, Swift.min(0.92, pct))
        host.layoutSubtreeIfNeeded()
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func createPanel() {
        let p = PermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: PermissionStackView.width + PermissionStackView.beak, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true   // 系统按带尖角的 alpha mask 精确绘制阴影(随尖角)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let h = NSHostingView(rootView: PermissionStackView(store: store, card: card))
        h.appearance = NSAppearance(named: .aqua)
        if #available(macOS 13.0, *) { h.sizingOptions = [.intrinsicContentSize] }
        p.contentView = h
        self.panel = p
        self.host = h
    }
}

/// `canBecomeKey = true` 让权限卡的自定义答案 `TextField` 能接键盘输入 + 选项按钮点击。
final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
