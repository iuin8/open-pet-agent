import Foundation

/// 一个权限请求里的「总是允许」建议(Claude 给的快捷规则)。
public struct PermissionSuggestion: Sendable, Equatable {
    public let type: String            // addRules / setMode / ...
    public let behavior: String?       // allow
    public let destination: String?    // session / localSettings
    public let mode: String?           // acceptEdits / plan
    public let ruleSummaries: [String] // 「Bash: make build」之类人话规则
}

/// AskUserQuestion 的一个选项。
public struct PermissionQuestionOption: Sendable, Equatable {
    public let label: String
    public let description: String?
}

/// AskUserQuestion 的一个问题。
public struct PermissionQuestion: Sendable, Equatable {
    public let question: String
    public let header: String?
    public let options: [PermissionQuestionOption]
    public let multiSelect: Bool
}

/// 卡片三型:计划审批 / 问题选项 / 普通工具权限。
public enum PermissionPromptKind: Sendable, Equatable {
    case plan                              // ExitPlanMode
    case question([PermissionQuestion])    // AskUserQuestion
    case standard                          // 其余工具(Bash/Edit/…)
}

/// 一个待用户处置的权限请求 —— 由 `PermissionRequest` hook 的 POST payload 解析而来。
/// 纯值类型、Foundation only → 好无头单测;UI / server 在接线层。
public struct PermissionPrompt: Sendable, Equatable {
    public let sessionId: String?
    public let cwd: String?
    public let toolName: String
    /// 工具参数人话摘要(Bash→命令、Edit→文件名…),给 standard 卡片预览。
    public let summary: String
    public let suggestions: [PermissionSuggestion]
    public let kind: PermissionPromptKind

    public init(
        sessionId: String?,
        cwd: String?,
        toolName: String,
        summary: String,
        suggestions: [PermissionSuggestion],
        kind: PermissionPromptKind
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.summary = summary
        self.suggestions = suggestions
        self.kind = kind
    }

    /// cwd 末段(项目名),给卡片标项目。
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// AskUserQuestion 应答的**完整** `updatedInput` JSON,给 hook 回写。
    ///
    /// 关键:**重建原 `questions` 数组(原样)+ 加 `answers`** —— AskUserQuestion 的 tool input 只有
    /// `questions`,重建即等于原始;**绝不能只发 `{answers}`**,否则 `updatedInput` 把工具输入整个替换、
    /// 丢了 `questions`,客户端渲染时 `questions.map(...)` 碰 undefined → `undefined is not an object
    /// (evaluating 'H.map')` 崩(正确做法是「拷原始 input 全字段 + answers」,我们
    /// 早期只发 answers 的教训,见 [docs/lessons-learned.md §7.1])。
    ///
    /// `answers` 约定:**key = 问题文本** `question`,**value = 选项 label / 自定义文本**。
    /// 当前 UI 只答第一题。非 question 型 / 空答案 → nil。返回 `Data`(Sendable,过 `HookResponder` 边界)。
    public func answeredInputJSON(answer: String) -> Data? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .question(let questions) = kind, let first = questions.first, !trimmed.isEmpty else { return nil }
        let rebuilt = questions.map { q -> [String: Any] in
            var dict: [String: Any] = ["question": q.question, "multiSelect": q.multiSelect]
            if let header = q.header { dict["header"] = header }
            dict["options"] = q.options.map { opt -> [String: Any] in
                var od: [String: Any] = ["label": opt.label]
                if let desc = opt.description { od["description"] = desc }
                return od
            }
            return dict
        }
        let input: [String: Any] = ["questions": rebuilt, "answers": [first.question: trimmed]]
        return try? JSONSerialization.data(withJSONObject: input)
    }

    // MARK: - 解析

    /// 解析 hook POST 的一行 JSON 文本。非 PermissionRequest / 非法 → nil。
    public static func parse(jsonText: String) -> PermissionPrompt? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(obj)
    }

    /// 解析已反序列化的 payload 字典。
    public static func parse(_ obj: [String: Any]) -> PermissionPrompt? {
        // 容忍缺 hook_event_name(只要带 tool_name 也认),但事件名若有必须对得上。
        if let ev = obj["hook_event_name"] as? String, ev != PermissionResponse.hookEventName {
            return nil
        }
        guard let toolName = (obj["tool_name"] as? String), !toolName.isEmpty else { return nil }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        return PermissionPrompt(
            sessionId: obj["session_id"] as? String,
            cwd: obj["cwd"] as? String,
            toolName: toolName,
            summary: ClaudeTranscriptParser.toolSummary(name: toolName, input: input),
            suggestions: parseSuggestions(obj["permission_suggestions"]),
            kind: classify(toolName: toolName, input: input)
        )
    }

    private static func classify(toolName: String, input: [String: Any]) -> PermissionPromptKind {
        if toolName == "ExitPlanMode" { return .plan }
        if toolName == "AskUserQuestion", let qs = parseQuestions(input), !qs.isEmpty {
            return .question(qs)
        }
        return .standard
    }

    private static func parseQuestions(_ input: [String: Any]) -> [PermissionQuestion]? {
        guard let rawQuestions = input["questions"] as? [[String: Any]] else { return nil }
        let parsed = rawQuestions.compactMap { q -> PermissionQuestion? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> PermissionQuestionOption? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return PermissionQuestionOption(label: label, description: o["description"] as? String)
            }
            return PermissionQuestion(
                question: text,
                header: q["header"] as? String,
                options: options,
                multiSelect: q["multiSelect"] as? Bool ?? false
            )
        }
        return parsed.isEmpty ? nil : parsed
    }

    private static func parseSuggestions(_ raw: Any?) -> [PermissionSuggestion] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> PermissionSuggestion? in
            guard let type = dict["type"] as? String else { return nil }
            let rules = (dict["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
                let tool = rule["toolName"] as? String
                let content = rule["ruleContent"] as? String
                switch (tool, content) {
                case let (t?, c?): return "\(t): \(c)"
                case let (t?, nil): return t
                case let (nil, c?): return c
                default: return nil
                }
            }
            return PermissionSuggestion(
                type: type,
                behavior: dict["behavior"] as? String,
                destination: dict["destination"] as? String,
                mode: dict["mode"] as? String,
                ruleSummaries: rules
            )
        }
    }
}
