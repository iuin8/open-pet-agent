import CoreGraphics
import PetBehavior

/// 引擎产出(top-origin anchor + 当前帧 imageAnchor + 图像尺寸)→ NSWindow 的 bottom-origin frame。
/// 纯函数,无 AppKit,可无头测。
///
/// - 窗口左上(top-origin) = anchor − imageAnchor;窗口尺寸 = 图像尺寸。
/// - NSWindow bottom-origin:窗口底边 y = `screenHeight − 窗口顶 y(top-origin) − 窗口高`。
/// - x 与屏幕同向(主屏 originX=0;多屏副屏由 host 传 `screenOriginX`)。
/// - **右向图锚点 x 镜像**:`lookRight && 无专用右图`时图水平翻转,锚点 x 取 `imageWidth − imageAnchorX`
///   (由调用方算好后传入 `imageAnchorX`)。
public enum ShimejiWindowGeometry {
    /// `scale`(PF6 全局大小因子,1=原始):窗口尺寸 + 锚点偏移同乘 → 窗口绕 anchor 世界点等比放大。
    /// 因 `imageAnchor` 偏移与窗口尺寸都乘 scale,锚点像素屏幕位置恒 = `windowTopLeft + imageAnchor*scale
    /// = anchor` 不动(脚/抓点仍贴边),layer 的 `.resizeAspect` 把 sprite 撑满放大后的窗口。
    public static func windowFrame(
        anchor: BehaviorPoint,
        imageAnchorX: Double,
        imageAnchorY: Double,
        imageWidth: Double,
        imageHeight: Double,
        screenHeight: Double,
        screenOriginX: Double = 0,
        screenOriginYBottom: Double = 0,
        scale: Double = 1
    ) -> CGRect {
        let w = imageWidth * scale, h = imageHeight * scale
        let anchorOffsetX = imageAnchorX * scale, anchorOffsetY = imageAnchorY * scale
        let topLeftXTop = anchor.x - anchorOffsetX
        let topLeftYTop = anchor.y - anchorOffsetY
        let originXBottom = screenOriginX + topLeftXTop
        let originYBottom = screenOriginYBottom + (screenHeight - topLeftYTop - h)
        return CGRect(x: originXBottom, y: originYBottom, width: w, height: h)
    }
}
