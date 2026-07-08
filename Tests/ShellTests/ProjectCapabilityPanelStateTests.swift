import Testing
@testable import Shell

@Suite("ProjectCapabilityPanelState")
struct ProjectCapabilityPanelStateTests {
    @Test("Row：有 source 时默认复制 source → destination 对")
    func rowCopiesSourceDestinationPair() {
        let row = ProjectCapabilityPanelState.Row(
            kind: "复制生成目录",
            target: "/tmp/repo/.agents/skills/dev-toolkit-lint",
            source: "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint",
            pluginID: "dev-toolkit"
        )

        #expect(row.copyText == "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint → /tmp/repo/.agents/skills/dev-toolkit-lint")
        #expect(row.source == "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint")
        #expect(row.pluginID == "dev-toolkit")
    }
}
