import AppKit
import CoreGraphics
import Foundation

struct ActiveSpaceIdentifierProvider: Sendable {
    typealias WindowInfoSource = @Sendable () -> [[String: Any]]
    typealias CurrentProcessIdentifier = @Sendable () -> Int32
    typealias FrontmostApplicationProcessIdentifier = @Sendable () -> Int32?

    private let windowInfoSource: WindowInfoSource
    private let currentProcessIdentifier: CurrentProcessIdentifier
    private let frontmostApplicationProcessIdentifier: FrontmostApplicationProcessIdentifier

    init(
        windowInfoSource: @escaping WindowInfoSource = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        },
        currentProcessIdentifier: @escaping CurrentProcessIdentifier = {
            ProcessInfo.processInfo.processIdentifier
        },
        frontmostApplicationProcessIdentifier: @escaping FrontmostApplicationProcessIdentifier = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.windowInfoSource = windowInfoSource
        self.currentProcessIdentifier = currentProcessIdentifier
        self.frontmostApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
    }

    func current() -> String {
        let myPID = currentProcessIdentifier()
        let eligibleWindows: [(pid: Int32, workspace: Int)] = windowInfoSource().compactMap { windowInfo in
            guard
                let pid = Self.int32Value(forKey: kCGWindowOwnerPID as String, in: windowInfo),
                let layer = Self.intValue(forKey: kCGWindowLayer as String, in: windowInfo),
                let alpha = Self.doubleValue(forKey: kCGWindowAlpha as String, in: windowInfo),
                let workspace = Self.intValue(forKey: "kCGWindowWorkspace", in: windowInfo),
                pid != myPID,
                layer == 0,
                alpha >= 0.05
            else {
                return nil
            }

            return (pid, workspace)
        }

        if
            let frontmostPID = frontmostApplicationProcessIdentifier(),
            let frontmostWindow = eligibleWindows.first(where: { $0.pid == frontmostPID })
        {
            return "space-\(frontmostWindow.workspace)"
        }

        if let firstEligibleWindow = eligibleWindows.first {
            return "space-\(firstEligibleWindow.workspace)"
        }

        return "unknown"
    }

    private static func int32Value(forKey key: String, in windowInfo: [String: Any]) -> Int32? {
        if let value = windowInfo[key] as? Int32 {
            value
        } else if let value = windowInfo[key] as? NSNumber {
            value.int32Value
        } else if let value = windowInfo[key] as? Int {
            Int32(value)
        } else {
            nil
        }
    }

    private static func intValue(forKey key: String, in windowInfo: [String: Any]) -> Int? {
        if let value = windowInfo[key] as? Int {
            value
        } else if let value = windowInfo[key] as? NSNumber {
            value.intValue
        } else {
            nil
        }
    }

    private static func doubleValue(forKey key: String, in windowInfo: [String: Any]) -> Double? {
        if let value = windowInfo[key] as? Double {
            value
        } else if let value = windowInfo[key] as? NSNumber {
            value.doubleValue
        } else {
            nil
        }
    }
}
