import Foundation

/// 一个子 agent(Claude Code Task/Agent 工具派生的 sidechain)的引用。
public struct SubagentRef: Sendable, Equatable {
    /// 关联父会话里 Task/Agent 工具 tool_use 的 id(`toolu_01…`)。
    public let toolUseId: String
    /// 子 agent 类型(security-reviewer / Explore / general-purpose …)。
    public let agentType: String
    /// 任务描述(meta.json 的 description)。
    public let description: String
    /// 子 agent 自己的 transcript(`agent-{id}.jsonl`)。
    public let transcriptURL: URL

    public init(toolUseId: String, agentType: String, description: String, transcriptURL: URL) {
        self.toolUseId = toolUseId
        self.agentType = agentType
        self.description = description
        self.transcriptURL = transcriptURL
    }
}

/// 扫描一个 Claude Code 会话的 `subagents/` 目录 → `toolUseId → SubagentRef` 映射(D2)。
///
/// 子 agent transcript 在 `<projectDir>/<sessionId>/subagents/agent-*.{jsonl,meta.json}` ——
/// `meta.json` 含 `{agentType, description, toolUseId}`,其中 `toolUseId` **精确对上**父会话里那条
/// Task/Agent 工具的 tool_use id(参考 claude-devtools (https://github.com/matt1398/claude-devtools) 的 sidechain 关联)。会话流里 Task 行据此
/// 点开「子 agent 侧卡」看子 agent 的完整 transcript(而非把子 agent 当独立会话列进 picker,见 D1 过滤)。
///
/// 纯文件 IO + Foundation → 可在后台 `Task.detached` 跑,别阻塞主线程。
public enum SubagentIndex {
    private struct TeamTask: Sendable, Equatable {
        let toolUseId: String
        let description: String
        let memberName: String
    }

    private struct TeamMessage: Sendable, Equatable {
        let memberName: String
        let summary: String
    }

    /// 据会话 transcript URL 推 subagents 目录:`<dir>/<sid>.jsonl` → `<dir>/<sid>/subagents`。
    public static func subagentsDir(forSession sessionURL: URL) -> URL {
        sessionURL.deletingPathExtension().appendingPathComponent("subagents")
    }

    /// 扫某会话的全部子 agent。无目录 / 空 / 非法 → 空字典。只 Claude Code 有此结构(Codex 无)。
    /// 普通 Task 走 meta.toolUseId 精确匹配；team spawn 缺 toolUseId 时，借鉴 claude-devtools:
    /// 用子 agent 首条 `<teammate-message summary="…">` 反查父会话 Task.description。
    public static func scan(sessionURL: URL) -> [String: SubagentRef] {
        let dir = subagentsDir(forSession: sessionURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [:] }
        let teamTasks = teamTasks(sessionURL: sessionURL)
        var map: [String: SubagentRef] = [:]
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") && !meta.lastPathComponent.hasPrefix("agent-acompact") {
            if let ref = parseMeta(meta) ?? parseTeamMeta(meta, teamTasks: teamTasks) {
                map[ref.toolUseId] = ref
            }
        }
        return map
    }

    /// 扫一个 workflow run 目录(`<sid>/subagents/workflows/<runId>/`)的全部衍生 agent(#9)。
    /// 与 Task 子 agent 不同:workflow agent 的 `meta.json` **只有 `agentType`(无 toolUseId)** →
    /// 合成 toolUseId = `wf:<runId>:<jsonl文件名>`(供列表卡点开该 agent transcript)。无目录 → 空。
    public static func scanWorkflowRun(sessionURL: URL, runId: String) -> [SubagentRef] {
        let dir = subagentsDir(forSession: sessionURL)
            .appendingPathComponent("workflows").appendingPathComponent(runId)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("agent-") && !$0.lastPathComponent.hasPrefix("agent-acompact") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { jsonl in
                let meta = jsonl.deletingPathExtension().appendingPathExtension("meta.json")
                let agentType = (try? Data(contentsOf: meta))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0["agentType"] as? String } ?? "agent"
                return SubagentRef(toolUseId: "wf:\(runId):\(jsonl.lastPathComponent)",
                                   agentType: agentType, description: "", transcriptURL: jsonl)
            }
    }

    /// 解析一个 `agent-{id}.meta.json` → `SubagentRef`。对应 jsonl = 同名去 `.meta.json` 换 `.jsonl`。
    /// 无 `toolUseId` → nil(没法关联父行)。
    static func parseMeta(_ metaURL: URL) -> SubagentRef? {
        guard let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolUseId = (obj["toolUseId"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        else { return nil }
        // agent-X.meta.json → 去 .json → agent-X.meta → 去 .meta → agent-X → + .jsonl
        let jsonl = jsonlURL(forMeta: metaURL)
        return SubagentRef(
            toolUseId: toolUseId,
            agentType: (obj["agentType"] as? String) ?? "subagent",
            description: (obj["description"] as? String) ?? "",
            transcriptURL: jsonl
        )
    }

    /// Team spawn 的 meta 常没有 toolUseId；用 teammate summary 与父会话 Task.description 补关联。
    private static func parseTeamMeta(_ metaURL: URL, teamTasks: [TeamTask]) -> SubagentRef? {
        guard !teamTasks.isEmpty,
              let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let jsonl = jsonlURL(forMeta: metaURL)
        guard let teamMessage = teammateMessage(in: jsonl),
              let match = teamTasks.first(where: { $0.description == teamMessage.summary && $0.memberName == teamMessage.memberName })
        else { return nil }
        return SubagentRef(
            toolUseId: match.toolUseId,
            agentType: (obj["agentType"] as? String) ?? teamMessage.memberName,
            description: teamMessage.summary,
            transcriptURL: jsonl
        )
    }

    private static func jsonlURL(forMeta metaURL: URL) -> URL {
        metaURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("jsonl")
    }

    private static func teamTasks(sessionURL: URL) -> [TeamTask] {
        guard let content = try? String(contentsOf: sessionURL, encoding: .utf8) else { return [] }
        var tasks: [TeamTask] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let id = (block["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                      let name = block["name"] as? String,
                      (name == "Task" || name == "Agent"),
                      let input = block["input"] as? [String: Any],
                      input["team_name"] is String,
                      let memberName = (input["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                      let description = (input["description"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                else { continue }
                tasks.append(TeamTask(toolUseId: id, description: description, memberName: memberName))
            }
        }
        return tasks
    }

    private static func teammateMessage(in jsonl: URL) -> TeamMessage? {
        guard let content = try? String(contentsOf: jsonl, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = messageText(obj),
                  let teamMessage = teammateMessage(inText: text)
            else { continue }
            return teamMessage
        }
        return nil
    }

    private static func messageText(_ obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            if let text = message["content"] as? String { return text }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
        }
        return obj["content"] as? String
    }

    private static func teammateMessage(inText text: String) -> TeamMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<teammate-message "),
              let memberName = xmlAttribute(trimmed, "teammate_id").flatMap({ $0.isEmpty ? nil : xmlUnescape($0) }),
              let summary = xmlAttribute(trimmed, "summary").flatMap({ $0.isEmpty ? nil : xmlUnescape($0) })
        else { return nil }
        return TeamMessage(memberName: memberName, summary: summary)
    }

    private static func xmlAttribute(_ s: String, _ name: String) -> String? {
        guard let key = s.range(of: name + "=\"") else { return nil }
        let start = key.upperBound
        guard let end = s[start...].firstIndex(of: "\"") else { return nil }
        return String(s[start..<end])
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
