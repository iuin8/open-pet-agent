import AgentSensing
import SwiftUI

/// 上下文窗口占用条(P3.8 F,参考 claude-devtools):会话流顶部一条细 token 占用指示
/// (`上下文 84.4k · 42%` + 细填充条),颜色随占用升高 绿→琥珀→红。数据来自所选会话最新 assistant `usage`。
///
/// **常驻**(2026-06-16):Claude Code 有会话即恒显于顶部,`tokens == nil`(尚未扫到 usage)显「统计中」
/// 占位 —— 不再随数据有无闪进闪出,方便随时瞄一眼占用。
///
/// **ACP 复活**(2026-07-20,ACP-3):`init(used:size:cost:)` 接 ACP `usage_update` 直报的真实
/// used/size(跳过自适应猜窗口),由 `PetChatTabContent` composer 上方在有数据时显示。
/// 警告色 ≥80%(绿 <80% / 琥珀 80–85% / 红 ≥85%,对齐 Zed 0.8 阈值)。
struct ContextUsageBar: View {
    /// nil = 尚无 usage 数据(显「统计中」占位)。
    let tokens: Int?
    var limit: Int = SessionMetadata.contextWindowLimit
    /// 预格式化费用展示串(ACP cost;nil = 不显示)。
    var cost: String? = nil
    /// true = limit 是 agent 直报真实窗口(ACP),跳过自适应放大;false = 自适应猜(Claude 扫描)。
    private var isExactLimit = false

    /// 自适应上限:占用超 200k → 必是 1M 上下文模型(Claude 标准 200k / 扩展 1M),用 1M 算占比,
    /// 免得 1M 模型的会话被 200k 上限误显成 100%(看着像满了)。ACP 直报真实窗口时不启用。
    private var effectiveLimit: Int { isExactLimit ? limit : ((tokens ?? 0) > limit ? 1_000_000 : limit) }
    private var fraction: Double { min(1, max(0, Double(tokens ?? 0) / Double(effectiveLimit))) }
    private var color: Color {
        guard tokens != nil else { return ChatCardTheme.textPrimary.opacity(0.3) }   // 占位态:灰
        return fraction < 0.8 ? Color(nsColor: .systemGreen)
            : fraction < 0.85 ? Color(red: 0.95, green: 0.65, blue: 0.14)
            : Color(nsColor: .systemRed)
    }

    private var label: String {
        guard let tokens else { return "上下文 统计中…" }
        let base = "上下文 \(Self.format(tokens)) · \(Int((fraction * 100).rounded()))%"
        return cost.map { "\(base) · \($0)" } ?? base
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color.opacity(0.9))
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.6))
                .fixedSize()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ChatCardTheme.textPrimary.opacity(0.08))
                    // 占位态(无数据)不画填充 stub;有数据时至少 2pt 可见。
                    if tokens != nil {
                        Capsule().fill(color.opacity(0.85))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// 84403 → "84.4k";1230000 → "1.2M";< 1000 原样。
    static func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }
}

extension ContextUsageBar {
    /// ACP 入口:`usage_update` 直报真实 used/size(跳过自适应猜窗口),cost 为 App 预格式化展示串。
    init(used: Int, size: Int, cost: String? = nil) {
        self.tokens = used
        self.limit = max(1, size)   // 防 0 除(fraction 兜底)
        self.cost = cost
        self.isExactLimit = true
    }

    /// ACP fallback 入口:仅知 used(agent 未报窗口,如 opencode PromptResponse.usage),
    /// 走自适应猜窗口(同 Claude 扫描路径)。
    init(adaptiveUsed used: Int, cost: String? = nil) {
        self.tokens = used
        self.cost = cost
    }
}
