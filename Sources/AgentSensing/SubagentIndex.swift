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

    /// 据会话 transcript URL 推 subagents 目录:`<dir>/<sid>.jsonl` → `<dir>/<sid>/subagents`。
    public static func subagentsDir(forSession sessionURL: URL) -> URL {
        sessionURL.deletingPathExtension().appendingPathComponent("subagents")
    }

    /// 扫某会话的全部子 agent。无目录 / 空 / 非法 → 空字典。只 Claude Code 有此结构(Codex 无)。
    public static func scan(sessionURL: URL) -> [String: SubagentRef] {
        let dir = subagentsDir(forSession: sessionURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var map: [String: SubagentRef] = [:]
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") && !meta.lastPathComponent.hasPrefix("agent-acompact") {
            if let ref = parseMeta(meta) { map[ref.toolUseId] = ref }
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
        let jsonl = metaURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("jsonl")
        return SubagentRef(
            toolUseId: toolUseId,
            agentType: (obj["agentType"] as? String) ?? "subagent",
            description: (obj["description"] as? String) ?? "",
            transcriptURL: jsonl
        )
    }
}
