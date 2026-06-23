import Testing
import Foundation
@testable import AgentSensing

@Suite("PermissionPrompt — hook payload → 卡片模型")
struct PermissionPromptTests {

    @Test("ExitPlanMode → .plan")
    func planKind() {
        let line = #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/Users/me/proj","tool_name":"ExitPlanMode","tool_input":{"plan":"做 X 再做 Y"}}"#
        let p = PermissionPrompt.parse(jsonText: line)
        #expect(p?.kind == .plan)
        #expect(p?.toolName == "ExitPlanMode")
        #expect(p?.projectName == "proj")
    }

    @Test("AskUserQuestion → .question,解析问题 + 选项 + multiSelect")
    func questionKind() {
        let line = #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"选哪个?","header":"方案","multiSelect":true,"options":[{"label":"A","description":"上策"},{"label":"B"}]}]}}"#
        guard case .question(let qs)? = PermissionPrompt.parse(jsonText: line)?.kind else {
            Issue.record("应解析成 .question"); return
        }
        #expect(qs.count == 1)
        #expect(qs[0].question == "选哪个?")
        #expect(qs[0].header == "方案")
        #expect(qs[0].multiSelect == true)
        #expect(qs[0].options == [
            PermissionQuestionOption(label: "A", description: "上策"),
            PermissionQuestionOption(label: "B", description: nil),
        ])
    }

    @Test("普通工具(Bash)→ .standard,摘要取命令")
    func standardKind() {
        let line = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x","description":"清临时"}}"#
        let p = PermissionPrompt.parse(jsonText: line)
        #expect(p?.kind == .standard)
        #expect(p?.summary == "清临时")   // 复用 ClaudeTranscriptParser.toolSummary:description 优先
    }

    @Test("permission_suggestions 解析成「总是允许」规则")
    func suggestions() {
        let line = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"},"permission_suggestions":[{"type":"addRules","destination":"localSettings","behavior":"allow","rules":[{"toolName":"Bash","ruleContent":"make build"}]},{"type":"setMode","mode":"acceptEdits"}]}"#
        let p = PermissionPrompt.parse(jsonText: line)
        #expect(p?.suggestions.count == 2)
        #expect(p?.suggestions.first?.type == "addRules")
        #expect(p?.suggestions.first?.ruleSummaries == ["Bash: make build"])
        #expect(p?.suggestions.last?.mode == "acceptEdits")
    }

    @Test("AskUserQuestion 但无 options → 仍是 .question(光问题)")
    func questionNoOptions() {
        let line = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"确认?"}]}}"#
        guard case .question(let qs)? = PermissionPrompt.parse(jsonText: line)?.kind else {
            Issue.record("应是 .question"); return
        }
        #expect(qs[0].options.isEmpty)
    }

    @Test("非 PermissionRequest 事件 → nil")
    func wrongEvent() {
        #expect(PermissionPrompt.parse(jsonText: #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#) == nil)
    }

    @Test("缺 tool_name / 非 JSON → nil")
    func malformed() {
        #expect(PermissionPrompt.parse(jsonText: #"{"hook_event_name":"PermissionRequest"}"#) == nil)
        #expect(PermissionPrompt.parse(jsonText: "nope") == nil)
    }
}

@Suite("PermissionResponse — 决策 → hook 回写 JSON")
struct PermissionResponseTests {

    @Test("allow → 官方 hookSpecificOutput schema")
    func allow() throws {
        let obj = PermissionResponse.hookOutput(.allow)
        let hso = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(hso["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(hso["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect(decision["updatedInput"] == nil)
    }

    @Test("allow + updatedInput → 带 updatedInput")
    func allowWithInput() throws {
        let obj = PermissionResponse.hookOutput(.allow, updatedInput: ["command": "npm run lint"])
        let decision = try #require((obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["command"] as? String == "npm run lint")
    }

    @Test("deny → behavior deny,无 updatedInput")
    func deny() throws {
        let decision = try #require((PermissionResponse.hookOutput(.deny)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
    }

    @Test("abstain → 空对象 hookOutput + 空 body(官方:2xx 空 body = 无决策)")
    func abstain() {
        #expect(PermissionResponse.hookOutput(.abstain).isEmpty)
        #expect(PermissionResponse.httpBody(.abstain).isEmpty)
    }

    @Test("answeredInputJSON 保留 questions 全字段 + answers key=问题文本(防客户端 H.map)")
    func answeredInputPreservesQuestions() throws {
        let prompt = PermissionPrompt.parse(jsonText: #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"用哪个方案?","header":"方案","options":[{"label":"A","description":"描述A"},{"label":"B"}]}]}}"#)
        let data = try #require(prompt?.answeredInputJSON(answer: "A"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 关键:questions 数组原样保留(不丢 → 客户端 questions.map 不崩)。
        let questions = try #require(obj["questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions[0]["question"] as? String == "用哪个方案?")
        #expect(questions[0]["header"] as? String == "方案")
        let options = try #require(questions[0]["options"] as? [[String: Any]])
        #expect(options.count == 2)
        #expect(options[0]["label"] as? String == "A")
        // answers:key = 问题文本,value = 选项 label(约定)。
        let answers = try #require(obj["answers"] as? [String: String])
        #expect(answers["用哪个方案?"] == "A")
    }

    @Test("answeredInputJSON 非 question 型 / 空答案 → nil")
    func answeredInputNilCases() {
        let std = PermissionPrompt.parse(jsonText: #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(std?.answeredInputJSON(answer: "x") == nil)
        let q = PermissionPrompt.parse(jsonText: #"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"q?","options":[{"label":"A"}]}]}}"#)
        #expect(q?.answeredInputJSON(answer: "   ") == nil)
    }

    @Test("httpBody allow → 可解析回 schema")
    func httpBodyRoundtrip() throws {
        let data = PermissionResponse.httpBody(.deny)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let behavior = ((obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String
        #expect(behavior == "deny")
    }
}
