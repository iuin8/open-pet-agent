import AppKit
import Foundation
import Testing
@testable import App
import Context
import Shell

// MARK: - Helpers

@MainActor
private func makeDelegate(
    screens: [CGDirectDisplayID] = [1],
    screenFrame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600),
    rootSystem: AppRootSystem
) -> MinimalAppDelegate {
    MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { screenFrame },
        currentDisplayIDs: { screens },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )
}

// MARK: - Tests

@Test("Registry is populated after applicationDidFinishLaunching with one display")
@MainActor
func registryContainsOneOverlayAfterLaunchWithOneDisplay() async throws {
    let system = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: .zero)
    ).makeRootSystem()
    let delegate = makeDelegate(screens: [42], rootSystem: system)

    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    let registry = try #require(delegate.overlayRegistry)
    #expect(registry.overlays.count == 1)
    #expect(registry.overlays[42] != nil)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Registry is populated after applicationDidFinishLaunching with two displays")
@MainActor
func registryContainsTwoOverlaysAfterLaunchWithTwoDisplays() async throws {
    let system = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: .zero)
    ).makeRootSystem()
    let delegate = makeDelegate(screens: [10, 20], rootSystem: system)

    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    let registry = try #require(delegate.overlayRegistry)
    #expect(registry.overlays.count == 2)
    #expect(registry.overlays[10] != nil)
    #expect(registry.overlays[20] != nil)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("didChangeScreenParameters notification triggers registry sync")
@MainActor
func screenParametersChangeNotificationTriggersRegistrySync() async throws {
    // Start with one display, later add a second one.
    final class DisplayIDs: @unchecked Sendable {
        var ids: [CGDirectDisplayID] = [100]
    }
    let state = DisplayIDs()

    let system = try await AppBootstrap(
        snapshot: DesktopSnapshot(cursorPosition: .zero)
    ).makeRootSystem()

    let delegate = MinimalAppDelegate(
        rootSystem: system,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        currentDisplayIDs: { state.ids },
        showShellWindows: { controller in
            controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        }
    )

    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    let registry = try #require(delegate.overlayRegistry)
    #expect(registry.overlays.count == 1)

    // Simulate a second display being plugged in.
    state.ids = [100, 200]
    NotificationCenter.default.post(
        name: NSApplication.didChangeScreenParametersNotification,
        object: nil
    )

    #expect(registry.overlays.count == 2)

    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil) }
}
