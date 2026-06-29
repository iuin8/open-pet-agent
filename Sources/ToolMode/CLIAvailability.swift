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

    /// engine kind → CLI binary name 映射。
    /// N2.1+ 接入真 subprocess 时,locate 这个 binary 来决定 engine 是否可用。
    ///
    /// 不再写死 `switch`:委托 `ToolEngineRegistry`(单一事实源,id 取代 enum
    /// 分支);未注册的 kind 兜底用 rawValue 当 binary 名。
    public static func binaryName(for kind: ToolEngineKind) -> String {
        ToolEngineRegistry.lookup(id: kind.rawValue)?.binaryName ?? kind.rawValue
    }
}
