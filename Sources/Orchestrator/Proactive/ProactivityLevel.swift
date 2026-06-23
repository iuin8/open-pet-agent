// Sources/Orchestrator/Proactive/ProactivityLevel.swift

/// 主动协助的「主动性级别」——设置页用户可选，控制节流强度与触发敏感度。
/// 节流查表参数见 `ProactiveSettings` 的计算属性；本枚举只是带名级别。
public enum ProactivityLevel: String, Codable, CaseIterable, Sendable {
    case off
    case restrained
    case moderate
    case active

    /// 设置页 Picker 显示用中文名。
    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .restrained: return "克制·待命"
        case .moderate: return "适度·察言观色"
        case .active: return "积极·伴侣"
        }
    }
}
