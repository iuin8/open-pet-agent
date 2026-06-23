import AppKit
import Foundation
import Testing
@testable import App
import Context
import Orchestrator
import Rendering

/// Minimal tests confirming AppBootstrap exposes a LiveContextBox and
/// wires the snapshotProvider into it during makeRootSystem().
@Suite("AppBootstrap liveContextBox wiring")
struct AppBootstrapLiveContextBoxTests {

    /// After makeRootSystem(), the box's snapshotProvider should be set
    /// (non-nil), because AppBootstrap wires it in makeRootSystem().
    @Test("snapshotProvider is set after makeRootSystem")
    func snapshotProviderSetAfterMakeRootSystem() async throws {
        let bootstrap = AppBootstrap(
            snapshot: .empty
        )
        _ = try await bootstrap.makeRootSystem()

        let box = bootstrap.liveContextBox
        let provider = await box.snapshotProvider
        #expect(provider != nil)
    }
}
