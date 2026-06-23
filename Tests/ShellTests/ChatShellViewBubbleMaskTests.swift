import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("ChatShellView — speech-bubble mask wiring")
struct ChatShellViewBubbleMaskTests {

    @Test("Initial view has a layer mask installed (no rectangular corner radius)")
    func layerMaskInstalled() {
        let view = ChatShellView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutSubtreeIfNeeded()
        // wantsUpdateLayer drives updateLayer() during layout, populating mask.
        view.layer?.layoutIfNeeded()
        #expect(view.layer?.mask != nil)
    }

    @Test("After layout the mask path is non-nil so clipping is active")
    func maskPathPopulatedAfterLayout() {
        let view = ChatShellView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        // Force an explicit updateLayer cycle in case the test harness skipped it.
        view.needsDisplay = true
        view.updateLayer()
        #expect(view.bubbleMaskPathIsSet)
    }

    @Test("Mask path occupies the inset bubble area (with shadow margin around it)")
    func maskCoversBubbleArea() {
        let view = ChatShellView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        let mask = view.layer?.mask as? CAShapeLayer
        let bbox = mask?.path?.boundingBox ?? .zero
        let margin = ChatBubbleTheme.shadowMargin
        // The bubble path is inset by `shadowMargin` on every edge so the
        // layer shadow has space to render. Allow a small tolerance for
        // the tail extruding past the inset bottom edge.
        #expect(bbox.minX >= margin - 0.5)
        #expect(bbox.minY >= margin - 0.5)
        #expect(bbox.maxX <= view.bounds.maxX - margin + 0.5)
        #expect(bbox.maxY <= view.bounds.maxY - margin + 0.5)
    }

    @Test("CALayer shadow path is set (replaces NSWindow rectangular shadow)")
    func layerShadowIsConfigured() {
        let view = ChatShellView()
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        // shadowPath should match the bubble outline so the shadow follows
        // the tail. shadowOpacity > 0 means it actually renders.
        #expect(view.layer?.shadowPath != nil)
        #expect((view.layer?.shadowOpacity ?? 0) > 0)
        #expect(view.layer?.masksToBounds == false)
    }
}
