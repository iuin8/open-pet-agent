import Foundation
import Testing
@testable import AgentMode
@testable import Shell

@MainActor
@Suite("ProjectCapabilityImportState")
struct ProjectCapabilityImportStateTests {
    @Test("初始化：扫描候选但确认前零写入")
    func initializationDoesNotImport() {
        var importCalls = 0
        let state = ProjectCapabilityImportState(
            scan: scan(),
            onImport: { _, _, _ in
                importCalls += 1
                return .snapshot(ProjectCapabilitySnapshot(
                    catalog: ProjectCapabilityCatalogModel(
                        projectID: "p",
                        plugins: []
                    ),
                    card: card(itemNames: [])
                ))
            }
        )

        #expect(state.candidates.count == 2)
        #expect(state.selectedIDs.isEmpty)
        #expect(importCalls == 0)
    }

    @Test("确认导入：只提交勾选候选并刷新 root")
    func importSelectedAppliesSnapshot() {
        let original = card(itemNames: [])
        let refreshed = card(itemNames: ["review"])
        var received: [String] = []
        var applied: ProjectCapabilityImportOutcome?
        let state = ProjectCapabilityImportState(
            scan: scan(),
            onImport: { candidates, pluginID, pluginName in
                received = candidates.map(\.name)
                #expect(pluginID == "imported-local")
                #expect(pluginName == "Imported Local")
                return .snapshot(ProjectCapabilitySnapshot(
                    catalog: ProjectCapabilityCatalogModel(
                        projectID: "p",
                        plugins: []
                    ),
                    card: refreshed
                ))
            },
            onApply: { applied = $0 }
        )
        state.pluginID = "imported-local"
        state.pluginName = "Imported Local"
        state.toggleSelection("skill:review:claudeSkill")

        state.importSelected()

        #expect(received == ["review"])
        guard case .snapshot(let snapshot) = applied else {
            Issue.record("未应用完整 snapshot")
            return
        }
        #expect(snapshot.card.items.map(\.name) == ["review"])
        #expect(state.selectedIDs.isEmpty)
        #expect(state.didImport)
        #expect(state.errorMessage == nil)
        #expect(original.items.isEmpty)
    }

    @Test("导入失败：保留选择、输入与错误")
    func importFailurePreservesDraft() {
        struct ImportError: Error {}
        let state = ProjectCapabilityImportState(
            scan: scan(),
            onImport: { _, _, _ in throw ImportError() }
        )
        state.pluginID = "custom-import"
        state.pluginName = "Custom Import"
        state.toggleSelection("skill:review:claudeSkill")
        let selected = state.selectedIDs

        state.importSelected()

        #expect(state.selectedIDs == selected)
        #expect(state.pluginID == "custom-import")
        #expect(state.pluginName == "Custom Import")
        #expect(state.errorMessage != nil)
        #expect(state.didImport == false)
    }

    @Test("验证失败：显示可操作的原始错误信息")
    func validationFailureShowsActionableMessage() {
        let state = ProjectCapabilityImportState(
            scan: scan(),
            onImport: { _, _, _ in
                throw ProjectCapabilityValidationError(
                    "Canonical plugin already exists: imported-local"
                )
            }
        )
        state.toggleSelection("skill:review:claudeSkill")

        state.importSelected()

        #expect(
            state.errorMessage
                == "Canonical plugin already exists: imported-local"
        )
    }

    @Test("冲突候选：默认不选且不能手动选")
    func conflictingCandidateCannotBeSelected() {
        let conflict = ProjectCapabilityImportCandidate(
            id: "skill:review:agentsSkill",
            kind: .skill,
            name: "review",
            sources: [.init(
                kind: .agentsSkill,
                url: URL(fileURLWithPath: "/tmp/review/SKILL.md")
            )],
            skillBody: "# different",
            diagnostics: [.error("Conflicting import: review", path: nil)]
        )
        let state = ProjectCapabilityImportState(
            scan: ProjectCapabilityImportScan(candidates: [conflict]),
            onImport: { _, _, _ in
                .snapshot(ProjectCapabilitySnapshot(
                    catalog: ProjectCapabilityCatalogModel(
                        projectID: "p",
                        plugins: []
                    ),
                    card: card(itemNames: [])
                ))
            }
        )

        state.toggleSelection(conflict.id)

        #expect(state.selectedIDs.isEmpty)
        #expect(state.canImport == false)
    }

    @Test("分组：按来源类型展示 Import Existing 候选")
    func candidateGroupsFollowSourceOrder() {
        let state = ProjectCapabilityImportState(
            scan: ProjectCapabilityImportScan(candidates: [
                ProjectCapabilityImportCandidate(
                    id: "mcp:filesystem:opencode",
                    kind: .mcp,
                    name: "filesystem",
                    sources: [.init(
                        kind: .opencodeMCP,
                        url: URL(fileURLWithPath: "/tmp/opencode.json")
                    )],
                    mcpValue: .object(["command": .array([.string("npx")])])
                ),
                ProjectCapabilityImportCandidate(
                    id: "skill:review:opencodeSkill",
                    kind: .skill,
                    name: "review",
                    sources: [.init(
                        kind: .opencodeSkill,
                        url: URL(fileURLWithPath: "/tmp/.opencode/skills/review/SKILL.md")
                    )],
                    skillBody: "# review"
                ),
                ProjectCapabilityImportCandidate(
                    id: "skill:deploy:claudeSkill",
                    kind: .skill,
                    name: "deploy",
                    sources: [.init(
                        kind: .claudeSkill,
                        url: URL(fileURLWithPath: "/tmp/.claude/skills/deploy/SKILL.md")
                    )],
                    skillBody: "# deploy"
                )
            ]),
            onImport: { _, _, _ in
                .snapshot(ProjectCapabilitySnapshot(
                    catalog: ProjectCapabilityCatalogModel(projectID: "p", plugins: []),
                    card: card(itemNames: [])
                ))
            }
        )

        #expect(state.candidateGroups.map(\.title) == [
            "Claude Code skills",
            "opencode skills",
            "opencode MCP"
        ])
        #expect(state.candidateGroups.map { $0.candidates.map(\.name) } == [
            ["deploy"],
            ["review"],
            ["filesystem"]
        ])
    }

    private func scan() -> ProjectCapabilityImportScan {
        ProjectCapabilityImportScan(candidates: [
            ProjectCapabilityImportCandidate(
                id: "skill:review:claudeSkill",
                kind: .skill,
                name: "review",
                sources: [.init(
                    kind: .claudeSkill,
                    url: URL(fileURLWithPath: "/tmp/review/SKILL.md")
                )],
                skillBody: "# review"
            ),
            ProjectCapabilityImportCandidate(
                id: "mcp:filesystem:claude",
                kind: .mcp,
                name: "filesystem",
                sources: [.init(
                    kind: .claudeMCP,
                    url: URL(fileURLWithPath: "/tmp/.mcp.json")
                )],
                mcpValue: .object(["command": .string("npx")])
            )
        ])
    }

    private func card(itemNames: [String]) -> ProjectCapabilityCardState {
        ProjectCapabilityCardState(
            selectedTab: .skills,
            items: itemNames.map { name in
                ProjectCapabilityCardState.Item(
                    id: "skill:imported:\(name)",
                    kind: .skill,
                    name: name,
                    pluginID: "imported-local",
                    sourcePath: "/tmp/\(name)",
                    targetPaths: [],
                    status: .enabled,
                    diagnostics: []
                )
            }
        )
    }
}
