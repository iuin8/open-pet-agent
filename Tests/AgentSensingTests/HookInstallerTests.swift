import Testing
import Foundation
@testable import AgentSensing

@Suite("HookInstaller — 追加/移除自己的 hook,不碰别的 hook 工具")
struct HookInstallerTests {

    /// 别的 hook 工具那条同步命令 hook(我们绝不能动它)。
    let otherToolEntry: [String: Any] = [
        "matcher": "",
        "hooks": [["type": "command", "command": "/Users/me/.other-hook-tool/hooks/hook-sender"]],
    ]

    func permissionEntries(_ s: [String: Any]) -> [[String: Any]] {
        ((s["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
    }
    func isOtherTool(_ e: [String: Any]) -> Bool {
        ((e["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains("other-hook-tool") == true
    }

    // MARK: - 纯变换

    @Test("空 settings upsert → 只有我们一条")
    func upsertEmpty() {
        let out = HookInstaller.upsert([:], port: 45831)
        let entries = permissionEntries(out)
        #expect(entries.count == 1)
        #expect(HookInstaller.isOurEntry(entries[0]))
    }

    @Test("有别的 hook 工具时 upsert → 它 + 我们,两条都在")
    func upsertKeepsOtherTool() {
        let settings: [String: Any] = ["hooks": ["PermissionRequest": [otherToolEntry]]]
        let entries = permissionEntries(HookInstaller.upsert(settings, port: 45831))
        #expect(entries.count == 2)
        #expect(entries.contains(where: isOtherTool))
        #expect(entries.contains(where: HookInstaller.isOurEntry))
    }

    @Test("已装(旧端口)再 upsert → 不重复,刷新成新端口")
    func upsertRefreshesPort() {
        let s1 = HookInstaller.upsert(["hooks": ["PermissionRequest": [otherToolEntry]]], port: 45831)
        let s2 = HookInstaller.upsert(s1, port: 45840)
        let entries = permissionEntries(s2)
        let ours = entries.filter(HookInstaller.isOurEntry)
        #expect(ours.count == 1)                                   // 不重复
        let url = ((ours[0]["hooks"] as? [[String: Any]])?.first?["url"] as? String) ?? ""
        #expect(url.contains("45840"))                              // 新端口
        #expect(entries.contains(where: isOtherTool))               // 别的 hook 工具仍在
    }

    @Test("移除我们的条目 → 别的 hook 工具保留")
    func removeKeepsOtherTool() {
        let s1 = HookInstaller.upsert(["hooks": ["PermissionRequest": [otherToolEntry]]], port: 45831)
        let entries = permissionEntries(HookInstaller.removingOurEntry(s1))
        #expect(entries.count == 1)
        #expect(isOtherTool(entries[0]))
        #expect(!entries.contains(where: HookInstaller.isOurEntry))
    }

    @Test("只有我们一条时移除 → PermissionRequest key 消失")
    func removeOnlyOurs() {
        let s1 = HookInstaller.upsert([:], port: 45831)
        let out = HookInstaller.removingOurEntry(s1)
        #expect(permissionEntries(out).isEmpty)
        // hooks 里没别的 → 整个 hooks key 也应被清掉
        #expect((out["hooks"] as? [String: Any]) == nil)
    }

    @Test("upsert 不碰其它事件的 hook(如 PostToolUse)")
    func upsertLeavesOtherEvents() {
        let settings: [String: Any] = ["hooks": ["PostToolUse": [otherToolEntry], "PermissionRequest": [otherToolEntry]]]
        let out = HookInstaller.upsert(settings, port: 45831)
        let post = (out["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        #expect(post?.count == 1)   // PostToolUse 原样
    }

    // MARK: - 文件往返

    func tempSettings(_ initial: [String: Any]?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hookinstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let initial {
            let data = try JSONSerialization.data(withJSONObject: initial)
            try data.write(to: url)
        }
        return url
    }

    @Test("install → 文件里有我们 + 别的 hook 工具;isInstalled true;uninstall → 只剩别的 hook 工具")
    func fileRoundTrip() throws {
        let url = try tempSettings(["hooks": ["PermissionRequest": [otherToolEntry]]])
        let installer = HookInstaller(settingsURL: url)

        try installer.install(port: 45833)
        #expect(installer.isInstalled())
        var onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        #expect(permissionEntries(onDisk).count == 2)
        #expect(permissionEntries(onDisk).contains(where: isOtherTool))

        try installer.uninstall()
        #expect(!installer.isInstalled())
        onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let after = permissionEntries(onDisk)
        #expect(after.count == 1)
        #expect(isOtherTool(after[0]))
    }

    @Test("settings.json 不存在 → install 创建,只有我们一条")
    func installCreatesFile() throws {
        let url = try tempSettings(nil)   // 不预创建文件
        let installer = HookInstaller(settingsURL: url)
        try installer.install(port: 45831)
        #expect(installer.isInstalled())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
