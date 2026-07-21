import Testing
import Foundation
@testable import App

@MainActor
@Suite("AgentTranscriptWakeupWatcher")
struct AgentTranscriptWakeupWatcherTests {
    @Test("start/stop toggles running for an existing transcript root")
    func startStopTogglesRunningStateForExistingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-wakeup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = AgentTranscriptWakeupWatcher(roots: [dir], debounce: 0.05) {}

        #expect(watcher.isRunning == false)
        watcher.start()
        #expect(watcher.isRunning)
        watcher.stop()
        #expect(watcher.isRunning == false)
    }
    actor Counter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    func appendUntilWakeup(transcript: URL, counter: Counter, timeout: Duration = .seconds(8)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var index = 0
        while clock.now < deadline {
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("next-\(index)\n".utf8))
            try handle.close()
            try await Task.sleep(nanoseconds: 100_000_000)
            if await counter.value() > 0 { return }
            index += 1
        }
        Issue.record("FSEvents wakeup did not arrive before deadline")
    }

    @Test("nested transcript append triggers wakeup")
    func nestedTranscriptAppendTriggersWakeup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-wakeup-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("07", isDirectory: true)
            .appendingPathComponent("21", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = projectDir.appendingPathComponent("session.jsonl")
        try "seed\n".write(to: transcript, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = AgentTranscriptWakeupWatcher(roots: [root], debounce: 0.01) {
            Task { await counter.increment() }
        }
        watcher.start()
        defer { watcher.stop() }

        try await appendUntilWakeup(transcript: transcript, counter: counter)
    }

}
