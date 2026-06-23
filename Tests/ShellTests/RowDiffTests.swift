import Testing
@testable import Shell

/// `RowDiff.classify` 纯函数测试 —— 会话流滚动决策的核心(§5.11 反复栽的「回弹/抖动」根因在此把关)。
/// 决策规则:`changeAtBottom == (suffix==0)` → 仅尾部变化且贴底才跟随到底;其余锚点恢复(视口不动)。
@Suite("RowDiff — 行序列结构 diff 分类(滚动决策无头把关)")
struct RowDiffTests {

    @Test("纯底部追加:prefix=全旧, suffix=0 → changeAtBottom(贴底才跟随)")
    func pureAppend() {
        let d = RowDiff.classify(oldIds: [0, 1, 2], newIds: [0, 1, 2, 3])
        #expect(d.prefix == 3)
        #expect(d.suffix == 0)
        #expect(d.oldMid == 0)
        #expect(d.newMid == 1)
        #expect(d.changeAtBottom == true)
    }

    @Test("正常 prepend(顶部按钮仍在):有稳定后缀 → 非尾部变化(锚点恢复,不跟随)")
    func prependButtonStays() {
        // old=[btn(-1), 5,6,7], new=[btn(-1), 3,4, 5,6,7]
        let d = RowDiff.classify(oldIds: [-1, 5, 6, 7], newIds: [-1, 3, 4, 5, 6, 7])
        #expect(d.prefix == 1)        // 按钮哨兵匹配
        #expect(d.suffix == 3)        // 5,6,7 稳定
        #expect(d.oldMid == 0)
        #expect(d.newMid == 2)        // 插入 3,4
        #expect(d.changeAtBottom == false)
    }

    @Test("**回弹 bug 场景**:加载到顶『按钮移除 + prepend』同帧 → oldMid>0 && newMid>0 但 suffix>0 → 不跟随到底")
    func buttonRemovedWithPrepend() {
        // old=[btn(-1), 5,6,7], new=[3,4, 5,6,7](按钮没了 + 前插 3,4)
        let d = RowDiff.classify(oldIds: [-1, 5, 6, 7], newIds: [3, 4, 5, 6, 7])
        #expect(d.prefix == 0)
        #expect(d.suffix == 3)        // 5,6,7 仍稳定
        #expect(d.oldMid == 1)        // 移除按钮
        #expect(d.newMid == 2)        // 前插 3,4
        // 旧实现这里 oldMid>0 && newMid>0 → reloadData+scrollToBottom(回弹根因);
        // 新决策只看 changeAtBottom(suffix==0)=false → 锚点恢复,视口纹丝不动。
        #expect(d.changeAtBottom == false)
    }

    @Test("仅内容变(id 全同)→ 无结构变, changeAtBottom(贴底则跟随运行中轮次增长)")
    func contentOnlyChange() {
        let d = RowDiff.classify(oldIds: [0, 1, 2], newIds: [0, 1, 2])
        #expect(d.prefix == 3)
        #expect(d.suffix == 0)
        #expect(d.oldMid == 0)
        #expect(d.newMid == 0)
        #expect(d.changeAtBottom == true)
    }

    @Test("尾部删行(末尾按钮/提示消失)→ suffix=0 → changeAtBottom")
    func removeAtBottom() {
        let d = RowDiff.classify(oldIds: [0, 1, 2, 3], newIds: [0, 1, 2])
        #expect(d.prefix == 3)
        #expect(d.suffix == 0)
        #expect(d.oldMid == 1)
        #expect(d.newMid == 0)
        #expect(d.changeAtBottom == true)
    }

    @Test("空 → 非空 / 全换:由调用方走 isSessionSwitch 整表重建,diff 仅用于增量分支")
    func emptyToNonEmpty() {
        let d = RowDiff.classify(oldIds: [], newIds: [0, 1])
        #expect(d.prefix == 0)
        #expect(d.suffix == 0)
        #expect(d.oldMid == 0)
        #expect(d.newMid == 2)
    }
}
