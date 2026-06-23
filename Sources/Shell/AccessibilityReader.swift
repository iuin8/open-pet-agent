#if canImport(ApplicationServices) && canImport(AppKit)
import AppKit
import ApplicationServices

/// C2 — 读取系统当前选中文本。两条 fallback 路径:
///
/// 1. **AX 直读**: 通过 Accessibility API 拿到 frontmost app → focused element →
///    `AXSelectedText` 属性。只读, 无副作用, 但要求目标 app 支持 AX
///    (Safari / VSCode / Notes / 系统原生 controls 都支持)。
/// 2. **⌘C fallback**: AX 失败时模拟 Command+C 复制选中文本到 `NSPasteboard`,
///    取一次内容再恢复 pasteboard 原内容 (避免污染剪贴板)。能多覆盖一些
///    AX 不友好的 webview / canvas。
///
/// 两条路径都失败时返回 `nil` — 调用方按"无选中文本"处理 (等同空召唤)。
///
/// 需要 Accessibility 权限。OpenPetAgent 已在 `WindowTracker` / `GlobalChatHotkey`
/// 申请基础, 这里只是复用; 若未授权 AX 直读必失败 → 走 ⌘C fallback
/// (`CGEvent.post` 同样依赖辅助功能权限, 没有时也会拿不到结果, 返回 nil)。
///
/// 参考实现: HermesPet (https://github.com/basionwang-bot/HermesPet)。
/// 与 HermesPet 的差异: 这里返回 `String?` 给调用方按 callback 风格处理,
/// 不走 `NotificationCenter` 广播; 也不内置 timeout / retry 循环
/// (单次尝试失败即返回 nil, 由调用方决定下一步)。
@MainActor
public enum AccessibilityReader {

    /// 读当前选中文本。order: AX 直读 → ⌘C fallback → nil。
    /// 调用线程: main; 同步返回 (含 50ms ⌘C 等待, 短到可接受)。
    public static func readSelectedText() -> String? {
        if let text = readViaAccessibility(), !text.isEmpty {
            return text
        }
        if let text = readViaCopyShortcut(), !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: - AX 直读

    /// 通过 system-wide AXUIElement 拿到 focused element 的
    /// `AXSelectedText`。无副作用; 失败安静返回 nil。
    private static func readViaAccessibility() -> String? {
        let systemElement = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusStatus == .success, let focusedRef = focused else {
            return nil
        }
        // focused 是 AnyObject 装的 AXUIElement; 直接桥接为 AXUIElement。
        let focusedElement = focusedRef as! AXUIElement
        var selected: AnyObject?
        let selStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard selStatus == .success, let text = selected as? String else {
            return nil
        }
        return text
    }

    // MARK: - ⌘C fallback

    /// 模拟 Command+C, 给系统 50ms 反应, 再读 `NSPasteboard`。
    /// 读完恢复原 pasteboard 内容, 避免污染用户剪贴板。
    ///
    /// 通过 `changeCount` 判断是否真有复制发生 — 如果没变化说明用户
    /// 没选中文本 (复制无效) 或目标 app 拒绝 ⌘C, 返回 nil。
    private static func readViaCopyShortcut() -> String? {
        let pasteboard = NSPasteboard.general
        let originalContents = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return nil
        }
        // kVK_Command = 0x37, kVK_ANSI_C = 0x08
        let cmdKey: CGKeyCode = 0x37
        let cKey: CGKeyCode = 0x08

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        cDown?.flags = .maskCommand
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        cUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // 系统转发 ⌘C → 目标 app 复制 → pasteboard 更新, 需要一点时间。
        // 50ms 经验值, 与 HermesPet 实测一致; 比这短经常拿不到内容。
        Thread.sleep(forTimeInterval: 0.05)

        let newChangeCount = pasteboard.changeCount
        let newContent = pasteboard.string(forType: .string)

        // 没变化 → 没成功复制 (没选中文本 / 目标 app 不响应)
        guard newChangeCount != originalChangeCount, let new = newContent else {
            return nil
        }

        // 复原 pasteboard, 避免污染用户剪贴板。
        pasteboard.clearContents()
        if let original = originalContents {
            pasteboard.setString(original, forType: .string)
        }

        return new
    }
}

#else

/// 非 Apple 平台 stub — OpenPetAgent 只构建于 macOS, 这条分支主要给 Linux CI
/// 编译试探时使用 (虽然项目 Package.swift 锁了 macOS 13+, 留个安全网)。
@MainActor
public enum AccessibilityReader {
    public static func readSelectedText() -> String? { nil }
}

#endif
