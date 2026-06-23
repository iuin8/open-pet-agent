import Foundation

/// 真 `codex exec --json` 子进程封装 (N2.4)。第二个工具 engine,跟
/// `ClaudeCodeEngine` 并列,选哪个由 `UserDefaults["tool.engine.kind"]`
/// 决定;`isAvailable` 探测 PATH 中是否有 `codex` binary。
///
/// 流程:
/// 1. `CLIAvailability.locate` 找 codex binary 在 PATH 中绝对路径
/// 2. spawn Process: `codex exec --json --skip-git-repo-check
///    --dangerously-bypass-approvals-and-sandbox -- <prompt>`
/// 3. 异步读 stdout (`readabilityHandler`), line-by-line 解析 JSON
/// 4. 解析 codex 的 JSONL 事件流:
///    - `type == "item.completed"` && `item.type == "agent_message"`
///      → yield `item.text`
///    - `type == "turn.completed"` → finish stream (但 process 还在收尾)
/// 5. `terminationHandler` 兜底:子进程非 0 退出 → 抛 `subprocessFailed`
///    (codex 自带 ERROR 日志到 stderr 但 exit 0 是正常的;**仅看 exit code**)
///
/// 关键差异 vs `ClaudeCodeEngine`:
/// - **事件名带点**:`thread.started` / `item.completed` / `turn.completed`
///   (不是下划线 `thread_started`)—— 实测 `codex exec --json` 0.130.0 输出
///   是 dot-namespaced,参考 HermesPet (https://github.com/basionwang-bot/HermesPet)
/// - **`--` 终止符必须有**:HermesPet 决策 #8,`-i FILE...` 是 clap greedy
///   multi-value flag。我们不传 `-i`,但 prompt 中可能出现 `-` 开头字符,统一
///   加 `--` 把 prompt 当 positional argument 处理更稳。
/// - **`--skip-git-repo-check`**:cwd 非 git repo 时 codex 默认会卡住要确认,
///   桌宠场景永远没 git repo 上下文,直接 skip。
/// - **`--dangerously-bypass-approvals-and-sandbox`**:桌宠是用户主动开
///   工具模式给它干活,不再每个操作单独询问审批。这跟 HermesPet 一样的取舍。
/// - **assistant 文本一次性给**:codex 每个 `item.completed` agent_message
///   是一段完整文本,**不是增量**。多段之间用 `"\n\n"` 拼接(跟 HermesPet
///   一致)。所以这里**没有** ClaudeCodeEngine 的 partial-update 去重逻辑。
/// - **stderr 不当错误**:codex 0.130.0 启动时会先打一堆 token/skill ERROR
///   日志到 stderr,然后正常完成。**绝不能因 stderr 非空就 throw**。
///
/// 简化范围(HermesPet 原版做了, 我们 N2.4 不做):
/// - 不传图片 `-i path` (纯文本聊天)
/// - 不做 session resume (HermesPet 每个对话绑定 thread_id,我们工具层一次
///   一次任务,resume 留 N3+ 多轮工具对话时再做)
/// - 不广播 `HermesPetToolStarted/Ended` 通知(notification 是 UI 关注的事,
///   ToolMode 层不管)
/// - 不消费 codex 生成的图片(`.codex/generated_images` 监听)
///
/// 并发模型:
/// - 跟 ClaudeCodeEngine 同形:`readabilityHandler` 系统线程回调,
///   `StreamState` 用 NSLock 串行化
/// - `AsyncThrowingStream` 的 yield / finish 本身线程安全
/// - 调用方取消 stream → `onTermination` 把子进程 SIGTERM 掉
public struct CodexEngine: ToolEngine {
    public static let kind: ToolEngineKind = .codex

    /// 可注入的 binary 路径(测试用 fixture 指向 stub shell script)。
    /// `nil` = 运行时走 `CLIAvailability.locate` 找 "codex"。
    public let binaryPath: String?

    /// 可注入的环境变量(测试用)。生产代码 `nil` = 用扩展 PATH 的
    /// `CLIProcessEnvironment.augmented()`。
    public let processEnvironment: [String: String]?

    /// 子进程读流硬超时(秒)。watchdog 到点仍未收尾 → SIGTERM 子进程 +
    /// `finish(throwing: .timedOut)`，防 EOF/stream 竞态让调用方永久挂住。
    /// 默认 300s 给真实工具任务足够余量；测试注入短值验证 watchdog。
    public let timeoutSeconds: Double

    public init(
        binaryPath: String? = nil,
        processEnvironment: [String: String]? = nil,
        timeoutSeconds: Double = 300
    ) {
        self.binaryPath = binaryPath
        self.processEnvironment = processEnvironment
        self.timeoutSeconds = timeoutSeconds
    }

    public var isAvailable: Bool {
        get async {
            if let path = binaryPath {
                return FileManager.default.isExecutableFile(atPath: path)
            }
            // 跟 ClaudeCodeEngine 一致 — GUI app 启动的 OpenPetAgent 拿到的 PATH
            // 通常只有 /usr/bin:/bin:/usr/sbin:/sbin,看不到 ~/.local/bin /
            // /opt/homebrew/bin。注入扩展 PATH 让它能找到。
            let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
            let paths = augmentedPath
                .split(separator: ":")
                .map(String.init)
            let cli = CLIAvailability()
            return await cli.locate(binary: "codex", searchPaths: paths) != nil
        }
    }

    public func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        let resolvedBinary = self.binaryPath
        let resolvedEnv = self.processEnvironment
        let resolvedTimeout = self.timeoutSeconds

        return AsyncThrowingStream { continuation in
            Task {
                // 1. 解析 binary 路径
                let binary: String
                if let path = resolvedBinary {
                    binary = path
                } else {
                    let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
                    let paths = augmentedPath
                        .split(separator: ":")
                        .map(String.init)
                    let cli = CLIAvailability()
                    guard let located = await cli.locate(
                        binary: "codex",
                        searchPaths: paths
                    ) else {
                        continuation.finish(
                            throwing: ToolEngineError.cliNotInstalled(.codex)
                        )
                        return
                    }
                    binary = located
                }

                // 2. spawn 子进程 + wire stream
                Self.spawnAndStream(
                    binary: binary,
                    prompt: prompt,
                    environment: resolvedEnv,
                    timeoutSeconds: resolvedTimeout,
                    continuation: continuation
                )
            }
        }
    }

    // MARK: - 子进程 spawn + stdout 流式解析

    /// spawn 子进程 + wire readabilityHandler + 设置 cleanup 钩子。
    /// 跟 ClaudeCodeEngine 同形,只是参数列表和事件解析不同。
    private static func spawnAndStream(
        binary: String,
        prompt: String,
        environment: [String: String]?,
        timeoutSeconds: Double,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // 参数固定:
        // - `exec`               单次任务模式(非 REPL)
        // - `--json`             JSONL 事件流到 stdout
        // - `--skip-git-repo-check` 桌宠 cwd 不一定是 git repo
        // - `--dangerously-bypass-approvals-and-sandbox` 工具模式由用户主动
        //   开启,不再每操作单独审批
        // - `--`                 显式终止 flag 解析,后面是 positional prompt
        process.arguments = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
            "--",
            prompt
        ]
        if let env = environment {
            process.environment = env
        } else {
            // 默认走扩展 PATH —— 与 ClaudeCodeEngine 一致, 保证子进程能找到
            // 依赖(codex 二进制本身可能 link 系统库,但子工具调用如 git/node
            // 也走这个 PATH)
            process.environment = CLIProcessEnvironment.augmented()
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 共享解析状态(回调线程安全)
        let state = CodexStreamState()
        let stderrBuffer = CodexLockedData()

        // stderr: 收集起来, 进程**非 0 退出**时才拼到 error message 里。
        // 注意:codex 0.130.0 启动时常态打 ERROR 日志到 stderr(token 过期 /
        // skill yaml parse 失败等),exit code 仍是 0 → 视为成功。所以**不能
        // 因 stderr 有内容就 throw**,这是跟 ClaudeCodeEngine 处理一致的。
        // EOF 防护(参考 HermesPet v1.2.10): availableData 返回空 = 管道 EOF,
        // 不立刻置 nil 的话 dispatch source 会高频回调读空 data → 200% CPU 空转,
        // 直到 terminationHandler 才被 cleanup。立刻 nil 关闭。
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        // stdout: 按 \n 切, 每行一个 codex JSONL 事件
        // EOF 同款防护。
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.consume(data: data, yieldText: { delta in
                continuation.yield(delta)
            }, finishSuccess: {
                continuation.finish()
            })
        }

        // watchdog 硬超时兜底:到点仍未收尾 → SIGTERM 子进程 + finish(timedOut)。
        // 防 EOF/stream 竞态让调用方 `for try await` 永久挂住(2026-06-04 修)。
        // `markFinishedIfNeeded` 保证与正常收尾 / terminationHandler 互斥,不重复 finish。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
            if Task.isCancelled { return }
            if state.markFinishedIfNeeded() {
                if process.isRunning { process.terminate() }
                continuation.finish(throwing: ToolEngineError.timedOut(.codex))
            }
        }

        // 子进程结束兜底
        process.terminationHandler = { proc in
            watchdog.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // 从 registry 移除(fire-and-forget,不阻塞 termination 回调)
            Task { await SubprocessRegistry.shared.unregister(proc) }
            // 已收尾(turn.completed 正常 finish / watchdog 超时)→ 不再处理,避免
            // 多余阻塞读 + 重复 finish。
            if state.didFinish { return }

            // drain 残余 stdout:readabilityHandler 可能在读到 turn.completed 前就被
            // 上面置 nil(进程快速退出竞态),buffered 数据没被 consume → 否则丢内容 +
            // 永不 finish(挂死根因)。进程已退出, readDataToEndOfFile 立即返回。
            let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                state.consume(data: remaining, yieldText: { continuation.yield($0) },
                              finishSuccess: { continuation.finish() })
            }
            if state.didFinish { return }

            // 仍未收尾 → 按 exit code 兜底。
            if proc.terminationStatus != 0 {
                _ = state.markFinishedIfNeeded()
                var errData = stderrBuffer.data
                errData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.finish(throwing: ToolEngineError.subprocessFailed(
                    exitCode: proc.terminationStatus,
                    stderr: stderr
                ))
            } else if state.markFinishedIfNeeded() {
                // 正常退出但无 turn.completed(stdout EOF 边界)→ 兜底 finish。
                continuation.finish()
            }
        }

        // 启动子进程
        do {
            try process.run()
        } catch {
            watchdog.cancel()
            continuation.finish(throwing: error)
            return
        }

        // 注册到全局 registry,app 退出时统一 SIGTERM 收口。
        Task { await SubprocessRegistry.shared.register(process) }

        // 调用方取消 stream → 杀子进程 + 停 watchdog。
        continuation.onTermination = { @Sendable _ in
            watchdog.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    // MARK: - 公共: codex JSONL 事件解析

    /// 解析一行 codex JSONL,提取 agent_message item 的完整文本。
    ///
    /// 匹配模式:
    /// ```json
    /// {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
    /// ```
    ///
    /// 返回 `nil` 的情况:
    /// - 行不是 JSON
    /// - `type` 不是 `"item.completed"`
    /// - `item.type` 不是 `"agent_message"`
    /// - `item.text` 为空 / 缺失
    ///
    /// 错误格式静默忽略(返回 `nil`),避免一行坏 JSON 让整个 stream 挂掉。
    /// 这点跟 ClaudeCodeEngine.parseAssistantText 行为一致 —— stream 应当
    /// 容忍 codex 未来加新事件类型 / 字段。
    public static func parseAgentMessage(_ line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String, type == "item.completed" else {
            return nil
        }
        guard let item = json["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              itemType == "agent_message",
              let text = item["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return text
    }

    /// 解析一行 codex JSONL 的 `error` 事件。
    ///
    /// codex JSONL 流里偶尔会出现:
    /// ```json
    /// {"type":"error","message":"..."}
    /// ```
    /// 返回非 nil 的 message 字符串;其他事件返回 nil。
    ///
    /// 注意:目前实测 codex 0.130.0 把致命错误打 stderr + exit code != 0,
    /// 而非用 JSONL `error` 事件。该解析器留给未来 codex 升级后用 JSONL
    /// 错误事件的兼容性(有备无患)。当前 streaming 路径不主动消费它,
    /// 仅作为 public 解析器暴露给上层 / 测试。
    public static func parseErrorEvent(_ line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String, type == "error" else {
            return nil
        }
        return json["message"] as? String
    }

    /// 判断一行是不是 `turn.completed` 事件 —— stream 结束信号。
    public static func isTurnCompleted(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (json["type"] as? String) == "turn.completed"
    }
}

// MARK: - 内部状态机

/// stdout 解析的可变状态。`readabilityHandler` 在系统线程被调用,
/// 必须用锁串行化。
///
/// 跟 ClaudeCodeEngine 的 `StreamState` 不同点:
/// - codex 每个 agent_message 都是完整段文本(非增量),所以没有
///   "已 yield 长度"跟踪;多段之间插 `"\n\n"` 拼接。
/// - codex 用 `turn.completed` 显式 finish,没有 ClaudeCode 的
///   `result` 事件那种 `is_error` 字段。
private final class CodexStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var hasEmittedAny: Bool = false
    private var _didFinish: Bool = false

    /// 是否已收尾（drain 前判，避免重复 finish / 多余阻塞读）。
    var didFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinish
    }

    /// 标记 finish 状态。返回 true 表示这次调用是第一个 marker(可以触发
    /// 后续 finish 操作);返回 false 表示之前已经 finish 过,调用方应当
    /// 跳过(避免重复 finish AsyncThrowingStream 引发 trap)。
    func markFinishedIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _didFinish { return false }
        _didFinish = true
        return true
    }

    /// 消费 stdout 新到达的数据。按 `\n` 切行解析,触发 yield/finish 回调。
    /// 回调可能在锁外执行(yield 自身线程安全, 不必要持锁)。
    func consume(
        data: Data,
        yieldText: (String) -> Void,
        finishSuccess: () -> Void
    ) {
        lock.lock()
        if _didFinish {
            lock.unlock()
            return
        }
        buffer.append(data)

        var pendingDeltas: [String] = []
        var shouldFinish = false

        // 按 \n (0x0A) 切行
        while let nlRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<nlRange.lowerBound)
            buffer.removeSubrange(0..<nlRange.upperBound)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty else {
                continue
            }

            // 优先看是不是 turn.completed —— 显式 finish 信号
            if CodexEngine.isTurnCompleted(line) {
                shouldFinish = true
                break  // turn.completed 后续不再处理(实测后面没东西)
            }

            // 否则尝试当 agent_message 解析
            guard let text = CodexEngine.parseAgentMessage(line) else {
                // 不是 agent_message,可能是 thread.started / turn.started /
                // item.started / item.completed(非 agent_message)等。
                // 静默跳过(我们 N2.4 不消费工具事件)。
                continue
            }

            // 多段 agent_message 之间插 \n\n 分隔,跟 HermesPet 一致
            if hasEmittedAny {
                pendingDeltas.append("\n\n")
            }
            pendingDeltas.append(text)
            hasEmittedAny = true
        }

        if shouldFinish {
            _didFinish = true
        }
        lock.unlock()

        for delta in pendingDeltas {
            yieldText(delta)
        }
        if shouldFinish {
            finishSuccess()
        }
    }
}

/// 子进程 stderr 的线程安全缓冲区。与 ClaudeCodeEngine 内部的 `LockedData`
/// 同构,这里独立一份避免 fileprivate 跨文件耦合。
private final class CodexLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
    }
}
