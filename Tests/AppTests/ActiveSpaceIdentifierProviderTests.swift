import CoreGraphics
import Foundation
import Testing
@testable import App

@Test("Active space provider returns the first eligible workspace identifier")
func activeSpaceProviderReturnsTheFirstEligibleWorkspaceIdentifier() {
    let provider = ActiveSpaceIdentifierProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 7
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current() == "space-7")
}

@Test("Active space provider skips ineligible windows until it finds a workspace")
func activeSpaceProviderSkipsIneligibleWindowsUntilItFindsAWorkspace() {
    let provider = ActiveSpaceIdentifierProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 999,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 2
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 3,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 4
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 0.0,
                    "kCGWindowWorkspace": 5
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 8
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current() == "space-8")
}

@Test("Active space provider prefers the frontmost application workspace")
func activeSpaceProviderPrefersTheFrontmostApplicationWorkspace() {
    let provider = ActiveSpaceIdentifierProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 3
                ],
                [
                    kCGWindowOwnerPID as String: 555,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 9
                ]
            ]
        },
        currentProcessIdentifier: { 999 },
        frontmostApplicationProcessIdentifier: { 555 }
    )

    #expect(provider.current() == "space-9")
}

@Test("Active space provider falls back to first eligible window when frontmost is unavailable")
func activeSpaceProviderFallsBackToFirstEligibleWindowWhenFrontmostIsUnavailable() {
    let provider = ActiveSpaceIdentifierProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 3
                ],
                [
                    kCGWindowOwnerPID as String: 555,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 9
                ]
            ]
        },
        currentProcessIdentifier: { 999 },
        frontmostApplicationProcessIdentifier: { nil }
    )

    #expect(provider.current() == "space-3")
}

@Test("Active space provider falls back to unknown when no eligible workspace exists")
func activeSpaceProviderFallsBackToUnknownWhenNoEligibleWorkspaceExists() {
    let provider = ActiveSpaceIdentifierProvider(
        windowInfoSource: {
            [
                [
                    kCGWindowOwnerPID as String: 999,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0,
                    "kCGWindowWorkspace": 2
                ],
                [
                    kCGWindowOwnerPID as String: 777,
                    kCGWindowLayer as String: 0,
                    kCGWindowAlpha as String: 1.0
                ]
            ]
        },
        currentProcessIdentifier: { 999 }
    )

    #expect(provider.current() == "unknown")
}
