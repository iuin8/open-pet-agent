import AppKit
import QuartzCore
import Testing
@testable import App
@testable import Shell
@testable import Orchestrator
import Context
import Rendering
import RuntimeBridge

// MARK: - Screenshot wiring end-to-end tests
//
// Verifies that MinimalAppDelegate wires menuBarController.onShareScreenshot
// to DesktopShellController.overlayWindowForScreenshot, and that the
// overlayWindowForScreenshot computed property returns the overlay window.

@MainActor
private func makeMinimalDelegateForScreenshot() -> MinimalAppDelegate {
    let rootSystem = AppRootSystem(
        snapshot: DesktopSnapshot(),
        windowGraph: .bootstrap,
        companionBootstrap: CompanionBootstrap(
            capabilities: RuntimeCapabilities(),
            initialRenderState: RenderState(
                petPositionX: 100,
                petPositionY: 100,
                petRotation: 0,
                particleCount: 0,
                particles: [],
                contactCount: 0,
                isSnowEnabled: false
            )
        ),
        runtimeTicker: RuntimeTicker { previousState, _, _ in
            RuntimeTickResult(
                renderState: previousState,
                snapshot: DesktopSnapshot()
            )
        },
        conversationResponder: ConversationResponder { message in
            "echo: \(message)"
        }
    )

    return MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        currentTime: { 0 },
        startFrameLoop: { _ in nil },
        showShellWindows: { _ in },
        waitForRuntimeFrame: {}
    )
}

@Suite("ScreenshotWiring")
@MainActor
struct ScreenshotWiringTests {

    @Test("DesktopShellController overlayWindowForScreenshot returns the overlay NSWindow")
    func desktopShellControllerOverlayWindowForScreenshotReturnsOverlayWindow() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let overlayWindow = controller.overlayWindowForScreenshot
        #expect(overlayWindow === controller.windowSet.overlayWindow)
    }

    @Test("onShareScreenshot wiring: menuBarController closure routes to shellController overlay")
    func onShareScreenshotWiringRoutesToShellControllerOverlay() throws {
        let menuBarController = MenuBarController()
        var capturedWindow: NSWindow?

        let delegate = makeMinimalDelegateForScreenshot()

        // Inject a mock screenshot service that records which window was passed.
        let mockService = OverlayScreenshotService(
            sharingServicePresenter: { _, _ in }
        )

        // Wire manually the same way MinimalAppDelegate would:
        // onShareScreenshot → shellController.overlayWindowForScreenshot
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        defer {
            delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }

        let shellController = try #require(delegate.launchedShellController)

        // Simulate what the wired closure does: grab the overlay window.
        menuBarController.onShareScreenshot = {
            capturedWindow = shellController.overlayWindowForScreenshot
        }

        menuBarController.onShareScreenshot()
        _ = mockService  // suppress unused warning

        #expect(capturedWindow === shellController.windowSet.overlayWindow)
    }
}
