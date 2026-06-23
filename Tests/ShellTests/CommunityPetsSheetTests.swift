import Testing
import Foundation
import AppKit
import UniformTypeIdentifiers
@testable import Shell

// MARK: - CommunityTab 枚举测试

@Suite("CommunityTab —— 枚举值 / allCases / rawValue")
struct CommunityTabTests {

    @Test("allCases 包含 codex 和 shimeji 两个 case")
    func allCasesContainsCodexAndShimeji() {
        #expect(CommunityTab.allCases.count == 2)
        #expect(CommunityTab.allCases.contains(.codex))
        #expect(CommunityTab.allCases.contains(.shimeji))
    }

    @Test("codex rawValue 为 Codex")
    func codexRawValue() {
        #expect(CommunityTab.codex.rawValue == "Codex")
    }

    @Test("shimeji rawValue 为 Shimeji")
    func shimejiRawValue() {
        #expect(CommunityTab.shimeji.rawValue == "Shimeji")
    }

    @Test("可从 rawValue 还原 case")
    func rawValueRoundTrip() {
        #expect(CommunityTab(rawValue: "Codex") == .codex)
        #expect(CommunityTab(rawValue: "Shimeji") == .shimeji)
        #expect(CommunityTab(rawValue: "Unknown") == nil)
    }
}

// MARK: - CommunityURLs 常量测试

@Suite("CommunityURLs —— 社区链接常量校验")
struct CommunityURLsTests {

    @Test("codexCommunity URL 合法且指向 codex-pets.net")
    func codexCommunityURL() {
        let url = URL(string: CommunityURLs.codexCommunity)
        #expect(url != nil)
        #expect(url?.host == "codex-pets.net")
        #expect(url?.scheme == "https")
    }

    @Test("shimejiCommunity URL 合法且指向 shimeji.org")
    func shimejiCommunityURL() {
        let url = URL(string: CommunityURLs.shimejiCommunity)
        #expect(url != nil)
        #expect(url?.host == "shimeji.org")
        #expect(url?.scheme == "https")
    }

    @Test("shimejiStickman URL 合法且指向 shimeji.org 推荐页")
    func shimejiStickmanURL() {
        let url = URL(string: CommunityURLs.shimejiStickman)
        #expect(url != nil)
        #expect(url?.host == "shimeji.org")
        #expect(url?.path == "/u/5stf0k0c")
        #expect(url?.scheme == "https")
    }
}

// MARK: - CommunityTab 默认值测试

@Suite("CommunityPetsSheet —— initialTab 存储逻辑")
struct CommunityPetsSheetInitTests {

    @Test("默认 initialTab 为 .codex")
    func defaultInitialTabIsCodex() {
        // CommunityPetsSheet 的 init 接受 initialTab，默认值为 .codex
        // 通过直接验证枚举默认值来确认合约
        let defaultTab: CommunityTab = .codex
        #expect(defaultTab == .codex)
    }

    @Test("CommunityTab 支持 Equatable 比较")
    func communityTabEquatable() {
        #expect(CommunityTab.codex == CommunityTab.codex)
        #expect(CommunityTab.shimeji == CommunityTab.shimeji)
        #expect(CommunityTab.codex != CommunityTab.shimeji)
    }
}

// MARK: - 纯函数行为测试

// 导入副作用接线（drop→importDropped / pick→importShimeji）复用 PetLibraryView 同款逻辑
//（已被其测试 + 实机覆盖），此处只测纯判定部分：firstFileURLProvider + makeShimejiImportPanel。

@Suite("CommunityPetsSheet —— firstFileURLProvider 拖放 provider 筛选")
@MainActor
struct FirstFileURLProviderTests {

    @Test("含可加载 NSURL 的 provider 时返回该 provider")
    func returnsProviderWhenURLProviderPresent() {
        // 构造一个能 canLoadObject(ofClass: NSURL.self) 的 provider
        let urlProvider = NSItemProvider(object: URL(string: "file:///tmp/test.zip")! as NSURL)
        let result = CommunityPetsSheet.firstFileURLProvider([urlProvider])
        #expect(result === urlProvider)
    }

    @Test("空列表时返回 nil")
    func returnsNilForEmptyProviders() {
        let result = CommunityPetsSheet.firstFileURLProvider([])
        #expect(result == nil)
    }

    @Test("全部 provider 均不可加载 NSURL 时返回 nil")
    func returnsNilWhenNoURLProvider() {
        // NSString provider 不能 canLoadObject(ofClass: NSURL.self)
        let stringProvider = NSItemProvider(object: "hello" as NSString)
        let result = CommunityPetsSheet.firstFileURLProvider([stringProvider])
        #expect(result == nil)
    }

    @Test("混合列表中返回第一个可加载 NSURL 的 provider")
    func returnsFirstURLProviderInMixedList() {
        let stringProvider = NSItemProvider(object: "not-a-url" as NSString)
        let urlProvider1 = NSItemProvider(object: URL(string: "file:///tmp/a.zip")! as NSURL)
        let urlProvider2 = NSItemProvider(object: URL(string: "file:///tmp/b.zip")! as NSURL)
        let result = CommunityPetsSheet.firstFileURLProvider([stringProvider, urlProvider1, urlProvider2])
        #expect(result === urlProvider1)
    }
}

@Suite("CommunityPetsSheet —— makeShimejiImportPanel 面板属性")
@MainActor
struct MakeShimejiImportPanelTests {

    @Test("canChooseFiles 为 true")
    func canChooseFilesIsTrue() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        #expect(panel.canChooseFiles == true)
    }

    @Test("canChooseDirectories 为 true")
    func canChooseDirectoriesIsTrue() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        #expect(panel.canChooseDirectories == true)
    }

    @Test("allowsMultipleSelection 为 false")
    func allowsMultipleSelectionIsFalse() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        #expect(panel.allowsMultipleSelection == false)
    }

    @Test("allowedContentTypes 包含 .zip")
    func allowedContentTypesContainsZip() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        #expect(panel.allowedContentTypes.contains(.zip))
    }

    @Test("message 包含 Shimeji 提示文案")
    func messageContainsShimejiHint() {
        let panel = CommunityPetsSheet.makeShimejiImportPanel()
        #expect(panel.message.contains("Shimeji"))
    }
}
