import Foundation

/// 真 `claude -p` 子进程封装 (N2.1)。替换 `StubClaudeCodeEngine` 用于工具层
/// 实际任务执行。`StubClaudeCodeEngine` 保留作 ToolMode-disabled / 开发机
/// 没装 claude 时的 fallback。
///
/// 流程:
/// 1. `CLIAvailability.locate` 找 claude binary 在 PATH 中绝对路径
/// 2. spawn Process: `claude -p <prompt> --output-format stream-json --verbose`
/// 3. 异步读 stdout (`readabilityHandler` 回调), line-by-line 解析 JSON
/// 4. 遇到 `type == "assistant"` 的 message → 增量 yield text content
/// 5. 遇到 `type == "result"`:
///    - `is_error == true`  → finish stream 抛 `subprocessFailed`
///    - `is_error == false` → finish stream
/// 6. `terminationHandler` 兜底:子进程非 0 退出 → 抛 `subprocessFailed`
///
/// 简化范围 (HermesPet 原版做了, 我们 N2.1 不做):
/// - 不传 image attachments (`claude -p` 单纯文本)
/// - 不做 `--add-dir` 自动路径推断
/// - 不接 stderr 中间过程 (HermesPet 用 stderr 做 progress 提示, 我们只在异常时拼到错误)
/// - 不做 process pool / queue (单次 task 单 process)
/// - 不做工具调用 Notification 广播 (Notifications 是 UI 关注的事, ToolMode 层不管)
///
/// 并发模型:
/// - `Process.run()` 在调用 thread 启动子进程, stdout/stderr 由系统线程回调
///   `readabilityHandler` —— 解析状态必须线程安全, 用 `StreamState` (NSLock 保护)
/// - `AsyncThrowingStream` 的 `continuation.yield` / `finish` 本身线程安全
/// - 调用方取消 stream → `onTermination` 把子进程 SIGTERM 掉
public struct ClaudeCodeEngine: ToolEngine {
    public static let kind: ToolEngineKind = .claudeCode

    /// 可注入的 binary 路径(测试用 fixture 指向 stub shell script)。
    /// `nil` = 运行时走 `CLIAvailability.locate` 找 "claude"。
    public let binaryPath: String?

    /// 可注入的环境变量(测试用)。生产代码 `nil` = 用 `ProcessInfo.environment`。
    public let processEnvironment: [String: String]?

    /// 子进程读流硬超时(秒)。watchdog 到点仍未收尾 → SIGTERM 子进程 +
    /// `finish(throwing: .timedOut)`，防 EOF/stream 竞态让调用方永久挂住。
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
            // 注入扩展过的 searchPaths 让 GUI 启动的 OpenPetAgent 也能找到
            // ~/.local/bin / /opt/homebrew/bin 等用户实际安装目录。
            let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
            let paths = augmentedPath
                .split(separator: ":")
                .map(String.init)
            let cli = CLIAvailability()
            return await cli.locate(binary: "claude", searchPaths: paths) != nil
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
                    // 与 isAvailable 保持一致 — 注入扩展 PATH 让 GUI app 也能
                    // 找到 ~/.local/bin / /opt/homebrew/bin 中的 CLI。
                    let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
                    let paths = augmentedPath
                        .split(separator: ":")
                        .map(String.init)
                    let cli = CLIAvailability()
                    guard let located = await cli.locate(
                        binary: "claude",
                        searchPaths: paths
                    ) else {
                        continuation.finish(
                            throwing: ToolEngineError.cliNotInstalled(.claudeCode)
                        )
                        return
                    }
                    binary = located
                }

                // 2. 启动子进程并把 lifecycle 委派到同步辅助函数 ——
                //    spawn / 等待 / cleanup 都在内部完成。
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
    /// 抽到 static 函数为了让 `run(prompt:)` 内部 Task 闭包更短、并让逻辑可测。
    ///
    /// `continuation` 由调用方持有, 这里只负责往里 `yield` / `finish`。
    private static func spawnAndStream(
        binary: String,
        prompt: String,
        environment: [String: String]?,
        timeoutSeconds: Double,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose"  // stream-json 必须配 --verbose
        ]
        if let env = environment {
            process.environment = env
        } else {
            // 默认走扩展 PATH,确保子进程也能找到 ~/.local/bin / brew 等位置
            // 的依赖(比如 claude 走 `#!/usr/bin/env node` 时需要 PATH 里有 node)。
            process.environment = CLIProcessEnvironment.augmented()
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 共享解析状态(回调线程安全)
        let state = StreamState()
        let stderrBuffer = LockedData()

        // stderr: 收集起来, 进程异常退出时拼到 error message 里
        // EOF 防护(参考 HermesPet v1.2.10 修复): availableData 返回空 = 管道
        // EOF, 不立刻置 nil 的话 dispatch source 会高频回调读空 data → 200%
        // CPU 空转, 直到 termination 才被 cleanup。在 handler 内立刻 nil 关闭。
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        // stdout: 按行切, 每行一个 stream-json message
        // EOF 同款防护。
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.consume(data: data, yieldText: { delta in
                continuation.yield(delta)
            }, finishWithError: { err in
                continuation.finish(throwing: err)
            }, finishSuccess: {
                continuation.finish()
            })
        }

        // watchdog 硬超时兜底:到点仍未收尾 → SIGTERM 子进程 + finish(timedOut)。
        // 防 EOF/stream 竞态让调用方 `for try await` 永久挂住(2026-06-04 修)。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
            if Task.isCancelled { return }
            if state.markFinishedIfNeeded() {
                if process.isRunning { process.terminate() }
                continuation.finish(throwing: ToolEngineError.timedOut(.claudeCode))
            }
        }

        // 子进程结束兜底: 正常退出由 "result" 事件 finish; 异常退出在这里抛。
        // 这里也是 SubprocessRegistry 的 unregister 时机 —— Process 一旦走完
        // terminationHandler 就不会再活,无论是正常 exit / SIGTERM / SIGKILL。
        process.terminationHandler = { proc in
            watchdog.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // 从 registry 移除(fire-and-forget,不阻塞 termination 回调)
            Task { await SubprocessRegistry.shared.unregister(proc) }
            // 已收尾(result 事件正常 finish / watchdog 超时)→ 不再处理。
            if state.didFinish { return }

            // drain 残余 stdout:readabilityHandler 可能在读到 result 事件前就被上面
            // 置 nil(进程快速退出竞态),buffered 数据没被 consume → 否则丢内容 +
            // **永不 finish**(exit 0 时下面 != 0 分支不触发 → consumer 永久挂死,
            // 这是 131 分钟挂死的根因)。进程已退出, readDataToEndOfFile 立即返回。
            let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                state.consume(data: remaining,
                              yieldText: { continuation.yield($0) },
                              finishWithError: { continuation.finish(throwing: $0) },
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
                // exit 0 但无 result 事件(stdout EOF 边界)→ 兜底 finish。
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
        // fire-and-forget:register 是 actor hop,但子进程已经在跑,不阻塞 stream。
        Task { await SubprocessRegistry.shared.register(process) }

        // 调用方取消 stream → 杀子进程 + 停 watchdog。
        continuation.onTermination = { @Sendable _ in
            watchdog.cancel()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    // MARK: - 公共: stream-json line 解析

    /// 解析一行 stream-json,返回 assistant message 完整 text content
    /// (多个 text content block 合并)。
    ///
    /// 返回 `nil` 的情况:
    /// - 行不是 JSON
    /// - `type` 不是 `"assistant"`
    /// - `message.content` 数组为空或无 text 块
    ///
    /// 错误格式静默忽略(返回 `nil`),避免一行坏 JSON 让整个 stream 挂掉。
    public static func parseAssistantText(_ line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String, type == "assistant" else {
            return nil
        }
        guard let message = json["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else {
            return nil
        }
        var collected = ""
        for content in contentArray {
            if let contentType = content["type"] as? String,
               contentType == "text",
               let text = content["text"] as? String {
                collected += text
            }
        }
        return collected.isEmpty ? nil : collected
    }

    /// 解析一行 stream-json 的 `result` 事件。
    /// 返回 nil = 该行不是 result; 返回非 nil = result 事件, `.success` /
    /// `.failure(errorText)`。
    public static func parseResultEvent(_ line: String) -> ResultEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String, type == "result" else { return nil }
        let isError = json["is_error"] as? Bool ?? false
        if isError {
            let msg = (json["result"] as? String) ?? "未知错误"
            return .failure(msg)
        }
        return .success
    }

    /// `result` 事件类型。
    public enum ResultEvent: Equatable, Sendable {
        case success
        case failure(String)
    }
}

// MARK: - 内部状态机

/// stdout 解析的可变状态。`readabilityHandler` 在系统线程被调用,
/// 必须用锁串行化。
///
/// 同时跟踪 assistant message 的"已 yield 文本长度"实现增量 yield:
/// stream-json 模式下每条 partial message 输出当前累计文本,
/// 我们要扣掉上次已 yield 的部分,避免重复。
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lastAssistantId: String?
    private var lastAssistantText: String = ""
    private var _didFinish: Bool = false

    var didFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinish
    }

    func markFinished() {
        lock.lock(); defer { lock.unlock() }
        _didFinish = true
    }

    /// 原子 test-and-set。返回 true = 本次是第一个收尾者(可 finish);false =
    /// 已被别处收尾(跳过，避免重复 finish AsyncThrowingStream 引发 trap)。
    /// watchdog / terminationHandler 竞争收尾时用它互斥。
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
        finishWithError: (Error) -> Void,
        finishSuccess: () -> Void
    ) {
        lock.lock()
        if _didFinish {
            lock.unlock()
            return
        }
        buffer.append(data)

        var pendingDeltas: [String] = []
        var resultToReport: ClaudeCodeEngine.ResultEvent?

        // 按 \n (0x0A) 切行
        while let nlRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<nlRange.lowerBound)
            buffer.removeSubrange(0..<nlRange.upperBound)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty else {
                continue
            }

            // 先看是不是 result 事件
            if let result = ClaudeCodeEngine.parseResultEvent(line) {
                resultToReport = result
                break  // result 后面的行不再处理
            }

            // 否则尝试当 assistant message 解析
            guard let fullText = ClaudeCodeEngine.parseAssistantText(line) else {
                continue
            }

            // 提取 message id 决定是增量更新还是新 message
            let messageId = Self.extractAssistantMessageId(from: line)
            if let messageId, messageId == lastAssistantId {
                // 同一条 message 的 partial update, yield 增量
                if fullText.count > lastAssistantText.count {
                    let delta = String(fullText.dropFirst(lastAssistantText.count))
                    pendingDeltas.append(delta)
                    lastAssistantText = fullText
                }
            } else {
                // 新 message: 多轮 tool calling 时会有多条
                if lastAssistantId != nil, !fullText.isEmpty {
                    pendingDeltas.append("\n\n")
                }
                lastAssistantId = messageId
                lastAssistantText = fullText
                if !fullText.isEmpty {
                    pendingDeltas.append(fullText)
                }
            }
        }

        if resultToReport != nil {
            _didFinish = true
        }
        lock.unlock()

        for delta in pendingDeltas {
            yieldText(delta)
        }
        switch resultToReport {
        case .some(.success):
            finishSuccess()
        case .some(.failure(let msg)):
            finishWithError(ToolEngineError.subprocessFailed(exitCode: 0, stderr: msg))
        case .none:
            break
        }
    }

    /// 从原始 JSON 行里提取 `message.id`。没有就 nil(stub script 可能不带 id)。
    private static func extractAssistantMessageId(from line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let message = json["message"] as? [String: Any] else { return nil }
        return message["id"] as? String
    }
}

/// 子进程 stderr 的线程安全缓冲区。
private final class LockedData: @unchecked Sendable {
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
