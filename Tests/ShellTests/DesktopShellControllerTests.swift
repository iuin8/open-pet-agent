import AppKit
import Context
import Foundation
import Rendering
import RuntimeBridge
import Testing
@testable import Shell

private final class AccessibilityPromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

@Test("Desktop shell controller creates three windows; pet visible, legacy chat hidden by default")
@MainActor
func desktopShellControllerCreatesVisiblePetAndChatShells() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )

    let windowSet = controller.windowSet

    #expect(windowSet.allWindows.count == 3)
    #expect(controller.diagnostics.issues.isEmpty)
    #expect(windowSet.overlayWindow.ignoresMouseEvents)
    #expect(windowSet.petWindow.title == "OpenPetAgent Pet")
    #expect(windowSet.chatWindow.title == "OpenPetAgent Chat")
    #expect(windowSet.overlayWindow.isReleasedWhenClosed == false)
    #expect(windowSet.petWindow.isReleasedWhenClosed == false)
    #expect(windowSet.chatWindow.isReleasedWhenClosed == false)

    controller.showInitialWindows()

    #expect(windowSet.petWindow.isVisible)
    // Legacy chatWindow is dead code — Stage is the default chat surface.
    // showInitialWindows must not order the chat panel front. The panel
    // is still instantiated (so the contentView wire in MinimalAppDelegate
    // still works) but stays hidden unless pet 右键 "显示聊天" summons it.
    #expect(windowSet.chatWindow.isVisible == false)

    windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("showInitialWindows keeps the legacy chatWindow hidden (regression for soft-delete)")
@MainActor
func showInitialWindowsKeepsLegacyChatHidden() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )

    // Sanity precondition: before showInitialWindows nothing is visible.
    #expect(controller.windowSet.chatWindow.isVisible == false)

    controller.showInitialWindows()

    #expect(controller.windowSet.chatWindow.isVisible == false)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller records duplicate window kinds instead of trapping")
@MainActor
func desktopShellControllerRecordsDuplicateWindowKinds() {
    let windowGraph = WindowGraph(
        windows: [
            WindowDescriptor(kind: .overlay, isInteractive: false, level: 0),
            WindowDescriptor(kind: .pet, isInteractive: true, level: 1),
            WindowDescriptor(kind: .pet, isInteractive: false, level: 99),
            WindowDescriptor(kind: .chat, isInteractive: true, level: 2)
        ]
    )

    let controller = DesktopShellController(
        windowGraph: windowGraph,
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )

    #expect(controller.diagnostics.issues == [.duplicateKind(.pet)])
    #expect(controller.windowSet.petWindow.ignoresMouseEvents == false)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller reports missing window kinds when it fills defaults")
@MainActor
func desktopShellControllerReportsMissingWindowKinds() {
    let windowGraph = WindowGraph(
        windows: [
            WindowDescriptor(kind: .overlay, isInteractive: false, level: 0)
        ]
    )

    let controller = DesktopShellController(
        windowGraph: windowGraph,
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )

    #expect(controller.diagnostics.issues == [.missingKind(.pet), .missingKind(.chat)])
    #expect(controller.windowSet.allWindows.count == 3)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller uses the provided initial pet position")
@MainActor
func desktopShellControllerUsesProvidedInitialPetPosition() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    #expect(controller.windowSet.petWindow.frame.origin.x == 144)
    #expect(controller.windowSet.petWindow.frame.origin.y == 233)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller anchors the chat window to the initial pet position")
@MainActor
func desktopShellControllerAnchorsChatWindowToInitialPetPosition() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    let petFrame = controller.windowSet.petWindow.frame
    let chatFrame = controller.windowSet.chatWindow.frame

    // The bubble visual is what the user perceives — the window itself
    // extends `shadowMargin` past the bubble on each side so the layer
    // shadow has room to render. Assert against the visual edge.
    #expect(chatFrame.minX + ChatBubbleTheme.shadowMargin == petFrame.maxX + 40)
    #expect(chatFrame.midY == petFrame.midY)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller records pet drag and release interaction events")
@MainActor
func desktopShellControllerRecordsPetDragAndReleaseInteractionEvents() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    controller.recordPetDrag(to: NSPoint(x: 210, y: 260))
    controller.recordPetRelease(at: NSPoint(x: 230, y: 280))

    #expect(
        controller.interactionEvents == [
            .petDrag(positionX: 210, positionY: 260),
            .petRelease(positionX: 230, positionY: 280)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller emits pet interaction events through the injected sink")
@MainActor
func desktopShellControllerEmitsPetInteractionEventsThroughInjectedSink() {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )

    controller.recordPetDrag(to: NSPoint(x: 210, y: 260))
    controller.recordPetRelease(at: NSPoint(x: 230, y: 280))

    #expect(
        emittedEvents == [
            .petDrag(positionX: 210, positionY: 260),
            .petRelease(positionX: 230, positionY: 280)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}


@Test("Desktop shell controller re-anchors the chat window when the pet moves")
@MainActor
func desktopShellControllerReanchorsTheChatWindowWhenThePetMoves() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    controller.handlePetDragDidMove(to: NSPoint(x: 200, y: 320))

    let petFrame = controller.windowSet.petWindow.frame
    let chatFrame = controller.windowSet.chatWindow.frame

    #expect(petFrame.origin == NSPoint(x: 200, y: 320))
    #expect(chatFrame.minX == petFrame.maxX + 40)
    #expect(chatFrame.midY == petFrame.midY)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller keeps the chat window anchored when the pet drag ends")
@MainActor
func desktopShellControllerKeepsTheChatWindowAnchoredWhenThePetDragEnds() {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    controller.handlePetDragDidEnd(at: NSPoint(x: 180, y: 300))

    let petFrame = controller.windowSet.petWindow.frame
    let chatFrame = controller.windowSet.chatWindow.frame

    #expect(petFrame.origin == NSPoint(x: 180, y: 300))
    #expect(chatFrame.minX == petFrame.maxX + 40)
    #expect(chatFrame.midY == petFrame.midY)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

/// Edge cases for chat-window clamping when pet is dragged near a screen edge.
/// Each row is `(label, dragPoint, expectedClampedAxis)`:
///   .right  → chatFrame.maxX must equal 800 and minX must be >= 0
///   .top    → chatFrame.maxY must equal 600 and minY must be >= 0
///   .bottom → chatFrame.minY must equal 0 and maxY must be <= 600
fileprivate enum ChatClampEdge: Sendable {
    case right, top, bottom
}

@Test(
    "Desktop shell controller keeps the chat window visible when the pet nears a screen edge",
    arguments: [
        (ChatClampEdge.right, NSPoint(x: 620, y: 320)),
        (ChatClampEdge.top, NSPoint(x: 200, y: 560)),
        (ChatClampEdge.bottom, NSPoint(x: 200, y: -40)),
    ]
)
@MainActor
fileprivate func desktopShellControllerKeepsChatWindowVisibleNearEdge(edge: ChatClampEdge, dragPoint: NSPoint) {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    controller.handlePetDragDidMove(to: dragPoint)

    let chatFrame = controller.windowSet.chatWindow.frame

    switch edge {
    case .right:
        #expect(chatFrame.maxX == 800)
        #expect(chatFrame.minX >= 0)
    case .top:
        #expect(chatFrame.maxY == 600)
        #expect(chatFrame.minY >= 0)
    case .bottom:
        #expect(chatFrame.minY == 0)
        #expect(chatFrame.maxY <= 600)
    }

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller syncs chat layout without duplicating pet drag events")
@MainActor
func desktopShellControllerSyncsChatLayoutWithoutDuplicatingPetDragEvents() {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )

    controller.handlePetDragDidMove(to: NSPoint(x: 210, y: 260))

    #expect(
        emittedEvents == [
            .petDrag(positionX: 210, positionY: 260)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

// (top/bottom-edge cases now folded into the parametrized "...nears a screen edge" test above)

@Test("Desktop shell controller emits pet interaction events from drag intent bridge methods")
@MainActor
func desktopShellControllerEmitsPetInteractionEventsFromDragIntentBridgeMethods() {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )

    controller.handlePetDragDidMove(to: NSPoint(x: 210, y: 260))
    controller.handlePetDragDidEnd(at: NSPoint(x: 230, y: 280))

    #expect(
        emittedEvents == [
            .petDrag(positionX: 210, positionY: 260),
            .petRelease(positionX: 230, positionY: 280)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window emits pet release from leftMouseUp sendEvent after a drag move")
@MainActor
func petShellWindowEmitsPetReleaseFromLeftMouseUpSendEventAfterADragMove() throws {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let delegate = try #require(petWindow.delegate as? PetWindowDragAdapter)
    delegate.windowDragDidMove(to: petWindow.frame.origin)
    let event = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )
    let mouseUpEvent = try #require(event)
    petWindow.sendEvent(mouseUpEvent)

    #expect(
        emittedEvents == [
            .petDrag(positionX: petWindow.frame.origin.x, positionY: petWindow.frame.origin.y),
            .petRelease(positionX: petWindow.frame.origin.x, positionY: petWindow.frame.origin.y)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}


@Test("Desktop shell controller installs a native chat view")
@MainActor
func desktopShellControllerInstallsANativeChatView() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    let chatView = try #require(controller.windowSet.chatWindow.contentView as? ChatShellView)

    #expect(chatView.transcript == "OpenPetAgent 已就绪。")
    #expect(chatView.inputText == "")

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Chat shell view sends a local reply")
@MainActor
func chatShellViewSendsALocalReply() async {
    let chatView = ChatShellView()

    chatView.inputText = "你好"
    await chatView.sendCurrentMessage()

    #expect(chatView.inputText == "")
    #expect(chatView.transcript.contains("你：你好"))
    #expect(chatView.transcript.contains("OpenPetAgent：我听到“你好”了。"))
}

@Test("Chat shell view keeps the newer transcript when async replies finish out of order")
@MainActor
func chatShellViewKeepsTheNewerTranscriptWhenAsyncRepliesFinishOutOfOrder() async {
    final class ReplyQueue {
        private var continuations: [CheckedContinuation<String, Never>] = []
        private var entryContinuations: [CheckedContinuation<Void, Never>] = []

        func wait() async -> String {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                entryContinuations.forEach { $0.resume() }
                entryContinuations = []
            }
        }

        func waitForCount(_ expectedCount: Int) async {
            if continuations.count >= expectedCount {
                return
            }

            await withCheckedContinuation { continuation in
                entryContinuations.append(continuation)
            }
        }

        func resume(index: Int, reply: String) {
            continuations[index].resume(returning: reply)
        }
    }

    let replyQueue = ReplyQueue()
    let chatView = ChatShellView(replyHandler: { _ in
        await replyQueue.wait()
    })

    chatView.inputText = "第一条"
    let firstSend = Task { @MainActor in
        await chatView.sendCurrentMessage()
    }
    await replyQueue.waitForCount(1)
    chatView.inputText = "第二条"
    let secondSend = Task { @MainActor in
        await chatView.sendCurrentMessage()
    }
    await replyQueue.waitForCount(2)

    replyQueue.resume(index: 1, reply: "第二个回复")
    await secondSend.value
    replyQueue.resume(index: 0, reply: "第一个回复")
    await firstSend.value

    #expect(chatView.transcript.contains("你：第二条"))
    #expect(chatView.transcript.contains("OpenPetAgent：第二个回复"))
    #expect(chatView.transcript.contains("第一条") == false)
}

@Test("Chat shell view does not clear a newer draft after an async reply")
@MainActor
func chatShellViewDoesNotClearANewerDraftAfterAnAsyncReply() async {
    final class ReplyGate {
        var continuation: CheckedContinuation<String, Never>?
        var entryContinuation: CheckedContinuation<Void, Never>?

        func wait() async -> String {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entryContinuation?.resume()
                entryContinuation = nil
            }
        }

        func waitForEntry() async {
            await withCheckedContinuation { continuation in
                self.entryContinuation = continuation
            }
        }

        func resume() {
            continuation?.resume(returning: "稍后回复")
            continuation = nil
        }
    }

    let replyGate = ReplyGate()
    let chatView = ChatShellView(replyHandler: { _ in
        await replyGate.wait()
    })

    chatView.inputText = "第一条"
    let sendTask = Task { @MainActor in
        await chatView.sendCurrentMessage()
    }
    await replyGate.waitForEntry()
    chatView.inputText = "新草稿"
    replyGate.resume()
    await sendTask.value

    #expect(chatView.inputText == "新草稿")
    #expect(chatView.transcript.contains("你：第一条"))
    #expect(chatView.transcript.contains("OpenPetAgent：稍后回复"))
}

@Test("Chat shell view uses the injected reply handler")
@MainActor
func chatShellViewUsesTheInjectedReplyHandler() async {
    var receivedMessages: [String] = []
    let chatView = ChatShellView(replyHandler: { message in
        receivedMessages.append(message)
        return "来自 handler：\(message)"
    })

    chatView.inputText = "接入编排器"
    await chatView.sendCurrentMessage()

    #expect(receivedMessages == ["接入编排器"])
    #expect(chatView.transcript.contains("OpenPetAgent：来自 handler：接入编排器"))
}

@Test("Pet shell window shows chat on double-click after an unmatched drag-end fallback")
@MainActor
func petShellWindowShowsChatAfterAnUnmatchedDragEndFallback() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let delegate = try #require(petWindow.delegate as? PetWindowDragAdapter)
    delegate.windowDragDidMove(to: NSPoint(x: 210, y: 260))
    delegate.windowDragDidEnd(at: NSPoint(x: 230, y: 280))
    delegate.windowDragDidMove(to: NSPoint(x: 240, y: 290))
    let endedDrag = delegate.windowMouseUp(afterDraggingAt: NSPoint(x: 260, y: 310))
    controller.windowSet.chatWindow.orderOut(nil)

    #expect(endedDrag)

    let event = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 2,   // 双击才开对话卡片（单击 = 轻反应）
        pressure: 0
    )
    let mouseUpEvent = try #require(event)
    petWindow.sendEvent(mouseUpEvent)

    #expect(controller.windowSet.chatWindow.isVisible)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window shows chat when a new double-click follows an unmatched drag-end fallback")
@MainActor
func petShellWindowShowsChatWhenANewClickFollowsAnUnmatchedDragEndFallback() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let delegate = try #require(petWindow.delegate as? PetWindowDragAdapter)
    delegate.windowDragDidMove(to: NSPoint(x: 210, y: 260))
    delegate.windowDragDidEnd(at: NSPoint(x: 230, y: 280))

    let mouseDown = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 1,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
    let mouseUp = try #require(NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 2,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 2,   // 双击才开对话卡片（单击 = 轻反应）
        pressure: 0
    ))
    petWindow.sendEvent(mouseDown)
    petWindow.sendEvent(mouseUp)

    #expect(controller.windowSet.chatWindow.isVisible)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window keeps chat hidden when mouse-up follows drag-end fallback")
@MainActor
func petShellWindowKeepsChatHiddenWhenMouseUpFollowsDragEndFallback() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let delegate = try #require(petWindow.delegate as? PetWindowDragAdapter)
    delegate.windowDragDidMove(to: NSPoint(x: 210, y: 260))
    delegate.windowDragDidEnd(at: NSPoint(x: 230, y: 280))
    let event = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )
    let mouseUpEvent = try #require(event)
    petWindow.sendEvent(mouseUpEvent)

    #expect(controller.windowSet.chatWindow.isVisible == false)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window installs a right-click menu with exit")
@MainActor
func petShellWindowInstallsARightClickMenuWithExit() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    let exitItem = try #require(menu.items.first(where: { $0.title == "退出 OpenPetAgent" }))

    #expect(petWindow.contentView?.menu === menu)
    #expect(exitItem.isEnabled)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window exit menu item invokes the injected quit handler")
@MainActor
func petShellWindowExitMenuItemInvokesTheInjectedQuitHandler() throws {
    var didQuit = false
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        quitHandler: {
            didQuit = true
        }
    )

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    let exitItem = try #require(menu.items.first(where: { $0.title == "退出 OpenPetAgent" }))
    // 动作走共享 PetActionMenu(target 不再是 petWindow);经 target+action 派发仍触发注入的 quit。
    let action = try #require(exitItem.action)

    NSApp.sendAction(action, to: exitItem.target, from: exitItem)

    #expect(didQuit)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil as Any?) }
}

@Test("Pet shell window show chat menu item opens the chat window")
@MainActor
func petShellWindowShowChatMenuItemOpensTheChatWindow() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    let showChatItem = try #require(menu.items.first(where: { $0.title == "显示聊天" }))
    // 动作走共享 PetActionMenu(target 不再是 petWindow);经 target+action 派发仍开聊天窗。
    let action = try #require(showChatItem.action)

    NSApp.sendAction(action, to: showChatItem.target, from: showChatItem)

    #expect(controller.windowSet.chatWindow.isVisible)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller renders companion behavior label on chat shell")
@MainActor
func desktopShellControllerRendersCompanionBehaviorLabelOnChatShell() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let chatView = try #require(controller.windowSet.chatWindow.contentView as? ChatShellView)

    controller.syncCompanionBehavior(.snowing)
    #expect(chatView.companionBehaviorText == "状态：下雪中")

    controller.syncCompanionBehavior(.tracking)
    #expect(chatView.companionBehaviorText == "状态：追踪光标")

    controller.syncCompanionBehavior(.idle)
    #expect(chatView.companionBehaviorText == "状态：闲庭信步")

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("pet 右键菜单不再含「申请辅助功能权限」(已迁设置面板)")
@MainActor
func petShellWindowNoLongerHasAccessibilityItem() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    #expect(menu.items.contains(where: { $0.title == "申请辅助功能权限" }) == false)
    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

// 旧「独立下雪菜单项」测试已移除 —— 雪开关统一进「天气」submenu 单选(强制下雪 / 关闭天气效果),
// 见下面 petMenuWeatherSubmenuHasUnifiedModeAndClear 覆盖。

@Test("状态栏菜单 与 右键桌宠菜单 结构逐项一致(同一 PetActionMenu source of truth)")
@MainActor
func menuBarAndPetMenuStructureAreIdentical() throws {
    let menuBar = MenuBarController()
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let petMenu = try #require(petWindow.menu)

    func topTitles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }
    func weatherTitles(_ menu: NSMenu) -> [String] {
        (menu.items.first { $0.title == "天气" })?.submenu?.items.map(\.title) ?? []
    }
    // 两 surface 走同一 PetActionMenu → 顶层项 + 天气 submenu 顺序/标题逐项相同。
    #expect(topTitles(menuBar.menuForTesting) == topTitles(petMenu))
    #expect(weatherTitles(menuBar.menuForTesting) == weatherTitles(petMenu))
    #expect(weatherTitles(petMenu).isEmpty == false)   // 防两边都空的假阳性
    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("pet 右键「天气」submenu 含统一单选(关闭天气效果)+ 立即清除积雪")
@MainActor
func petMenuWeatherSubmenuHasUnifiedModeAndClear() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let menu = try #require(petWindow.menu)
    let weather = try #require(menu.items.first(where: { $0.title == "天气" }))
    let titles = try #require(weather.submenu).items.map(\.title)
    #expect(titles.contains("关闭天气效果"))
    #expect(titles.contains("强制下雪"))
    #expect(titles.contains("立即清除积雪"))
    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop shell controller toggles the snow placeholder on the overlay")
@MainActor
func desktopShellControllerTogglesSnowPlaceholderOnOverlay() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )

    let overlayView = try #require(controller.windowSet.overlayWindow.contentView as? DesktopOverlayView)
    let particles: [CGPoint] = [
        CGPoint(x: 21, y: 34),
        CGPoint(x: 55, y: 89),
        CGPoint(x: 144, y: 233),
        CGPoint(x: 233, y: 377),
        CGPoint(x: 377, y: 144),
    ]
    controller.syncSnowPlaceholder(isEnabled: true, particles: particles)
    #expect(overlayView.isSnowPlaceholderVisible)
    // Metal renders the visible snow when its layer is present; the
    // NSTextField glyph layer becomes a hidden fallback that still tracks
    // particle positions for future fallback rendering and animation tests.
    #expect(overlayView.visibleSnowflakeCount == 0)
    #expect(overlayView.isSnowPlaceholderAnimating)
    overlayView.layoutSubtreeIfNeeded()
    #expect(overlayView.firstSnowflakeFrame.origin.x == 21)
    #expect(overlayView.snowflakeFrame(at: 1).origin.x == 55)

    let firstFrameY = overlayView.firstSnowflakeFrame.minY
    controller.advanceSnowPlaceholderFrame()
    #expect(overlayView.firstSnowflakeFrame.minY < firstFrameY)

    let disabledFrameY = overlayView.firstSnowflakeFrame.minY
    controller.syncSnowPlaceholder(isEnabled: false)
    #expect(overlayView.isSnowPlaceholderVisible == false)
    #expect(overlayView.visibleSnowflakeCount == 0)
    #expect(overlayView.isSnowPlaceholderAnimating == false)

    controller.advanceSnowPlaceholderFrame()
    #expect(overlayView.firstSnowflakeFrame.minY == disabledFrameY)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop overlay advance drifts snowflakes horizontally over many frames")
@MainActor
func desktopOverlayAdvanceDriftsSnowflakesHorizontallyOverManyFrames() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let overlayView = try #require(controller.windowSet.overlayWindow.contentView as? DesktopOverlayView)
    let particles: [CGPoint] = (0..<6).map { i in
        CGPoint(x: 100 + CGFloat(i) * 80, y: 400)
    }
    controller.syncSnowPlaceholder(isEnabled: true, particles: particles)

    let startXs = (0..<6).map { overlayView.snowflakeFrame(at: $0).origin.x }
    for _ in 0..<60 {
        controller.advanceSnowPlaceholderFrame()
    }
    let endXs = (0..<6).map { overlayView.snowflakeFrame(at: $0).origin.x }

    let driftedCount = zip(startXs, endXs).reduce(into: 0) { count, pair in
        if abs(pair.0 - pair.1) > 0.5 {
            count += 1
        }
    }
    #expect(driftedCount >= 3)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop overlay snowflake font stays within natural size range")
@MainActor
func desktopOverlaySnowflakeFontStaysWithinNaturalSizeRange() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let overlayView = try #require(controller.windowSet.overlayWindow.contentView as? DesktopOverlayView)

    let sizes = overlayView.snowflakeFontSizesForTesting
    let maxSize = sizes.max() ?? 0
    let minSize = sizes.min() ?? 0
    #expect(maxSize <= 14)
    #expect(minSize >= 6)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop overlay snowflake glyphs are varied")
@MainActor
func desktopOverlaySnowflakeGlyphsAreVaried() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let overlayView = try #require(controller.windowSet.overlayWindow.contentView as? DesktopOverlayView)

    let uniqueGlyphCount = Set(overlayView.snowflakeGlyphsForTesting).count
    #expect(uniqueGlyphCount >= 3)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Desktop overlay view hides nstextfield snowflakes when metal layer is active")
@MainActor
func desktopOverlayViewHidesNSTextFieldSnowflakesWhenMetalLayerIsActive() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    let overlayView = try #require(controller.windowSet.overlayWindow.contentView as? DesktopOverlayView)
    let metalView = try #require(overlayView.metalSnowLayerView)

    controller.syncSnowPlaceholder(
        isEnabled: true,
        particles: [
            CGPoint(x: 21, y: 34),
            CGPoint(x: 55, y: 89),
            CGPoint(x: 144, y: 233),
        ]
    )

    #expect(metalView.isHidden == false)
    #expect(overlayView.visibleSnowflakeCount == 0)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}


@Test("Pet shell window shows chat when double-clicked without dragging")
@MainActor
func petShellWindowShowsChatWhenClickedWithoutDragging() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let event = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 2,   // 双击才开对话卡片（单击 = 轻反应）
        pressure: 0
    )
    let mouseUpEvent = try #require(event)
    petWindow.sendEvent(mouseUpEvent)

    #expect(controller.windowSet.chatWindow.isVisible)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet shell window keeps chat hidden on a single click (light reaction only)")
@MainActor
func petShellWindowKeepsChatHiddenOnSingleClick() throws {
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233)
    )
    controller.windowSet.chatWindow.orderOut(nil)

    let petWindow = try #require(controller.windowSet.petWindow as? PetShellWindow)
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: petWindow.frame.origin,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: petWindow.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,   // 单击 = 轻反应（triggerJump + acknowledge），不开卡片
        pressure: 0
    ))
    petWindow.sendEvent(event)

    // 单击不开对话卡片（双击才开）。
    #expect(controller.windowSet.chatWindow.isVisible == false)

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet window drag adapter forwards move through the explicit move seam")
@MainActor
func petWindowDragAdapterForwardsMoveThroughTheExplicitMoveSeam() {
    var capturedPositions: [NSPoint] = []
    let adapter = PetWindowDragAdapter(
        onWindowDidMove: { position in
            capturedPositions.append(position)
        }
    )

    adapter.windowDragDidMove(to: NSPoint(x: 210, y: 260))

    #expect(capturedPositions == [NSPoint(x: 210, y: 260)])
}


@Test("Pet window drag adapter forwards drag-end through the explicit drag-end seam")
@MainActor
func petWindowDragAdapterForwardsDragEndThroughTheExplicitDragEndSeam() {
    var capturedPositions: [NSPoint] = []
    let adapter = PetWindowDragAdapter(
        onDragDidEnd: { position in
            capturedPositions.append(position)
        }
    )

    adapter.windowDragDidEnd(at: NSPoint(x: 230, y: 280))

    #expect(capturedPositions == [NSPoint(x: 230, y: 280)])
}

@Test("Pet window drag adapter emits pet release from mouse-up after a drag move")
@MainActor
func petWindowDragAdapterEmitsPetReleaseFromMouseUpAfterADragMove() {
    var capturedPositions: [NSPoint] = []
    let adapter = PetWindowDragAdapter(
        onDragDidEnd: { position in
            capturedPositions.append(position)
        }
    )

    adapter.windowDragDidMove(to: NSPoint(x: 210, y: 260))
    let endedDrag = adapter.windowMouseUp(afterDraggingAt: NSPoint(x: 230, y: 280))

    #expect(endedDrag)
    #expect(capturedPositions == [NSPoint(x: 230, y: 280)])
}

@Test("Pet window drag adapter ignores mouse-up when no drag move happened")
@MainActor
func petWindowDragAdapterIgnoresMouseUpWhenNoDragMoveHappened() {
    var capturedPositions: [NSPoint] = []
    let adapter = PetWindowDragAdapter(
        onDragDidEnd: { position in
            capturedPositions.append(position)
        }
    )

    let endedDrag = adapter.windowMouseUp(afterDraggingAt: NSPoint(x: 230, y: 280))

    #expect(endedDrag == false)
    #expect(capturedPositions.isEmpty)
}


@Test("Pet window drag adapter still emits pet release from the resize fallback callback")
@MainActor
func petWindowDragAdapterStillEmitsPetReleaseFromTheResizeFallbackCallback() throws {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )

    let petWindow = controller.windowSet.petWindow
    let delegate = try #require(petWindow.delegate as? PetWindowDragAdapter)
    delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: petWindow))

    #expect(
        emittedEvents == [
            .petRelease(positionX: petWindow.frame.origin.x, positionY: petWindow.frame.origin.y)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}

@Test("Pet window drag adapter forwards AppKit callbacks into drag intent methods")
@MainActor
func petWindowDragAdapterForwardsAppKitCallbacksIntoDragIntentMethods() {
    var emittedEvents: [ShellInteractionEvent] = []
    let controller = DesktopShellController(
        screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
        initialState: ShellInitialState(petPositionX: 144, petPositionY: 233),
        interactionEventSink: { event in
            emittedEvents.append(event)
        }
    )
    let adapter = PetWindowDragAdapter(
        onWindowDidMove: { position in
            controller.handlePetDragDidMove(to: position)
        },
        onDragDidEnd: { position in
            controller.handlePetDragDidEnd(at: position)
        }
    )

    adapter.windowDragDidMove(to: NSPoint(x: 210, y: 260))
    adapter.windowDragDidEnd(at: NSPoint(x: 230, y: 280))

    #expect(
        emittedEvents == [
            .petDrag(positionX: 210, positionY: 260),
            .petRelease(positionX: 230, positionY: 280)
        ]
    )

    controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
}
