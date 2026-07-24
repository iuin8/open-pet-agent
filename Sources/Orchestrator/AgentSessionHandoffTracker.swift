import Foundation

// AgentSessionHandoffTracker:P4 跨引擎/项目交接。
//
// ACP session 存在各 agent 自己的存储里,跨引擎/跨项目(会话桶 engineKind|cwd 变化)后
// 新 session 上下文为零 —— 协议层无解(硬边界)。本 tracker 在**首次进入某桶**的 agent run
// 产出一次性「背景交接」(此前会话摘要,注入首条 prompt);再进同桶不交接 —— 该桶 engine
// 自己的 ACP session 已持上下文(P5:@mention 多引擎交错切换不重复注入,省 token)。
// actor:replyStream 的并发上下文里串行化「读桶 + 更新」,防并发首个 run 重复交接。

/// 跟踪 agent 会话桶的一次性交接背景供给(每桶每 app 会话最多交接一次)。
public actor AgentSessionHandoffTracker {
    /// 本 app 会话内已进入过的桶(engineKind|cwd)。
    private var seenBuckets: Set<String> = []

    public init() {}

    /// 每个 agent run 前调。桶**首次出现**且此前已有别的桶(= 存在可交接的时间线)→
    /// 调 transcript 拿摘要返回;首个桶(首轮)/已见过的桶 → 仅记录返回 nil。
    /// transcript 惰性(仅判定交接时调用);transcript 返回 nil(空时间线)桶也标记已见,
    /// 不逐条消息重试。
    public func contextIfFirstSeen(
        bucket: String,
        transcript: @Sendable () async -> String?
    ) async -> String? {
        let hadPriorBucket = !seenBuckets.isEmpty
        guard !seenBuckets.contains(bucket) else { return nil }
        seenBuckets.insert(bucket)
        guard hadPriorBucket else { return nil }
        return await transcript()
    }
}
