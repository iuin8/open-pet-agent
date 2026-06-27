// Sources/Orchestrator/Proactive/ProactiveDiagnostics.swift
import Foundation
import os

/// 主动协助管线的可观测性 + 超时兜底（#3：根治「宠物突然不再主动说话且无从诊断」）。
///
/// 两件事：
///   1. `ProactiveDiag` —— 统一日志。各决策闸 / 生成耗时 / 失败原因走 `os.Logger`
///      (category=`proactive`，`log stream --predicate 'category=="proactive"'` 可看)；
///      `PETAGENT_DEBUG_PROACTIVE=1` 时额外镜像到 stderr（直跑二进制看决策链）。
///      **隐私**：只记 kind / 决策结果 / 耗时 / 长度等非 PII，**绝不记**窗口标题 / persona / 建议正文。
///   2. `withProactiveTimeout` —— 给 LLM 生成加独立硬超时。LLM 网关异常时
///      `streamChat` 可能挂起远超 URLSession 超时；不兜底则 `isGenerating` 永卡 true →
///      整个主动引擎静默死。超时抛错 → 引擎 `defer` 复位 `isGenerating` → 下次能恢复。
public enum ProactiveDiag {
    static let logger = Logger(subsystem: "io.openpetagent", category: "proactive")
    /// 直跑二进制时把决策镜像到 stderr（开发调试用，见 development-guide 调试开关表）。
    static let mirrorToStderr = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_PROACTIVE"] == "1"

    /// 决策闸结果（为什么没冒 / 跳过）。非 PII。
    public static func decision(_ message: @autoclosure () -> String) {
        let m = message()
        logger.debug("\(m, privacy: .public)")
        emit("• " + m)
    }

    /// 关键事件（真的冒了一条 / 生成耗时）。非 PII。
    public static func event(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        emit("✓ " + m)
    }

    /// 失败 / 超时（这是「突然不说话」的根因线索）。非 PII。
    public static func failure(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        emit("⚠️ " + m)
    }

    private static func emit(_ line: String) {
        guard mirrorToStderr else { return }
        FileHandle.standardError.write(Data(("[PROACTIVE] " + line + "\n").utf8))
    }
}

/// 超时错误（与普通生成失败区分，便于日志归因）。
public struct ProactiveTimeoutError: Error, Sendable {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
}

/// 给一段 async 操作加硬超时：操作与「睡 `seconds` 后抛超时」竞速，谁先完成用谁，
/// 另一支取消。`seconds <= 0` 视为不超时（直接 await 操作，给测试/特殊场景用）。
public func withProactiveTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProactiveTimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ProactiveTimeoutError(seconds: seconds) }
        return first
    }
}
