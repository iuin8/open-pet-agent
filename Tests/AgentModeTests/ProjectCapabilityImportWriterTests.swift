import XCTest
@testable import AgentMode

final class ProjectCapabilityImportWriterTests: XCTestCase {
    private var root: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectCapabilityImportWriterTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        project = AgentProject(
            id: "p",
            name: "P",
            rootURL: root.appendingPathComponent("repo", isDirectory: true),
            isExternal: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testImportCreatesCanonicalPluginWithoutMaterializing() throws {
        let source = root.appendingPathComponent("source")
        let candidates = [
            ProjectCapabilityImportCandidate(
                id: "skill:review:claudeSkill",
                kind: .skill,
                name: "review",
                sources: [.init(kind: .claudeSkill, url: source)],
                skillBody: "# review\n\nImported.\n",
                skillFiles: [
                    .init(
                        relativePath: "SKILL.md",
                        contents: Data("# review\n\nImported.\n".utf8)
                    ),
                    .init(
                        relativePath: "references/guide.md",
                        contents: Data("Supporting guide.".utf8)
                    )
                ]
            ),
            ProjectCapabilityImportCandidate(
                id: "mcp:filesystem:claude",
                kind: .mcp,
                name: "filesystem",
                sources: [.init(kind: .claudeMCP, url: source)],
                mcpValue: .object([
                    "command": .string("npx"),
                    "args": .array([.string("-y"), .string("server-filesystem")]),
                    "vendorField": .bool(true)
                ])
            )
        ]

        try ProjectCapabilityWriter().importCandidates(
            candidates,
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        )

        let pluginRoot = ProjectConfig.pluginDirectory(
            for: project,
            pluginID: "imported-local"
        )
        XCTAssertEqual(
            try String(
                contentsOf: pluginRoot.appendingPathComponent("skills/review/SKILL.md"),
                encoding: .utf8
            ),
            "# review\n\nImported.\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: pluginRoot.appendingPathComponent(
                    "skills/review/references/guide.md"
                ),
                encoding: .utf8
            ),
            "Supporting guide."
        )
        let manifest = try json(pluginRoot.appendingPathComponent("plugin.json"))
        XCTAssertEqual(manifest["id"] as? String, "imported-local")
        XCTAssertEqual(manifest["skills"] as? [String], ["skills/review"])
        XCTAssertEqual(manifest["mcp"] as? [String], ["mcp/servers.json#filesystem"])
        let servers = try XCTUnwrap(
            try json(pluginRoot.appendingPathComponent("mcp/servers.json"))["mcpServers"]
                as? [String: Any]
        )
        let filesystem = try XCTUnwrap(servers["filesystem"] as? [String: Any])
        XCTAssertEqual(filesystem["vendorField"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".mcp.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".codex/config.toml").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".agents").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".claude").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectConfig.pluginRoot(for: project)
                .appendingPathComponent(".materialized").path
        ))
    }

    func testImportFailsClosedWhenCanonicalPluginExists() throws {
        let pluginRoot = ProjectConfig.pluginDirectory(
            for: project,
            pluginID: "imported-local"
        )
        try FileManager.default.createDirectory(
            at: pluginRoot,
            withIntermediateDirectories: true
        )
        let existing = pluginRoot.appendingPathComponent("owned.txt")
        try Data("keep".utf8).write(to: existing, options: .atomic)
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(kind: .claudeSkill, url: root)],
            skillBody: "# review\n"
        )

        XCTAssertThrowsError(try ProjectCapabilityWriter().importCandidates(
            [candidate],
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        ))

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginRoot.appendingPathComponent("plugin.json").path
        ))
    }

    func testImportPreservesSourceTargets() throws {
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(kind: .claudeSkill, url: root)],
            skillBody: "# review\n",
            skillFiles: [.init(
                relativePath: "SKILL.md",
                contents: Data("# review\n".utf8)
            )]
        )

        let plugin = try ProjectCapabilityWriter().importCandidates(
            [candidate],
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        )

        let manifest = try json(
            ProjectConfig.pluginDirectory(
                for: project,
                pluginID: "imported-local"
            ).appendingPathComponent("plugin.json")
        )
        let engines = try XCTUnwrap(manifest["engines"] as? [String: Any])
        XCTAssertNotNil(engines["claude-code"])
        XCTAssertNil(engines["codex"])
        XCTAssertEqual(plugin.skills.first?.targets, [.claudeCode])
    }

    func testImportMixedSourcesUsePluginLevelTargetUnion() throws {
        let candidates = [
            ProjectCapabilityImportCandidate(
                id: "skill:review:claudeSkill",
                kind: .skill,
                name: "review",
                sources: [.init(kind: .claudeSkill, url: root)],
                skillBody: "# review\n",
                skillFiles: [.init(
                    relativePath: "SKILL.md",
                    contents: Data("# review\n".utf8)
                )]
            ),
            ProjectCapabilityImportCandidate(
                id: "skill:deploy:agentsSkill",
                kind: .skill,
                name: "deploy",
                sources: [.init(kind: .agentsSkill, url: root)],
                skillBody: "# deploy\n",
                skillFiles: [.init(
                    relativePath: "SKILL.md",
                    contents: Data("# deploy\n".utf8)
                )]
            )
        ]

        let plugin = try ProjectCapabilityWriter().importCandidates(
            candidates,
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        )

        XCTAssertTrue(plugin.skills.allSatisfy {
            $0.targets == [.claudeCode, .codex]
        })
    }

    func testImportRejectsHiddenPluginID() throws {
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(kind: .claudeSkill, url: root)],
            skillBody: "# review\n",
            skillFiles: [.init(
                relativePath: "SKILL.md",
                contents: Data("# review\n".utf8)
            )]
        )

        XCTAssertThrowsError(try ProjectCapabilityWriter().importCandidates(
            [candidate],
            project: project,
            pluginID: ".materialized",
            pluginName: "Hidden"
        ))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectConfig.pluginRoot(for: project)
                .appendingPathComponent(".materialized").path
        ))
    }

    func testImportRejectsSymlinkedCanonicalPluginRoot() throws {
        let outside = root.appendingPathComponent("outside-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let openPetAgent = project.rootURL
            .appendingPathComponent(".open-pet-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: openPetAgent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: openPetAgent.appendingPathComponent("plugins", isDirectory: true),
            withDestinationURL: outside
        )
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(kind: .claudeSkill, url: root)],
            skillBody: "# review\n",
            skillFiles: [.init(
                relativePath: "SKILL.md",
                contents: Data("# review\n".utf8)
            )]
        )

        XCTAssertThrowsError(try ProjectCapabilityWriter().importCandidates(
            [candidate],
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        ))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("imported-local").path
        ))
    }

    func testImportRejectsConflictingCandidateWithoutWriting() throws {
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(kind: .claudeSkill, url: root)],
            skillBody: "# review\n",
            diagnostics: [.error("Conflicting import: review", path: nil)]
        )

        XCTAssertThrowsError(try ProjectCapabilityWriter().importCandidates(
            [candidate],
            project: project,
            pluginID: "imported-local",
            pluginName: "Imported Local"
        ))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectConfig.pluginDirectory(
                for: project,
                pluginID: "imported-local"
            ).path
        ))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
