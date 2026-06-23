import Foundation

/// 扫 transcript 文件抽轻量元数据(标题 / 项目 / 起始时间 / git 分支 / 消息数),供陪伴卡片 picker 区分会话。
///
/// **成本感知**(实测真实文件可达 1GB,轮询 1.5s 不能全扫):
/// - 标题 / 项目 / 起始时间 / 分支只读**头部** `headBytes` + **尾部** `tailBytes`(Claude 自写的 `ai-title`
///   最新值在尾部),都是廉价 seek。
/// - 消息数需全读 → 带 `maxCountBytes` 预算上限,超限返回 nil(picker 此时靠 标题+分支+时间 区分)。
/// - 按 `(path, mtime, size)` 缓存:文件没变不重扫,轮询多次也只 `stat` 一次命中缓存。
///
/// `actor`:缓存是可变共享态;文件 IO 同步进行(actor 自有 executor,不阻塞 main)。Foundation only、可注入参数 → 无头单测。
public actor SessionMetadataScanner {

    private struct CacheKey: Hashable {
        let path: String
        let mtime: TimeInterval
        let size: UInt64
    }

    private var cache: [CacheKey: SessionMetadata] = [:]

    private let headBytes: Int
    private let tailBytes: Int
    private let maxCountBytes: UInt64
    /// 标题裁剪长度(picker 单行显示)。
    private let titleClip: Int

    public init(
        headBytes: Int = 32_768,
        tailBytes: Int = 65_536,
        maxCountBytes: UInt64 = 64 << 20,
        titleClip: Int = 48
    ) {
        self.headBytes = headBytes
        self.tailBytes = tailBytes
        self.maxCountBytes = maxCountBytes
        self.titleClip = titleClip
    }

    /// 返回 `url` 的会话元数据。文件不存在 / 读失败 → nil。命中 `(path,mtime,size)` 缓存则不重扫。
    public func metadata(for url: URL, agent: AgentKind) -> SessionMetadata? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        let key = CacheKey(path: url.path, mtime: mtime.timeIntervalSince1970, size: size)
        if let hit = cache[key] { return hit }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let head = readHead(handle)
        let tail = readTail(handle, size: size)

        let parsed = parseHead(head, agent: agent)
        let gitBranch = Self.extractJSONString(head, key: "gitBranch", takeLast: false)
        let aiTitle = Self.extractJSONString(tail, key: "aiTitle", takeLast: true)
        let title = [aiTitle, parsed.firstUser]
            .compactMap { $0 }
            .first { !$0.isEmpty }
            .map { clip($0) }
        let count = size <= maxCountBytes ? countMessages(handle, agent: agent) : nil
        // 上下文窗口占用:尾部最新 assistant usage(Claude 才有此格式;Codex → nil)。
        let contextTokens = agent == .claudeCode ? Self.extractLatestContextTokens(tail) : nil

        let meta = SessionMetadata(
            title: title,
            projectName: parsed.projectName,
            startTime: parsed.startTime,
            gitBranch: gitBranch,
            messageCount: count,
            contextTokens: contextTokens,
            lastModified: mtime
        )
        cache[key] = meta
        return meta
    }

    // MARK: - 头/尾读取

    private func readHead(_ handle: FileHandle) -> String {
        do { try handle.seek(toOffset: 0) } catch { return "" }
        let data = (try? handle.read(upToCount: headBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func readTail(_ handle: FileHandle, size: UInt64) -> String {
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 头部解析(复用 parser 拿首条 user / 起始时间 / 项目)

    private func parseHead(
        _ head: String,
        agent: AgentKind
    ) -> (firstUser: String?, startTime: Date?, projectName: String?) {
        let parser: any TranscriptParser = (agent == .codex) ? CodexTranscriptParser() : ClaudeTranscriptParser()
        var firstUser: String?
        var startTime: Date?
        var projectName: String?
        // 末行可能被 headBytes 切半 → parser 自然返回空丢弃,无害。一行可能多事件(P0-2)→ 逐个取元数据。
        outer: for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            for ev in parser.parse(line: String(line), fallbackSessionId: "", fallbackCwd: nil) {
                if startTime == nil { startTime = ev.timestamp }
                if projectName == nil, let p = ev.projectName { projectName = p }
                if firstUser == nil, case .userPrompt(let text) = ev.kind,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstUser = text
                }
                if firstUser != nil, startTime != nil, projectName != nil { break outer }
            }
        }
        return (firstUser, startTime, projectName)
    }

    // MARK: - 消息数(预算内全读 → 数 user/assistant 标记出现次数)

    private func countMessages(_ handle: FileHandle, agent: AgentKind) -> Int? {
        do { try handle.seek(toOffset: 0) } catch { return nil }
        guard let data = try? handle.readToEnd() else { return nil }
        let userMark = Data((agent == .codex ? #""role":"user""# : #""type":"user""#).utf8)
        let asstMark = Data((agent == .codex ? #""role":"assistant""# : #""type":"assistant""#).utf8)
        // 每条 user/assistant 记录行恰好含一个对应标记 → 数标记出现次数 = 消息数。
        return Self.countOccurrences(of: userMark, in: data) + Self.countOccurrences(of: asstMark, in: data)
    }

    // MARK: - 纯函数 helper(可单测)

    /// 从 JSON 文本里抽 `"key":"value"` 的 value(处理 `\"` 转义)。`takeLast` 取最后一个匹配(aiTitle 用最新)。
    static func extractJSONString(_ text: String, key: String, takeLast: Bool) -> String? {
        let marker = "\"\(key)\":\""
        var searchStart = text.startIndex
        var found: String?
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            var i = range.upperBound
            var value = ""
            var escaped = false
            while i < text.endIndex {
                let c = text[i]
                if escaped {
                    value.append(c); escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    break
                } else {
                    value.append(c)
                }
                i = text.index(after: i)
            }
            found = value
            if !takeLast { break }
            searchStart = i
        }
        return (found?.isEmpty == false) ? found : nil
    }

    /// 数 `needle` 在 `haystack` 里出现次数(不重叠)。
    static func countOccurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// 从尾部文本抽**最新一条 assistant `usage`** 的上下文 token 数 =
    /// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`(参考 claude-devtools)。
    /// 取最后一个 `"usage":{` 块(= 最新轮);三字段都在嵌套 `server_tool_use` 之前 → 取到首个 `}` 即够。
    static func extractLatestContextTokens(_ text: String) -> Int? {
        guard let r = text.range(of: "\"usage\":{", options: .backwards) else { return nil }
        let obj = text[r.upperBound...].prefix(while: { $0 != "}" })
        func num(_ key: String) -> Int {
            guard let kr = obj.range(of: "\"\(key)\":") else { return 0 }
            return Int(obj[kr.upperBound...].prefix(while: { $0.isNumber })) ?? 0
        }
        let total = num("input_tokens") + num("cache_creation_input_tokens") + num("cache_read_input_tokens")
        return total > 0 ? total : nil
    }

    /// 标题裁剪:换行折成空格、压多余空白、超 `titleClip` 截断加省略号。
    private func clip(_ raw: String) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if collapsed.count <= titleClip { return collapsed }
        return String(collapsed.prefix(titleClip)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
