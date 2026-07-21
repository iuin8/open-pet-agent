import Foundation

// AgentSessionHandoffTracker:P4 跨引擎/项目交接。
//
// ACP session 存在各 agent 自己的存储里,跨引擎/跨项目(会话桶 engineKind|cwd 变化)后
// 新 session 上下文为零 —— 协议层无解(硬边界)。本 tracker 在桶变化后的首个 agent run
// 产出一次性「背景交接」(此前会话摘要,注入首条 prompt),之后同桶不再触发。
// actor:replyStream 的并发上下文里串行化「读桶 + 更新」,防并发首个 run 重复交接。

/// 跟踪 agent 会话桶变化的一次性交接背景供给。
public actor AgentSessionHandoffTracker {
    private var lastBucket: String?

    public init() {}

    /// 每个 agent run 前调。桶与上次不同(且非首轮)→ 调 transcript 拿摘要返回;
    /// 首轮/同桶 → 仅更新记录返回 nil。transcript 惰性(仅变化时调用);
    /// transcript 返回 nil(空时间线)桶也更新,不逐条消息重试。
    public func contextIfBucketChanged(
        bucket: String,
        transcript: @Sendable () async -> String?
    ) async -> String? {
        defer { lastBucket = bucket }
        guard let lastBucket, lastBucket != bucket else { return nil }
        return await transcript()
    }
}
