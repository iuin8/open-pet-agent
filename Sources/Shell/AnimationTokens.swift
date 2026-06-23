import QuartzCore

/// 全局动画 token —— 各处用同一套时长 / timing 函数,避免现拍 0.15 / 0.2 / 0.6 字面值。
///
/// 设计原则:
/// 1. 按「意图」命名(snappy / smooth / breathe / talking …),不按时长命名
/// 2. 默认 timing 都是 `.easeInEaseOut`(OpenPetAgent 当前唯一全局 timing);需要其他曲线时另取
/// 3. OpenPetAgent 是 AppKit + CoreAnimation,不用 SwiftUI;token 返回 `TimeInterval` 和缓存的
///    `CAMediaTimingFunction`,不返回 SwiftUI `Animation`
/// 4. 来源参考 HermesPet (https://github.com/basionwang-bot/HermesPet) 的「统一动画语言」思想
public enum AnimTok {

    // MARK: - 通用 token (跨文件复用)

    /// 微交互(气泡淡入淡出、按钮反馈、focus 变化)—— 150 ms,短促但稳重
    public static let snappy: TimeInterval = 0.15

    /// 标准过渡(轻量布局切换、watching 倾斜固定)—— 200 ms,平滑无晃动
    public static let smooth: TimeInterval = 0.2

    /// 装饰性循环呼吸(autoreverse + repeatForever)—— 1.8 s 一拍
    public static let breathe: TimeInterval = 1.8

    // MARK: - Chat 桌宠状态专用

    /// `.thinking` —— ±8° 摆动 + opacity 1.0↔0.85 脉冲(autoreverse)
    public static let thinking: TimeInterval = 0.6

    /// `.talking` —— 缩放冲击 1.0→1.12→1.0
    public static let talking: TimeInterval = 0.4

    /// `.confused` —— ±12° 抖动 × 3 cycle
    public static let confusedShake: TimeInterval = 0.5

    // MARK: - Timing functions (CAMediaTimingFunction 缓存)

    /// `.easeInEaseOut` —— OpenPetAgent 全局默认 timing,所有动画共享一个实例避免重复 init
    public static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
}
