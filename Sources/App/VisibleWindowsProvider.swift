import Context
import CoreGraphics
import Foundation

struct VisibleWindowsProvider: Sendable {
    typealias WindowInfoSource = @Sendable () -> [[String: Any]]
    typealias CurrentProcessIdentifier = @Sendable () -> Int32

    private let windowInfoSource: WindowInfoSource
    private let currentProcessIdentifier: CurrentProcessIdentifier

    init(
        windowInfoSource: @escaping WindowInfoSource = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        },
        currentProcessIdentifier: @escaping CurrentProcessIdentifier = {
            ProcessInfo.processInfo.processIdentifier
        }
    ) {
        self.windowInfoSource = windowInfoSource
        self.currentProcessIdentifier = currentProcessIdentifier
    }

    func current() -> [VisibleWindowSnapshot] {
        let myPID = currentProcessIdentifier()

        return windowInfoSource().compactMap { windowInfo in
            guard
                let pid = Self.int32Value(forKey: kCGWindowOwnerPID as String, in: windowInfo),
                let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                let layer = Self.intValue(forKey: kCGWindowLayer as String, in: windowInfo),
                let alpha = Self.doubleValue(forKey: kCGWindowAlpha as String, in: windowInfo),
                let bounds = Self.rectValue(forKey: kCGWindowBounds as String, in: windowInfo),
                pid != myPID,
                layer == 0,
                alpha >= 0.05
            else {
                return nil
            }

            // 窗口标题（kCGWindowName，需屏幕录制权限）。空串归 nil。
            let rawTitle = windowInfo[kCGWindowName as String] as? String
            let title = (rawTitle?.isEmpty == false) ? rawTitle : nil

            return VisibleWindowSnapshot(
                ownerName: ownerName,
                bounds: bounds,
                workspace: Self.intValue(forKey: "kCGWindowWorkspace", in: windowInfo),
                title: title
            )
        }
    }

    private static func rectValue(forKey key: String, in windowInfo: [String: Any]) -> Rect? {
        guard
            let bounds = windowInfo[key] as? [String: Any],
            let x = doubleValue(forKey: "X", in: bounds),
            let y = doubleValue(forKey: "Y", in: bounds),
            let width = doubleValue(forKey: "Width", in: bounds),
            let height = doubleValue(forKey: "Height", in: bounds)
        else {
            return nil
        }

        return Rect(origin: Point(x: x, y: y), width: width, height: height)
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
