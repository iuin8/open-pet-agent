import AppKit
import Foundation

/// S3 Pin 卡片协调器 —— 桥接 `PinStore`(actor 持久化层)与 `PinCardWindow`
/// (UI 层)。
///
/// 职责:
/// - 启动时从 store 加载所有 pin → 创建对应 window 显示
/// - `add` 新 pin:Pin → store add → 创建 window;若 store add 触发上限裁剪,
///   关掉对应的 window
/// - `remove` 指定 pin:关闭 window + store remove
/// - 拖动 callback:转发到 store.updateOrigin
///
/// 使用方:`MinimalAppDelegate.didFinishLaunching` 创建 + start;⌘⇧P 快捷键
/// 触发 add。
@MainActor
public final class PinCardController {

    // MARK: - Constants

    /// 新 pin 默认 origin —— 屏幕中心稍偏右上,避开 pet 默认位置。
    /// 同时为防止多张 pin 完全重叠,每张追加一个微小的 offset。
    private static let newPinOffsetStep: CGFloat = 24

    // MARK: - Stored

    private let pinStore: PinStore
    private var cards: [UUID: PinCardWindow] = [:]

    /// 已显示卡片数量(测试访问器)。
    public var cardCount: Int { cards.count }

    public init(pinStore: PinStore) {
        self.pinStore = pinStore
    }

    // MARK: - Lifecycle

    /// 启动:从 store 加载所有持久化的 pin 并创建对应 window。
    /// app launch 时调一次即可。
    public func start() async {
        _ = try? await pinStore.load()
        let pins = await pinStore.allPins()
        for pin in pins {
            createCard(for: pin)
        }
    }

    /// 关闭所有 window 并清空内部表。store 不动(磁盘上 pin 保留)。
    /// 用于测试 teardown。
    public func shutdown() {
        for card in cards.values {
            card.close()
        }
        cards.removeAll()
    }

    // MARK: - Public API

    /// 创建一张新 pin:`store.add` → 创建 window → 显示。
    /// 若 store 返回被裁掉的 pin(超过 maxPins),关闭对应的 window。
    @discardableResult
    public func add(content: String, defaultOrigin: NSPoint) async -> Pin {
        let origin = nextSpawnOrigin(seedOrigin: defaultOrigin)
        let pin = Pin(content: content, origin: origin)
        let trimmed = await pinStore.add(pin)
        // 关闭被裁掉的 window
        for dropped in trimmed {
            if let card = cards.removeValue(forKey: dropped.id) {
                card.close()
            }
        }
        createCard(for: pin)
        return pin
    }

    /// 删除指定 pin:关闭 window + store remove。
    public func remove(id: UUID) async {
        if let card = cards.removeValue(forKey: id) {
            card.close()
        }
        await pinStore.remove(id: id)
    }

    /// 测试访问器:某个 ID 是否有对应 window。
    public func hasCard(id: UUID) -> Bool {
        cards[id] != nil
    }

    /// 测试访问器:某个 ID 对应的 card(或 nil)。
    public func card(id: UUID) -> PinCardWindow? {
        cards[id]
    }

    // MARK: - Private

    /// 创建一个 PinCardWindow 并显示。同 ID 已存在则跳过(防御性)。
    private func createCard(for pin: Pin) {
        guard cards[pin.id] == nil else { return }
        let pinID = pin.id
        let card = PinCardWindow(
            pinID: pinID,
            content: pin.content,
            origin: pin.origin,
            onMoved: { [weak self] newOrigin in
                guard let self else { return }
                Task { @MainActor in
                    await self.pinStore.updateOrigin(id: pinID, origin: newOrigin)
                }
            },
            onClose: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.remove(id: pinID)
                }
            }
        )
        cards[pinID] = card
        card.show()
    }

    /// 计算新 pin 的 spawn origin —— 若 seedOrigin 上已有 pin,沿对角线偏移
    /// `newPinOffsetStep * 已有数量`,避免完全重叠。
    private func nextSpawnOrigin(seedOrigin: NSPoint) -> NSPoint {
        let step = CGFloat(cards.count) * Self.newPinOffsetStep
        return NSPoint(x: seedOrigin.x + step, y: seedOrigin.y - step)
    }
}
