import XCTest
@testable import AgentMode

final class ProjectCapabilityDiagnosticsTests: XCTestCase {
    func testRenderShowsProjectionTargetsAndDiagnostics() {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let source = root.appendingPathComponent(".open-pet-agent/plugins/dev-toolkit/skills/code-review", isDirectory: true)
        let codexConfig = root.appendingPathComponent(".codex/config.toml", isDirectory: false)
        let codexSkill = root.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true)
        let plans = [
            ProjectionPlan(
                projectID: "p",
                engineID: AgentEngineKind.codex.rawValue,
                pluginID: "codex",
                operations: [
                    .writeFile(contents: "model = \"x\"", destination: codexConfig),
                    .copyDirectory(source: source, destination: codexSkill)
                ],
                diagnostics: [
                    ProjectConfigDiagnostic(severity: .warning, message: "Unknown plugin capability ignored: widgets", path: source.deletingLastPathComponent().path)
                ]
            )
        ]

        let text = ProjectCapabilityDiagnostics.render([
            ProjectCapabilityDiagnosticSection(engineName: "Codex", plans: plans),
            ProjectCapabilityDiagnosticSection(engineName: "Claude Code", plans: [], errorDescription: "重复 Claude Code MCP server 投影: filesystem")
        ])

        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("ownership: OpenPetAgent 生成内容"))
        XCTAssertTrue(text.contains("写入生成文件: /tmp/project/.codex/config.toml"))
        XCTAssertTrue(text.contains("复制生成目录: /tmp/project/.open-pet-agent/plugins/dev-toolkit/skills/code-review → /tmp/project/.agents/skills/dev-toolkit-code-review"))
        XCTAssertTrue(text.contains("warning: Unknown plugin capability ignored: widgets"))
        XCTAssertTrue(text.contains("Claude Code"))
        XCTAssertTrue(text.contains("失败: 重复 Claude Code MCP server 投影: filesystem"))
    }

    func testRenderShowsNoPlannedWritesForEmptySection() {
        let text = ProjectCapabilityDiagnostics.render([
            ProjectCapabilityDiagnosticSection(engineName: "opencode", plans: [])
        ])

        XCTAssertTrue(text.contains("opencode"))
        XCTAssertTrue(text.contains("无计划写入"))
    }
}
