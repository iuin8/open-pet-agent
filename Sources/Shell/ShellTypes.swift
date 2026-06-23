import AppKit

public struct ShellInitialState: Sendable, Equatable {
    public let petPositionX: Double
    public let petPositionY: Double

    public init(petPositionX: Double, petPositionY: Double) {
        self.petPositionX = petPositionX
        self.petPositionY = petPositionY
    }

    public static let `default` = ShellInitialState(petPositionX: 80, petPositionY: 310)
}

public struct ShellWindowSet: Sendable {
    public let overlayWindow: NSWindow
    public let petWindow: NSWindow
    public let chatWindow: NSWindow

    public var allWindows: [NSWindow] {
        [overlayWindow, petWindow, chatWindow]
    }

    public init(
        overlayWindow: NSWindow,
        petWindow: NSWindow,
        chatWindow: NSWindow
    ) {
        self.overlayWindow = overlayWindow
        self.petWindow = petWindow
        self.chatWindow = chatWindow
    }
}

public struct ShellGraphDiagnostics: Sendable, Equatable {
    public enum Issue: Sendable, Equatable {
        case duplicateKind(WindowDescriptor.Kind)
        case missingKind(WindowDescriptor.Kind)
    }

    public let issues: [Issue]

    public init(issues: [Issue] = []) {
        self.issues = issues
    }
}

public enum ShellInteractionEvent: Sendable, Equatable {
    case petDrag(positionX: Double, positionY: Double)
    case petRelease(positionX: Double, positionY: Double)
    case snowToggleRequested
}
