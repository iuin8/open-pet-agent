import Testing
import Foundation
@testable import AgentSensing

@Suite("FileTailer.split — 纯行切分")
struct LineSplitTests {

    @Test("两行带结尾换行 → 两行,无余量")
    func twoCompleteLines() {
        let (lines, rem) = FileTailer.split(buffer: "", incoming: "a\nb\n")
        #expect(lines == ["a", "b"])
        #expect(rem == "")
    }

    @Test("尾行无换行 → 留作余量")
    func partialTrailingLine() {
        let (lines, rem) = FileTailer.split(buffer: "", incoming: "a\nb")
        #expect(lines == ["a"])
        #expect(rem == "b")
    }

    @Test("上次半行 + 本次补全 → 拼回完整行")
    func bufferStitched() {
        let (lines, rem) = FileTailer.split(buffer: "he", incoming: "llo\nworld")
        #expect(lines == ["hello"])
        #expect(rem == "world")
    }

    @Test("空 incoming + 空 buffer → 啥都没有")
    func empty() {
        let (lines, rem) = FileTailer.split(buffer: "", incoming: "")
        #expect(lines.isEmpty)
        #expect(rem == "")
    }

    @Test("空行被丢弃")
    func blankLinesDropped() {
        let (lines, rem) = FileTailer.split(buffer: "", incoming: "a\n\nb\n")
        #expect(lines == ["a", "b"])
        #expect(rem == "")
    }
}

@Suite("FileTailer — 增量 tail 真实文件")
struct FileTailerTests {

    /// 在临时目录建一个文件,返回 url + 清理闭包。
    func tempFile(_ initial: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsensing-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try initial.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("startAtEnd=false 从头读已有内容")
    func readFromStart() throws {
        let url = try tempFile("line1\nline2\n")
        var t = FileTailer(url: url, startAtEnd: false)
        #expect(t.readNewLines() == ["line1", "line2"])
        #expect(t.readNewLines() == [])   // 无新增
    }

    @Test("startAtEnd=true 跳过历史,只读后续追加")
    func skipHistory() throws {
        let url = try tempFile("old1\nold2\n")
        var t = FileTailer(url: url, startAtEnd: true)
        #expect(t.readNewLines() == [])    // 历史被跳过
        try append("new1\n", to: url)
        #expect(t.readNewLines() == ["new1"])
    }

    @Test("分两次追加半行 → 补全后才吐整行")
    func partialAcrossReads() throws {
        let url = try tempFile()
        var t = FileTailer(url: url, startAtEnd: false)
        try append("{\"a\":", to: url)
        #expect(t.readNewLines() == [])           // 半行,先缓冲
        try append("1}\n", to: url)
        #expect(t.readNewLines() == ["{\"a\":1}"])  // 拼回
    }

    @Test("文件被截断/轮换为更短内容 → 重置从头读")
    func truncationResets() throws {
        let url = try tempFile("aaaa\nbbbb\ncccc\n")          // 15 字节
        var t = FileTailer(url: url, startAtEnd: false)
        _ = t.readNewLines()
        try "fresh\n".write(to: url, atomically: true, encoding: .utf8)  // 6 字节 < 旧 offset → 截断
        #expect(t.readNewLines() == ["fresh"])
    }
}

@Suite("SessionDiscovery — 按 mtime 找活跃 jsonl")
struct SessionDiscoveryTests {

    func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsensing-disc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeJSONL(_ name: String, mtime: Date, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    @Test("只返回窗口内改动的文件,新→旧排序")
    func recentSortedByMtime() throws {
        let root = try tempRoot()
        let now = Date(timeIntervalSince1970: 10_000)
        _ = try writeJSONL("fresh.jsonl", mtime: now.addingTimeInterval(-5), under: root)
        _ = try writeJSONL("older.jsonl", mtime: now.addingTimeInterval(-30), under: root)
        _ = try writeJSONL("stale.jsonl", mtime: now.addingTimeInterval(-500), under: root)

        // 比 lastPathComponent —— enumerator 会把 /var 解析成 /private/var,全 URL 等值不可靠。
        let names = SessionDiscovery.recentJSONL(under: root, within: 90, now: now)
            .map(\.lastPathComponent)
        #expect(names == ["fresh.jsonl", "older.jsonl"])   // stale 超窗被排除
    }

    @Test("非 jsonl 被忽略")
    func ignoresNonJSONL() throws {
        let root = try tempRoot()
        let now = Date(timeIntervalSince1970: 10_000)
        _ = try writeJSONL("a.jsonl", mtime: now, under: root)
        _ = try writeJSONL("agent-acompact123.jsonl", mtime: now, under: root)
        let txt = root.appendingPathComponent("b.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: txt.path)

        let result = SessionDiscovery.recentJSONL(under: root, within: 90, now: now)
        #expect(result.count == 1)
        #expect(result.first?.lastPathComponent == "a.jsonl")
    }

    @Test("目录不存在 → 空数组(不崩)")
    func missingRoot() {
        let ghost = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(SessionDiscovery.recentJSONL(under: ghost).isEmpty)
    }

    @Test("excludeInternal:剪掉 subagents/workflows/tool-results 子树(含深层),保留父会话 + Codex 日期嵌套")
    func excludesInternalSubtrees() throws {
        let root = try tempRoot()
        let now = Date(timeIntervalSince1970: 10_000)
        let fm = FileManager.default
        // 父会话(直属项目目录)→ 应收
        _ = try writeJSONL("session.jsonl", mtime: now, under: root)
        // 内部子树 `<proj>/<uuid>/subagents/...`(含再嵌套)→ 应整棵剪掉
        let sub = root.appendingPathComponent("uuid").appendingPathComponent("subagents")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try writeJSONL("agent-1.jsonl", mtime: now, under: sub)
        let deep = sub.appendingPathComponent("nested")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        _ = try writeJSONL("agent-2.jsonl", mtime: now, under: deep)
        // Codex 风格日期嵌套(目录名非内部名)→ 应照常递归收到
        let dated = root.appendingPathComponent("2026/06/26")
        try fm.createDirectory(at: dated, withIntermediateDirectories: true)
        _ = try writeJSONL("rollout-x.jsonl", mtime: now, under: dated)

        let kept = Set(SessionDiscovery.recentJSONL(under: root, within: 90, now: now).map(\.lastPathComponent))
        #expect(kept == ["session.jsonl", "rollout-x.jsonl"])   // subagents 子树两文件被剪,日期嵌套保留

        // excludeInternal=false → 不剪,全收(含内部),验证开关仍生效
        let all = SessionDiscovery.recentJSONL(under: root, within: 90, now: now, excludeInternal: false)
        #expect(all.count == 4)
    }
}
