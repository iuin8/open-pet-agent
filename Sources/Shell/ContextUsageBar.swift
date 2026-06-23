import AgentSensing
import SwiftUI

/// 上下文窗口占用条(P3.8 F,参考 claude-devtools):会话流顶部一条细 token 占用指示
/// (`上下文 84.4k · 42%` + 细填充条),颜色随占用升高 绿→琥珀→红。数据来自所选会话最新 assistant `usage`。
///
/// **常驻**(2026-06-16):Claude Code 有会话即恒显于顶部,`tokens == nil`(尚未扫到 usage)显「统计中」
/// 占位 —— 不再随数据有无闪进闪出,方便随时瞄一眼占用。
struct ContextUsageBar: View {
    /// nil = 尚无 usage 数据(显「统计中」占位)。
    let tokens: Int?
    var limit: Int = SessionMetadata.contextWindowLimit

    /// 自适应上限:占用超 200k → 必是 1M 上下文模型(Claude 标准 200k / 扩展 1M),用 1M 算占比,
    /// 免得 1M 模型的会话被 200k 上限误显成 100%(看着像满了)。
    private var effectiveLimit: Int { (tokens ?? 0) > limit ? 1_000_000 : limit }
    private var fraction: Double { min(1, max(0, Double(tokens ?? 0) / Double(effectiveLimit))) }
    private var color: Color {
        guard tokens != nil else { return ChatCardTheme.textPrimary.opacity(0.3) }   // 占位态:灰
        return fraction < 0.6 ? Color(nsColor: .systemGreen)
            : fraction < 0.85 ? Color(red: 0.95, green: 0.65, blue: 0.14)
            : Color(nsColor: .systemRed)
    }

    private var label: String {
        guard let tokens else { return "上下文 统计中…" }
        return "上下文 \(Self.format(tokens)) · \(Int((fraction * 100).rounded()))%"
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
