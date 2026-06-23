import AppKit

/// 「贴主陪伴卡空白侧」面板定位的**单一真相**(列容器 + 浏览历史 sheet 共用,逻辑统一)。
///
/// 右侧空间够放 / 比左侧大 → 贴右,否则贴左;宽取 `min(期望宽, 该侧可用宽)`(列容器内容超宽时内部横滚);
/// **顶对齐主卡**(面板高 = 主卡高时 == 底对齐,故对两者一致);双侧都放不下 → x clamp 进屏。
/// 纯函数 → 可无头单测,且「贴边 + 跟随移动」全经此一处(同一 `didMove` 观察重定位列容器与 sheet)。
public enum BesideMainLayout {
    public static func frame(maxSize: NSSize, mainFrame: NSRect, screen: NSRect,
                             gap: CGFloat = 12, margin: CGFloat = 12) -> NSRect {
        let spaceRight = screen.maxX - mainFrame.maxX - gap - margin
        let spaceLeft = mainFrame.minX - screen.minX - gap - margin
        let onRight = spaceRight >= maxSize.width || spaceRight >= spaceLeft
        let avail = max(0, onRight ? spaceRight : spaceLeft)
        let w = max(1, min(maxSize.width, avail))
        let h = maxSize.height
        let rawX = onRight ? mainFrame.maxX + gap : mainFrame.minX - gap - w
        let x = min(max(rawX, screen.minX + margin), screen.maxX - w - margin)
        let y = min(max(mainFrame.maxY - h, screen.minY + margin), screen.maxY - h - margin)
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
