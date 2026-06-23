import AppKit

/// 承载 PetRenderer.contentLayer 的薄 host：把内容层设为自己的 backing layer
/// (随 view bounds 自动 sizing),装到 pet window。透明、CAMetalLayer 自驱 present 不需 AppKit drawing。
/// 原 Rendering.MetalPetHostingView,2026-06-07 P1 剥 NSView 时移到 Shell host 层。
@MainActor
public final class PetLayerHostView: NSView {
    public init(content: CALayer) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer = content
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isOpaque: Bool { false }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}
}
