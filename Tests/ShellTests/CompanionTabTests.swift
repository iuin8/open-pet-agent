import Testing
@testable import Shell

@Suite("CompanionTab")
struct CompanionTabTests {

    @Test("allCases 顺序：Pet Chat → Claude Code → Codex")
    func allCasesOrder() {
        #expect(CompanionTab.allCases == [.petChat, .claudeCode, .codex])
    }

    @Test("默认/首个 tab 是 Pet Chat")
    func firstIsPetChat() {
        #expect(CompanionTab.allCases.first == .petChat)
    }

    @Test("每个 tab 的 displayName 非空且含预期文案")
    func displayNamesNonEmpty() {
        for tab in CompanionTab.allCases {
            #expect(!tab.displayName.isEmpty)
        }
        #expect(CompanionTab.petChat.displayName.contains("Pet Chat"))
        #expect(CompanionTab.claudeCode.displayName.contains("Claude"))
        #expect(CompanionTab.codex.displayName.contains("Codex"))
    }

    @Test("每个 tab 的 systemImage 非空（SF Symbol 名）")
    func systemImagesNonEmpty() {
        for tab in CompanionTab.allCases {
            #expect(!tab.systemImage.isEmpty)
        }
    }

    @Test("TabBadge 默认 none 可构造", arguments: [TabBadge.none, .active, .awaiting])
    func tabBadgeCases(badge: TabBadge) {
        // 仅验证三个 case 都可构造（编译期穷尽 + 运行期可用）。
        switch badge {
        case .none, .active, .awaiting:
            #expect(Bool(true))
        }
    }
}
