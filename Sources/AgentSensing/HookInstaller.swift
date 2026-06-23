import Foundation
import os

/// 把 OpenPetAgent **自己的** `type: "http"` PermissionRequest hook 追加进 `~/.claude/settings.json`,
/// 并能干净移除 —— **绝不动任何别人的 hook 条目**(用户决策:新增不覆盖、只管自己、可开关)。
///
/// 用官方 `type:"http"` 直接 POST 到本地 server,不落 shell 脚本文件。
///
/// 纯变换(`upsert`/`removingOurEntry`/`isOurEntry`)无 I/O → 好无头单测;文件读写是薄壳。
public struct HookInstaller {

    public static let hookPath = "/hooks/permission-request"
    public static let host = "127.0.0.1"
    /// hook 超时(秒)。Claude Code 等本 hook 应答最多这么久,超时即关连接(用户晚于此的点击写进死连接 → 无效)。
    /// 从 120s **拉长到 600s(10 min)**:桌宠权限卡让你从容答,别被 2 分钟逼着。配 App 层 liveness 轮询:
    /// 连接真死了(超时/Claude 退出)自动从队列移除死卡(不杵着可点但无效),不靠用户去点一张死卡。
    public static let timeoutSeconds = 600
    private static let log = Logger(subsystem: "io.openpetagent", category: "AgentSensing.installer")
    private static let event = "PermissionRequest"

    /// 我们的 hook url(端口由 server 实际监听端口决定)。
    public static func url(port: UInt16) -> String { "http://\(host):\(port)\(hookPath)" }

    let settingsURL: URL

    public init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")) {
        self.settingsURL = settingsURL
    }

    // MARK: - 文件壳

    /// 追加/更新我们的 hook(若已存在则刷新端口)。其它条目原样保留。
    public func install(port: UInt16) throws {
        let settings = readSettings()
        let updated = Self.upsert(settings, port: port)
        try writeSettings(updated)
        Self.log.notice("已装 PermissionRequest http hook @\(port, privacy: .public)")
    }

    /// 只移除我们自己的条目。其它条目保留。
    public func uninstall() throws {
        let settings = readSettings()
        let updated = Self.removingOurEntry(settings)
        try writeSettings(updated)
        Self.log.notice("已卸 OpenPetAgent PermissionRequest http hook")
    }

    public func isInstalled() -> Bool {
        Self.permissionEntries(readSettings()).contains(where: Self.isOurEntry)
    }

    /// 已装条目里的端口(没装 → nil)。调用方据此判断「端口没变就别重写 settings.json」,
    /// 避免每次启动都 churn 用户配置(JSONSerialization 重排全文件)。
    public func installedPort() -> UInt16? {
        for entry in Self.permissionEntries(readSettings()) where Self.isOurEntry(entry) {
            guard let inner = entry["hooks"] as? [[String: Any]],
                  let url = inner.first(where: { ($0["type"] as? String) == "http" })?["url"] as? String,
                  let comps = URLComponents(string: url), let p = comps.port
            else { continue }
            return UInt16(exactly: p)
        }
        return nil
    }

    private func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        // 注:JSONSerialization 会重排键(无法保留原顺序/格式)——可读但会改写全文件,
        // 这是这种做法的固有代价。.atomic 防写坏。
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - 纯变换(可测)

    /// 我们的 hook 条目。
    static func ourEntry(port: UInt16) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "http", "url": url(port: port), "timeout": timeoutSeconds]]]
    }

    /// 判断一个 `hooks.PermissionRequest[]` 条目是不是我们的(内含 type:http + url 命中我们的 path)。
    static func isOurEntry(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { hook in
            (hook["type"] as? String) == "http"
                && (hook["url"] as? String)?.contains(hookPath) == true
        }
    }

    /// 追加/刷新我们的条目:先剔掉旧的我们条目(防重复/换端口),再 append 一个新的。其它条目不动。
    static func upsert(_ settings: [String: Any], port: UInt16) -> [String: Any] {
        var out = settings
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var entries = permissionEntries(settings).filter { !isOurEntry($0) }   // 留别人的
        entries.append(ourEntry(port: port))
        hooks[event] = entries
        out["hooks"] = hooks
        return out
    }

    /// 移除我们的条目;若 PermissionRequest 因此空了则删 key;若 hooks 空了则删 hooks。
    static func removingOurEntry(_ settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        let remaining = permissionEntries(settings).filter { !isOurEntry($0) }
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return out
    }

    private static func permissionEntries(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }
}
