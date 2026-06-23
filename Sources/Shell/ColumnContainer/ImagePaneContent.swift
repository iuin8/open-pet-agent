import AppKit
import SwiftUI

/// 列容器里的「图片」内容（从旧 `ImageCardView` 抽出，去 header pin/close）。fit-to-列 + 原生缩放/平移。
struct ImagePaneContent: View {
    let data: Data

    var body: some View {
        Group {
            if let img = NSImage(data: data) {
                ZoomableImageView(image: img)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 26))
                        .foregroundColor(ChatCardTheme.textPrimary.opacity(0.3))
                    Text("图片解码失败")
                        .font(.system(size: 12))
                        .foregroundColor(ChatCardTheme.textPrimary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 原生缩放/平移图片区：`NSScrollView.allowsMagnification`（捏合/双指缩放、滚动平移）+ 默认 fit-to-card。
/// 照搬自 `ImageCardWindowController` 里的同名 private struct。
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1.0
        scroll.maxMagnification = 6.0
        scroll.drawsBackground = false
        let iv = NSImageView()
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown   // fit：等比缩进卡内
        iv.imageAlignment = .alignCenter
        // **跟随 scrollview 尺寸**(列容器里首次 update 时 contentSize 可能为 0 → 旧版固定帧成 0×0 不可见)。
        // autoresizingMask 让 imageView 随 clip view 改尺寸 + 布局后异步填满一次,免依赖 update 时机。
        iv.autoresizingMask = [.width, .height]
        scroll.documentView = iv
        DispatchQueue.main.async { iv.frame = scroll.contentView.bounds }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let iv = scroll.documentView as? NSImageView else { return }
        if iv.image !== image { iv.image = image; scroll.magnification = 1.0 }
        let s = scroll.contentSize
        if s.width > 1, s.height > 1 { iv.frame = NSRect(origin: .zero, size: s) }   // 防 0×0;放大由 magnification 叠加
    }
}
