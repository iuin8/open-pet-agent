import XCTest
@testable import AgentMode

final class ProjectCapabilityCommunityCatalogTests: XCTestCase {
    private var source: ProjectCapabilityCommunitySource!

    override func setUpWithError() throws {
        source = try ProjectCapabilityCommunitySource(
            name: "Community",
            url: "https://example.com/catalog.json",
            addedAt: "2026-07-22T00:00:00Z"
        )
    }

    func testParseMCPEntryPreservesHeadersAndUnknownFields() throws {
        let drafts = try ProjectCapabilityCommunityCatalog.parse(Data(#"""
        {
          "schemaVersion": 1,
          "name": "Community",
          "entries": [
            {
              "id": "remote-search",
              "kind": "mcp",
              "name": "Remote Search",
              "description": "Remote MCP",
              "sourceURL": "https://example.com/remote-search",
              "revision": "v1.0.0",
              "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "serverName": "remote-search",
              "serverJSON": {
                "type": "http",
                "url": "https://mcp.example.com/mcp",
                "headers": { "X-Trace": "1" },
                "vendorField": true
              }
            }
          ]
        }
        """#.utf8), source: source)

        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.kind, .mcp)
        XCTAssertEqual(draft.name, "Remote Search")
        XCTAssertEqual(draft.pluginID, "remote-search")
        XCTAssertEqual(draft.sourceMetadata.kind, .marketplace)
        XCTAssertEqual(draft.sourceMetadata.url, "https://example.com/catalog.json#remote-search")
        XCTAssertEqual(draft.sourceMetadata.revision, "v1.0.0")
        XCTAssertEqual(draft.sourceMetadata.contentHash, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertTrue(draft.canInstall)
        let server = try XCTUnwrap(draft.mcpServers.first)
        XCTAssertEqual(server.name, "remote-search")
        XCTAssertEqual(server.value.objectValue?["headers"], .object(["X-Trace": .string("1")]))
        XCTAssertEqual(server.value.objectValue?["vendorField"], .bool(true))
    }

    func testParseSkillEntryRequiresContainedSkillFiles() throws {
        XCTAssertThrowsError(try ProjectCapabilityCommunityCatalog.parse(Data(#"""
        {
          "schemaVersion": 1,
          "name": "Community",
          "entries": [
            {
              "id": "bad-skill",
              "kind": "skill",
              "name": "bad-skill",
              "description": "Bad",
              "sourceURL": "https://example.com/bad-skill.zip",
              "revision": "v1.0.0",
              "contentHash": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "skillFiles": [
                { "path": "../secret", "text": "nope" }
              ]
            }
          ]
        }
        """#.utf8), source: source))

        let drafts = try ProjectCapabilityCommunityCatalog.parse(Data(#"""
        {
          "schemaVersion": 1,
          "name": "Community",
          "entries": [
            {
              "id": "review-skill",
              "kind": "skill",
              "name": "review-skill",
              "description": "Review diffs",
              "sourceURL": "https://example.com/review-skill.zip",
              "revision": "v1.0.0",
              "contentHash": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "skillFiles": [
                { "path": "SKILL.md", "text": "---\nname: review-skill\ndescription: Review diffs\n---\n\nReview staged diffs." },
                { "path": "references/guide.md", "text": "Guide" }
              ]
            }
          ]
        }
        """#.utf8), source: source)

        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.kind, .skill)
        XCTAssertEqual(draft.skillFiles.map(\.relativePath), ["SKILL.md", "references/guide.md"])
        XCTAssertEqual(draft.skillFiles.first?.contents, Data("---\nname: review-skill\ndescription: Review diffs\n---\n\nReview staged diffs.".utf8))
        XCTAssertTrue(draft.canInstall)
    }

    func testRemoteEntryWithoutContentHashIsBrowseOnly() throws {
        let drafts = try ProjectCapabilityCommunityCatalog.parse(Data(#"""
        {
          "schemaVersion": 1,
          "name": "Community",
          "entries": [
            {
              "id": "nohash",
              "kind": "mcp",
              "name": "No Hash",
              "description": "Missing hash",
              "sourceURL": "https://example.com/nohash",
              "serverName": "nohash",
              "serverJSON": { "type": "local", "command": "npx" }
            }
          ]
        }
        """#.utf8), source: source)

        let draft = try XCTUnwrap(drafts.first)
        XCTAssertFalse(draft.canInstall)
        XCTAssertEqual(draft.blockingReason, "远端社区条目缺少 contentHash，只能浏览或手动复制 JSON")
    }

    func testParseRejectsInvalidIDsHashesSourceURLsAndDuplicateFiles() {
        let cases = [
            #"""
            {
              "schemaVersion": 1,
              "name": "Community",
              "entries": [{
                "id": "../evil",
                "kind": "mcp",
                "name": "Bad ID",
                "description": "Bad",
                "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "serverName": "bad",
                "serverJSON": { "type": "local", "command": "npx" }
              }]
            }
            """#,
            #"""
            {
              "schemaVersion": 1,
              "name": "Community",
              "entries": [{
                "id": "bad-hash",
                "kind": "mcp",
                "name": "Bad Hash",
                "description": "Bad",
                "contentHash": "sha256:nothex",
                "serverName": "bad-hash",
                "serverJSON": { "type": "local", "command": "npx" }
              }]
            }
            """#,
            #"""
            {
              "schemaVersion": 1,
              "name": "Community",
              "entries": [{
                "id": "bad-source",
                "kind": "mcp",
                "name": "Bad Source",
                "description": "Bad",
                "sourceURL": "http://example.com/bad",
                "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "serverName": "bad-source",
                "serverJSON": { "type": "local", "command": "npx" }
              }]
            }
            """#,
            #"""
            {
              "schemaVersion": 1,
              "name": "Community",
              "entries": [{
                "id": "duplicate-files",
                "kind": "skill",
                "name": "Duplicate Files",
                "description": "Bad",
                "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "skillFiles": [
                  { "path": "SKILL.md", "text": "one" },
                  { "path": "SKILL.md", "text": "two" }
                ]
              }]
            }
            """#
        ]

        for item in cases {
            XCTAssertThrowsError(try ProjectCapabilityCommunityCatalog.parse(Data(item.utf8), source: source))
        }
    }
}
