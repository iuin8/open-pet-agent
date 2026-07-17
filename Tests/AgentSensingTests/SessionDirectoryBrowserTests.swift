import Testing
import Foundation
@testable import AgentSensing

@Suite("SessionDirectoryBrowser — 目录→会话")
struct SessionDirectoryBrowserTests {
    @Test("encode:斜杠→连字符 + 前导 -")
    func encodesCwd() {
        #expect(SessionDirectoryBrowser.encode(cwd: "/Users/me/dev/proj") == "-Users-me-dev-proj")
        #expect(SessionDirectoryBrowser.encode(cwd: "/Users/me/my-proj") == "-Users-me-my-proj")   // 含-原样
    }
    @Test("resolveSessionDir:在 projects 下直读;否则当 cwd 编码到 projects 子目录")
    func resolvesDir() {
        let root = URL(fileURLWithPath: "/home/.claude/projects")
        // 选中本就在 projects 下 → 直读
        let inside = URL(fileURLWithPath: "/home/.claude/projects/-Users-me-proj")
        #expect(SessionDirectoryBrowser.resolveSessionDir(picked: inside, projectsRoot: root).path == inside.path)
        // 选中项目 cwd → 编码进 projects
        let proj = URL(fileURLWithPath: "/Users/me/proj")
        #expect(SessionDirectoryBrowser.resolveSessionDir(picked: proj, projectsRoot: root).path == "/home/.claude/projects/-Users-me-proj")
    }
    @Test("scan:列目录 *.jsonl → AgentSessionRef(sessionId=去扩展名),非 jsonl 跳过")
    func scansJsonl() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("br-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("aaa.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("bbb.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("agent-acompact123.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let refs = SessionDirectoryBrowser.scan(directory: dir, agent: .claudeCode)
        #expect(Set(refs.map(\.sessionId)) == ["aaa", "bbb"])
        #expect(refs.allSatisfy { $0.url.pathExtension == "jsonl" })
    }
    @Test("scan:目录不存在 → []")
    func scanMissing() {
        #expect(SessionDirectoryBrowser.scan(directory: URL(fileURLWithPath: "/nope-\(UUID().uuidString)"), agent: .claudeCode).isEmpty)
    }
}
