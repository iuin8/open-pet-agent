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
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test("wakeups are debounced before invoking poll")
    func wakeupsAreDebouncedBeforeInvokingPoll() async throws {
        let counter = Counter()
        let watcher = AgentTranscriptWakeupWatcher(roots: [], debounce: 0.01) {
            counter.increment()
        }

        watcher.triggerWakeupForTesting()
        watcher.triggerWakeupForTesting()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(counter.value() == 1)
    }

}
