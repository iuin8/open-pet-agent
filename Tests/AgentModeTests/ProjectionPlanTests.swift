import XCTest
@testable import AgentMode

final class ProjectionPlanTests: XCTestCase {
    func testProjectionStateRoundTrips() throws {
        let state = ProjectionState(
            schemaVersion: 1,
            projectID: "p1",
            engineID: "opencode",
            pluginID: "dev-toolkit",
            pluginVersion: "1.0.0",
            materializedAt: Date(timeIntervalSince1970: 10),
            operations: [RecordedProjectionOperation(kind: "writeFile", destinationPath: "/tmp/out", sourcePath: nil)],
            warnings: ["warn"]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ProjectionState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func testTrustedRootAllowsNestedPath() {
        XCTAssertTrue(ProjectionTrust.isPath(URL(fileURLWithPath: "/tmp/root/a/b"), inside: URL(fileURLWithPath: "/tmp/root")))
    }

    func testTrustedRootRejectsSiblingPrefix() {
        XCTAssertFalse(ProjectionTrust.isPath(URL(fileURLWithPath: "/tmp/root-evil/a"), inside: URL(fileURLWithPath: "/tmp/root")))
    }
}
