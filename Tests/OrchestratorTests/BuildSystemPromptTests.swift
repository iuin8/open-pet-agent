import Testing
import Foundation
@testable import Orchestrator
import Context
import RuntimeBridge

// MARK: - Helpers

private func makeDisplay(width: Double = 1440, height: Double = 900) -> DisplaySnapshot {
    DisplaySnapshot(id: 0, width: width, height: height)
}

private func makeSnapshot(
    displays: [DisplaySnapshot] = [DisplaySnapshot(id: 0, width: 1440, height: 900)],
    cursorPosition: Point = Point(x: 720, y: 450),
    visibleApplicationName: String? = "Xcode"
) -> DesktopSnapshot {
    DesktopSnapshot(
        displays: displays,
        cursorPosition: cursorPosition,
        visibleApplicationName: visibleApplicationName
    )
}

/// Returns a Calendar fixed at a given hour (UTC, calendar timezone irrelevant —
/// we only test hour-of-day bucketing).
private func calendar(hour: Int) -> (Calendar, Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 5
    comps.day = 17
    comps.hour = hour
    comps.minute = 0
    comps.second = 0
    comps.timeZone = TimeZone(secondsFromGMT: 0)
    let date = cal.date(from: comps)!
    return (cal, date)
}

// MARK: - Suite

@Suite("CompanionOrchestrator.buildSystemPrompt")
struct BuildSystemPromptTests {

    // MARK: 1. Full context block: snapshot + petContext → contains [Desktop Context]
    //
    // Single parametrized check: each row drives a tailored snapshot/pet pair and
    // asserts the corresponding substring appears in the rendered prompt.

    @Test(
        "full context block contains expected substring",
        arguments: [
            // (label, appName, displayCount, cursor, behavior, snowEnabled, expectedSubstring)
            ("[Desktop Context] header", "Xcode", 1, Point(x: 720, y: 450), CompanionBehavior.idle, false, "[Desktop Context]"),
            ("frontmost app name", "Safari", 1, Point(x: 720, y: 450), CompanionBehavior.idle, false, "Safari"),
            ("time label (hour=10)", "Xcode", 1, Point(x: 720, y: 450), CompanionBehavior.idle, false, "上午"),
            ("display count (2)", "Xcode", 2, Point(x: 720, y: 450), CompanionBehavior.idle, false, "2"),
            ("cursor zone label (top-left)", "Xcode", 1, Point(x: 100, y: 800), CompanionBehavior.idle, false, "屏幕左上"),
            ("pet behavior heading", "Xcode", 1, Point(x: 720, y: 450), CompanionBehavior.tracking, false, "桌宠状态"),
            ("snow status heading", "Xcode", 1, Point(x: 720, y: 450), CompanionBehavior.idle, true, "雪景模式"),
        ]
    )
    func fullContextBlockContainsExpected(
        label: String,
        appName: String,
        displayCount: Int,
        cursor: Point,
        behavior: CompanionBehavior,
        snow: Bool,
        expected: String
    ) {
        let (cal, now) = calendar(hour: 10)
        let displays = Array(repeating: makeDisplay(width: 1440, height: 900), count: displayCount)
        let snapshot = makeSnapshot(
            displays: displays,
            cursorPosition: cursor,
            visibleApplicationName: appName
        )
        let pet = PetContext(behavior: behavior, isSnowEnabled: snow)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(prompt.contains(expected), "\(label): expected prompt to contain \(expected)")
    }

    // MARK: 2. nil snapshot → no [Desktop Context] block

    @Test("nil snapshot omits [Desktop Context] block")
    func nilSnapshotOmitsContextBlock() {
        let (cal, now) = calendar(hour: 10)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: nil, petContext: nil, now: now, calendar: cal
        )

        #expect(!prompt.contains("[Desktop Context]"))
    }

    @Test("nil snapshot returns base prompt")
    func nilSnapshotReturnsBasePrompt() {
        let (cal, now) = calendar(hour: 10)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: nil, petContext: nil, now: now, calendar: cal
        )

        #expect(prompt.contains("OpenPetAgent"))
    }

    // MARK: 3. nil petContext → context block exists but no pet/snow lines

    @Test("nil petContext omits pet behavior line")
    func nilPetContextOmitsPetBehaviorLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot()

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: nil, now: now, calendar: cal
        )

        #expect(prompt.contains("[Desktop Context]"))
        #expect(!prompt.contains("桌宠状态"))
    }

    @Test("nil petContext omits snow status line")
    func nilPetContextOmitsSnowLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot()

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: nil, now: now, calendar: cal
        )

        #expect(!prompt.contains("雪景模式"))
    }

    // MARK: 4. nil frontmost app → that line absent or shows fallback

    @Test("nil visibleApplicationName omits or shows fallback for app line")
    func nilAppNameOmitsOrShowsFallback() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: nil)
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        // The line should never expose the literal nil/Optional description.
        #expect(!prompt.contains("Optional("))
        // Also: no "前台应用" line when app name is nil — we either omit it cleanly
        // or write a non-nil fallback. Either way, no raw "nil" token.
        #expect(!prompt.contains(": nil"))
        #expect(!prompt.contains("：nil"))
    }

    // MARK: 4a. selfApplicationName filter (chat focused = OpenPetAgent is frontmost)

    @Test("selfApplicationName equals frontmost → 前台应用 line omitted (no self-reporting noise)")
    func selfNameMatchingFrontmostOmitsLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "OpenPetAgent")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: "OpenPetAgent"
        )

        #expect(!prompt.contains("前台应用"))
        #expect(!prompt.contains("OpenPetAgent："))
        // Block itself still present (we still have time/displays/cursor/pet).
        #expect(prompt.contains("[Desktop Context]"))
    }

    @Test("selfApplicationName differs from frontmost → 前台应用 line still present")
    func selfNameDifferentKeepsLine() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "Xcode")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: "OpenPetAgent"
        )

        #expect(prompt.contains("Xcode"))
        #expect(prompt.contains("- 当前前台应用：Xcode"))
    }

    @Test("selfApplicationName nil (default) → no filtering, frontmost line always present")
    func selfNameNilDoesNotFilter() {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(visibleApplicationName: "OpenPetAgent")
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot,
            petContext: pet,
            now: now,
            calendar: cal,
            selfApplicationName: nil
        )

        #expect(prompt.contains("OpenPetAgent"))
    }

    // MARK: 5. Time label buckets

    @Test(
        "hour-of-day → time-bucket label",
        arguments: [
            (8, "上午"),
            (14, "下午"),
            (20, "晚上"),
            (2, "深夜"),
        ]
    )
    func hourMapsToTimeLabel(hour: Int, expected: String) {
        let (cal, now) = calendar(hour: hour)
        let snapshot = makeSnapshot()
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(prompt.contains(expected))
    }

    // MARK: 6. Cursor zone

    @Test(
        "cursor position → zone label",
        arguments: [
            // 1440×900 display, macOS coords (y=0 bottom).
            (Point(x: 100, y: 800), "屏幕左上"),
            (Point(x: 1400, y: 50), "屏幕右下"),
            (Point(x: 720, y: 450), "屏幕中央"),
        ]
    )
    func cursorMapsToZone(cursor: Point, expected: String) {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(
            displays: [makeDisplay(width: 1440, height: 900)],
            cursorPosition: cursor
        )
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(prompt.contains(expected))
    }

    // MARK: 7. Display count

    @Test(
        "display count → label",
        arguments: [
            (1, "1"),
            (2, "2"),
        ]
    )
    func displayCountAppearsInPrompt(count: Int, expected: String) {
        let (cal, now) = calendar(hour: 10)
        let displays = Array(repeating: makeDisplay(), count: count)
        let snapshot = makeSnapshot(displays: displays)
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(prompt.contains(expected))
    }

    // MARK: 8. Pet behavior labels

    @Test(
        "behavior → label substring",
        arguments: [
            (CompanionBehavior.idle, false, "闲"),
            (CompanionBehavior.tracking, false, "追踪"),
            (CompanionBehavior.snowing, true, "雪"),
        ]
    )
    func behaviorMapsToLabel(behavior: CompanionBehavior, snow: Bool, expected: String) {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot()
        let pet = PetContext(behavior: behavior, isSnowEnabled: snow)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(prompt.contains(expected))
    }

    // MARK: 9. No raw coordinates

    @Test(
        "raw cursor coordinate must not leak into prompt",
        arguments: [
            // axis label, x, y, full string, trimmed string
            ("x", 987.654321, 400.0, "987.654321", "987.65"),
            ("y", 500.0, 123.456789, "123.456789", "123.45"),
        ]
    )
    func promptDoesNotContainRawCoordinate(axis: String, x: Double, y: Double, fullValue: String, trimmedValue: String) {
        let (cal, now) = calendar(hour: 10)
        let snapshot = makeSnapshot(
            displays: [makeDisplay()],
            cursorPosition: Point(x: x, y: y)
        )
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)

        let prompt = CompanionOrchestrator.buildSystemPrompt(
            snapshot: snapshot, petContext: pet, now: now, calendar: cal
        )

        #expect(!prompt.contains(fullValue))
        #expect(!prompt.contains(trimmedValue))
    }
}
