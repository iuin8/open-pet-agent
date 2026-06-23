import AppKit

/// 兼容性 stub。原 AppKit `SettingsContentView` 在 SwiftUI 重写中已删除,
/// 但其上的静态 `editingSelector(for:)` 仍被
/// `Tests/ShellTests/SettingsContentViewKeyTests.swift` 引用 — 保留 type +
/// 静态方法,使老测试无需修改即可继续验证 Cmd-shortcut 解析逻辑(与
/// `ChatShellView.editingSelector(for:)` 实现一致,作为单测目标存在)。
///
/// 当 OpenPetAgent 整体迁移完 SwiftUI 后,这两段静态逻辑可以合并到一个 namespace
/// `KeyEquivalentMapper`,但当前为保持代码改动最小化,继续以兼容 type 形式
/// 提供。
@MainActor
internal enum SettingsContentView {
    /// Map a key event to the standard editing selector or `nil` if not recognised.
    /// Cmd+V/C/X/A → paste/copy/cut/selectAll; Cmd+Z / Cmd+Shift+Z → undo/redo。
    internal static func editingSelector(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }

        let shift = event.modifierFlags.contains(.shift)
        switch chars {
        case "v": return #selector(NSText.paste(_:))
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default:  return nil
        }
    }
}
