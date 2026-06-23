import Testing
import Context
@testable import Orchestrator

@Suite("DesktopContextFormatter 窗口上下文")
struct DesktopContextFormatterTests {
    private func win(_ owner: String, _ title: String? = nil) -> VisibleWindowSnapshot {
        VisibleWindowSnapshot(ownerName: owner, bounds: .zero, title: title)
    }

    @Test("无可见窗口 → 空数组（调用方不追加段落）")
    func emptyWindowsYieldsNoLines() {
        let snap = DesktopSnapshot(visibleWindows: [])
        #expect(DesktopContextFormatter.windowContextLines(snapshot: snap).isEmpty)
    }

    @Test("有标题窗口 → 标题段 + 逐条「app — 标题」，保前→后顺序")
    func listsWindowsWithTitlesInOrder() {
        let snap = DesktopSnapshot(visibleWindows: [
            win("Code", "FallingSandTuning.swift — pet-agent"),
            win("Google Chrome", "GitHub"),
        ])
        let lines = DesktopContextFormatter.windowContextLines(snapshot: snap)
        #expect(lines.first == "- 桌面窗口（前台在最前）：")
        #expect(lines[1] == "  · Code — FallingSandTuning.swift — pet-agent")
        #expect(lines[2] == "  · Google Chrome — GitHub")
    }

    @Test("窗口无标题 → 只列 app 名，不带破折号")
    func windowWithoutTitleShowsOwnerOnly() {
        let snap = DesktopSnapshot(visibleWindows: [win("微信", nil), win("钉钉", "")])
        let lines = DesktopContextFormatter.windowContextLines(snapshot: snap)
        #expect(lines.contains("  · 微信"))
        #expect(lines.contains("  · 钉钉"))            // 空串标题也只列 app 名
        #expect(!lines.contains(where: { $0.contains("微信 —") }))
    }

    @Test("超长标题截断加省略号")
    func longTitleTruncated() {
        let long = String(repeating: "A", count: 120)
        let snap = DesktopSnapshot(visibleWindows: [win("Code", long)])
        let lines = DesktopContextFormatter.windowContextLines(snapshot: snap, maxTitleLength: 60)
        let bullet = lines[1]
        #expect(bullet.hasSuffix("…"))
        #expect(bullet.count <= "  · Code — ".count + 60)
    }

    @Test("超过 maxWindows → 其余折叠成「另有 K 个窗口」")
    func overflowFoldedIntoCount() {
        let windows = (0..<10).map { win("App\($0)", "t\($0)") }
        let snap = DesktopSnapshot(visibleWindows: windows)
        let lines = DesktopContextFormatter.windowContextLines(snapshot: snap, maxWindows: 6)
        // 1 标题行 + 6 窗口行 + 1 折叠行
        #expect(lines.count == 8)
        #expect(lines.last == "  （另有 4 个窗口）")
    }

    @Test("过滤掉 OpenPetAgent 自身窗口")
    func filtersSelfWindows() {
        let snap = DesktopSnapshot(visibleWindows: [win("OpenPetAgent", "聊天"), win("Code", "x.swift")])
        let lines = DesktopContextFormatter.windowContextLines(snapshot: snap, selfApplicationName: "OpenPetAgent")
        #expect(!lines.contains(where: { $0.contains("OpenPetAgent") }))
        #expect(lines.contains("  · Code — x.swift"))
    }

    @Test("仅 self 窗口 → 过滤后为空 → 空数组")
    func onlySelfWindowsYieldsEmpty() {
        let snap = DesktopSnapshot(visibleWindows: [win("OpenPetAgent", "聊天")])
        #expect(DesktopContextFormatter.windowContextLines(snapshot: snap, selfApplicationName: "OpenPetAgent").isEmpty)
    }
}
