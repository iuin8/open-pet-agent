import Foundation

/// 访达选目录 → 该目录历史会话引用(spec §2)。智能识别:选中在 `~/.claude/projects/` 下 → 直读;
/// 否则当项目 cwd → 编码(`/`→`-`)解析到 projects 子目录。纯函数 + 注入根/FileManager → 无头测。
public enum SessionDirectoryBrowser {

    /// 默认 Claude projects 根。
    public static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// cwd → Claude 编码目录名(`/Users/me/proj` → `-Users-fa-proj`)。仅 encode(decode 有歧义,不做)。
    public static func encode(cwd: String) -> String {
        let dashed = cwd.replacingOccurrences(of: "/", with: "-")
        return dashed.hasPrefix("-") ? dashed : "-" + dashed
    }

    /// 选中目录 → 实际要扫的会话目录。在 projectsRoot 下(含自身)→ 原样;否则当 cwd 编码进 projectsRoot。
    public static func resolveSessionDir(picked: URL, projectsRoot: URL) -> URL {
        let p = picked.standardizedFileURL.path, root = projectsRoot.standardizedFileURL.path
        if p == root || p.hasPrefix(root + "/") { return picked }
        return projectsRoot.appendingPathComponent(encode(cwd: p))
    }

    /// 扫会话目录的 `*.jsonl` → refs(sessionId = 去扩展名文件名)。Codex 同样直读(调用方选 jsonl 目录)。
    public static func scan(directory: URL, agent: AgentKind,
                            fileManager: FileManager = .default) -> [AgentSessionRef] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .map { AgentSessionRef(agent: agent, sessionId: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    /// 选中目录 + agent → refs(Claude 走智能识别;Codex 直读选中目录)。
    public static func sessions(picked: URL, agent: AgentKind,
                                projectsRoot: URL = defaultProjectsRoot()) -> [AgentSessionRef] {
        let dir = agent == .claudeCode ? resolveSessionDir(picked: picked, projectsRoot: projectsRoot) : picked
        return scan(directory: dir, agent: agent)
    }
}
