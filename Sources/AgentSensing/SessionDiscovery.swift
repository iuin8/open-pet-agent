import Foundation

/// 定位「活跃」的 agent 会话 jsonl 文件 —— Claude Code 与 Codex 各自的目录约定 + 按 mtime
/// 判活跃。纯路径/属性逻辑,`root`/`now` 可注入 → 无头单测不碰真实 home。
public enum SessionDiscovery {

    /// Claude Code transcript 根:`~/.claude/projects/<编码cwd>/<session>.jsonl`(递归)。
    public static var claudeProjectsRoot: URL {
        homeDir.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Codex 会话根:`$CODEX_HOME/sessions` 或 `~/.codex/sessions`,内含 `rollout-<ts>-<uuid>.jsonl`(递归)。
    public static var codexSessionsRoot: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return homeDir.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// 子 agent / 内部子目录名(Claude Code 把子 agent transcript 放 `{session}/subagents/`,
    /// 工作流/工具结果放 `{session}/workflows|tool-results/`)。这些**不是独立会话**,不进 picker(P3.8 D)。
    public static let internalSubdirs: Set<String> = ["subagents", "workflows", "tool-results"]

    /// 递归列出 `root` 下、最近 `within` 秒内有改动的 `.jsonl`,按 mtime 新→旧排序。
    /// 找不到目录返回空。`within` 决定「活跃」窗口(默认 90s:刚有写入 = 正在跑)。
    /// `excludeInternal`:跳过子 agent / 内部子目录文件(默认 true,见 `internalSubdirs`)→
    /// 子 agent 不当独立会话列出(经父会话 Task 行侧卡查看,P3.8 D)。
    public static func recentJSONL(
        under root: URL,
        within: TimeInterval = 90,
        now: Date = Date(),
        excludeInternal: Bool = true
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var hits: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // 内部子目录(subagents/workflows/tool-results)→ 在目录层整棵剪掉,**不下钻**。
            // 这些子树常占 ~97% 文件却全非独立会话;旧实现递归走完整棵树再按 pathComponents 事后丢,
            // = 白走全树(每目录 getattrlistbulk + 每文件 stat,随 ~/.claude 历史线性恶化)。
            // skipDescendants 对 Claude 的 `<proj>/<uuid>/subagents` 任意深度通用,
            // 且不影响 Codex `sessions/<年>/<月>/<日>` 日期嵌套(非内部名 → 照常递归)。
            if excludeInternal, values?.isDirectory == true,
               internalSubdirs.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl",
                  values?.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix("agent-acompact"),
                  let mtime = values?.contentModificationDate,
                  now.timeIntervalSince(mtime) <= within
            else { continue }
            hits.append((url, mtime))
        }
        return hits.sorted { $0.mtime > $1.mtime }.map(\.url)
    }
}
