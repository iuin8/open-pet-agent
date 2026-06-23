import AppKit
import Testing
@testable import Shell
@testable import Rendering

@Suite("DesktopShellController.dispatchSignature (N3.3)")
@MainActor
struct DispatchSignatureTests {

    // MARK: - Fake renderer

    /// 测试 double: 记录所有 trigger + 暴露可控 supportedSignatures。
    final class RecordingRenderer: PetRenderer {
        let contentLayer: CALayer = CALayer()
        var supportedSignatures: Set<SignatureAction>
        var triggered: [SignatureAction] = []

        init(supported: Set<SignatureAction> = []) {
            self.supportedSignatures = supported
        }

        func updateForState(_ state: PetEmotionState) {}
        func trigger(_ signature: SignatureAction) {
            triggered.append(signature)
        }
    }

    // MARK: - Helpers

    private func makeController() -> DesktopShellController {
        DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    // MARK: - Tests

    @Test("renderer 为 nil 时 dispatch 静默忽略 (不崩溃)")
    func dispatchNoRendererIsNoOp() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        controller.petRenderer = nil

        // 不该抛错 / crash
        controller.dispatchSignature(.celebrate)
        controller.dispatchSignature(.refuse)
        controller.dispatchSignature(.acknowledge)
    }

    @Test("supportedSignatures 不含 action 时不调 renderer.trigger")
    func dispatchUnsupportedSkipsTrigger() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let renderer = RecordingRenderer(supported: [.celebrate])
        controller.petRenderer = renderer

        controller.dispatchSignature(.refuse)
        controller.dispatchSignature(.acknowledge)

        #expect(renderer.triggered.isEmpty)
    }

    @Test("supportedSignatures 含 action 时调 renderer.trigger 且记录")
    func dispatchSupportedFiresTrigger() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let renderer = RecordingRenderer(supported: [.celebrate, .refuse, .acknowledge])
        controller.petRenderer = renderer

        controller.dispatchSignature(.celebrate)
        controller.dispatchSignature(.refuse)
        controller.dispatchSignature(.acknowledge)

        #expect(renderer.triggered == [.celebrate, .refuse, .acknowledge])
    }

    @Test("默认 PetRenderer (supportedSignatures 空集) 的 dispatch 全部忽略")
    func dispatchDefaultRendererIgnoresAll() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        // 不主动设 supported, 走默认空集
        let renderer = RecordingRenderer()
        controller.petRenderer = renderer

        // 全部都该被过滤掉
        for action in [SignatureAction.greet, .celebrate, .acknowledge, .refuse, .signatureIdle, .reactToDragEnd] {
            controller.dispatchSignature(action)
        }
        #expect(renderer.triggered.isEmpty)
    }

    // MARK: - applyPetChatBehavior talking → idle 路径

    @Test("applyPetChatBehavior talking → idle 触发 dispatchSignature(.celebrate)")
    func talkingToIdleDispatchesCelebrate() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let renderer = RecordingRenderer(supported: [.celebrate])
        controller.petRenderer = renderer

        controller.applyPetChatBehavior(.talking)
        controller.applyPetChatBehavior(.idle)

        #expect(renderer.triggered == [.celebrate])
    }

    @Test("applyPetChatBehavior idle → idle 不 dispatch celebrate (只 talking→idle 算)")
    func idleToIdleDoesNotDispatch() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let renderer = RecordingRenderer(supported: [.celebrate])
        controller.petRenderer = renderer

        controller.applyPetChatBehavior(.idle)
        controller.applyPetChatBehavior(.idle)

        #expect(renderer.triggered.isEmpty)
    }

    // MARK: - replacePetRenderer (N3.4 运行时切换)

    /// 跟踪 display link 调用次数的 renderer double。
    final class DisplayLinkTrackingRenderer: PetRenderer {
        let contentLayer: CALayer = CALayer()
        var pauseCount = 0
        var resumeCount = 0
        var statesReceived: [PetEmotionState] = []
        func updateForState(_ state: PetEmotionState) { statesReceived.append(state) }
        func pauseDisplayLink() { pauseCount += 1 }
        func resumeDisplayLink() { resumeCount += 1 }
    }

    @Test("replacePetRenderer: 旧 renderer pause, 新 renderer resume")
    func replacePausesOldResumesNew() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let old = DisplayLinkTrackingRenderer()
        controller.petRenderer = old

        let new = DisplayLinkTrackingRenderer()
        controller.replacePetRenderer(with: new)

        #expect(old.pauseCount == 1)
        #expect(new.resumeCount == 1)
        #expect(controller.petRenderer === new)
        // 旧的不被 resume
        #expect(old.resumeCount == 0)
    }

    @Test("replacePetRenderer: 替换后 petWindow.contentView host 承载新 renderer.contentLayer")
    func replaceSwapsContentView() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let new = DisplayLinkTrackingRenderer()

        controller.replacePetRenderer(with: new)

        #expect((controller.windowSet.petWindow.contentView as? PetLayerHostView)?.layer === new.contentLayer)
    }

    @Test("replacePetRenderer: 替换后右键菜单沿用 (drag handlers 在 window level)")
    func replacePreservesMenu() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let originalMenu = controller.windowSet.petWindow.contentView?.menu

        let new = DisplayLinkTrackingRenderer()
        controller.replacePetRenderer(with: new)

        #expect((controller.windowSet.petWindow.contentView as? PetLayerHostView)?.menu === originalMenu)
    }

    @Test("replacePetRenderer: 当前 ChatBehaviorState 自动重发给新 renderer")
    func replaceReissuesCurrentState() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let old = DisplayLinkTrackingRenderer()
        controller.petRenderer = old

        // 推 chat 到 .thinking
        controller.applyPetChatBehavior(.thinking)

        // 换 renderer, 新 renderer 应该立刻收到 .thinking
        let new = DisplayLinkTrackingRenderer()
        controller.replacePetRenderer(with: new)

        #expect(new.statesReceived == [.thinking])
    }

    @Test("replacePetRenderer(nil): 回 placeholder NSView, 旧 renderer pause")
    func replaceWithNilFallsBackToPlaceholder() {
        let controller = makeController()
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }
        let old = DisplayLinkTrackingRenderer()
        controller.petRenderer = old

        controller.replacePetRenderer(with: nil)

        #expect(controller.petRenderer == nil)
        #expect(old.pauseCount == 1)
        // contentView 是 placeholder host, 不再承载 old.contentLayer
        #expect((controller.windowSet.petWindow.contentView as? PetLayerHostView)?.layer !== old.contentLayer)
        #expect(controller.windowSet.petWindow.contentView != nil)
    }
}
