import AppKit

/// Companion overlay/window defaults that must stay below the macOS menu bar.
///
/// Ordinary pet, snow, chat, and side-card surfaces use `.floating` so they sit
/// above app windows but below `.mainMenu` / `.statusBar`. System-embedded
/// surfaces such as Dynamic Island intentionally do not use this policy.
public enum ShellWindowPolicy {
    public static let passiveCompanionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle,
    ]

    public static let activeCompanionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
    ]

    public static let transientCompanionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .transient,
    ]

    @MainActor
    public static func applyCompanionOverlayStyle(
        to window: NSWindow,
        title: String? = nil,
        interactive: Bool,
        behavior: NSWindow.CollectionBehavior? = nil,
        hasShadow: Bool = false
    ) {
        if let title { window.title = title }
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.collectionBehavior = behavior ?? activeCompanionBehavior
        window.ignoresMouseEvents = !interactive
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = hasShadow
    }

    public static func clamp(_ frame: NSRect, inside visibleFrame: NSRect, margin: CGFloat = 0) -> NSRect {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - frame.width - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - frame.height - margin
        return NSRect(
            x: clamp(frame.origin.x, min: minX, max: maxX),
            y: clamp(frame.origin.y, min: minY, max: maxY),
            width: frame.width,
            height: frame.height
        )
    }

    public static func clamp(_ origin: NSPoint, size: NSSize, inside visibleFrame: NSRect, margin: CGFloat = 0) -> NSPoint {
        clamp(NSRect(origin: origin, size: size), inside: visibleFrame, margin: margin).origin
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard max > min else { return min }
        return Swift.min(Swift.max(value, min), max)
    }
}
