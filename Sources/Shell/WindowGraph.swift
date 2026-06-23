public struct WindowDescriptor: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case overlay
        case pet
        case chat
    }

    public let kind: Kind
    public let isInteractive: Bool
    public let level: Int

    public init(kind: Kind, isInteractive: Bool, level: Int) {
        self.kind = kind
        self.isInteractive = isInteractive
        self.level = level
    }
}

public struct WindowGraph: Sendable, Equatable {
    public let windows: [WindowDescriptor]

    public init(windows: [WindowDescriptor]) {
        self.windows = windows
    }

    public static let bootstrap = WindowGraph(
        windows: [
            WindowDescriptor(kind: .overlay, isInteractive: false, level: 0),
            WindowDescriptor(kind: .pet, isInteractive: true, level: 1),
            WindowDescriptor(kind: .chat, isInteractive: true, level: 2)
        ]
    )
}
