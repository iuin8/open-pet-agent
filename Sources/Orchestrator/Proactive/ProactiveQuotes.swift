// Sources/Orchestrator/Proactive/ProactiveQuotes.swift
import Context
import Foundation

/// 生命感「碎碎念」预设短语库（无 LLM，零成本）。
///
/// 纯函数 `pick`：按 snapshot 前台 app + 当前小时选桶 → 注入式 randomIndex 抽一句
/// → 若与上一句重复则换下一句（避免立刻重复显「假」）。randomIndex 注入便于确定性单测。
/// 短句口语、casual、≤20 字。深夜关怀优先于 app 桶。
public enum ProactiveQuotes {
    // MARK: - 分桶（每桶 6-8 句，简体中文、口语、避免尬）

    /// coding：盯着编辑器写代码。
    public static let codingQuotes: [String] = [
        "盯着代码看好久啦，喝口水歇会儿",
        "这段写得挺顺的样子",
        "卡住了就先起来走两步",
        "记得时不时存一下哦",
        "调试辛苦了，我陪着你",
        "思路打结的话，要不要说给我听",
        "敲得正起劲，我先不打扰",
    ]

    /// browsing：在浏览器里看东西。
    public static let browsingQuotes: [String] = [
        "在网上逛什么好东西呢",
        "查资料辛苦啦，找到了叫我",
        "看到有意思的记得收藏",
        "别一不小心刷太久啦",
        "慢慢看，我在旁边待着",
        "这页内容挺多的，慢慢消化",
    ]

    /// chatting：在聊天软件里。
    public static let chattingQuotes: [String] = [
        "在聊天呀，我先安静会儿",
        "好好聊，有事再叫我",
        "消息别回太急，喝口水",
        "聊得开心点哦",
        "我在这儿待着，不打扰你们",
        "热闹归热闹，也记得歇眼睛",
    ]

    /// lateNight：23:00–04:59 深夜关怀，优先级最高。
    public static let lateNightQuotes: [String] = [
        "这么晚还在忙呀，早点歇",
        "夜深了，注意别太累",
        "熬夜伤身，要不要先睡",
        "这个点了，眼睛该休息啦",
        "再忙也记得喝口热水",
        "我陪你到这儿，也别太晚",
    ]

    /// generic：兜底，无识别 app / 无 snapshot。
    public static let genericQuotes: [String] = [
        "我在呢，需要随时叫我",
        "忙着呢？我安静待着",
        "记得起来活动活动",
        "喝口水，歇会儿眼睛",
        "我一直在旁边陪着你",
        "今天也辛苦啦",
    ]

    // MARK: - app 关键词识别（小写匹配）

    private static let codingKeywords = ["xcode", "code", "vim", "idea", "cursor", "sublime", "emacs", "fleet", "android studio", "pycharm", "webstorm", "goland", "rustrover", "terminal", "iterm"]
    private static let browsingKeywords = ["safari", "chrome", "edge", "firefox", "arc", "brave", "opera"]
    private static let chattingKeywords = ["wechat", "微信", "slack", "telegram", "qq", "飞书", "lark", "discord", "钉钉", "dingtalk"]

    // MARK: - 选桶 + 抽句

    /// 深夜窗口：23:00–04:59（与 ProactiveTriggerEvaluator 一致）。
    private static func isLateNight(_ hour: Int) -> Bool { hour >= 23 || hour < 5 }

    /// 按 app 名匹配关键词选 app 桶；不命中返回 nil。
    private static func appBucket(for appName: String?) -> [String]? {
        guard let name = appName?.lowercased(), !name.isEmpty else { return nil }
        if codingKeywords.contains(where: name.contains) { return codingQuotes }
        if browsingKeywords.contains(where: name.contains) { return browsingQuotes }
        if chattingKeywords.contains(where: name.contains) { return chattingQuotes }
        return nil
    }

    /// 选桶：深夜优先（关怀） → app 桶 → generic 兜底。
    private static func bucket(snapshot: DesktopSnapshot?, hour: Int) -> [String] {
        if isLateNight(hour) { return lateNightQuotes }
        return appBucket(for: snapshot?.visibleApplicationName) ?? genericQuotes
    }

    /// 抽一句碎碎念。randomIndex(count) 注入便于测试；越界自动取模归位。
    /// `avoiding` = 上一句，抽到相同则换下一句（环绕，避免立刻重复）。
    public static func pick(
        snapshot: DesktopSnapshot?,
        hour: Int,
        avoiding last: String?,
        randomIndex: (Int) -> Int
    ) -> String? {
        let bucket = bucket(snapshot: snapshot, hour: hour)
        guard !bucket.isEmpty else { return nil }
        let idx = ((randomIndex(bucket.count) % bucket.count) + bucket.count) % bucket.count
        let pick = bucket[idx]
        // 与上一句撞了且桶里有别的句 → 取下一句（环绕）。
        if pick == last, bucket.count > 1 {
            return bucket[(idx + 1) % bucket.count]
        }
        return pick
    }
}
