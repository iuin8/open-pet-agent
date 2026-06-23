import Testing
import Foundation
@testable import AgentSensing

@Suite("SessionHistoryReader — 读 transcript 尾部窗口")
struct SessionHistoryReaderTests {

    func tempFile(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("histread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 一条合法 Claude assistant tool_use 行。
    func toolLine(_ cmd: String) -> String {
        #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\#(cmd)"}}]}}"#
    }

    @Test("小文件(< tailBytes)→ 返回全部合法行")
    func smallFile() throws {
        let url = try tempFile(toolLine("a") + "\n" + toolLine("b") + "\n")
        let events = SessionHistoryReader.read(url: url)
        #expect(events.count == 2)
        #expect(events.first?.kind == .toolUse(name: "Bash", summary: "a"))
    }

    @Test("大文件 → 只读尾部窗口,返回末尾若干合法行")
    func largeFileTail() throws {
        // 用大量噪声行填充到 > 默认 tailBytes,再在末尾放 3 条合法行。
        let filler = String(repeating: "{\"type\":\"attachment\",\"x\":\"" + String(repeating: "z", count: 200) + "\"}\n", count: 2000)  // ~ >400KB
        let tail = toolLine("t1") + "\n" + toolLine("t2") + "\n" + toolLine("t3") + "\n"
        let url = try tempFile(filler + tail)
        let events = SessionHistoryReader.read(url: url, tailBytes: 64_000)
        // 噪声(attachment)→ parser 返回 nil;只剩末尾合法行(seek 切半行可能少首条,故 ≥2)。
        #expect(events.count >= 2)
        #expect(events.last?.kind == .toolUse(name: "Bash", summary: "t3"))
    }

    @Test("不存在的文件 → []")
    func missing() {
        #expect(SessionHistoryReader.read(url: URL(fileURLWithPath: "/nope-\(UUID().uuidString).jsonl")).isEmpty)
    }

    // MARK: - G4 增量加载:窗口 + 游标链

    /// 一行 user prompt(便于按文本核对窗口边界)。
    func userLine(_ text: String) -> String {
        #"{"type":"user","sessionId":"s","message":{"content":"\#(text)"}}"#
    }

    @Test("窗口链:tail 窗 → endOffset 接更早窗,无缝无重叠,拼起来 = 全文")
    func windowChainNoOverlap() throws {
        // 10 行,每行带序号,总字节远大于小窗 → 必分多窗。
        let lines = (1...10).map { userLine("msg\($0)-\(String(repeating: "x", count: 80))") }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")

        var collected: [String] = []
        var cursor: UInt64? = nil
        var reachedStart = false
        var guardCount = 0
        repeat {
            let w = SessionHistoryReader.readWindow(url: url, endOffset: cursor, windowBytes: 200)
            // 把本窗事件文本 **前插**(更早窗在前)。
            let texts = w.events.compactMap { ev -> String? in
                if case .userPrompt(let t) = ev.kind { return t } else { return nil }
            }
            collected.insert(contentsOf: texts, at: 0)
            cursor = w.startOffset
            reachedStart = w.reachedStart
            guardCount += 1
        } while !reachedStart && guardCount < 50

        #expect(reachedStart)
        // 拼回的序号序列 = 原始 1..10 顺序,无重复无缺。
        let nums = collected.map { String($0.prefix(while: { $0 != "-" })) }
        #expect(nums == (1...10).map { "msg\($0)" })
    }

    @Test("readWindowSkippingNoise:尾部整窗噪音 → 往前跳到有事件的窗")
    func skipsNoiseWindows() throws {
        // 头部 1 条合法 user,后接一大段纯 attachment 噪音(> 默认窗,撑到末尾)。
        let noise = String(repeating: "{\"type\":\"attachment\",\"x\":\"" + String(repeating: "z", count: 200) + "\"}\n", count: 3000)  // ~ >600KB
        let url = try tempFile(userLine("真实首条") + "\n" + noise)
        // 单窗读末尾 → 全是噪音 → 空。
        #expect(SessionHistoryReader.readWindow(url: url, endOffset: nil, windowBytes: 200_000).events.isEmpty)
        // 跳噪音 → 往前找到那条 user。
        let w = SessionHistoryReader.readWindowSkippingNoise(url: url, endOffset: nil, windowBytes: 200_000)
        #expect(w.events.count == 1)
        if case .userPrompt(let t) = w.events.first?.kind { #expect(t == "真实首条") }
        else { Issue.record("应跳到 user 行") }
    }

    @Test("readWindowSkippingNoise:**夹在噪音间的真实消息不被跳读丢失**(skipStride 盲区回归)")
    func contiguousCrawlFindsSandwichedMessage() throws {
        // 一条 attachment 噪音行 ~60B。布局:头部噪音(3000B)+ 真实消息 + 尾部噪音(600B)。
        // 尾窗(256B)全噪音 → 触发爬;真实消息距尾 ~600B < crawlSpan(2048)→ **连续爬**一窗即覆盖。
        // 旧 skipStride 会从尾窗起点往头**跳 2048 再采样 256B** → 跳过真实消息(它在被跳过的 2KB gap 里)→ 丢。
        let noise = "{\"type\":\"attachment\",\"x\":\"" + String(repeating: "z", count: 30) + "\"}"
        let head = Array(repeating: noise, count: 50)      // ~3000B 头部噪音
        let tail = Array(repeating: noise, count: 10)      // ~600B 尾部噪音
        let lines = head + [userLine("夹在噪音间的真实消息")] + tail
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        // 尾窗确实空(纯噪音)。
        #expect(SessionHistoryReader.readWindow(url: url, endOffset: nil, windowBytes: 256).events.isEmpty)
        // 连续爬 → 找到夹在中间的真实消息(旧 skipStride 跳读会漏)。
        let w = SessionHistoryReader.readWindowSkippingNoise(url: url, endOffset: nil, windowBytes: 256, crawlSpan: 2048)
        let texts = w.events.compactMap { ev -> String? in if case .userPrompt(let t) = ev.kind { return t } else { return nil } }
        #expect(texts.contains("夹在噪音间的真实消息"), "连续爬应找到夹在噪音间的真实消息,不跳读丢失")
    }

    @Test("readRecentHistory:累积到 ≥minEvents 条(尾部一窗不够就往前补)")
    func recentHistoryAccumulates() throws {
        // 每行很长 → 一个 200B 窗只装得下几条 → 要补窗才够 minEvents。
        let lines = (1...30).map { userLine("m\($0)-\(String(repeating: "x", count: 60))") }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        let w = SessionHistoryReader.readRecentHistory(url: url, minEvents: 12, maxWindows: 20)
        #expect(w.events.count >= 12)
        // 末条仍是最新(m30)。
        if case .userPrompt(let t) = w.events.last?.kind { #expect(t.hasPrefix("m30")) }
        else { Issue.record("末条应是最新") }
    }

    @Test("readRecentHistory:小文件 → 全返回 + reachedStart")
    func recentHistorySmallFile() throws {
        let url = try tempFile(userLine("仅一条") + "\n")
        let w = SessionHistoryReader.readRecentHistory(url: url, minEvents: 40)
        #expect(w.events.count == 1)
        #expect(w.reachedStart)
    }

    @Test("readEarlierRows:按**可见 turn 行**累积(事件多折成少 turn 时,小窗补够 minRows 行)")
    func earlierRowsAccumulatesByTurns() throws {
        // 6 个 user 轮,每轮后跟 5 条 tool(折进同一 assistant 轮)→ 36 事件 / 12 可见 turn 行(6 user + 6 asst)。
        var lines: [String] = []
        for i in 1...6 {
            lines.append(userLine("u\(i)"))
            for _ in 1...5 { lines.append(toolLine("t")) }   // 5 tool 折进一个 asst 轮(不增可见行)
        }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        // 小窗(120B)→ 单窗只装几条事件、远不足 8 个 turn 行 → 必须按行累积补窗(验「不是按字节/事件停」)。
        let w = SessionHistoryReader.readEarlierRows(url: url, endOffset: size, minRows: 8, maxWindows: 40, windowBytes: 120)
        let turns = AgentConversation.buildTurns(from: w.events).count
        #expect(turns >= 8)   // 补够 ≥8 可见行(单窗按字节只会给 1-2 行)
    }

    @Test("readEarlierRows:到文件头即停(不超读),小文件全返回")
    func earlierRowsStopsAtStart() throws {
        let url = try tempFile(userLine("a") + "\n" + userLine("b") + "\n")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        // windowBytes=90:> 单行(~56)< 两行 → 每窗约 1 完整行,强制多窗累积;minRows=99 永远凑不够 → 靠到文件头停。
        let w = SessionHistoryReader.readEarlierRows(url: url, endOffset: size, minRows: 99, windowBytes: 90)
        #expect(w.reachedStart)        // minRows 凑不够也会因到文件头停
        #expect(w.events.count == 2)   // 全返回,不重复不漏
    }

    @Test("endOffset=nil → 读末尾窗;reachedStart 仅在读到文件头时 true")
    func tailWindowReachedStart() throws {
        let small = try tempFile(userLine("only") + "\n")
        let w1 = SessionHistoryReader.readWindow(url: small, endOffset: nil, windowBytes: 1_000_000)
        #expect(w1.reachedStart)               // 小文件一窗到底
        #expect(w1.events.count == 1)

        let big = try tempFile((1...20).map { userLine("m\($0)-\(String(repeating: "y", count: 60))") }.joined(separator: "\n") + "\n")
        let w2 = SessionHistoryReader.readWindow(url: big, endOffset: nil, windowBytes: 150)
        #expect(!w2.reachedStart)               // 末尾窗够不到文件头
        #expect(w2.startOffset > 0)
    }
}
