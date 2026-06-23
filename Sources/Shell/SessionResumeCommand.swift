import AgentSensing
import Foundation

/// 会话「在终端继续」命令 —— 复制到剪贴板供用户粘进终端续聊(参考 claude-devtools「Copy Resume Command」)。
/// 用**交互式 TUI 形态**(给人在终端续聊),不是 `codex exec` 那种自动化/JSON 形态:
/// - Claude:`claude --resume <sessionId>`
/// - Codex :`codex resume <sessionId>`(`codex exec resume` 是非交互脚本模式,这里要的是人续聊)
public enum SessionResumeCommand {
    /// 据 agent + sessionId 拼终端 resume 命令。
    public static func command(agent: AgentKind, sessionId: String) -> String {
        switch agent {
        case .claudeCode: return "claude --resume \(sessionId)"
        case .codex:      return "codex resume \(sessionId)"
        }
    }
}
