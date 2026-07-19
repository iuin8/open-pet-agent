import XCTest
@testable import AgentMode

final class ProjectCapabilityImportScannerTests: XCTestCase {
    private var root: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectCapabilityImportScannerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        project = AgentProject(
            id: "p",
            name: "P",
            rootURL: root,
            isExternal: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testScanDiscoversFourSupportedSourcesWithoutWriting() throws {
        try writeSkill(
            root: ".claude/skills",
            name: "review",
            body: "# review\n\nClaude body.\n"
        )
        try writeSkill(
            root: ".agents/skills",
            name: "deploy",
            body: "# deploy\n\nCodex body.\n"
        )
        try write(
            """
            {
              "mcpServers": {
                "filesystem": {
                  "command": "npx",
                  "args": ["-y", "server-filesystem"],
                  "vendorField": true
                }
              }
            }
            """,
            to: ".mcp.json"
        )
        try write(
            """
            [mcp_servers.memory]
            command = "uvx"
            args = ["memory-server", "--verbose"]
            """,
            to: ".codex/config.toml"
        )
        let before = try projectFiles()

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertEqual(try projectFiles(), before)
        XCTAssertTrue(scan.diagnostics.isEmpty)
        XCTAssertEqual(
            Set(scan.candidates.map { "\($0.kind.rawValue):\($0.name)" }),
            ["skill:review", "skill:deploy", "mcp:filesystem", "mcp:memory"]
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "review" }?.skillBody,
            "# review\n\nClaude body.\n"
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "filesystem" }?
                .mcpValue?.objectValue?["vendorField"],
            .bool(true)
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "memory" }?
                .mcpValue?.objectValue?["command"]?.stringValue,
            "uvx"
        )
    }

    func testScanMergesIdenticalSkillSources() throws {
        let body = "# review\n\nShared body.\n"
        try writeSkill(root: ".claude/skills", name: "review", body: body)
        try writeSkill(root: ".agents/skills", name: "review", body: body)

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        let candidate = try XCTUnwrap(scan.candidates.first)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertEqual(candidate.sources.map(\.kind), [.claudeSkill, .agentsSkill])
        XCTAssertTrue(candidate.diagnostics.isEmpty)
    }

    func testScanMarksDifferentContentWithSameNameAsConflict() throws {
        try writeSkill(
            root: ".claude/skills",
            name: "review",
            body: "# review\n\nClaude body.\n"
        )
        try writeSkill(
            root: ".agents/skills",
            name: "review",
            body: "# review\n\nCodex body.\n"
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertEqual(scan.candidates.count, 2)
        XCTAssertTrue(scan.candidates.allSatisfy {
            $0.diagnostics.contains { $0.message.contains("Conflicting import") }
        })
    }

    func testScanCapturesCompleteSkillDirectory() throws {
        try writeSkill(
            root: ".claude/skills",
            name: "review",
            body: "# review\n"
        )
        try write(
            "Supporting guide.",
            to: ".claude/skills/review/references/guide.md"
        )
        try write(
            "KEY=example",
            to: ".claude/skills/review/.env.example"
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        let candidate = try XCTUnwrap(scan.candidates.first)
        XCTAssertEqual(
            candidate.skillFiles.map(\.relativePath).sorted(),
            [".env.example", "SKILL.md", "references/guide.md"]
        )
        XCTAssertEqual(
            candidate.skillFiles.first {
                $0.relativePath == "references/guide.md"
            }?.contents,
            Data("Supporting guide.".utf8)
        )
    }

    func testScanRejectsNestedSkillSymlink() throws {
        try writeSkill(
            root: ".claude/skills",
            name: "review",
            body: "# review\n"
        )
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(
                ".claude/skills/review/secret.txt"
            ),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("symbolic link")
        })
    }

    func testScanRejectsSkillsRootSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("skills-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let skill = outside.appendingPathComponent("review", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# secret\n".utf8).write(
            to: skill.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let claudeRoot = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeRoot.appendingPathComponent("skills", isDirectory: true),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("escapes project")
        })
    }

    func testScanRejectsMCPConfigSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("""
        { "mcpServers": { "secret": { "command": "secret-server" } } }
        """.utf8).write(to: outside, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".mcp.json"),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("escapes project")
        })
    }

    func testScanRejectsCodexConfigSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("codex-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("""
        [mcp_servers.secret]
        command = "secret-server"
        """.utf8).write(to: outside, options: .atomic)
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: codexRoot.appendingPathComponent("config.toml"),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("escapes project")
        })
    }

    func testScanParsesQuotedCodexServerNameContainingDot() throws {
        try write(
            """
            [mcp_servers."vendor.memory"]
            command = "uvx"
            args = ["memory-server"]
            """,
            to: ".codex/config.toml"
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertEqual(scan.candidates.map(\.name), ["vendor.memory"])
        XCTAssertTrue(scan.diagnostics.isEmpty)
    }

    func testScanParsesCodexEnvironmentAndHTTPHeaders() throws {
        try write(
            """
            [mcp_servers.local]
            type = "stdio"
            command = "uvx"
            args = ["server"]
            cwd = "/tmp/work"
            env = { TOKEN = "secret", MODE = "safe" }
            startup_timeout_sec = 20

            [mcp_servers.remote]
            type = "http"
            url = "https://example.com/mcp"
            http_headers = { Authorization = "Bearer token" }
            enabled = true
            """,
            to: ".codex/config.toml"
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.diagnostics.isEmpty)
        let local = try XCTUnwrap(
            scan.candidates.first { $0.name == "local" }?.mcpValue?.objectValue
        )
        XCTAssertEqual(local["cwd"], .string("/tmp/work"))
        XCTAssertEqual(
            local["env"],
            .object(["TOKEN": .string("secret"), "MODE": .string("safe")])
        )
        XCTAssertEqual(local["startup_timeout_sec"], .int(20))
        let remote = try XCTUnwrap(
            scan.candidates.first { $0.name == "remote" }?.mcpValue?.objectValue
        )
        XCTAssertEqual(
            remote["headers"],
            .object(["Authorization": .string("Bearer token")])
        )
        XCTAssertEqual(remote["enabled"], .bool(true))
    }

    func testScanSkipsManifestRegisteredGeneratedProjections() throws {
        try writeSkill(
            root: ".claude/skills",
            name: "generated-claude",
            body: "# generated\n"
        )
        try writeSkill(
            root: ".agents/skills",
            name: "generated-codex",
            body: "# generated\n"
        )
        try writeSkill(
            root: ".opencode/skills",
            name: "generated-opencode",
            body: "# generated\n"
        )
        try write(
            """
            { "mcpServers": { "generated": { "command": "noop" } } }
            """,
            to: ".mcp.json"
        )
        try write(
            """
            # Generated by OpenPetAgent Codex projection. Do not edit by hand.

            [mcp_servers.generated]
            command = "noop"
            """,
            to: ".codex/config.toml"
        )
        try write(
            """
            { "mcp": { "generated": { "command": ["noop"] } } }
            """,
            to: "opencode.json"
        )
        var manifest = ProjectionGeneratedManifest()
        manifest.claim(path: ".claude/skills/generated-claude", kind: .directory, engineID: AgentEngineKind.claudeCode.rawValue)
        manifest.claim(path: ".agents/skills/generated-codex", kind: .directory, engineID: AgentEngineKind.codex.rawValue)
        manifest.claim(path: ".opencode/skills/generated-opencode", kind: .directory, engineID: AgentEngineKind.openCode.rawValue)
        manifest.claim(path: ".mcp.json", kind: .file, engineID: AgentEngineKind.claudeCode.rawValue)
        manifest.claim(path: ".codex/config.toml", kind: .file, engineID: AgentEngineKind.codex.rawValue)
        manifest.claim(path: "opencode.json", kind: .file, engineID: AgentEngineKind.openCode.rawValue)
        try ProjectionGeneratedManifestStore.save(manifest, projectRoot: project.rootURL)

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.isEmpty)
    }

    func testScanReportsExistingUnreadableOrInvalidSourceContainer() throws {
        try write("not-a-directory", to: ".claude/skills")
        let invalidUTF8 = Data([0xFF, 0xFE])
        let codexURL = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try invalidUTF8.write(to: codexURL, options: .atomic)

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("Unable to read import source")
                && $0.path?.hasSuffix(".claude/skills") == true
        })
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("Unable to read import source")
                && $0.path?.hasSuffix(".codex/config.toml") == true
        })
    }

    func testScanRejectsSkillSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# secret\n".utf8).write(
            to: outside.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let skillsRoot = root.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skillsRoot.appendingPathComponent("escaped", isDirectory: true),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.diagnostics.count, 1)
        XCTAssertTrue(scan.diagnostics[0].message.contains("escapes project"))
    }

    func testScanDiscoversOpencodeSkillAndMCPWithoutWriting() throws {
        try writeSkill(
            root: ".opencode/skills",
            name: "review",
            body: "# review\n\nOpencode body.\n"
        )
        try write(
            """
            {
              "mcp": {
                "filesystem": {
                  "command": ["npx", "-y", "server-filesystem"],
                  "vendorField": true
                }
              }
            }
            """,
            to: "opencode.json"
        )
        let before = try projectFiles()

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertEqual(try projectFiles(), before)
        XCTAssertTrue(scan.diagnostics.isEmpty)
        XCTAssertEqual(
            Set(scan.candidates.map { "\($0.kind.rawValue):\($0.name)" }),
            ["skill:review", "mcp:filesystem"]
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "review" }?.sources.map(\.kind),
            [.opencodeSkill]
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "filesystem" }?.sources.map(\.kind),
            [.opencodeMCP]
        )
        XCTAssertEqual(
            scan.candidates.first { $0.name == "filesystem" }?
                .mcpValue?.objectValue?["vendorField"],
            .bool(true)
        )
    }

    func testScanMergesIdenticalSkillSourcesAndReportsReuse() throws {
        let body = "# review\n\nShared body.\n"
        try writeSkill(root: ".claude/skills", name: "review", body: body)
        try writeSkill(root: ".opencode/skills", name: "review", body: body)

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        let candidate = try XCTUnwrap(scan.candidates.first)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertEqual(candidate.sources.map(\.kind), [.claudeSkill, .opencodeSkill])
        XCTAssertTrue(candidate.diagnostics.isEmpty)
    }

    func testScanRejectsOpencodeSkillSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("opencode-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# secret\n".utf8).write(
            to: outside.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let skillsRoot = root.appendingPathComponent(".opencode/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skillsRoot.appendingPathComponent("escaped", isDirectory: true),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.diagnostics.count, 1)
        XCTAssertTrue(scan.diagnostics[0].message.contains("escapes project"))
    }

    func testScanRejectsOpencodeConfigSymlinkOutsideProject() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("opencode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("""
        { "mcp": { "secret": { "command": ["secret-server"] } } }
        """.utf8).write(to: outside, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("opencode.json"),
            withDestinationURL: outside
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("escapes project")
        })
    }

    func testScanReportsMalformedOpencodeMCPSection() throws {
        try write(
            """
            { "mcp": [] }
            """,
            to: "opencode.json"
        )

        let scan = ProjectCapabilityImportScanner().scan(project: project)

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.diagnostics.contains {
            $0.message.contains("Malformed MCP import file: opencode.json")
                && $0.path?.hasSuffix("opencode.json") == true
        })
    }

    private func writeSkill(
        root relativeRoot: String,
        name: String,
        body: String
    ) throws {
        let directory = root
            .appendingPathComponent(relativeRoot, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(body.utf8).write(
            to: directory.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func projectFiles() throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }
}
