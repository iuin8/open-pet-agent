import AgentSensing
import Combine
import Foundation

/// 钉住会话的 UserDefaults 持久化(spec §2)。整张 `[PinnedSessionRef]` 以 JSON 存单 key,小数据量直存够用。
///
/// **单一可观察源**(`ObservableObject`):picker(经 `AgentSessionStore` 重算)与浏览历史 sheet
/// (`@ObservedObject` 直接观察本类)共用这一份钉住真相 —— 任一处 pin/unpin 都经 `togglePin` 落到这里、
/// 发 `objectWillChange` → 两个列表同步刷新(根治「历史列表与内建列表钉住不同步」:旧 sheet 用本地
/// `@State` 快照,与 store 脱节)。
public final class PinnedSessionStore: ObservableObject {
    private let defaults: UserDefaults
    private static let key = "petagent.pinnedSessions.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func all() -> [PinnedSessionRef] {
        guard let data = defaults.data(forKey: Self.key),
              let refs = try? JSONDecoder().decode([PinnedSessionRef].self, from: data) else { return [] }
        return refs
    }
    private func save(_ refs: [PinnedSessionRef]) {
        defaults.set(try? JSONEncoder().encode(refs), forKey: Self.key)
    }

    public func pinned(for agent: AgentKind) -> [PinnedSessionRef] {
        all().filter { $0.agent == agent }.sorted { $0.pinnedAt > $1.pinnedAt }
    }
    public func isPinned(agent: AgentKind, sessionId: String) -> Bool {
        all().contains { $0.agent == agent && $0.sessionId == sessionId }
    }
    public func pin(_ ref: PinnedSessionRef) {
        objectWillChange.send()   // 观察 sheet 即时翻 📌(同时 picker 经 store 重算)
        var refs = all().filter { !($0.agent == ref.agent && $0.sessionId == ref.sessionId) }   // 去重
        refs.append(ref)
        save(refs)
    }
    public func unpin(agent: AgentKind, sessionId: String) {
        objectWillChange.send()
        save(all().filter { !($0.agent == agent && $0.sessionId == sessionId) })
    }
}
