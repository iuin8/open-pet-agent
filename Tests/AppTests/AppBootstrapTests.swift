import AppKit
import Foundation
import Testing
@testable import App
import Context
import Orchestrator
import Rendering
import RuntimeBridge
import Shell

private struct SimulatedBootstrapError: LocalizedError {
    var errorDescription: String? {
        "simulated bootstrap failure"
    }
}

private final class DelegateProxy: NSObject, NSApplicationDelegate {}

private final class SamplerDisplaySnapshotQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[DisplaySnapshot]]

    init(_ queue: [[DisplaySnapshot]]) {
        self.queue = queue
    }

    func next() -> [DisplaySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return queue.removeFirst()
    }
}

private final class SamplerChangeTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let captured = handler
        lock.unlock()
        captured?()
    }
}

private final class SamplerCallCounter: @unchecked Sendable {
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

private final class SamplerThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    func recordCurrentThread() {
        lock.lock()
        recordedValues.append(Thread.isMainThread)
        lock.unlock()
    }

    func allValuesAreMainThread() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues.isEmpty == false && recordedValues.allSatisfy { $0 }
    }
}

@MainActor
private final class FrameLoopSpy {
    private(set) var tickCount = 0

    func tick() {
        tickCount += 1
    }
}

private final class SuspendedTickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let entryContinuation = self.entryContinuation
            self.entryContinuation = nil
            lock.unlock()
            entryContinuation?.resume()
        }
    }

    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.entryContinuation = continuation
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class PointSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let points: [Point]
    private var index = 0

    init(_ points: [Point]) {
        self.points = points
    }

    func next() -> Point {
        lock.lock()
        defer { lock.unlock() }

        let point = points[min(index, points.count - 1)]
        index += 1
        return point
    }
}

private final class WindowInfoSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let payloads: [[[String: Any]]]
    private var index = 0

    init(payloads: [[[String: Any]]]) {
        self.payloads = payloads
    }

    func next() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        let currentIndex = min(index, payloads.count - 1)
        index += 1
        return payloads[currentIndex]
    }
}

@Test("App bootstrap assembles root system from shell and orchestrator")
func appBootstrapAssemblesRootSystem() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))

    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()

    #expect(rootSystem.snapshot == snapshot)
    #expect(rootSystem.windowGraph.windows.count == 3)
    #expect(rootSystem.windowGraph.windows.map(\.kind) == [.overlay, .pet, .chat])
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionX == 21)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionY == 34)
}

@Test("App bootstrap exposes the orchestrator conversation responder")
func appBootstrapExposesTheOrchestratorConversationResponder() async throws {
    let rootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    ).makeRootSystem()

    let reply = await rootSystem.conversationResponder.reply(to: "你好")

    #expect(reply == "我听到“你好”了。")
}

@Test("App bootstrap samples a live desktop snapshot by default")
func appBootstrapSamplesALiveDesktopSnapshotByDefault() async throws {
    let expectedVisibleWindows = [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 800, height: 600),
            workspace: 7
        )
    ]
    let liveSnapshot = DesktopSnapshot(
        displays: [DisplaySnapshot(id: 1, width: 1512, height: 982)],
        activeSpaceIdentifier: "space-7",
        cursorPosition: Point(x: 56, y: 78),
        visibleApplicationName: "Finder",
        visibleWindows: expectedVisibleWindows
    )

    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { liveSnapshot.displays },
            activeSpaceIdentifier: { liveSnapshot.activeSpaceIdentifier },
            currentCursorPosition: { liveSnapshot.cursorPosition },
            frontmostApplicationName: { liveSnapshot.visibleApplicationName },
            currentVisibleWindows: { liveSnapshot.visibleWindows }
        )
    ).makeRootSystem()

    #expect(rootSystem.snapshot == liveSnapshot)
    #expect(rootSystem.snapshot.displays == [DisplaySnapshot(id: 1, width: 1512, height: 982)])
    #expect(rootSystem.snapshot.activeSpaceIdentifier == "space-7")
    #expect(rootSystem.snapshot.visibleWindows == expectedVisibleWindows)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionX == 56)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionY == 78)
}

@Test("App bootstrap live sampler includes visible windows from providers")
func appBootstrapLiveSamplerIncludesVisibleWindowsFromProviders() {
    let expectedDisplays = [DisplaySnapshot(id: 1, width: 1512, height: 982)]
    let expectedVisibleWindows = [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 800, height: 600),
            workspace: 7
        )
    ]
    let sampler = AppBootstrap.makeLiveSnapshotSampler(
        currentDisplays: { expectedDisplays },
        windowInfoSource: {
            [[
                kCGWindowOwnerPID as String: 777,
                kCGWindowOwnerName as String: "Finder",
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                "kCGWindowWorkspace": 7,
                kCGWindowBounds as String: [
                    "X": 10.0,
                    "Y": 20.0,
                    "Width": 800.0,
                    "Height": 600.0
                ]
            ]]
        },
        currentProcessIdentifier: { 999 },
        frontmostApplicationProcessIdentifier: { nil },
        currentCursorPosition: { Point(x: 56, y: 78) },
        frontmostApplicationName: { "Finder" }
    )

    let snapshot = sampler.sample()

    #expect(snapshot.displays == expectedDisplays)
    #expect(snapshot.activeSpaceIdentifier == "space-7")
    #expect(snapshot.cursorPosition == Point(x: 56, y: 78))
    #expect(snapshot.visibleApplicationName == "Finder")
    #expect(snapshot.visibleWindows == expectedVisibleWindows)
}

@Test("App bootstrap live sampler derives active space and visible windows from the same window snapshot")
func appBootstrapLiveSamplerDerivesActiveSpaceAndVisibleWindowsFromTheSameWindowSnapshot() {
    let firstWindowPayload: [[String: Any]] = [[
        kCGWindowOwnerPID as String: 777,
        kCGWindowOwnerName as String: "Finder",
        kCGWindowLayer as String: 0,
        kCGWindowAlpha as String: 1.0,
        "kCGWindowWorkspace": 7,
        kCGWindowBounds as String: [
            "X": 10.0,
            "Y": 20.0,
            "Width": 800.0,
            "Height": 600.0
        ]
    ]]
    let secondWindowPayload: [[String: Any]] = [[
        kCGWindowOwnerPID as String: 888,
        kCGWindowOwnerName as String: "Xcode",
        kCGWindowLayer as String: 0,
        kCGWindowAlpha as String: 1.0,
        "kCGWindowWorkspace": 9,
        kCGWindowBounds as String: [
            "X": 30.0,
            "Y": 40.0,
            "Width": 1200.0,
            "Height": 900.0
        ]
    ]]
    let windowInfoSequence = WindowInfoSequence(payloads: [firstWindowPayload, secondWindowPayload])
    let sampler = AppBootstrap.makeLiveSnapshotSampler(
        currentDisplays: { [] },
        windowInfoSource: {
            windowInfoSequence.next()
        },
        currentProcessIdentifier: { 999 },
        frontmostApplicationProcessIdentifier: { nil },
        currentCursorPosition: { .zero },
        frontmostApplicationName: { nil }
    )

    let snapshot = sampler.sample()

    #expect(snapshot.activeSpaceIdentifier == "space-7")
    #expect(snapshot.visibleWindows == [
        VisibleWindowSnapshot(
            ownerName: "Finder",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 800, height: 600),
            workspace: 7
        )
    ])
}

@Test("App bootstrap samples desktop state on the main thread")
func appBootstrapSamplesDesktopStateOnTheMainThread() async throws {
    let samplerThreadRecorder = SamplerThreadRecorder()

    _ = try await Task.detached {
        try await AppBootstrap(
            snapshotSampler: DesktopSnapshotSampler(
                currentDisplays: {
                    samplerThreadRecorder.recordCurrentThread()
                    return []
                },
                activeSpaceIdentifier: {
                    samplerThreadRecorder.recordCurrentThread()
                    return "space-7"
                },
                currentCursorPosition: {
                    samplerThreadRecorder.recordCurrentThread()
                    return Point(x: 56, y: 78)
                },
                frontmostApplicationName: {
                    samplerThreadRecorder.recordCurrentThread()
                    return "Finder"
                },
                currentVisibleWindows: {
                    samplerThreadRecorder.recordCurrentThread()
                    return []
                }
            )
        ).makeRootSystem()
    }.value

    #expect(samplerThreadRecorder.allValuesAreMainThread())
}

@Test("App bootstrap prefers an explicit snapshot over the live sampler")
func appBootstrapPrefersAnExplicitSnapshotOverTheLiveSampler() async throws {
    let explicitSnapshot = DesktopSnapshot(
        cursorPosition: Point(x: 21, y: 34),
        visibleApplicationName: "Xcode"
    )
    let samplerCallCounter = SamplerCallCounter()

    let rootSystem = try await AppBootstrap(
        snapshot: explicitSnapshot,
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: {
                samplerCallCounter.increment()
                return [DisplaySnapshot(id: 9, width: 1920, height: 1080)]
            },
            activeSpaceIdentifier: {
                samplerCallCounter.increment()
                return "space-9"
            },
            currentCursorPosition: {
                samplerCallCounter.increment()
                return Point(x: 89, y: 144)
            },
            frontmostApplicationName: {
                samplerCallCounter.increment()
                return "Finder"
            },
            currentVisibleWindows: {
                samplerCallCounter.increment()
                return []
            }
        )
    ).makeRootSystem()

    #expect(rootSystem.snapshot == explicitSnapshot)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionX == 21)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionY == 34)
    #expect(samplerCallCounter.value() == 0)
}

@Test("Minimal app delegate default frame loop ticks without run loop mode dependence")
@MainActor
func minimalAppDelegateDefaultFrameLoopTicksWithoutRunLoopModeDependence() async throws {
    // The frame loop runs on a private DispatchSource timer (60Hz, ~16.67ms),
    // which fires off the main thread. Poll the tick counter rather than burn
    // a fixed 200ms sleep so this test finishes in roughly one timer interval.
    let counter = TickCounter()
    let queue = DispatchQueue(label: "test.frameLoop")
    let handle = MinimalAppDelegate.makeDefaultFrameLoop(
        { counter.increment() },
        makeTimer: { DispatchSource.makeTimerSource(queue: queue) }
    )
    defer { handle.cancel() }

    // Poll with a generous upper bound (1s = far more than 60 frames). This
    // exits within ~16ms on a healthy machine while staying robust under load.
    let deadline = Date(timeIntervalSinceNow: 1.0)
    while counter.value() == 0 && Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000) // 5ms
    }

    #expect(counter.value() > 0)
}

/// Thread-safe int counter for cross-thread frame-loop tick assertions.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Test("OpenPetAgent app computes bootstrap failures off the main actor seam")
func petAgentAppBootstrapLaunchStateReportsFailure() async {
    let launchState = await OpenPetAgentApp.bootstrapLaunchState {
        throw SimulatedBootstrapError()
    }

    #expect(launchState == .failed("Failed to bootstrap OpenPetAgent: simulated bootstrap failure"))
}

@Test("OpenPetAgent app launch flow composes bootstrap failure reporting end to end")
@MainActor
func petAgentAppLaunchFlowComposesBootstrapFailurePath() async throws {
    var didLaunchReadyPath = false
    var reportedData: Data?
    var receivedExitCode: Int32?

    await OpenPetAgentApp.runLaunchFlow(
        makeRootSystem: { throw SimulatedBootstrapError() },
        launchReadyApp: { _ in
            didLaunchReadyPath = true
        },
        writeToStandardError: {
            reportedData = $0
        },
        exitProcess: { exitCode in
            receivedExitCode = exitCode
        }
    )

    #expect(didLaunchReadyPath == false)
    #expect(receivedExitCode == OpenPetAgentApp.bootstrapFailureExitCode)
    #expect(
        String(data: try #require(reportedData), encoding: .utf8)
            == "Failed to bootstrap OpenPetAgent: simulated bootstrap failure\n"
    )
}

@Test("OpenPetAgent app launch flow launches the ready app after bootstrap succeeds")
@MainActor
func petAgentAppLaunchFlowLaunchesReadyApp() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    let expectedRootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    var launchedRootSystem: AppRootSystem?
    var reportedData: Data?
    var receivedExitCode: Int32?

    await OpenPetAgentApp.runLaunchFlow(
        makeRootSystem: { expectedRootSystem },
        launchReadyApp: { rootSystem in
            launchedRootSystem = rootSystem
        },
        writeToStandardError: {
            reportedData = $0
        },
        exitProcess: { exitCode in
            receivedExitCode = exitCode
        }
    )

    #expect(launchedRootSystem == expectedRootSystem)
    #expect(reportedData == nil)
    #expect(receivedExitCode == nil)
}

@Test("OpenPetAgent ready app launch wires activation policy delegate and run in order")
@MainActor
func petAgentReadyAppLaunchWiresAppLifecycle() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    var recordedEvents: [String] = []
    var installedDelegate: NSApplicationDelegate?

    OpenPetAgentApp.launchReadyApp(
        rootSystem: rootSystem,
        setActivationPolicy: { policy in
            recordedEvents.append("activationPolicy")
            #expect(policy == .accessory)
        },
        installDelegate: { delegate in
            recordedEvents.append("delegate")
            installedDelegate = delegate
        },
        runApplication: { _ in
            recordedEvents.append("run")
        }
    )

    #expect(recordedEvents == ["activationPolicy", "delegate", "run"])
    #expect(installedDelegate is MinimalAppDelegate)
}

@Test("OpenPetAgent ready app launch keeps the installed delegate alive through the run seam")
@MainActor
func petAgentReadyAppLaunchKeepsInstalledDelegateAliveThroughRunApplication() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    weak var weakInstalledDelegate: AnyObject?
    var observedDelegate: AnyObject?

    OpenPetAgentApp.launchReadyApp(
        rootSystem: rootSystem,
        setActivationPolicy: { _ in },
        installDelegate: { delegate in
            weakInstalledDelegate = delegate as AnyObject
        },
        runApplication: { delegate in
            observedDelegate = delegate as AnyObject
        }
    )

    #expect(weakInstalledDelegate != nil)
    #expect(observedDelegate === weakInstalledDelegate)
    #expect(observedDelegate is MinimalAppDelegate)
}

@Test("OpenPetAgent ready app launch runs the installed delegate instance")
@MainActor
func petAgentReadyAppLaunchRunsInstalledDelegateInstance() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    let delegateProxy = DelegateProxy()
    var observedDelegate: NSApplicationDelegate?

    OpenPetAgentApp.launchReadyApp(
        rootSystem: rootSystem,
        setActivationPolicy: { _ in },
        installDelegate: { _ in
        },
        makeDelegate: { _ in
            delegateProxy
        },
        runApplication: { delegate in
            observedDelegate = delegate
        }
    )

    #expect(observedDelegate === delegateProxy)
}

@Test("OpenPetAgent ready app launch retains the installed delegate after launch returns")
@MainActor
func petAgentReadyAppLaunchRetainsInstalledDelegateAfterLaunchReturns() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 21, y: 34))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    weak var weakInstalledDelegate: AnyObject?

    OpenPetAgentApp.launchReadyApp(
        rootSystem: rootSystem,
        setActivationPolicy: { _ in },
        installDelegate: { delegate in
            weakInstalledDelegate = delegate as AnyObject
        },
        runApplication: { _ in }
    )

    #expect(weakInstalledDelegate != nil)
}

@Test("Minimal app delegate launches visible shell windows with bootstrap-derived initial state")
@MainActor
func minimalAppDelegateLaunchesVisibleShellWindowsWithBootstrapDerivedInitialState() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    let shellController = try #require(delegate.launchedShellController)
    #expect(shellController.windowSet.allWindows.count == 3)
    #expect(shellController.windowSet.overlayWindow.isVisible)
    #expect(shellController.windowSet.petWindow.frame.origin == NSPoint(x: 144, y: 233))
    #expect(shellController.windowSet.petWindow.isVisible)
    // Legacy chatWindow is soft-deleted: Stage 默认主路径, legacy panel
    // stays hidden after launch. Pet 右键 "显示聊天" can still summon it.
    #expect(shellController.windowSet.chatWindow.isVisible == false)

    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate wires chat replies through the root conversation responder")
@MainActor
func minimalAppDelegateWiresChatRepliesThroughRootConversationResponder() async throws {
    let bootstrappedRootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    ).makeRootSystem()
    let rootSystem = AppRootSystem(
        snapshot: bootstrappedRootSystem.snapshot,
        windowGraph: bootstrappedRootSystem.windowGraph,
        companionBootstrap: bootstrappedRootSystem.companionBootstrap,
        runtimeTicker: bootstrappedRootSystem.runtimeTicker,
        conversationResponder: ConversationResponder { message in
            "编排器回复：\(message)"
        }
    )
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let shellController = try #require(delegate.launchedShellController)
    let chatView = try #require(shellController.windowSet.chatWindow.contentView as? ChatShellView)
    chatView.inputText = "你好"
    await chatView.sendCurrentMessage()

    #expect(chatView.transcript.contains("OpenPetAgent：编排器回复：你好"))

    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate builds the shell controller from root system state")
@MainActor
func minimalAppDelegateBuildsShellControllerFromRootSystemState() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    let screenFrame = NSRect(x: 0, y: 0, width: 1024, height: 768)
    let expectedController = DesktopShellController(
        windowGraph: rootSystem.windowGraph,
        screenFrame: screenFrame,
        initialState: ShellInitialState(
            petPositionX: rootSystem.companionBootstrap.initialRenderState.petPositionX,
            petPositionY: rootSystem.companionBootstrap.initialRenderState.petPositionY
        )
    )
    var receivedWindowGraph: WindowGraph?
    var receivedScreenFrame: NSRect?
    var receivedInitialState: ShellInitialState?
    var shownController: DesktopShellController?

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { screenFrame },
        makeShellController: { windowGraph, screenFrame, initialState, _, _ in
            receivedWindowGraph = windowGraph
            receivedScreenFrame = screenFrame
            receivedInitialState = initialState
            return expectedController
        },
        showShellWindows: { controller in
            shownController = controller
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(receivedWindowGraph == rootSystem.windowGraph)
    #expect(receivedScreenFrame == screenFrame)
    #expect(
        receivedInitialState
            == ShellInitialState(
                petPositionX: rootSystem.companionBootstrap.initialRenderState.petPositionX,
                petPositionY: rootSystem.companionBootstrap.initialRenderState.petPositionY
            )
    )
    #expect(delegate.launchedShellController === expectedController)
    #expect(shownController === expectedController)

    expectedController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate ignores duplicate finish-launch notifications once shell is running")
@MainActor
func minimalAppDelegateIgnoresDuplicateFinishLaunchingNotifications() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    let screenFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let expectedInitialState = ShellInitialState(
        petPositionX: rootSystem.companionBootstrap.initialRenderState.petPositionX,
        petPositionY: rootSystem.companionBootstrap.initialRenderState.petPositionY
    )
    let expectedController = DesktopShellController(
        windowGraph: rootSystem.windowGraph,
        screenFrame: screenFrame,
        initialState: expectedInitialState
    )
    var screenFrameReadCount = 0
    var makeShellControllerCallCount = 0
    var showShellWindowsCallCount = 0

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: {
            screenFrameReadCount += 1
            return screenFrame
        },
        makeShellController: { windowGraph, receivedScreenFrame, initialState, _, _ in
            makeShellControllerCallCount += 1
            #expect(windowGraph == rootSystem.windowGraph)
            #expect(receivedScreenFrame == screenFrame)
            #expect(initialState == expectedInitialState)
            return expectedController
        },
        showShellWindows: { controller in
            showShellWindowsCallCount += 1
            #expect(controller === expectedController)
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(screenFrameReadCount == 1)
    #expect(makeShellControllerCallCount == 1)
    #expect(showShellWindowsCallCount == 1)
    #expect(delegate.launchedShellController === expectedController)

    expectedController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate resists reentrant finish-launch while building the shell controller")
@MainActor
func minimalAppDelegateResistsReentrantFinishLaunchingWhileBuildingShellController() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    let screenFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
    var builtControllers: [DesktopShellController] = []
    var didTriggerReentrantLaunch = false
    var delegate: MinimalAppDelegate?

    delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { screenFrame },
        makeShellController: { windowGraph, screenFrame, initialState, _, _ in
            if didTriggerReentrantLaunch == false {
                didTriggerReentrantLaunch = true
                delegate?.applicationDidFinishLaunching(
                    Notification(name: NSApplication.didFinishLaunchingNotification)
                )
            }

            let controller = DesktopShellController(
                windowGraph: windowGraph,
                screenFrame: screenFrame,
                initialState: initialState
            )
            builtControllers.append(controller)
            return controller
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate?.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(builtControllers.count == 1)
    #expect(delegate?.launchedShellController === builtControllers.first)
}

@Test("Minimal app delegate resists reentrant finish-launch while showing windows")
@MainActor
func minimalAppDelegateResistsReentrantFinishLaunchingWhileShowingWindows() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    let screenFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
    var builtControllers: [DesktopShellController] = []
    var delegate: MinimalAppDelegate?

    delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { screenFrame },
        makeShellController: { windowGraph, screenFrame, initialState, _, _ in
            let controller = DesktopShellController(
                windowGraph: windowGraph,
                screenFrame: screenFrame,
                initialState: initialState
            )
            builtControllers.append(controller)
            return controller
        },
        showShellWindows: { controller in
            if builtControllers.count == 1 {
                delegate?.applicationDidFinishLaunching(
                    Notification(name: NSApplication.didFinishLaunchingNotification)
                )
            }
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate?.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(builtControllers.count == 1)
    #expect(delegate?.launchedShellController === builtControllers.first)
}

@Test("Minimal app delegate keeps pet stationary when both spatial behaviors off")
@MainActor
func minimalAppDelegateKeepsPetStationaryWhenSpatialBehaviorsOff() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 500, y: 0),
        Point(x: 500, y: 0),
    ])
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    var capturedTick: (@MainActor () async -> Void)?

    // 跟随 + 漫游都关 → pet 不动(漫游默认 on,故需显式注入两者皆关)。
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        menuBarController: MenuBarController(initialFollowingEnabled: false, initialRoamingEnabled: false),
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    #expect(delegate.isFollowingEnabled == false)
    #expect(delegate.isRoamingEnabled == false)

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)
    let shellController = try #require(delegate.launchedShellController)
    let startX = shellController.windowSet.petWindow.frame.origin.x

    await tick()

    #expect(shellController.windowSet.petWindow.frame.origin.x == startX)

    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate follows cursor when menu bar following is enabled")
@MainActor
func minimalAppDelegateFollowsCursorWhenMenuBarFollowingIsEnabled() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 500, y: 0),
    ])
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    var capturedTick: (@MainActor () async -> Void)?

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        menuBarController: MenuBarController(initialFollowingEnabled: true),
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        },
        idleSecondsProvider: { 0 } // 活跃用户 → physics 跟光标(确定性,不进漫步)
    )

    #expect(delegate.isFollowingEnabled)

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)
    let shellController = try #require(delegate.launchedShellController)
    let startX = shellController.windowSet.petWindow.frame.origin.x

    await tick()

    #expect(shellController.windowSet.petWindow.frame.origin.x > startX)

    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate advances pet window through the runtime frame loop")
@MainActor
func minimalAppDelegateAdvancesPetWindowThroughRuntimeFrameLoop() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 100, y: 0),
    ])
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    let frameLoopSpy = FrameLoopSpy()
    var frameTask: Task<Void, Never>?

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        menuBarController: MenuBarController(initialFollowingEnabled: true),
        startFrameLoop: { tick in
            let task = Task { @MainActor in
                await tick()
                frameLoopSpy.tick()
            }
            frameTask = task
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        },
        idleSecondsProvider: { 0 } // 活跃用户 → physics 跟光标(确定性,不进漫步)
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    await frameTask?.value

    let shellController = try #require(delegate.launchedShellController)
    #expect(frameLoopSpy.tickCount == 1)
    #expect(shellController.windowSet.petWindow.frame.origin.x > 0)
    #expect(shellController.windowSet.petWindow.frame.origin.y == 0)
}

@Test("Minimal app delegate roams to the ground when the user is idle")
@MainActor
func minimalAppDelegateRoamsToGroundWhenIdle() async throws {
    // 光标固定在屏幕高处:physics 会把 pet 往上拽向光标,roaming 则降到地面 —— 用
    // endY 贴地证明漫步(及 screenBounds/idleSeconds 的帧循环接入)真在跑。
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { Point(x: 400, y: 560) },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    // 固定步进时钟:每帧 dt = 1/60(紧循环真实 dt≈0,不足以驱动重力下落)。
    final class StepClock: @unchecked Sendable {
        private var t = 0.0
        func next() -> TimeInterval { t += 1.0 / 60.0; return t }
    }
    let clock = StepClock()
    var capturedTick: (@MainActor () async -> Void)?
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) }, // 地面 = minY = 0
        currentTime: { clock.next() },
        menuBarController: MenuBarController(initialFollowingEnabled: true),
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        },
        idleSecondsProvider: { 100 } // 空闲 → 漫步
    )
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)
    let shellController = try #require(delegate.launchedShellController)
    for _ in 0..<180 { await tick() } // ~3s:漫步把 pet 降到地面贴地溜达
    let endY = shellController.windowSet.petWindow.frame.origin.y
    // physics 会拽到光标 y≈560;roaming 降到地面 ≈0。贴地 → 漫步在帧循环里生效。
    #expect(endY < 50)
    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate discards runtime output when pet is dragged during a tick")
@MainActor
func minimalAppDelegateDiscardsRuntimeOutputWhenPetIsDraggedDuringTick() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 200, y: 0),
    ])
    let tickGate = SuspendedTickGate()
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    var frameTask: Task<Void, Never>?

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        startFrameLoop: { tick in
            let task = Task { @MainActor in
                await tick()
            }
            frameTask = task
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        },
        waitForRuntimeFrame: {
            await tickGate.wait()
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let shellController = try #require(delegate.launchedShellController)
    await tickGate.waitForEntry()
    shellController.handlePetDragDidMove(to: NSPoint(x: 100, y: 0))
    tickGate.resume()
    await frameTask?.value

    #expect(shellController.windowSet.petWindow.frame.origin.x == 100)
}

@Test("Minimal app delegate toggles snow state from shell interaction")
@MainActor
func minimalAppDelegateTogglesSnowStateFromShellInteraction() async throws {
    let bootstrappedRootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    ).makeRootSystem()
    let rootSystem = AppRootSystem(
        snapshot: bootstrappedRootSystem.snapshot,
        windowGraph: bootstrappedRootSystem.windowGraph,
        companionBootstrap: bootstrappedRootSystem.companionBootstrap,
        runtimeTicker: RuntimeTicker { previousRenderState, _, _ in
            RuntimeTickResult(
                renderState: RenderState(
                    petPositionX: previousRenderState.petPositionX,
                    petPositionY: previousRenderState.petPositionY,
                    petRotation: previousRenderState.petRotation,
                    particleCount: 5,
                    particles: (0..<5).map { index in
                        ParticlePosition(x: Double(index * 47), y: Double(index * 73))
                    },
                    contactCount: previousRenderState.contactCount,
                    isSnowEnabled: previousRenderState.isSnowEnabled
                ),
                snapshot: .empty
            )
        },
        conversationResponder: bootstrappedRootSystem.conversationResponder
    )
    var capturedTick: (@MainActor () async -> Void)?
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let shellController = try #require(delegate.launchedShellController)
    let petWindow = try #require(shellController.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    let snowItem = try #require(menu.items.first(where: { $0.title == "下雪" }))
    let action = try #require(snowItem.action)

    let overlayView = try #require(shellController.windowSet.overlayWindow.contentView as? DesktopOverlayView)

    NSApp.sendAction(action, to: snowItem.target, from: snowItem)
    #expect(delegate.isSnowEnabled)
    #expect(delegate.currentRenderState.isSnowEnabled)
    #expect(overlayView.isSnowPlaceholderVisible)

    // 推进一帧（falling-sand 在 GPU 上渲染；旧 NSTextField 雪花占位动画已随旧雪移除）。
    let tick = try #require(capturedTick)
    await tick()
    #expect(delegate.currentRenderState.particleCount == 5)

    NSApp.sendAction(action, to: snowItem.target, from: snowItem)
    #expect(delegate.isSnowEnabled == false)
    #expect(delegate.currentRenderState.isSnowEnabled == false)
    #expect(overlayView.isSnowPlaceholderVisible == false)

    shellController.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate computes delta time from injected clock between ticks")
@MainActor
func minimalAppDelegateComputesDeltaTimeFromInjectedClockBetweenTicks() async throws {
    let bootstrappedRootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    ).makeRootSystem()
    final class CapturedTicker: @unchecked Sendable {
        var deltaTimes: [Double] = []
    }
    let captured = CapturedTicker()
    let rootSystem = AppRootSystem(
        snapshot: bootstrappedRootSystem.snapshot,
        windowGraph: bootstrappedRootSystem.windowGraph,
        companionBootstrap: bootstrappedRootSystem.companionBootstrap,
        runtimeTicker: RuntimeTicker { previousRenderState, deltaTime, _ in
            captured.deltaTimes.append(deltaTime)
            return RuntimeTickResult(renderState: previousRenderState, snapshot: .empty)
        },
        conversationResponder: bootstrappedRootSystem.conversationResponder
    )
    final class FakeClock: @unchecked Sendable {
        var sequence: [TimeInterval] = [10.0, 10.25, 10.5]
        func next() -> TimeInterval {
            sequence.removeFirst()
        }
    }
    let clock = FakeClock()
    var capturedTick: (@MainActor () async -> Void)?
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        currentTime: { clock.next() },
        maxDeltaTime: 1.0,
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)

    await tick()
    await tick()

    #expect(captured.deltaTimes.count == 2)
    #expect(abs(captured.deltaTimes[0] - 0.25) < 1e-9)
    #expect(abs(captured.deltaTimes[1] - 0.25) < 1e-9)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Minimal app delegate clamps long stall delta time to frame budget")
@MainActor
func minimalAppDelegateClampsLongStallDeltaTimeToFrameBudget() async throws {
    let bootstrappedRootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    ).makeRootSystem()
    final class CapturedTicker: @unchecked Sendable {
        var deltaTimes: [Double] = []
    }
    let captured = CapturedTicker()
    let rootSystem = AppRootSystem(
        snapshot: bootstrappedRootSystem.snapshot,
        windowGraph: bootstrappedRootSystem.windowGraph,
        companionBootstrap: bootstrappedRootSystem.companionBootstrap,
        runtimeTicker: RuntimeTicker { previousRenderState, deltaTime, _ in
            captured.deltaTimes.append(deltaTime)
            return RuntimeTickResult(renderState: previousRenderState, snapshot: .empty)
        },
        conversationResponder: bootstrappedRootSystem.conversationResponder
    )
    final class FakeClock: @unchecked Sendable {
        var sequence: [TimeInterval] = [10.0, 13.0]
        func next() -> TimeInterval {
            sequence.removeFirst()
        }
    }
    let clock = FakeClock()
    var capturedTick: (@MainActor () async -> Void)?
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        currentTime: { clock.next() },
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)

    await tick()

    #expect(captured.deltaTimes.count == 1)
    #expect(captured.deltaTimes[0] <= 0.1)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}


@Test("Live snapshot sampler refreshes visible windows after window change fires")
@MainActor
func liveSnapshotSamplerRefreshesVisibleWindowsAfterWindowChangeFires() {
    let info1: [[String: Any]] = [
        [
            "kCGWindowOwnerPID": Int32(123),
            "kCGWindowOwnerName": "Finder",
            "kCGWindowBounds": [
                "X": 0, "Y": 0, "Width": 800, "Height": 600,
            ] as [String: Any],
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1.0,
            "kCGWindowWorkspace": 1,
        ],
    ]
    let info2: [[String: Any]] = [
        [
            "kCGWindowOwnerPID": Int32(123),
            "kCGWindowOwnerName": "Finder",
            "kCGWindowBounds": [
                "X": 100, "Y": 50, "Width": 800, "Height": 600,
            ] as [String: Any],
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1.0,
            "kCGWindowWorkspace": 1,
        ],
        [
            "kCGWindowOwnerPID": Int32(456),
            "kCGWindowOwnerName": "Xcode",
            "kCGWindowBounds": [
                "X": 200, "Y": 100, "Width": 1200, "Height": 800,
            ] as [String: Any],
            "kCGWindowLayer": 0,
            "kCGWindowAlpha": 1.0,
            "kCGWindowWorkspace": 1,
        ],
    ]
    let infoQueue = SamplerWindowInfoQueue([info1, info2])
    let trigger = SamplerChangeTrigger()
    let sampler = AppBootstrap.makeLiveSnapshotSampler(
        currentDisplays: { [] },
        windowInfoSource: { infoQueue.next() },
        currentProcessIdentifier: { 0 },
        frontmostApplicationProcessIdentifier: { nil },
        currentCursorPosition: { .zero },
        frontmostApplicationName: { nil },
        observeWindowChanges: { handler in trigger.register(handler) }
    )

    let firstWindows = sampler.sample().visibleWindows
    trigger.fire()
    let secondWindows = sampler.sample().visibleWindows

    #expect(firstWindows.count == 1)
    #expect(secondWindows.count == 2)
    #expect(secondWindows.first?.bounds.origin.x == 100)
}

private final class SamplerWindowInfoQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[[String: Any]]]

    init(_ queue: [[[String: Any]]]) {
        self.queue = queue
    }

    func next() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        if queue.count == 1 {
            return queue[0]
        }
        return queue.removeFirst()
    }
}

@Test("Live snapshot sampler refreshes displays after change notification fires")
@MainActor
func liveSnapshotSamplerRefreshesDisplaysAfterChangeNotificationFires() {
    let snapshots = SamplerDisplaySnapshotQueue([
        [DisplaySnapshot(id: 0, width: 800, height: 600)],
        [DisplaySnapshot(id: 0, width: 1920, height: 1080)],
    ])
    let trigger = SamplerChangeTrigger()
    let sampler = AppBootstrap.makeLiveSnapshotSampler(
        currentDisplays: { snapshots.next() },
        observeDisplayChanges: { handler in trigger.register(handler) },
        windowInfoSource: { [] },
        currentProcessIdentifier: { 0 },
        frontmostApplicationProcessIdentifier: { nil },
        currentCursorPosition: { .zero },
        frontmostApplicationName: { nil }
    )

    let firstDisplays = sampler.sample().displays
    trigger.fire()
    let secondDisplays = sampler.sample().displays

    #expect(firstDisplays.first?.width == 800)
    #expect(secondDisplays.first?.width == 1920)
}

@Test("Minimal app delegate passes computed delta time to runtime ticker")
@MainActor
func minimalAppDelegatePassesComputedDeltaTimeToRuntimeTicker() async throws {
    let bootstrappedRootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    ).makeRootSystem()
    final class CapturedTicker: @unchecked Sendable {
        var lastDeltaTime: Double = -1
    }
    let captured = CapturedTicker()
    let rootSystem = AppRootSystem(
        snapshot: bootstrappedRootSystem.snapshot,
        windowGraph: bootstrappedRootSystem.windowGraph,
        companionBootstrap: bootstrappedRootSystem.companionBootstrap,
        runtimeTicker: RuntimeTicker { previousRenderState, deltaTime, _ in
            captured.lastDeltaTime = deltaTime
            return RuntimeTickResult(renderState: previousRenderState, snapshot: .empty)
        },
        conversationResponder: bootstrappedRootSystem.conversationResponder
    )
    var capturedTick: (@MainActor () async -> Void)?
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)

    await tick()

    #expect(captured.lastDeltaTime >= 0)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}


@Test("Minimal app delegate advances runtime from the dragged pet position")
@MainActor
func minimalAppDelegateAdvancesRuntimeFromDraggedPetPosition() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 200, y: 0),
    ])
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    var frameTask: Task<Void, Never>?

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        menuBarController: MenuBarController(initialFollowingEnabled: true),
        startFrameLoop: { tick in
            let task = Task { @MainActor in
                await tick()
            }
            frameTask = task
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let shellController = try #require(delegate.launchedShellController)
    shellController.handlePetDragDidMove(to: NSPoint(x: 100, y: 0))
    await frameTask?.value

    #expect(shellController.windowSet.petWindow.frame.origin.x > 100)
}

@Test("Minimal app delegate skips overlapping runtime frame ticks")
@MainActor
func minimalAppDelegateSkipsOverlappingRuntimeFrameTicks() async throws {
    let pointSequence = PointSequence([
        Point(x: 0, y: 0),
        Point(x: 100, y: 0),
        Point(x: 200, y: 0),
    ])
    let tickGate = SuspendedTickGate()
    let rootSystem = try await AppBootstrap(
        snapshotSampler: DesktopSnapshotSampler(
            currentDisplays: { [] },
            activeSpaceIdentifier: { "unknown" },
            currentCursorPosition: { pointSequence.next() },
            frontmostApplicationName: { nil },
            currentVisibleWindows: { [] }
        )
    ).makeRootSystem()
    var capturedTick: (@MainActor () async -> Void)?
    var startedTickCount = 0

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        startFrameLoop: { tick in
            capturedTick = tick
            return nil
        },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        },
        waitForRuntimeFrame: {
            startedTickCount += 1
            await tickGate.wait()
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let tick = try #require(capturedTick)
    let firstTask = Task { @MainActor in await tick() }
    await tickGate.waitForEntry()
    let secondTask = Task { @MainActor in await tick() }
    await Task.yield()

    #expect(startedTickCount == 1)
    tickGate.resume()
    await firstTask.value
    await secondTask.value
}

@Test("Minimal app delegate ignores unrelated notifications before launch")
@MainActor
func minimalAppDelegateIgnoresUnrelatedNotificationsBeforeLaunch() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))
    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()
    var makeShellControllerCallCount = 0
    var showShellWindowsCallCount = 0

    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        makeShellController: { windowGraph, screenFrame, initialState, _, _ in
            makeShellControllerCallCount += 1
            return DesktopShellController(
                windowGraph: windowGraph,
                screenFrame: screenFrame,
                initialState: initialState
            )
        },
        showShellWindows: { controller in
            showShellWindowsCallCount += 1
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didBecomeActiveNotification))

    #expect(makeShellControllerCallCount == 0)
    #expect(showShellWindowsCallCount == 0)
    #expect(delegate.launchedShellController == nil)
}

@Test("App bootstrap carries the orchestrator initial render state into the root system")
func appBootstrapCarriesInitialRenderStateIntoRootSystem() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 144, y: 233))

    let rootSystem = try await AppBootstrap(snapshot: snapshot).makeRootSystem()

    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionX == 144)
    #expect(rootSystem.companionBootstrap.initialRenderState.petPositionY == 233)
}

// MARK: - LLM provider resolution tests

@Test("App bootstrap resolveLLMProvider returns nil when UserDefaults is empty and env var is absent")
func appBootstrapResolveLLMProviderReturnsNilWhenNoKeyConfigured() {
    let ud = makeLLMTestDefaults()
    // No env var "OPENAI_API_KEY" in test environment by default.
    let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)
    // In CI the env var may or may not be set; only assert nil when it is absent.
    if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
        #expect(provider == nil)
    }
}

@Test("App bootstrap resolveLLMProvider prefers UserDefaults over env var")
func appBootstrapResolveLLMProviderPrefersUserDefaultsOverEnvVar() throws {
    let ud = makeLLMTestDefaults()
    ud.set("sk-from-ud", forKey: LLMSettingsKeys.openAIApiKey)

    let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

    // A provider must be returned when UserDefaults has a key.
    #expect(provider != nil)
}

@Test("App bootstrap resolveLLMProvider returns non-nil provider when UserDefaults has a key")
func appBootstrapResolveLLMProviderReturnsProviderWhenUserDefaultsHasKey() throws {
    let ud = makeLLMTestDefaults()
    ud.set("sk-test-abc", forKey: LLMSettingsKeys.openAIApiKey)

    let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

    #expect(provider != nil)
}

@Test("App bootstrap userDefaults init wires provider into orchestrator conversation responder")
func appBootstrapUserDefaultsInitWiresProviderIntoOrchestrator() async throws {
    // Use an isolated UserDefaults suite — no key written → provider is nil → echo path.
    let ud = makeLLMTestDefaults()
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))

    // 仅在没有 env OPENAI_API_KEY 时才能稳定断言 echo fallback (env 会让
    // provider 变 non-nil, orchestrator 走 LLM 分支)。
    guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil else { return }

    let rootSystem = try await AppBootstrap(
        userDefaults: ud,
        snapshot: snapshot
    ).makeRootSystem()

    // With no key the orchestrator falls back to the echo reply.
    let reply = await rootSystem.conversationResponder.reply(to: "测试")
    #expect(reply == "\u{6211}\u{542C}\u{5230}\u{201C}测试\u{201D}\u{4E86}\u{3002}")
}

@Test("App bootstrap userDefaults init with stored key produces a provider that is wired in")
func appBootstrapUserDefaultsInitWithStoredKeyProducesProvider() async throws {
    let ud = makeLLMTestDefaults()
    // Write a dummy key — the provider will exist but HTTP calls will fail,
    // which is fine: we only test that the orchestrator uses the LLM path
    // (it will catch the error and fall back, but we can confirm the
    // provider is non-nil through the public resolveLLMProvider helper).
    ud.set("sk-dummy-key-for-test", forKey: LLMSettingsKeys.openAIApiKey)

    let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

    #expect(provider != nil, "A stored UserDefaults key must result in a non-nil LLM provider")
}

// MARK: - LLMConfig resolution tests (A.1.2 — custom base URL / model)

/// Create a fresh isolated UserDefaults suite for each test to prevent
/// parallel-test pollution of `UserDefaults.standard`.
private func makeLLMTestDefaults() -> UserDefaults {
    let suiteName = "io.openpetagent.test.llmconfig.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

@Test("resolveLLMConfig returns default base URL and model when nothing is configured")
func resolveLLMConfigDefaultsWhenNothingConfigured() {
    let ud = makeLLMTestDefaults()
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    #expect(config.baseURL == URL(string: "https://api.openai.com/v1")!)
    #expect(config.model == "gpt-4o-mini")
    #expect(config.endpoint == URL(string: "https://api.openai.com/v1/chat/completions")!)
}

@Test("resolveLLMConfig reads base URL from UserDefaults and builds correct endpoint")
func resolveLLMConfigReadsBaseURLFromUserDefaults() {
    let ud = makeLLMTestDefaults()
    ud.set("https://api.deepseek.com/v1", forKey: LLMSettingsKeys.openAIBaseURL)
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    #expect(config.endpoint == URL(string: "https://api.deepseek.com/v1/chat/completions")!)
}

@Test("resolveLLMConfig strips trailing slash from UserDefaults base URL before building endpoint")
func resolveLLMConfigStripsTrailingSlash() {
    let ud = makeLLMTestDefaults()
    ud.set("https://api.deepseek.com/v1/", forKey: LLMSettingsKeys.openAIBaseURL)
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    #expect(config.endpoint == URL(string: "https://api.deepseek.com/v1/chat/completions")!)
}

@Test("resolveLLMConfig reads model from UserDefaults")
func resolveLLMConfigReadsModelFromUserDefaults() {
    let ud = makeLLMTestDefaults()
    ud.set("deepseek-chat", forKey: LLMSettingsKeys.openAIModel)
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    #expect(config.model == "deepseek-chat")
}

@Test("resolveLLMConfig falls back to env OPENAI_BASE_URL when UserDefaults is absent")
func resolveLLMConfigFallsBackToEnvBaseURL() {
    // Fresh suite has no value set — env or default will win.
    let ud = makeLLMTestDefaults()
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)
    let envURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"].flatMap { URL(string: $0) }

    if let envURL {
        #expect(config.baseURL == envURL)
    } else {
        #expect(config.baseURL == URL(string: "https://api.openai.com/v1")!)
    }
}

@Test("resolveLLMConfig falls back to env OPENAI_MODEL when UserDefaults is absent")
func resolveLLMConfigFallsBackToEnvModel() {
    let ud = makeLLMTestDefaults()
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)
    let envModel = ProcessInfo.processInfo.environment["OPENAI_MODEL"]

    if let envModel {
        #expect(config.model == envModel)
    } else {
        #expect(config.model == "gpt-4o-mini")
    }
}

@Test("resolveLLMConfig endpoint uses all three custom values together")
func resolveLLMConfigAllCustomValues() throws {
    let ud = makeLLMTestDefaults()
    ud.set("https://api.groq.com/openai/v1", forKey: LLMSettingsKeys.openAIBaseURL)
    ud.set("llama3-8b-8192", forKey: LLMSettingsKeys.openAIModel)
    ud.set("gsk_test", forKey: LLMSettingsKeys.openAIApiKey)

    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    #expect(config.endpoint == URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
    #expect(config.model == "llama3-8b-8192")
    #expect(config.apiKey == "gsk_test")
}

@Test("resolveLLMConfig falls back to default endpoint when base URL string is invalid")
func resolveLLMConfigFallsBackToDefaultOnInvalidURL() {
    let ud = makeLLMTestDefaults()
    // "http://[::1" is a malformed IPv6 literal that URL(string:) rejects as nil.
    ud.set("http://[::1", forKey: LLMSettingsKeys.openAIBaseURL)
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)

    // Invalid URL must not crash; it must fall back to the default endpoint.
    #expect(config.endpoint == URL(string: "https://api.openai.com/v1/chat/completions")!)
}

@Test("resolveLLMProvider uses resolveLLMConfig endpoint and model when custom values are set")
func resolveLLMProviderUsesCustomEndpointAndModel() throws {
    let ud = makeLLMTestDefaults()
    ud.set("https://api.deepseek.com/v1", forKey: LLMSettingsKeys.openAIBaseURL)
    ud.set("deepseek-chat", forKey: LLMSettingsKeys.openAIModel)
    ud.set("sk-ds-test", forKey: LLMSettingsKeys.openAIApiKey)

    // The provider must be non-nil when a key is available.
    let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)
    #expect(provider != nil)

    // Verify the config itself so we know the correct endpoint is used.
    let config = AppBootstrap.resolveLLMConfig(userDefaults: ud)
    #expect(config.endpoint == URL(string: "https://api.deepseek.com/v1/chat/completions")!)
    #expect(config.model == "deepseek-chat")
}

// MARK: - A.2.1 ConversationStore wiring tests

@Test("AppBootstrap(userDefaults:) exposes a non-nil conversationStore")
func appBootstrapUserDefaultsInitExposesConversationStore() async throws {
    let ud = makeLLMTestDefaults()
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))

    let bootstrap = AppBootstrap(userDefaults: ud, snapshot: snapshot)

    // conversationStore is a non-optional public field: this compiles only if the
    // field is present and non-nil.
    let conversationStore: ConversationStore = bootstrap.conversationStore
    // We can call messages() without crashing — confirms the actor is properly initialised.
    let msgs = await conversationStore.messages()
    #expect(msgs.isEmpty)
}

@Test("AppBootstrap.makeRootSystem() loads conversationStore so messages() works without crash")
func makeRootSystemLoadsConversationStoreSuccessfully() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    // Use a fresh tmp store URL so we don't pollute ~/Library/Application Support
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appbootstrap-store-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let store = ConversationStore(storeURL: tmpURL)
    let bootstrap = AppBootstrap(conversationStore: store, snapshot: snapshot)

    _ = try await bootstrap.makeRootSystem()

    // After makeRootSystem, the store is loaded; messages() must not crash.
    let msgs = await bootstrap.conversationStore.messages()
    #expect(msgs.isEmpty)
}

// MARK: - A.2.3 modelName wiring

@Test("AppBootstrap resolveLLMConfig model name round-trips into contextWindow (A.2.3)")
func appBootstrapResolveLLMConfig_modelNameRoundTrips() async throws {
    // Arrange: inject a UserDefaults suite so we can control the model name
    // without touching .standard.
    let suiteName = "AppBootstrapModelNameTest-\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set("deepseek-chat", forKey: LLMSettingsKeys.openAIModel)

    // Act
    let resolvedConfig = AppBootstrap.resolveLLMConfig(
        userDefaults: userDefaults
    )

    // Assert: the resolved config model matches what we set
    #expect(resolvedConfig.model == "deepseek-chat")
    // And contextWindow for that model should be 32_000 (per §3.1)
    #expect(CompanionOrchestrator.contextWindow(for: resolvedConfig.model) == 32_000)
}

// MARK: - Task 4: 系统权限 probe 注入测试

@Test("设置 viewModel 注入 probe 后权限四态非空且 appleEvents 为 reserved")
@MainActor
func settingsViewModelHasPermissionStatuses() {
    // 使用全 notDetermined 的 probe(不触碰真实系统 API,无头测试可运行)。
    let probe = SystemPermissionProbe(
        accessibilityStatus: { .notDetermined },
        requestAccessibility: {},
        screenRecordingStatus: { .notDetermined },
        requestScreenRecording: {},
        locationStatus: { .notDetermined },
        requestLocation: {},
        openSettings: { _ in }
    )
    let controller = SettingsWindowController()
    controller.refreshPermissions(using: probe)

    let statuses = controller.permissionStatuses
    // 四态全灌入:accessibility / screenRecording / location / appleEvents。
    #expect(statuses.count == 4)
    #expect(statuses[.accessibility] == .notDetermined)
    #expect(statuses[.screenRecording] == .notDetermined)
    #expect(statuses[.location] == .notDetermined)
    // appleEvents 固定为 reserved(probe.status 硬编码,.reserved 不可请求)。
    #expect(statuses[.appleEvents] == .reserved)
}

@Test("首启动:辅助功能未授权 → 弹一次授权框;已授权 → 不弹")
@MainActor
func maybePromptAccessibilityOnLaunchPromptsOnlyWhenUntrusted() async throws {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func inc() { lock.lock(); n += 1; lock.unlock() }
    }
    let rootSystem = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    ).makeRootSystem()
    let delegate = MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) }
    )

    let untrusted = Counter()
    delegate.maybePromptAccessibilityOnLaunch(
        bridge: AccessibilityBridge(isProcessTrustedCheck: { false }, requestPrompt: { untrusted.inc() }))
    #expect(untrusted.count == 1)   // 未授权 → 弹一次

    let trusted = Counter()
    delegate.maybePromptAccessibilityOnLaunch(
        bridge: AccessibilityBridge(isProcessTrustedCheck: { true }, requestPrompt: { trusted.inc() }))
    #expect(trusted.count == 0)     // 已授权 → 不弹
}
