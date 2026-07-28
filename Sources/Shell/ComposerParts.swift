import Foundation

/// P7.1:composer 内容模型 —— opencode 式 part 数组是**唯一事实源**(文本段 + mention chip)。
/// `ChatCardState.draft` 只是它的序列化投影(wire format),`AgentMention.parse` 行首路由
/// 语义不变:行首 chip → `@trigger ` 前缀;行中 chip → 纯文本。
///
/// 本文件是纯逻辑(可单测),不 import AppKit/SwiftUI;NSAttributedString 双向桥在
/// `MentionChipAttachment.swift`。
public enum ComposerPart: Equatable, Sendable {
    /// 纯文本段(可含换行)。
    case text(String)
    /// mention chip。`isPinned` = 钉住态(深色底白字;一次性 = 浅底 accent 字)。
    case mention(trigger: String, isPinned: Bool)

    /// 便捷判定。
    public var isMention: Bool {
        if case .mention = self { return true }
        return false
    }
}

public enum ComposerParts {

    // MARK: - 序列化(wire format,与 P6.2 烘焙产物一致)

    /// parts → wire 文本:text 原样;mention → `@trigger `(带一个尾随空格)。
    /// **chip 拥有那个空格**:mention 后紧跟的 text part 若以空格/制表符开头,剥掉前导空白
    /// (防双空格;换行不属于 chip 的空格管辖,保留)。
    public static func serialized(_ parts: [ComposerPart]) -> String {
        var out = ""
        var previousWasMention = false
        for part in parts {
            switch part {
            case .text(let s):
                if previousWasMention {
                    out.append(String(s.drop(while: { $0 == " " || $0 == "\t" })))
                } else {
                    out.append(s)
                }
                previousWasMention = false
            case .mention(let trigger, _):
                out.append("@\(trigger) ")
                previousWasMention = true
            }
        }
        return out
    }

    /// 行首路由目标:第一个 part 是 mention → (trigger, isPinned);否则 nil。
    /// 与 `AgentMention.parse` 的行首语义一一对应(只有行首 chip 参与路由)。
    public static func leadingMention(_ parts: [ComposerPart]) -> (trigger: String, isPinned: Bool)? {
        guard case .mention(let trigger, let isPinned) = parts.first else { return nil }
        return (trigger, isPinned)
    }

    /// 是否可发送:text 拼接去空白后非空(**只有 chip 不算** —— 路由要求 mention 后有正文)。
    public static func hasContent(_ parts: [ComposerPart]) -> Bool {
        var text = ""
        for part in parts {
            if case .text(let s) = part { text.append(s) }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 纯函数操作

    /// picker 接受 mention:用 chip 替换已键入的 `@query` 段。
    ///
    /// 规则:
    /// - 找**最后一个**以 `@query` 结尾的 text part,剥掉该后缀(剥空则移除该 part);
    /// - chip 落在原键入段位置;若键入段之前只剩 mention(紧跟行首 chip 链)→ 行首 chip 链
    ///   整链让位、新 mention 独占行首(tray「重选/一次性顶掉钉住」语义;pinned chip 由
    ///   `ChatCardState.syncPinnedChip` 在 parts 清空后回补);
    /// - 找不到键入段(数据已变)→ 兜底插到末尾。
    public static func insertingMention(
        _ parts: [ComposerPart],
        trigger: String,
        isPinned: Bool,
        replacingTypedQuery query: String
    ) -> [ComposerPart] {
        var result = parts
        let suffix = "@" + query
        guard let qIndex = result.indices.last(where: {
            if case .text(let s) = result[$0] { return s.hasSuffix(suffix) }
            return false
        }) else {
            return normalized(result + [.mention(trigger: trigger, isPinned: isPinned)])
        }
        var insertion = qIndex
        if case .text(let s) = result[qIndex] {
            let stripped = String(s.dropLast(suffix.count))
            if stripped.isEmpty {
                result.remove(at: qIndex)
            } else {
                result[qIndex] = .text(stripped)
                insertion = qIndex + 1
            }
        }
        // 行首 chip 链让位:插入点之前全是 mention 且非空 → 整链移除,新 mention 独占行首。
        let before = result[..<insertion]
        if !before.isEmpty, before.allSatisfy(\.isMention) {
            result.removeFirst(before.count)
            insertion -= before.count
        }
        result.insert(.mention(trigger: trigger, isPinned: isPinned), at: insertion)
        return normalized(result)
    }

    /// 移除指定位置的 mention(越界/非 mention → 原样)。相邻 text 段合并(规范化)。
    public static func removingMention(at index: Int, in parts: [ComposerPart]) -> [ComposerPart] {
        guard parts.indices.contains(index), parts[index].isMention else { return parts }
        var result = parts
        result.remove(at: index)
        return normalized(result)
    }

    /// 切换指定位置 mention 的钉住态(越界/非 mention → 原样)。
    public static func togglingPin(at index: Int, in parts: [ComposerPart]) -> [ComposerPart] {
        guard parts.indices.contains(index),
              case .mention(let trigger, let isPinned) = parts[index] else { return parts }
        var result = parts
        result[index] = .mention(trigger: trigger, isPinned: !isPinned)
        return result
    }

    // MARK: - chip 点击菜单(行首引擎 chip 才有钉住项;与 P6.2 tray 逐项对齐)

    /// chip 菜单动作。具体 NSMenu 构建在编辑器侧,本枚举保持纯逻辑可单测。
    public enum ChipMenuAction: Equatable, Sendable {
        /// 钉住 / 取消钉住(按 chip 当前 `isPinned` 展示对应文案)。
        case togglePin
        /// 移除 chip(钉住 chip 的移除 = 取消钉住,由调用侧派发)。
        case remove
    }

    /// 行首引擎 chip = [togglePin, remove];行中 chip / soul chip = [remove]。
    public static func chipMenuActions(isLeading: Bool, isPinned: Bool, isSoul: Bool) -> [ChipMenuAction] {
        if isLeading, !isSoul {
            return [.togglePin, .remove]
        }
        return [.remove]
    }

    // MARK: - 规范化

    /// 去掉空 text 段、合并相邻 text 段(编辑器重建与纯函数操作共用同一份规范化,
    /// 保证 `[ComposerPart]` 相等比较稳定)。
    public static func normalized(_ parts: [ComposerPart]) -> [ComposerPart] {
        var out: [ComposerPart] = []
        for part in parts {
            switch part {
            case .text(let s):
                guard !s.isEmpty else { continue }
                if case .text(let tail) = out.last {
                    out[out.count - 1] = .text(tail + s)
                } else {
                    out.append(.text(s))
                }
            case .mention:
                out.append(part)
            }
        }
        return out
    }
}
