import Testing
import Foundation
@testable import Orchestrator
import Context
import Rendering

@Suite("LiveContextBox")
struct LiveContextBoxTests {

    // MARK: 1. Initial state → both providers nil

    @Test("initial snapshotProvider is nil")
    func initialSnapshotProviderIsNil() async {
        let box = LiveContextBox()
        let provider = await box.snapshotProvider
        #expect(provider == nil)
    }

    @Test("initial petContextProvider is nil")
    func initialPetContextProviderIsNil() async {
        let box = LiveContextBox()
        let provider = await box.petContextProvider
        #expect(provider == nil)
    }

    // MARK: 2. After set → provider is non-nil and returns expected value

    @Test("setSnapshotProvider stores and returns snapshot")
    func setSnapshotProviderStoresAndReturnsSnapshot() async {
        let box = LiveContextBox()
        let expected = DesktopSnapshot(
            displays: [DisplaySnapshot(id: 0, width: 1920, height: 1080)],
            visibleApplicationName: "Finder"
        )
        await box.setSnapshotProvider { expected }

        let provider = await box.snapshotProvider
        #expect(provider != nil)
        let result = await provider!()
        #expect(result == expected)
    }

    @Test("setPetContextProvider stores and returns pet context")
    func setPetContextProviderStoresAndReturnsPetContext() async {
        let box = LiveContextBox()
        let expected = PetContext(behavior: .tracking, isSnowEnabled: true)
        await box.setPetContextProvider { expected }

        let provider = await box.petContextProvider
        #expect(provider != nil)
        let result = await provider!()
        #expect(result == expected)
    }

    // MARK: 3. Replace (set second time) → uses new closure

    @Test("replacing snapshotProvider uses new closure")
    func replacingSnapshotProviderUsesNew() async {
        let box = LiveContextBox()
        let first = DesktopSnapshot(visibleApplicationName: "First")
        let second = DesktopSnapshot(visibleApplicationName: "Second")

        await box.setSnapshotProvider { first }
        await box.setSnapshotProvider { second }

        let provider = await box.snapshotProvider
        let result = await provider!()
        #expect(result.visibleApplicationName == "Second")
    }

    // MARK: 4. nil-safe: no set → orchestrator must not crash

    @Test("nil providers do not crash when accessed")
    func nilProvidersSafeAccess() async {
        let box = LiveContextBox()
        let snapshotProvider = await box.snapshotProvider
        let petContextProvider = await box.petContextProvider

        // Optional-chaining on nil closures must not crash
        let snapshotResult = await snapshotProvider?()
        let petResult = await petContextProvider?()

        #expect(snapshotResult == nil)
        #expect(petResult == nil)
    }
}
