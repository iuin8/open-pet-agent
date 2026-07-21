import Foundation

// ACPSessionStore:ACP 会话指针持久化(P2 跨重启恢复)。
//
// 只存「当前会话指针」—— (engineKind | cwd) → sessionId,不存 transcript(权威在各 agent
// 自己的存储:opencode server 落盘 / claude ~/.claude)。重启后 App 按指针走 `session/load`
// 回放重建 UI;指针失效(agent 侧已清)由调用方 catch 后 remove 回退新会话。
//
// 范式对齐 ConversationStore:actor 隔离、原子写(tmp + rename)、损坏 → .bak 恢复不崩。

/// (engineKind, cwd) → 当前 ACP sessionId 的持久映射。
public actor ACPSessionStore {

    /// 一条指针记录。updatedAt 供审计/未来清理策略用。
    public struct Record: Codable, Sendable, Equatable {
        public var sessionId: String
        public var updatedAt: Date

        public init(sessionId: String, updatedAt: Date = Date()) {
            self.sessionId = sessionId
            self.updatedAt = updatedAt
        }
    }

    private var records: [String: Record] = [:]
    private let storeURL: URL

    /// 测试注入 hermetic 路径。
    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    /// 默认 `~/Library/Application Support/OpenPetAgent/acp-sessions.json`。
    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(storeURL: appSupport
            .appendingPathComponent("OpenPetAgent", isDirectory: true)
            .appendingPathComponent("acp-sessions.json"))
    }

    /// 指针 key:engine 种类 + 会话工作目录(同 opencode 不同项目 → 各自指针)。
    public static func key(engineKind: String, cwd: String) -> String {
        "\(engineKind)|\(cwd)"
    }

    /// 读盘。文件不存在 → 空;损坏 → .bak 恢复(不抛,对齐 ConversationStore.load)。
    public func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            records = try JSONDecoder().decode([String: Record].self, from: data)
        } catch {
            print("[ACPSessionStore] decode failed, recovering: \(error)")
            let bakURL = storeURL.deletingPathExtension().appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.moveItem(at: storeURL, to: bakURL)
            records = [:]
        }
    }

    public func sessionId(forKey key: String) -> String? {
        records[key]?.sessionId
    }

    /// 写指针并立即落盘(失败只打日志,不打断会话流程)。
    public func set(sessionId: String, forKey key: String) {
        records[key] = Record(sessionId: sessionId)
        persist()
    }

    /// 清指针(指针失效回退 / 用户清空)。
    public func remove(forKey key: String) {
        guard records.removeValue(forKey: key) != nil else { return }
        persist()
    }

    /// 原子写:encode → tmp → rename。
    private func persist() {
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            let tmpURL = dir.appendingPathComponent(storeURL.lastPathComponent + ".tmp")
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: storeURL)
            }
        } catch {
            print("[ACPSessionStore] persist failed: \(error)")
        }
    }
}
