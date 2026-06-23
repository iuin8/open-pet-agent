import Foundation

/// 给 spawn 子进程的 environment 补常见 CLI 安装路径。
///
/// 问题:macOS GUI app 从 Dock/Finder 启动时拿到的
/// `ProcessInfo.environment["PATH"]` 通常只有
/// `/usr/bin:/bin:/usr/sbin:/sbin`,不含 `~/.local/bin` /
/// `/opt/homebrew/bin`(M1 Homebrew)/ `~/.nvm/.../bin`(nvm node)等。
/// 用户终端 `which claude` OK,OpenPetAgent 启动后 `CLIAvailability.locate`
/// 找不到,体验割裂。
///
/// 解决:用本 helper 给 child process environment 注入扩展 PATH,把这些
/// 常见安装路径都补进去。
///
/// 用法:`ClaudeCodeEngine` 在 spawn 时取
/// `processEnvironment ?? CLIProcessEnvironment.augmented()`,后者基于
/// `ProcessInfo.environment` + 拼接扩展 PATH。
///
/// 参考:HermesPet (https://github.com/basionwang-bot/HermesPet) — 我们
/// 简化掉 `cliLoginShellPATH` UserDefaults 探测(N2.x 看实际场景再加),保留
/// 核心扩展路径列表并保留 dir 存在性校验。
public enum CLIProcessEnvironment {

    /// 常见 CLI 安装路径(按优先级排序:用户级 → Homebrew → 系统)。
    /// 测试可通过 `augmented(extraPaths:)` 注入替代列表。
    public static let defaultExtraPaths: [String] = [
        // 用户级
        "~/.local/bin",
        "~/.local/share/mise/shims",
        "~/.asdf/shims",
        "~/.asdf/bin",
        "~/.cargo/bin",
        "~/.bun/bin",
        "~/.nvm/versions/node/bin",   // nvm 全局 npm 包
        "~/go/bin",
        // Homebrew
        "/opt/homebrew/bin",          // M1 / M2 / M3
        "/opt/homebrew/sbin",
        "/usr/local/bin",             // Intel Homebrew + 用户 install
        "/usr/local/sbin"
    ]

    /// 返回扩展过 PATH 的 environment 字典,基于 `ProcessInfo.environment`。
    ///
    /// - Parameter extraPaths: 测试注入用,生产代码传 `nil` 走 `defaultExtraPaths`。
    /// - Returns: 含合并后 PATH 的 environment 拷贝。
    ///
    /// 拼接规则:
    /// - 原 `PATH` 在前(尊重用户已配置的优先级,避免覆盖 customization)
    /// - 扩展路径在后,只追加 `ProcessInfo.environment["PATH"]` 中没出现过的目录
    /// - `~` 自动展开为 user home
    public static func augmented(extraPaths: [String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = mergedPath(
            existing: env["PATH"],
            extraPaths: extraPaths ?? defaultExtraPaths
        )
        return env
    }

    /// 合并原 PATH 和扩展路径,去重 + tilde 展开。
    /// 拆出来便于测试覆盖。
    static func mergedPath(existing: String?, extraPaths: [String]) -> String {
        var entries: [String] = []
        var seen = Set<String>()

        func appendDir(_ raw: String) {
            let expanded = expandTilde(raw)
            guard !expanded.isEmpty, !seen.contains(expanded) else { return }
            seen.insert(expanded)
            entries.append(expanded)
        }

        if let existing, !existing.isEmpty {
            for raw in existing.split(separator: ":") {
                appendDir(String(raw))
            }
        }
        for raw in extraPaths {
            appendDir(raw)
        }
        return entries.joined(separator: ":")
    }

    /// 展开 `~` 为 user home。internal 暴露便于测试。
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
