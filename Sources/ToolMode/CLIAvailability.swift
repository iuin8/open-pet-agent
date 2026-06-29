import Foundation

/// 探测系统 PATH 找 CLI binary 是否安装。
///
/// HermesPet (https://github.com/basionwang-bot/HermesPet) 版
/// 有 5 分钟缓存 + 2 秒 timeout + 并发探测,N2.0 先做最简版:同步 which
/// 探测,不缓存,测试可注入 `searchPaths` fixture。真实缓存 + 异步并发
/// 优化留 N2.x 真接 subprocess 时再考虑。
public actor CLIAvailability {

    public init() {}

    /// 探测某个 CLI binary 是否在系统 PATH 中。
    ///
    /// - Parameters:
    ///   - binary: CLI 名字(如 `"claude"`, `"codex"`, `"opencode"`)
    ///   - searchPaths: 测试用注入。生产代码传 `nil` 走
    ///     `ProcessInfo.environment["PATH"]`。
    /// - Returns: 找到的 binary 绝对路径,找不到 → `nil`。
    public func locate(binary: String, searchPaths: [String]? = nil) -> String? {
        let paths: [String]
        if let searchPaths {
            paths = searchPaths
        } else {
            let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            paths = envPath.components(separatedBy: ":")
        }
        for dir in paths where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
