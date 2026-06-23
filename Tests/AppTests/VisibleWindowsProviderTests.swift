import Context
import CoreGraphics
import Foundation
import Testing
@testable import App

@Test("Visible windows provider maps eligible windows into snapshots")
func visibleWindowsProviderMapsEligibleWindowsIntoSnapshots() {
    let provider = VisibleWindowsProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "Xcode",
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 7,
                    kCGWindowBounds as String: [
                        "X": 10.0,
                        "Y": 20.0,
                        "Width": 800.0,
                        "Height": 600.0
                    ]
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    let windows = provider.current()

    #expect(windows == [
        VisibleWindowSnapshot(
            ownerName: "Xcode",
            bounds: Rect(origin: Point(x: 10, y: 20), width: 800, height: 600),
            workspace: 7
        )
    ])
}

@Test("Visible windows provider parses kCGWindowName into title (empty → nil)")
func visibleWindowsProviderParsesWindowTitle() {
    let provider = VisibleWindowsProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "Code",
                    kCGWindowName as String: "FallingSandTuning.swift — pet-agent",
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 800.0, "Height": 600.0]
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "微信",
                    kCGWindowName as String: "",   // 空串 → title nil
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 400.0, "Height": 300.0]
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    let windows = provider.current()
    #expect(windows.count == 2)
    #expect(windows[0].title == "FallingSandTuning.swift — pet-agent")
    #expect(windows[1].title == nil)
}

@Test("Visible windows provider skips own-process windows")
func visibleWindowsProviderSkipsOwnProcessWindows() {
    let provider = VisibleWindowsProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 999,
                    kCGWindowOwnerName as String: "OpenPetAgent",
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 7,
                    kCGWindowBounds as String: [
                        "X": 0.0,
                        "Y": 0.0,
                        "Width": 200.0,
                        "Height": 200.0
                    ]
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current().isEmpty)
}

@Test("Visible windows provider skips non-zero layer and transparent windows")
func visibleWindowsProviderSkipsOverlayAndTransparentWindows() {
    let provider = VisibleWindowsProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "Menubar",
                    kCGWindowLayer as String: 25,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowBounds as String: [
                        "X": 0.0,
                        "Y": 0.0,
                        "Width": 1440.0,
                        "Height": 24.0
                    ]
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "Ghost",
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 0.0,
                    kCGWindowBounds as String: [
                        "X": 100.0,
                        "Y": 100.0,
                        "Width": 400.0,
                        "Height": 300.0
                    ]
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current().isEmpty)
}

@Test("Visible windows provider skips windows without bounds or owner name")
func visibleWindowsProviderSkipsWindowsWithoutBoundsOrOwnerName() {
    let provider = VisibleWindowsProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    kCGWindowBounds as String: [
                        "X": 0.0,
                        "Y": 0.0,
                        "Width": 400.0,
                        "Height": 300.0
                    ]
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowOwnerName as String: "NoBounds",
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current().isEmpty)
}
