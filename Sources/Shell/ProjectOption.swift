import Foundation

/// 项目选择器(`ProjectMenu`)的一个选项。纯展示数据(id + name + isExternal),
/// 由 App 从 `ProjectStore.list()` 派生注入(Shell 不依赖 App,故不在本层构造)。
/// mirror `MentionOption` 模式:App 派生注入展示数据,Shell 不碰数据源。
public struct ProjectOption: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isExternal: Bool
    public init(id: String, name: String, isExternal: Bool) {
        self.id = id
        self.name = name
        self.isExternal = isExternal
    }
}
