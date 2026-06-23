import AppKit
import QuartzCore
import Testing
@testable import Shell

// MARK: - OverlayScreenshotService unit tests
//
// Uses closure injection for the sharing presenter so NSSharingServicePicker
// is never shown during tests. All assertions run on @MainActor to match the
// service's own actor isolation.

@Suite("OverlayScreenshotService")
@MainActor
struct OverlayScreenshotServiceTests {

    // MARK: - captureOverlay happy path

    @Test("captureOverlay returns a non-nil NSImage when contentView has a layer")
    func captureOverlayReturnsImageWhenContentViewHasLayer() {
        let window = makeOpaqueWindow(size: NSSize(width: 200, height: 150))
        defer { window.orderOut(nil) }

        let service = OverlayScreenshotService()
        let image = service.captureOverlay(window: window)

        #expect(image != nil)
    }

    @Test("captureOverlay returns nil when the window has no contentView")
    func captureOverlayReturnsNilWhenNoContentView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = nil

        let service = OverlayScreenshotService()
        let image = service.captureOverlay(window: window)

        #expect(image == nil)
    }

    @Test("captureOverlay returns NSImage whose size matches the contentView bounds")
    func captureOverlaySizeMatchesContentViewBounds() throws {
        let size = NSSize(width: 320, height: 240)
        let window = makeOpaqueWindow(size: size)
        defer { window.orderOut(nil) }

        let service = OverlayScreenshotService()
        let image = try #require(service.captureOverlay(window: window))

        #expect(image.size.width == size.width)
        #expect(image.size.height == size.height)
    }

    @Test("captureOverlay result is PNG-serializable (has at least one representation)")
    func captureOverlayResultHasRepresentations() throws {
        let window = makeOpaqueWindow(size: NSSize(width: 100, height: 100))
        defer { window.orderOut(nil) }

        let service = OverlayScreenshotService()
        let image = try #require(service.captureOverlay(window: window))

        // A valid NSImage produced by bitmap capture always has at least one
        // NSBitmapImageRep — verifying PNG serialization is possible.
        image.lockFocus()
        image.unlockFocus()
        #expect(image.representations.isEmpty == false)
    }

    @Test("captureOverlay sets wantsLayer = true on contentView before capture")
    func captureOverlaySetsWantsLayerOnContentView() throws {
        let window = makeOpaqueWindow(size: NSSize(width: 100, height: 100))
        defer { window.orderOut(nil) }

        // Start with wantsLayer = false to verify the service sets it.
        let contentView = try #require(window.contentView)
        contentView.wantsLayer = false

        let service = OverlayScreenshotService()
        _ = service.captureOverlay(window: window)

        #expect(contentView.wantsLayer)
    }

    @Test("captureOverlay returns nil for a zero-size contentView")
    func captureOverlayReturnsNilForZeroSizeContent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: .zero)

        let service = OverlayScreenshotService()
        let image = service.captureOverlay(window: window)

        #expect(image == nil)
    }

    @Test("captureOverlay returns nil when contentView is present but frame has zero width")
    func captureOverlayReturnsNilForZeroWidthContent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 200))

        let service = OverlayScreenshotService()
        let image = service.captureOverlay(window: window)

        #expect(image == nil)
    }

    @Test("captureOverlay returns nil when contentView frame has zero height")
    func captureOverlayReturnsNilForZeroHeightContent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 0),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 0))

        let service = OverlayScreenshotService()
        let image = service.captureOverlay(window: window)

        #expect(image == nil)
    }

    // MARK: - captureAndShare injection seam

    @Test("captureAndShare invokes the sharing presenter with a non-nil image and non-nil anchor view")
    func captureAndShareInvokesPresenterWithImageAndAnchorView() throws {
        let window = makeOpaqueWindow(size: NSSize(width: 200, height: 150))
        defer { window.orderOut(nil) }

        var capturedImage: NSImage?
        var capturedAnchor: NSView?

        let service = OverlayScreenshotService(
            sharingServicePresenter: { image, anchor in
                capturedImage = image
                capturedAnchor = anchor
            }
        )

        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        service.captureAndShare(window: window, anchorView: anchorView)

        #expect(capturedImage != nil)
        #expect(capturedAnchor != nil)
    }

    @Test("captureAndShare does not invoke the presenter when the window has no contentView")
    func captureAndShareDoesNotInvokePresenterForNilContentView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = nil

        var presenterCalled = false
        let service = OverlayScreenshotService(
            sharingServicePresenter: { _, _ in
                presenterCalled = true
            }
        )

        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        service.captureAndShare(window: window, anchorView: anchorView)

        #expect(presenterCalled == false)
    }

    @Test("captureAndShare passes the exact anchor view supplied by the caller")
    func captureAndSharePassesExactAnchorView() throws {
        let window = makeOpaqueWindow(size: NSSize(width: 200, height: 150))
        defer { window.orderOut(nil) }

        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        var receivedAnchor: NSView?

        let service = OverlayScreenshotService(
            sharingServicePresenter: { _, anchor in
                receivedAnchor = anchor
            }
        )

        service.captureAndShare(window: window, anchorView: anchorView)

        #expect(receivedAnchor === anchorView)
    }

    // MARK: - Helpers

    private func makeOpaqueWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .orange
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.orange.cgColor
        window.contentView = view
        return window
    }
}
