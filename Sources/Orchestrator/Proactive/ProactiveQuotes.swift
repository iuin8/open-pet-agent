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
        "这 bug 早晚被你拿下",
        "编译跑着，趁机眨眨眼睛",
        "写到一半别忘了刚才的思路",
        "要不要起来接杯水再战",
        "代码越写越顺，状态不错呀",
    ]

    /// browsing：在浏览器里看东西。
    public static let browsingQuotes: [String] = [
        "在网上逛什么好东西呢",
        "查资料辛苦啦，找到了叫我",
        "看到有意思的记得收藏",
        "别一不小心刷太久啦",
        "慢慢看，我在旁边待着",
        "这页内容挺多的，慢慢消化",
        "找资料像寻宝，加油呀",
        "标签页开太多啦，关几个轻松点",
        "看累了就闭眼歇十秒",
        "有想查的也可以问我哦",
        "别被推荐流带跑啦",
    ]

    /// chatting：在聊天软件里。
    public static let chattingQuotes: [String] = [
        "在聊天呀，我先安静会儿",
        "好好聊，有事再叫我",
        "消息别回太急，喝口水",
        "聊得开心点哦",
        "我在这儿待着，不打扰你们",
        "热闹归热闹，也记得歇眼睛",
        "消息攒一波再回也没关系",
        "聊到尽兴别忘了正事呀",
        "需要我帮你想措辞就说",
    ]

    /// design：设计 / 画图工具。
    public static let designQuotes: [String] = [
        "在画画呀，配色看着真舒服",
        "调细节辛苦啦，退远看一眼整体",
        "灵感来了就赶紧记下来",
        "对齐像素的样子好专注",
        "卡住的话先存个版本再试",
        "审美在线，这版挺好看",
        "眼睛盯久了，看看远处歇歇",
        "要不要换个参考找找灵感",
    ]

    /// writing：写作 / 笔记工具。
    public static let writingQuotes: [String] = [
        "码字辛苦啦，思路别断",
        "写不出就先列个提纲呀",
        "这段表达挺顺的",
        "记得随手存一下",
        "卡壳了就起来走两步再写",
        "灵感稍纵即逝，先记关键词",
        "写累了喝口水润润嗓",
        "一字一句都在变好呢",
    ]

    /// media：音乐 / 视频 / 影音。
    public static let mediaQuotes: [String] = [
        "在听歌呀，跟着放松一下",
        "看片愉快，别熬太晚哦",
        "歇会儿挺好的，我陪你看",
        "音量别开太大伤耳朵",
        "放松归放松，坐久了起来动动",
        "这首挺好听，难怪你循环",
        "看完这集记得歇歇眼",
    ]

    /// meeting：视频会议。
    public static let meetingQuotes: [String] = [
        "开会中呀，我先安静待着",
        "会议加油，结束叫我",
        "久坐开会，记得动动肩颈",
        "喝口水再继续讲呀",
        "认真听会的样子很可靠",
        "会开久了，眼睛也歇一歇",
    ]

    /// lateNight：23:00–04:59 深夜关怀，优先级最高。
    public static let lateNightQuotes: [String] = [
        "这么晚还在忙呀，早点歇",
        "夜深了，注意别太累",
        "熬夜伤身，要不要先睡",
        "这个点了，眼睛该休息啦",
        "再忙也记得喝口热水",
        "我陪你到这儿，也别太晚",
        "夜里效率低，不如睡足再战",
        "肩颈僵了吧，伸个懒腰",
        "这个点的安静，也别耗太狠",
        "答应我，这件事完就去睡",
    ]

    /// generic：兜底，无识别 app / 无 snapshot。
    public static let genericQuotes: [String] = [
        "我在呢，需要随时叫我",
        "忙着呢？我安静待着",
        "记得起来活动活动",
        "喝口水，歇会儿眼睛",
        "我一直在旁边陪着你",
        "今天也辛苦啦",
        "坐久了，起来伸个懒腰呀",
        "深呼吸一下，放松点",
        "有需要随时喊我帮忙",
        "节奏自己掌握，别太赶",
        "你做得挺好的，别太苛求自己",
    ]

    // MARK: - app 关键词识别（小写匹配）

    private static let codingKeywords = ["xcode", "code", "vim", "idea", "cursor", "sublime", "emacs", "fleet", "android studio", "pycharm", "webstorm", "goland", "rustrover", "terminal", "iterm", "nova", "zed", "clion", "datagrip", "rider"]
    private static let browsingKeywords = ["safari", "chrome", "edge", "firefox", "arc", "brave", "opera", "vivaldi", "zen"]
    private static let chattingKeywords = ["wechat", "微信", "slack", "telegram", "qq", "飞书", "lark", "discord", "钉钉", "dingtalk", "messages", "信息", "imessage", "whatsapp"]
    private static let designKeywords = ["figma", "sketch", "photoshop", "illustrator", "affinity", "zeplin", "framer", "principle", "pixelmator", "blender", "lightroom", "premiere", "after effects"]
    private static let writingKeywords = ["notion", "typora", "obsidian", "ulysses", "bear", "语雀", "word", "pages", "wps", "craft", "logseq", "scrivener", "ia writer", "marginnote", "goodnotes"]
    private static let mediaKeywords = ["music", "网易云", "spotify", "qqmusic", "qq音乐", "iina", "quicktime", "vlc", "infuse", "bilibili", "哔哩", "youtube", "netflix", "podcast", "播客", "apple tv"]
    private static let meetingKeywords = ["zoom", "腾讯会议", "tencent meeting", "teams", "webex", "飞书会议", "google meet", "voov", "腾讯视频会议"]

    // MARK: - 选桶 + 抽句

    /// 深夜窗口：23:00–04:59（与 ProactiveTriggerEvaluator 一致）。
    private static func isLateNight(_ hour: Int) -> Bool { hour >= 23 || hour < 5 }

    /// 按 app 名匹配关键词选 app 桶；不命中返回 nil。
    /// 顺序：先具体（coding/design/writing/meeting/chatting/media）后宽泛（browsing），
    /// 避免广义浏览器关键词盖过专用 app。
    private static func appBucket(for appName: String?) -> [String]? {
        guard let name = appName?.lowercased(), !name.isEmpty else { return nil }
        if codingKeywords.contains(where: name.contains) { return codingQuotes }
        if designKeywords.contains(where: name.contains) { return designQuotes }
        if writingKeywords.contains(where: name.contains) { return writingQuotes }
        if meetingKeywords.contains(where: name.contains) { return meetingQuotes }
        if chattingKeywords.contains(where: name.contains) { return chattingQuotes }
        if mediaKeywords.contains(where: name.contains) { return mediaQuotes }
        if browsingKeywords.contains(where: name.contains) { return browsingQuotes }
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
