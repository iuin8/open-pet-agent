import Foundation

// P3:三个引擎统一 ACP —— claude/codex 变体(同 `ACPAgentEngine` 实现,kind 不同,
// router 经 `type(of:).kind` 反推正确 kind)。spawn 命令由 registry / applySelectedAgentEngine
// 注入(claude-agent-acp / codex-acp),此处只声明 kind 身份。
//
// 能力矩阵(2026-07-21 本机实测,经 ACPSmoke 真互操作):
// | 能力              | opencode 1.18 | claude-agent-acp 0.37 | codex-acp 0.15 |
// | 会话保持(同 session 多轮) | ✅          | ✅                   | ✅            |
// | usage_update      | ❌(响应带 unstable usage,fallback) | ✅ used+size+cost | ✅ used+size |
// | session/list      | ✅            | ✅                   | ✅(nextCursor 为时间戳,翻页有界跟随) |
// | session/load 回放 | ✅            | ✅                   | ✅            |

/// `claude-agent-acp`(npm `@agentclientprotocol/claude-agent-acp`)驱动的 Claude 引擎。
/// 认证带外:复用本机 claude CLI 登录态(ACP `authMethods` 为空,无需 ACP authenticate)。
public final class ClaudeACPAgentEngine: ACPAgentEngine {
    override public class var kind: AgentEngineKind { .claudeCode }
}

/// `codex-acp`(npm `@zed-industries/codex-acp`)驱动的 Codex 引擎。
/// 认证带外:复用本机 codex CLI 登录态(ChatGPT / OPENAI_API_KEY)。
public final class CodexACPAgentEngine: ACPAgentEngine {
    override public class var kind: AgentEngineKind { .codex }
}
