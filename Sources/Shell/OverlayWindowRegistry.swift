import AppKit

/// Manages the collection of overlay NSWindows, one per connected display.
///
/// All state is confined to @MainActor. `sync(displayIDs:screenFrameProvider:)`
/// is idempotent: calling it multiple times with the same set of display IDs
/// produces no observable change (no reallocation, no callback firing).
@MainActor
public final class OverlayWindowRegistry {
    // MARK: - Public state

    /// Current overlay windows keyed by CGDirectDisplayID.
    public private(set) var overlays: [CGDirectDisplayID: NSWindow] = [:]

    /// Screen frames (global NSScreen bottom-origin coordinates) for each
    /// registered display. Stores `NSScreen.visibleFrame` — i.e. without the
    /// menu bar / Dock. Used to construct the overlay window and the GPU
    /// `worldSize` (snow falls inside this region).
    public var screenFrames: [CGDirectDisplayID: NSRect] = [:]

    /// Full screen frames (`NSScreen.frame`, **including** the menu bar) for
    /// each registered display.
    ///
    /// Why we store this separately: CGWindow bounds use a top-origin global
    /// coordinate system whose y=0 sits at the *physical* top of the main
    /// display — i.e. the top of the menu bar. To convert a CGWindow y to a
    /// runtime bottom-origin y we must flip against the **full** screen
    /// height, not the visible frame. Using the visible frame height instead
    /// puts collision rects ~24 px low (the menu-bar height), letting snow
    /// fall right through window tops. See `MinimalAppDelegate+GPUSnowTick`
    /// for the actual y-flip math.
    public var fullScreenFrames: [CGDirectDisplayID: NSRect] = [:]

    /// Called synchronously before a window is removed from the registry.
    /// Receive the display ID and the window being retired.
    public var onWillRemove: (@MainActor (CGDirectDisplayID, NSWindow) -> Void)?

    /// Called synchronously after a new window has been added to the registry.
    public var onDidAdd: (@MainActor (CGDirectDisplayID, NSWindow) -> Void)?

    // MARK: - Private state

    private let makeOverlay: @MainActor (NSRect) -> NSWindow

    // MARK: - Init

    /// - Parameters:
    ///   - makeOverlay: Factory receiving the screen's visible frame.
    ///     Called exactly once per unique `CGDirectDisplayID`.
    public init(
        makeOverlay: @escaping @MainActor (NSRect) -> NSWindow
    ) {
        self.makeOverlay = makeOverlay
    }

    // MARK: - Named factory for the live NSScreen path

    /// Creates a registry using a per-screen factory.
    public static func live(
        makeOverlay: @escaping @MainActor (NSScreen) -> NSWindow
    ) -> OverlayWindowRegistry {
        OverlayWindowRegistry { frame in
            let w = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            ShellWindowPolicy.applyCompanionOverlayStyle(
                to: w,
                interactive: false,
                behavior: ShellWindowPolicy.passiveCompanionBehavior
            )
            return w
        }
    }

    // MARK: - Sync (primary API — display-ID based, test-friendly)

    /// Idempotent sync against a set of `CGDirectDisplayID` values.
    ///
    /// - Parameters:
    ///   - displayIDs: The currently connected display IDs.
    ///   - screenFrameProvider: Called once per *new* display ID to obtain the
    ///     frame used to construct the overlay window and coordinator.
    ///     Not called for IDs that are already registered.
    public func sync(
        displayIDs: [CGDirectDisplayID],
        screenFrameProvider: @MainActor (CGDirectDisplayID) -> NSRect
    ) {
        let current = Set(overlays.keys)
        let next = Set(displayIDs)

        let added = next.subtracting(current)
        let removed = current.subtracting(next)

        for id in removed {
            guard let window = overlays[id] else { continue }
            onWillRemove?(id, window)
            window.orderOut(nil)
            overlays.removeValue(forKey: id)
            screenFrames.removeValue(forKey: id)
            fullScreenFrames.removeValue(forKey: id)
        }

        for id in added {
            let frame = screenFrameProvider(id)
            let window = makeOverlay(frame)
            overlays[id] = window
            screenFrames[id] = frame
            onDidAdd?(id, window)
        }
    }

    // MARK: - Sync (live NSScreen path)

    /// Syncs against the current `[NSScreen]` array.
    /// Extracts `CGDirectDisplayID` from each screen's `deviceDescription`
    /// and falls back to a sequential index when the key is absent.
    ///
    /// Populates both `screenFrames` (visibleFrame — overlay region) and
    /// `fullScreenFrames` (full NSScreen.frame including menu bar — needed
    /// for CGWindow → overlay coordinate flips).
    public func sync(screens: [NSScreen]) {
        var visibleMap: [CGDirectDisplayID: NSRect] = [:]
        var fullMap: [CGDirectDisplayID: NSRect] = [:]
        var ids: [CGDirectDisplayID] = []
        for (index, screen) in screens.enumerated() {
            let id = screen.displayID ?? CGDirectDisplayID(index)
            visibleMap[id] = screen.visibleFrame
            fullMap[id] = screen.frame
            ids.append(id)
        }

        sync(displayIDs: ids, screenFrameProvider: { id in
            visibleMap[id] ?? .zero
        })

        // Mirror the full screen frames so the per-frame tick can flip
        // CGWindow.y against the physical screen height (incl. menu bar)
        // rather than the visible-frame height.
        fullScreenFrames = fullMap
    }

    // MARK: - Accessor

    /// Returns the current overlays dictionary. Equivalent to reading `overlays`.
    public func current() -> [CGDirectDisplayID: NSWindow] {
        overlays
    }
}

// MARK: - NSScreen + CGDirectDisplayID helper

extension NSScreen {
    /// Extracts the `CGDirectDisplayID` from the screen's `deviceDescription`.
    /// Returns `nil` when the key is absent (e.g. in headless / test environments).
    public var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
