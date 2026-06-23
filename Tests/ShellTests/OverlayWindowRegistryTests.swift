import AppKit
import Testing
@testable import Shell

// MARK: - Mock helpers

/// Creates a minimal NSScreen-like test double.
/// Real NSScreen cannot be instantiated in tests, so we use a factory closure
/// that the registry calls to build each overlay window, injected at init time.
/// The registry's own init takes `makeOverlay: @escaping @MainActor (NSScreen) -> NSWindow`,
/// which we can swap for a factory that doesn't touch NSScreen at all.

@MainActor
private func makeWindow(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) -> NSWindow {
    let w = NSWindow(
        contentRect: frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    w.isReleasedWhenClosed = false
    return w
}

// A fake NSScreen stand-in — we can't subclass NSScreen, but OverlayWindowRegistry
// only needs `screen.deviceDescription` and `screen.visibleFrame` at add time.
// We exercise the registry through the `makeOverlay` closure injection path so
// NSScreen is never called in tests; screens are only used as dictionary keys.

@MainActor
final class OverlayWindowRegistryTests {
    // Nothing — tests are free functions below (Swift Testing style).
}

// MARK: - Tests

@Test("Registry is empty after init")
@MainActor
func registryIsEmptyAfterInit() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }
    #expect(registry.overlays.isEmpty)
}

@Test("sync with one display ID produces one overlay entry")
@MainActor
func syncOneEntryProducesOneOverlay() {
    var callCount = 0
    let registry = OverlayWindowRegistry { _ in
        callCount += 1
        return makeWindow()
    }

    let displayID: CGDirectDisplayID = 100
    registry.sync(displayIDs: [displayID], screenFrameProvider: { _ in
        NSRect(x: 0, y: 0, width: 1440, height: 900)
    })

    #expect(registry.overlays.count == 1)
    #expect(registry.overlays[displayID] != nil)
    #expect(callCount == 1)
}

@Test("sync with two display IDs produces two overlay entries")
@MainActor
func syncTwoEntriesProducesTwoOverlays() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }

    registry.sync(displayIDs: [1, 2], screenFrameProvider: { _ in
        NSRect(x: 0, y: 0, width: 1920, height: 1080)
    })

    #expect(registry.overlays.count == 2)
    #expect(registry.overlays[1] != nil)
    #expect(registry.overlays[2] != nil)
}

@Test("sync with same display IDs twice does not rebuild overlays (idempotent)")
@MainActor
func syncSameInputTwiceDoesNotRebuildOverlays() {
    var callCount = 0
    let registry = OverlayWindowRegistry { _ in
        callCount += 1
        return makeWindow()
    }

    registry.sync(displayIDs: [42], screenFrameProvider: { _ in NSRect.zero })
    let firstWindow = registry.overlays[42]

    registry.sync(displayIDs: [42], screenFrameProvider: { _ in NSRect.zero })
    let secondWindow = registry.overlays[42]

    #expect(callCount == 1, "makeOverlay must only be called once for the same displayID")
    #expect(firstWindow === secondWindow, "Same NSWindow instance must be reused")
}

@Test("sync removing a screen reduces overlay count and triggers onWillRemove")
@MainActor
func syncRemovingScreenTriggersOnWillRemove() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }

    registry.sync(displayIDs: [1, 2, 3], screenFrameProvider: { _ in NSRect.zero })
    #expect(registry.overlays.count == 3)

    var removedIDs: [CGDirectDisplayID] = []
    registry.onWillRemove = { id, _ in
        removedIDs.append(id)
    }

    registry.sync(displayIDs: [1], screenFrameProvider: { _ in NSRect.zero })

    #expect(registry.overlays.count == 1)
    #expect(removedIDs.sorted() == [2, 3])
}

@Test("sync adding a screen triggers onDidAdd")
@MainActor
func syncAddingScreenTriggersOnDidAdd() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }

    registry.sync(displayIDs: [10], screenFrameProvider: { _ in NSRect.zero })

    var addedIDs: [CGDirectDisplayID] = []
    registry.onDidAdd = { id, _ in
        addedIDs.append(id)
    }

    registry.sync(displayIDs: [10, 20], screenFrameProvider: { _ in NSRect.zero })

    #expect(addedIDs == [20])
}

@Test("sync reordering display IDs without change triggers no add or remove")
@MainActor
func syncReorderingDoesNotTriggerCallbacks() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }

    registry.sync(displayIDs: [1, 2, 3], screenFrameProvider: { _ in NSRect.zero })

    var addCount = 0
    var removeCount = 0
    registry.onDidAdd = { _, _ in addCount += 1 }
    registry.onWillRemove = { _, _ in removeCount += 1 }

    // Same set, different order
    registry.sync(displayIDs: [3, 1, 2], screenFrameProvider: { _ in NSRect.zero })

    #expect(addCount == 0)
    #expect(removeCount == 0)
    #expect(registry.overlays.count == 3)
}

@Test("onWillRemove being nil does not crash when a screen is removed")
@MainActor
func onWillRemoveNilDoesNotCrash() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }
    registry.onWillRemove = nil

    registry.sync(displayIDs: [7, 8], screenFrameProvider: { _ in NSRect.zero })
    // Remove one — should not crash even though callback is nil
    registry.sync(displayIDs: [7], screenFrameProvider: { _ in NSRect.zero })

    #expect(registry.overlays.count == 1)
}

@Test("onDidAdd being nil does not crash when a screen is added")
@MainActor
func onDidAddNilDoesNotCrash() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }
    registry.onDidAdd = nil

    registry.sync(displayIDs: [5], screenFrameProvider: { _ in NSRect.zero })
    // Add one — should not crash even though callback is nil
    registry.sync(displayIDs: [5, 6], screenFrameProvider: { _ in NSRect.zero })

    #expect(registry.overlays.count == 2)
}

@Test("makeOverlay receives a distinct call per unique display ID")
@MainActor
func makeOverlayReceivesDistinctCallPerDisplayID() {
    var receivedFrames: [NSRect] = []
    let frames: [CGDirectDisplayID: NSRect] = [
        1: NSRect(x: 0, y: 0, width: 1440, height: 900),
        2: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
    ]
    let registry = OverlayWindowRegistry { _ in
        makeWindow()
    }

    registry.sync(displayIDs: [1, 2], screenFrameProvider: { id in
        receivedFrames.append(frames[id] ?? .zero)
        return frames[id] ?? .zero
    })

    #expect(receivedFrames.count == 2)
}

@Test("multiple idempotent syncs remain consistent under repeated identical input")
@MainActor
func repeatedIdempotentSyncsRemainConsistent() {
    var callCount = 0
    let registry = OverlayWindowRegistry { _ in
        callCount += 1
        return makeWindow()
    }

    for _ in 0..<5 {
        registry.sync(displayIDs: [100, 200], screenFrameProvider: { _ in NSRect.zero })
    }

    #expect(callCount == 2, "Only 2 unique displayIDs — makeOverlay must be called exactly once each")
    #expect(registry.overlays.count == 2)
}

@Test("current() returns same dictionary as overlays property")
@MainActor
func currentReturnsSameAsDictionaryProperty() {
    let registry = OverlayWindowRegistry { _ in makeWindow() }
    registry.sync(displayIDs: [11, 22], screenFrameProvider: { _ in NSRect.zero })

    let via_current = registry.current()
    let via_property = registry.overlays

    #expect(via_current.keys.sorted() == via_property.keys.sorted())
}
