import Testing
import Foundation
@testable import AgentSensing

@Suite("SessionMetadataScanner — 会话文件轻量元数据(标题/分支/消息数/缓存)")
struct SessionMetadataScannerTests {

    func tempFile(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metascan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 一条合法 Claude user prompt 行(带 cwd / gitBranch / timestamp)。
    func claudeUser(_ text: String, cwd: String = "/Users/me/dev/pet-agent", branch: String = "main") -> String {
        #"{"type":"user","sessionId":"s","cwd":"\#(cwd)","gitBranch":"\#(branch)","timestamp":"2026-06-14T10:00:00.000Z","message":{"content":"\#(text)"}}"#
    }

    func claudeAssistant(_ text: String) -> String {
        #"{"type":"assistant","gitBranch":"main","timestamp":"2026-06-14T10:01:00.000Z","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func aiTitleLine(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)"}"#
    }

    // MARK: - 标题

    @Test("有 ai-title → 标题用 ai-title(优于首条 user 消息)")
    func titlePrefersAITitle() async throws {
        let url = try tempFile(
            claudeUser("改个登录 bug") + "\n" + claudeAssistant("好") + "\n" + aiTitleLine("修复登录流程") + "\n"
        )
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .claudeCode)
        #expect(meta?.title == "修复登录流程")
    }

    @Test("无 ai-title → 标题回退首条 user 消息")
    func titleFallsBackToFirstUser() async throws {
        let url = try tempFile(claudeUser("帮我重构缓存层") + "\n" + claudeAssistant("好的") + "\n")
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .claudeCode)
        #expect(meta?.title == "帮我重构缓存层")
    }

    @Test("超长标题 → 裁剪到上限 + 省略号")
    func titleClipped() async throws {
        let long = String(repeating: "长", count: 80)
        let url = try tempFile(claudeUser(long) + "\n")
        let meta = await SessionMetadataScanner(titleClip: 10).metadata(for: url, agent: .claudeCode)
        #expect(meta?.title?.count == 11)       // 10 字 + "…"
        #expect(meta?.title?.hasSuffix("…") == true)
    }

    // MARK: - 分支 / 项目 / 起始时间

    @Test("gitBranch 从头部抽取(同项目多会话消歧位)")
    func gitBranchExtracted() async throws {
        let url = try tempFile(claudeUser("x", branch: "feature/proactive") + "\n")
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .claudeCode)
        #expect(meta?.gitBranch == "feature/proactive")
    }

    @Test("projectName 从 cwd 末段抽取 / startTime 非空")
    func projectAndStartTime() async throws {
        let url = try tempFile(claudeUser("x", cwd: "/Users/me/dev/myproj") + "\n")
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .claudeCode)
        #expect(meta?.projectName == "myproj")
        #expect(meta?.startTime != nil)
    }

    // MARK: - 消息数 + 预算上限

    @Test("messageCount 数 user+assistant 记录(忽略噪声行)")
    func messageCount() async throws {
        let content = claudeUser("问1") + "\n"
            + claudeAssistant("答1") + "\n"
            + aiTitleLine("标题") + "\n"                                   // 噪声,不计
            + #"{"type":"attachment","x":"y"}"# + "\n"                     // 噪声,不计
            + claudeUser("问2") + "\n"
            + claudeAssistant("答2") + "\n"
        let url = try tempFile(content)
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .claudeCode)
        #expect(meta?.messageCount == 4)        // 2 user + 2 assistant
    }

    @Test("文件超扫描预算 → messageCount = nil(但标题/分支仍出)")
    func messageCountNilWhenOverBudget() async throws {
        let url = try tempFile(claudeUser("大文件") + "\n" + aiTitleLine("标题") + "\n")
        // maxCountBytes 设 1 字节 → 文件必超预算 → 不数。
        let meta = await SessionMetadataScanner(maxCountBytes: 1).metadata(for: url, agent: .claudeCode)
        #expect(meta?.messageCount == nil)
        #expect(meta?.title == "标题")           // 标题仍从头/尾抽到
    }

    // MARK: - Codex

    @Test("Codex 会话 → 首条 user 消息当标题(无 ai-title)")
    func codexTitle() async throws {
        let line = #"{"timestamp":"2026-06-08T09:42:22.363Z","type":"event_msg","payload":{"type":"user_message","message":"用 Codex 跑个测试"}}"#
        let url = try tempFile(line + "\n")
        let meta = await SessionMetadataScanner().metadata(for: url, agent: .codex)
        #expect(meta?.title == "用 Codex 跑个测试")
    }

    // MARK: - 缓存 / 边界

    @Test("同文件二次调用 → 结果一致(命中缓存)")
    func cacheConsistent() async throws {
        let url = try tempFile(claudeUser("缓存测试") + "\n")
        let scanner = SessionMetadataScanner()
        let first = await scanner.metadata(for: url, agent: .claudeCode)
        let second = await scanner.metadata(for: url, agent: .claudeCode)
        #expect(first == second)
    }

    @Test("不存在的文件 → nil")
    func missingFile() async {
        let meta = await SessionMetadataScanner().metadata(
            for: URL(fileURLWithPath: "/nope-\(UUID().uuidString).jsonl"), agent: .claudeCode
        )
        #expect(meta == nil)
    }

    // MARK: - 纯函数

    @Test("extractJSONString 处理转义引号 + takeLast 取最新")
    func extractHandlesEscapeAndLast() {
        let text = #"{"aiTitle":"first"} ... {"aiTitle":"a \"quoted\" title"}"#
        #expect(SessionMetadataScanner.extractJSONString(text, key: "aiTitle", takeLast: false) == "first")
        #expect(SessionMetadataScanner.extractJSONString(text, key: "aiTitle", takeLast: true) == #"a "quoted" title"#)
        #expect(SessionMetadataScanner.extractJSONString(text, key: "missing", takeLast: false) == nil)
    }

    @Test("extractLatestContextTokens 取最新 usage 的 input+cache_creation+cache_read(P3.8 F)")
    func extractsLatestContextTokens() {
        // 两轮 usage,取最新(最后一个)。input 1 + cache_creation 502 + cache_read 83900 = 84403;output 不计。
        let tail = #"{"usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":9}} "#
            + #"{"usage":{"input_tokens":1,"cache_creation_input_tokens":502,"cache_read_input_tokens":83900,"output_tokens":43,"server_tool_use":{"web_search_requests":0}}}"#
        #expect(SessionMetadataScanner.extractLatestContextTokens(tail) == 84403)
        #expect(SessionMetadataScanner.extractLatestContextTokens("no usage here") == nil)
    }
}
