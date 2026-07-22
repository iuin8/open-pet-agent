import CoreServices
import Foundation

/// App-layer transcript directory wakeup. It only reduces latency by calling the existing poll path;
/// `AgentSensingService` remains the source of truth.
@MainActor
final class AgentTranscriptWakeupWatcher {
    private let roots: [URL]
    private let debounce: TimeInterval
    private let onWakeup: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    private(set) var isRunning = false

    init(roots: [URL], debounce: TimeInterval = 0.15, onWakeup: @escaping @Sendable () -> Void) {
        self.roots = roots
        self.debounce = debounce
        self.onWakeup = onWakeup
    }

    deinit {
        debounceWorkItem?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        guard !isRunning else { return }
        let paths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<AgentTranscriptWakeupWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleWakeup()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if FSEventStreamStart(stream) {
            self.stream = stream
            isRunning = true
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        guard let stream else {
            isRunning = false
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isRunning = false
    }

    func triggerWakeupForTesting() {
        scheduleWakeup()
    }

    private func scheduleWakeup() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [onWakeup] in onWakeup() }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
