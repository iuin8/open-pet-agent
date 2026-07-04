import XCTest
@testable import App
@testable import AgentMode

/// P2a persona 配置测试。测试用 `homeDirectoryOverride` 隔离真 `~/.open-pet-agent/workspace/`。
final class PersonaConfigTests: XCTestCase {
    private var tmpHome: URL!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonaConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testReadSoulNilIfMissing() {
        XCTAssertNil(PersonaConfig.readSoul())
    }

    func testEnsureDefaultSoulCreatesAndPersists() throws {
        let url = try PersonaConfig.ensureDefaultSoul()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = PersonaConfig.readSoul()
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("OpenPetAgent") == true)
    }

    func testEnsureDefaultSoulIdempotentPreservesUserEdits() throws {
        try PersonaConfig.ensureDefaultSoul()
        // 用户改 SOUL.md
        let modified = "# 自定义人格\n我是自定义"
        try modified.data(using: .utf8)?.write(to: PersonaConfig.soulMDURL, options: .atomic)
        // 再次 ensure 不覆盖
        try PersonaConfig.ensureDefaultSoul()
        XCTAssertEqual(PersonaConfig.readSoul(), modified)
    }

    func testSoulMDURLUnderWorkspace() {
        XCTAssertTrue(PersonaConfig.soulMDURL.path.hasSuffix(".open-pet-agent/workspace/SOUL.md"))
    }

    func testWriteSoulPersistsAndReads() throws {
        try PersonaConfig.writeSoul("# 自定义人格\n测试内容")
        XCTAssertEqual(PersonaConfig.readSoul(), "# 自定义人格\n测试内容")
    }
}
