import AppKit

/// 三窗口（overlay / pet / chat）的**无状态构造工厂**。从 `DesktopShellController`
/// 抽出（P2，2026-06-10）——控制器只做窗口编排 + 事件路由，构造期的 descriptor
/// 解析 + NSWindow 配置样板下沉到这里，缩小控制器跨层职责与 AppKit 噪音。
///
/// 命名诚实：这是「构造」而非「协调」——窗口建好后由控制器持有（`windowSet`）并
/// 在运行时编排（拖拽/几何同步/菜单）。故不叫 `WindowCoordinator`。
///
/// `@MainActor`：构造 NSWindow/NSView 子类（`ChatShellView`/`DesktopOverlayView`/
/// `PetShellWindow` 等的 init 都是主线程隔离）。原静态方法在 `@MainActor` 控制器内
/// 隐式继承此隔离，迁出后需显式标注。
@MainActor
enum ShellWindowFactory {
    /// descriptor 解析结果：去重后的 kind→descriptor 映射 + 收集到的图诊断。
    struct DescriptorResolution {
        let descriptors: [WindowDescriptor.Kind: WindowDescriptor]
        let diagnostics: ShellGraphDiagnostics
    }

    static func resolveDescriptors(from windowGraph: WindowGraph) -> DescriptorResolution {
        var descriptors: [WindowDescriptor.Kind: WindowDescriptor] = [:]
        var issues: [ShellGraphDiagnostics.Issue] = []

        for descriptor in windowGraph.windows {
            if descriptors[descriptor.kind] != nil {
                issues.append(.duplicateKind(descriptor.kind))
                continue
            }

            descriptors[descriptor.kind] = descriptor
        }

        for fallbackDescriptor in fallbackDescriptors {
            if descriptors[fallbackDescriptor.kind] == nil {
                issues.append(.missingKind(fallbackDescriptor.kind))
                descriptors[fallbackDescriptor.kind] = fallbackDescriptor
            }
        }

        return DescriptorResolution(
            descriptors: descriptors,
            diagnostics: ShellGraphDiagnostics(issues: issues)
        )
    }

    static func makeWindowSet(
        descriptors: [WindowDescriptor.Kind: WindowDescriptor],
        screenFrame: NSRect,
        initialState: ShellInitialState,
        chatReplyHandler: @escaping ChatShellView.ReplyHandler
    ) -> ShellWindowSet {
        let overlayWindow = makeOverlayWindow(
            descriptor: descriptors[.overlay] ?? fallbackDescriptor(for: .overlay),
            screenFrame: screenFrame
        )
        let petWindow = makePetWindow(
            descriptor: descriptors[.pet] ?? fallbackDescriptor(for: .pet),
            screenFrame: screenFrame,
            initialState: initialState
        )
        let chatWindow = makeChatWindow(
            descriptor: descriptors[.chat] ?? fallbackDescriptor(for: .chat),
            petFrame: petWindow.frame,
            replyHandler: chatReplyHandler
        )

        return ShellWindowSet(
            overlayWindow: overlayWindow,
            petWindow: petWindow,
            chatWindow: chatWindow
        )
    }

    static var fallbackDescriptors: [WindowDescriptor] {
        [
            WindowDescriptor(kind: .overlay, isInteractive: false, level: 0),
            WindowDescriptor(kind: .pet, isInteractive: true, level: 1),
            WindowDescriptor(kind: .chat, isInteractive: true, level: 2)
        ]
    }

    static func fallbackDescriptor(for kind: WindowDescriptor.Kind) -> WindowDescriptor {
        fallbackDescriptors.first(where: { $0.kind == kind }) ?? WindowDescriptor(kind: kind, isInteractive: true, level: 0)
    }

    static func makeOverlayWindow(
        descriptor: WindowDescriptor,
        screenFrame: NSRect
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenPetAgent Overlay"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = !descriptor.isInteractive
        // `.floating` (3) instead of `.screenSaver` (1000) so the overlay
        // still sits above normal app windows (level 0) — keeping the
        // snow visible on top of the user's desktop — but stays below
        // the system menu popups (`.popUpMenu` = 101) and the menu bar
        // / status item windows (`.mainMenu`/.statusBar` = 24/25). That
        // way clicking a menu bar item or right-clicking a status icon
        // brings the popup *above* the snow instead of letting the
        // snow cover the menu the user is trying to read.
        window.level = .floating
        // `.fullScreenAuxiliary` 让桌面 overlay（雪/天气）也能出现在全屏 app（如 VSCode 全屏）
        // 的独立 Space 上 —— 否则用户全屏编辑器时桌面内容整片消失（情绪/主动气泡因配了此项仍显示，
        // 形成「气泡孤零零浮着、内容不见」的断裂）。对齐 HermesPet ClawdWalkOverlay 的窗口配置。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = DesktopOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
        return window
    }

    static func makePetWindow(
        descriptor: WindowDescriptor,
        screenFrame: NSRect,
        initialState: ShellInitialState
    ) -> NSWindow {
        let size = NSSize(width: 72, height: 72)
        let origin = NSPoint(
            x: screenFrame.minX + initialState.petPositionX,
            y: screenFrame.minY + initialState.petPositionY
        )
        // 根因#2 修复:pet 窗口必须 `.borderless`(非 `.titled`)。`.titled` 被 AppKit 当「标准
        // 用户管理窗口」,逐帧程序化 setFrameOrigin 重定位时 NSWindow.frame 更新但窗口服务器不提交
        // → 漫步/爬墙算出位置却屏上不动。所有工作中的桌面漫步桌宠(HermesPet ClawdWalkOverlay /
        // agentpet PetWindowController = borderless NSPanel + 每帧 setFrameOrigin;AccountyCat =
        // borderless NSWindow)一律用 borderless 自由漂浮窗。
        let window = PetShellWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureFloatingWindow(window, descriptor: descriptor, title: "OpenPetAgent Pet")
        // 改2:pet 窗口放弃 AppKit 背景拖拽,改由 PetShellWindow.sendEvent 显式 mouseDragged 接管
        // (对齐 HermesPet/Shimeji)。AppKit 背景拖拽走窗口服务器、起止点不确定,与 60fps 漫游
        // setFrameOrigin 抢窗口、且 drag 结束检测不可靠;显式驱动让 grab 起/移/止确定。
        window.isMovableByWindowBackground = false
        window.contentView = makePlaceholderView(
            title: "Pet Shell",
            subtitle: "Desktop companion shell is alive.",
            backgroundColor: NSColor.systemOrange.withAlphaComponent(0.92)
        )
        return window
    }

    static func makeChatWindow(
        descriptor: WindowDescriptor,
        petFrame: NSRect,
        replyHandler: @escaping ChatShellView.ReplyHandler
    ) -> NSWindow {
        // Bubble visual occupies 320×200; we wrap it with `shadowMargin`
        // on every edge so the bubble's `CALayer.shadowPath` has room to
        // render without being clipped at the contentView edge.
        let bubbleSize = NSSize(width: 320, height: 200)
        let margin = ChatBubbleTheme.shadowMargin
        let size = NSSize(width: bubbleSize.width + 2 * margin, height: bubbleSize.height + 2 * margin)
        let origin = NSPoint(
            x: petFrame.maxX + 40 - margin,
            y: petFrame.midY - (size.height / 2)
        )
        // NSPanel + `.nonactivatingPanel` — clicking the bubble doesn't
        // pull the app forward. `.fullSizeContentView` removes the
        // titlebar so the bubble is the entire window.
        let panel = ChatBubblePanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title is still set for accessibility / window menus / tests that
        // identify the chat window. It is not visible (no titlebar).
        panel.title = "OpenPetAgent Chat"
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Transparent host: the bubble draws its own background + shadow.
        // System window shadow would draw a rectangle around the content,
        // not the bubble outline — turn it off.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Float above normal app windows, visible across spaces + fullscreen.
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = !descriptor.isInteractive
        panel.animationBehavior = .none
        panel.contentView = ChatShellView(replyHandler: replyHandler)
        return panel
    }

    static func configureFloatingWindow(
        _ window: NSWindow,
        descriptor: WindowDescriptor,
        title: String
    ) {
        window.title = title
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        // 补 `.stationary`（对齐 HermesPet ClawdWalkOverlay + 本项目情绪/主动气泡的配置）：
        // 让桌宠在全屏 app（VSCode 全屏等）的独立 Space 上稳定显示，不随 Space 切换漂移。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = !descriptor.isInteractive
        // Transparent host — without this the `.titled` styleMask's default
        // NSWindow backgroundColor (controlBackgroundColor / off-white) and
        // rectangular system shadow leak around the Orb's circular SDF as
        // a visible white box. Pet's Orb is round, its window must be
        // fully transparent and not draw a system shadow.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
    }

    static func makePlaceholderView(
        title: String,
        subtitle: String,
        backgroundColor: NSColor
    ) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        view.layer?.cornerRadius = 20

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
        ])

        return view
    }
}
