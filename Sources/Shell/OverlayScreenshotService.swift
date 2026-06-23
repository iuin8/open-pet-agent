import AppKit

/// Captures the OpenPetAgent overlay window into an NSImage and presents
/// the system sharing panel so the user can share it via Mail, Messages,
/// AirDrop, Copy, etc.
///
/// Design notes:
/// - Uses `NSView.bitmapImageRepForCachingDisplay` + `cacheDisplay` rather
///   than `CALayer.render(in:)`. The overlay's content view hosts a
///   `CAMetalLayer`; `cacheDisplay` asks AppKit to composite the layer tree
///   (including GPU-rendered Metal content) into a bitmap, which gives a
///   more stable result than driving the Core Graphics render path directly.
/// - `NSSharingServicePicker` is injected via a closure so tests can mock
///   the presenter without ever showing a real share sheet.
/// - All methods are `@MainActor` because NSWindow/NSView are main-thread
///   only in Swift 6 strict-concurrency mode.
@MainActor
public final class OverlayScreenshotService {

    /// Injectable presenter: receives the captured image and an anchor view
    /// (used to position the NSSharingServicePicker popover). The default
    /// implementation shows the native share panel anchored to the supplied
    /// view.
    public var sharingServicePresenter: @MainActor (NSImage, NSView) -> Void

    public init(
        sharingServicePresenter: (@MainActor (NSImage, NSView) -> Void)? = nil
    ) {
        self.sharingServicePresenter = sharingServicePresenter ?? { image, anchor in
            let picker = NSSharingServicePicker(items: [image])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    // MARK: - Public API

    /// Captures the overlay window's content view into an NSImage.
    ///
    /// Returns `nil` if:
    /// - `window.contentView` is nil
    /// - the content view's bounds have zero width or height
    public func captureOverlay(window: NSWindow) -> NSImage? {
        guard let contentView = window.contentView else {
            return nil
        }

        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        // Ensure the view is layer-backed before requesting a bitmap cache.
        contentView.wantsLayer = true

        guard
            let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return nil
        }

        contentView.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Captures the overlay window and immediately presents the system
    /// sharing panel anchored to `anchorView`.
    ///
    /// If the window has no content view or capture fails, this is a no-op
    /// (no share panel is shown, no error is surfaced to the user).
    public func captureAndShare(window: NSWindow, anchorView: NSView) {
        guard let image = captureOverlay(window: window) else {
            return
        }
        sharingServicePresenter(image, anchorView)
    }
}
