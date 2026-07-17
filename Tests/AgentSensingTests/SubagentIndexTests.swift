import Testing
import Foundation
@testable import AgentSensing

/// `SubagentIndex` —— 扫会话 `subagents/` 目录 → toolUseId → 子 agent transcript 映射(D2)。
@Suite("SubagentIndex — 子 agent transcript 关联")
struct SubagentIndexTests {

    /// 建临时 `<tmp>/<sid>.jsonl` + `<tmp>/<sid>/subagents/agent-*.{meta.json,jsonl}` fixture,返回会话 URL。
    func makeFixture(metas: [(id: String, toolUseId: String, type: String, desc: String)]) throws -> (sessionURL: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-test-\(metas.count)-\(metas.first?.id ?? "x")")
        let sid = "session-abc"
        let sessionURL = base.appendingPathComponent("\(sid).jsonl")
        let subdir = base.appendingPathComponent(sid).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "{}".write(to: sessionURL, atomically: true, encoding: .utf8)
        for m in metas {
            let meta: [String: Any] = ["agentType": m.type, "description": m.desc, "toolUseId": m.toolUseId]
            let data = try JSONSerialization.data(withJSONObject: meta)
            try data.write(to: subdir.appendingPathComponent("agent-\(m.id).meta.json"))
            try "{\"x\":1}".write(to: subdir.appendingPathComponent("agent-\(m.id).jsonl"), atomically: true, encoding: .utf8)
        }
        return (sessionURL, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("subagentsDir:<dir>/<sid>.jsonl → <dir>/<sid>/subagents")
    func dirDerivation() {
        let url = URL(fileURLWithPath: "/p/proj/c204bb47.jsonl")
        #expect(SubagentIndex.subagentsDir(forSession: url).path == "/p/proj/c204bb47/subagents")
    }

    @Test("scan:meta.json → toolUseId 映射 + jsonl 路径对")
    func scanMaps() throws {
        let (sessionURL, cleanup) = try makeFixture(metas: [
            (id: "a0e74", toolUseId: "toolu_01AAA", type: "security-reviewer", desc: "审 SSH"),
            (id: "a124d", toolUseId: "toolu_01BBB", type: "Explore", desc: "摸代码"),
        ])
        defer { cleanup() }
        let map = SubagentIndex.scan(sessionURL: sessionURL)
        #expect(map.count == 2)
        let a = map["toolu_01AAA"]
        #expect(a?.agentType == "security-reviewer")
        #expect(a?.description == "审 SSH")
        #expect(a?.transcriptURL.lastPathComponent == "agent-a0e74.jsonl")
        #expect(map["toolu_01BBB"]?.agentType == "Explore")
    }

    @Test("无 subagents 目录 → 空映射(不崩)")
    func missingDir() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).jsonl")
        #expect(SubagentIndex.scan(sessionURL: url).isEmpty)
    }

    @Test("meta 缺 toolUseId → 跳过该条")
    func missingToolUseId() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-noid-\(UUID().uuidString)")
        let sessionURL = base.appendingPathComponent("s.jsonl")
        let subdir = base.appendingPathComponent("s").appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "{}".write(to: sessionURL, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["agentType": "x", "description": "y"])
            .write(to: subdir.appendingPathComponent("agent-z.meta.json"))
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SubagentIndex.scan(sessionURL: sessionURL).isEmpty)
    }

    @Test("scan:跳过 agent-acompact 压缩 artifact")
    func compactArtifactSkipped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-noid-\(UUID().uuidString)")
        let sessionURL = base.appendingPathComponent("s.jsonl")
        let subdir = base.appendingPathComponent("s").appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "{}".write(to: sessionURL, atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["agentType": "compact", "description": "summary", "toolUseId": "toolu_compact"]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: subdir.appendingPathComponent("agent-acompact123.meta.json"))
        try "{}".write(to: subdir.appendingPathComponent("agent-acompact123.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SubagentIndex.scan(sessionURL: sessionURL).isEmpty)
    }

    @Test("scanWorkflowRun:跳过 agent-acompact 压缩 artifact")
    func workflowRunSkipsCompactArtifact() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-wf-\(UUID().uuidString)")
        let sessionURL = base.appendingPathComponent("s.jsonl")
        let dir = base.appendingPathComponent("s/subagents/workflows/wf_1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: sessionURL, atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("agent-real.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("agent-acompact123.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }

        let refs = SubagentIndex.scanWorkflowRun(sessionURL: sessionURL, runId: "wf_1")

        #expect(refs.map(\.transcriptURL.lastPathComponent) == ["agent-real.jsonl"])
    }
}
