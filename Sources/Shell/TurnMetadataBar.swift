import AgentSensing
import SwiftUI

/// 模型一轮的**元数据栏**(2026-06-16 借 claude-devtools (https://github.com/matt1398/claude-devtools) 的 AIGroup header)。窄卡(360)紧凑单行:
/// `[●] ✦opus 4.8  ⚙4 · 🧠2 · 8.5s   👥  84.4k ›` —— 状态点 + 模型徽标 + 工具/思考计数 + 耗时 + 子 agent + per-turn 上下文 + chevron。
/// 主区点击 → 轮次时间线侧卡(思考全文 + 每个工具 input/output);👥 单独点 → 子 agent 侧卡。
struct TurnMetadataBar: View {
    let turn: AssistantTurn
    /// 命中子 agent → 显 👥(类型);nil = 无。
    var subagentType: String? = nil
    /// 主区点击(看本轮时间线)。nil = 不可点(无可看详情)。
    var onTap: (() -> Void)? = nil
    /// 👥 点击(开子 agent 侧卡)。
    var onOpenSubagent: (() -> Void)? = nil
    /// 🧩 点击(开 workflow 衍生 agent 列表卡,#9)。参数 = workflow run id。
    var onOpenWorkflow: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            mainRegion
            Spacer(minLength: 4)
            if let t = subagentType { subagentPill(t) }
            if let wf = turn.workflowRunIds.first { workflowPill(wf, count: turn.workflowRunIds.count) }
            if let ctx = turn.contextTokens { contextChip(ctx) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ChatCardTheme.textPrimary.opacity(0.04))
        )
    }

    /// 主区(状态点 + 模型 + 计数 + 耗时 + chevron),整块一个点击区 → 时间线侧卡。
    private var mainRegion: some View {
        Button { onTap?() } label: {
            HStack(spacing: 5) {
                statusDot
                if let model = turn.shortModelName {
                    Text(model)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
                }
                if turn.thinkingCount > 0 { iconCount("brain", turn.thinkingCount) }
                if turn.toolCount > 0 { iconCount("wrench.and.screwdriver.fill", turn.toolCount) }
                if let d = turn.durationText {
                    Text(d)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                }
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ChatCardTheme.accent.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    @ViewBuilder
    private var statusDot: some View {
        if turn.hasError {
            Circle().fill(Color(nsColor: .systemRed)).frame(width: 6, height: 6)
        } else if turn.isRunning {
            // 进行中:脉冲点
            PulseDot()
        } else {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent.opacity(0.7))
        }
    }

    private func iconCount(_ icon: String, _ n: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .medium))
            Text("\(n)").font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.55))
    }

    private func subagentPill(_ type: String) -> some View {
        Button { onOpenSubagent?() } label: {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill").font(.system(size: 8, weight: .semibold))
                Text(type).font(.system(size: 9.5, weight: .medium, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(ChatCardTheme.accent.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 🧩 workflow 入口药丸:点 → 列出该 workflow 全部衍生 agent(#9)。
    private func workflowPill(_ runId: String, count: Int) -> some View {
        Button { onOpenWorkflow?(runId) } label: {
            HStack(spacing: 3) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 8, weight: .semibold))
                Text(count > 1 ? "workflow ×\(count)" : "workflow").font(.system(size: 9.5, weight: .medium, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(ChatCardTheme.accent.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func contextChip(_ tokens: Int) -> some View {
        Text("\(ContextUsageBar.format(tokens))")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
            .help("本轮上下文占用 \(tokens) tokens")
    }

}

/// 进行中脉冲点(呼吸式 accent 圆点)。
private struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(ChatCardTheme.accent.opacity(on ? 0.3 : 0.95))
            .frame(width: 6, height: 6)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
    }
}
