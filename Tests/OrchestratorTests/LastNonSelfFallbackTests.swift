import Context
import Foundation
import Testing
@testable import Orchestrator

@Suite("LiveContextBox.observe + buildSystemPrompt lastNonSelfApplicationName fallback")
struct LastNonSelfFallbackTests {

    // MARK: - LiveContextBox.observe

    @Test("observe with non-self app records it as lastNonSelfApplicationName")
    func observeRecordsNonSelfApp() async {
        let box = LiveContextBox()
        let snapshot = makeSnapshot(visibleApplicationName: "Xcode")
        await box.observe(snapshot: snapshot, selfApplicationName: "OpenPetAgent")
        let recorded = await box.lastNonSelfApplicationName
        #expect(recorded == "Xcode")
    }

    @Test("observe with self app does NOT overwrite previous non-self memory")
    func observeWithSelfDoesNotOverwrite() async {
        let box = LiveContextBox()
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "Xcode"),
            selfApplicationName: "OpenPetAgent"
        )
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "OpenPetAgent"),
            selfApplicationName: "OpenPetAgent"
        )
        let recorded = await box.lastNonSelfApplicationName
        #expect(recorded == "Xcode", "self frontmost must not erase the prior workspace memory")
    }

    @Test("observe with nil snapshot is a no-op")
    func observeNilSnapshotIsNoOp() async {
        let box = LiveContextBox()
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "Xcode"),
            selfApplicationName: "OpenPetAgent"
        )
        await box.observe(snapshot: nil, selfApplicationName: "OpenPetAgent")
        let recorded = await box.lastNonSelfApplicationName
        #expect(recorded == "Xcode")
    }

    @Test("observe with empty frontmost name is a no-op")
    func observeEmptyAppNameIsNoOp() async {
        let box = LiveContextBox()
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "Xcode"),
            selfApplicationName: "OpenPetAgent"
        )
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: ""),
            selfApplicationName: "OpenPetAgent"
        )
        let recorded = await box.lastNonSelfApplicationName
        #expect(recorded == "Xcode")
    }

    @Test("observe with non-self app updates memory to the latest one")
    func observeUpdatesToLatestNonSelf() async {
        let box = LiveContextBox()
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "Xcode"),
            selfApplicationName: "OpenPetAgent"
        )
        await box.observe(
            snapshot: makeSnapshot(visibleApplicationName: "Safari"),
            selfApplicationName: "OpenPetAgent"
        )
        let recorded = await box.lastNonSelfApplicationName
        #expect(recorded == "Safari")
    }

    // MARK: - buildSystemPrompt fallback

    @Test("self is frontmost + lastNonSelf set → '最近活跃应用' line used")
    func selfFrontmostUsesFallbackLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "OpenPetAgent")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)
        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: "OpenPetAgent",
            lastNonSelfApplicationName: "Xcode"
        )
        #expect(prompt.contains("- 最近活跃应用：Xcode"))
        #expect(!prompt.contains("- 当前前台应用"))
    }

    @Test("non-self frontmost + lastNonSelf set → '当前前台应用' wins, fallback line absent")
    func nonSelfFrontmostWinsOverFallback() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "Safari")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)
        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: "OpenPetAgent",
            lastNonSelfApplicationName: "Xcode"
        )
        #expect(prompt.contains("- 当前前台应用：Safari"))
        #expect(!prompt.contains("最近活跃应用"))
    }

    @Test("self is frontmost + lastNonSelf nil → no app line at all (cold start)")
    func selfFrontmostNoFallbackOmitsLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "OpenPetAgent")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)
        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: "OpenPetAgent",
            lastNonSelfApplicationName: nil
        )
        #expect(!prompt.contains("当前前台应用"))
        #expect(!prompt.contains("最近活跃应用"))
    }

    // MARK: - Helpers

    private func makeSnapshot(visibleApplicationName: String?) -> DesktopSnapshot {
        DesktopSnapshot(
            displays: [DisplaySnapshot(id: 0, width: 1920, height: 1080)],
            cursorPosition: Point(x: 100, y: 100),
            visibleApplicationName: visibleApplicationName
        )
    }

    private func calendar(hour: Int) -> (Calendar, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: 2026, month: 5, day: 18, hour: hour, minute: 0)
        return (cal, cal.date(from: comps)!)
    }
}
