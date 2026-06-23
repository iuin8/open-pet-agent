import AppKit
import Foundation

/// S3 Pin 卡片数据模型 —— 用户从当前 AI 回复"钉"到桌面的 Markdown 块。
///
/// `origin` 是 panel 左下角的屏幕坐标(逻辑像素,AppKit y 向上)。用户拖动后
/// `PinCardController` 会回调更新该字段并即时落盘。
///
/// 字段最少化:MVP 只关心"内容 + 创建时间 + 位置",pin 之间没有 mode / 来源
/// 等附加信息。后续要拓展(任务化 / 来源会话 ID / mode 主色)再加。
public struct Pin: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let content: String
    public let createdAt: Date
    public var origin: NSPoint

    public init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = Date(),
        origin: NSPoint
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.origin = origin
    }

    // MARK: - Codable

    /// `NSPoint` 不是天然 Codable —— 拆成 `x` / `y` 两个 Double 落盘。
    private enum CodingKeys: String, CodingKey {
        case id, content, createdAt, originX, originY
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        let x = try c.decode(Double.self, forKey: .originX)
        let y = try c.decode(Double.self, forKey: .originY)
        self.origin = NSPoint(x: x, y: y)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(Double(origin.x), forKey: .originX)
        try c.encode(Double(origin.y), forKey: .originY)
    }

    // Equatable 默认实现对 NSPoint 字段会因 NSPoint != Equatable 失败,
    // 手写。
    public static func == (lhs: Pin, rhs: Pin) -> Bool {
        lhs.id == rhs.id
            && lhs.content == rhs.content
            && lhs.createdAt == rhs.createdAt
            && lhs.origin.x == rhs.origin.x
            && lhs.origin.y == rhs.origin.y
    }
}

/// S3 Pin 持久化层 —— actor 隔离,落盘到
/// `~/Library/Application Support/OpenPetAgent/pins.json`。
///
/// 设计跟 `ConversationStore` 同源:
/// - atomic write(tmp 文件 + replaceItem) 防止崩溃时半写文件
/// - JSON 损坏时改名 `.bak` + 起新数组,不抛错给上层
/// - 测试用 init 注入 storeURL,生产用 default 路径
///
/// 上限 8 张(避免桌面爆炸);`add` 时若超出,从最旧(`createdAt` 最小)的
/// 开始裁掉,返回被裁掉的 ID 列表给上层关 window。
public actor PinStore {

    /// 上限。HermesPet 同样的取值。
    public static let maxPins: Int = 8

    private var pins: [Pin]
    private let storeURL: URL

    /// 测试用 init:注入临时目录路径,不污染 ~/Library/。
    public init(storeURL: URL) {
        self.storeURL = storeURL
        self.pins = []
    }

    /// 生产 init:默认 ~/Library/Application Support/OpenPetAgent/pins.json。
    public init() {
        self.init(storeURL: Self.defaultStoreURL())
    }

    // MARK: - Default path

    public static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("OpenPetAgent", isDirectory: true)
            .appendingPathComponent("pins.json")
    }

    // MARK: - Public API

    /// 从磁盘加载现有 pin。文件不存在 → 空数组。JSON 损坏 → 改名 .bak 起新。
    /// 跟 ConversationStore.load 一致:返回 throws 是 forward-compatible,
    /// 实际不会向上抛(异常路径在内部 swallow)。
    @discardableResult
    public func load() async throws -> [Pin] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return pins
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pins = try decoder.decode([Pin].self, from: data)
        } catch {
            recoverFromCorruption(error: error)
        }
        return pins
    }

    /// 内存快照。
    public func allPins() -> [Pin] {
        pins
    }

    /// 追加一张 pin,即时落盘。返回被裁掉的 pin 列表(空数组表示未触发上限)。
    /// 上限触发时**从最旧的开始裁**,保证用户最新的 pin 不会被覆盖。
    @discardableResult
    public func add(_ pin: Pin) async -> [Pin] {
        pins.append(pin)
        let trimmed = trimToCapIfNeeded()
        await persist()
        return trimmed
    }

    /// 删除指定 ID 的 pin,即时落盘。pin 不存在则 no-op。
    public func remove(id: UUID) async {
        pins.removeAll { $0.id == id }
        await persist()
    }

    /// 更新指定 pin 的 origin(用户拖动结束后调)。pin 不存在则 no-op。
    public func updateOrigin(id: UUID, origin: NSPoint) async {
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[idx].origin = origin
        await persist()
    }

    /// 清空所有 pin + 落盘。
    public func clear() async {
        pins.removeAll()
        await persist()
    }

    // MARK: - Private

    /// 按 createdAt 升序排,超过 maxPins 时丢最旧的 N 张,返回被丢的列表。
    private func trimToCapIfNeeded() -> [Pin] {
        guard pins.count > Self.maxPins else { return [] }
        let sorted = pins.sorted { $0.createdAt < $1.createdAt }
        let dropCount = pins.count - Self.maxPins
        let dropped = Array(sorted.prefix(dropCount))
        let droppedIDs = Set(dropped.map(\.id))
        pins.removeAll { droppedIDs.contains($0.id) }
        return dropped
    }

    private func persist() async {
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(pins)
            let tmpURL = dir.appendingPathComponent(
                storeURL.lastPathComponent + ".tmp"
            )
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: storeURL)
            }
        } catch {
            print("[PinStore] persist failed: \(error)")
        }
    }

    private func recoverFromCorruption(error: Error) {
        print("[PinStore] decode failed, recovering: \(error)")
        let bakURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                storeURL.deletingPathExtension().lastPathComponent + ".bak"
            )
        if FileManager.default.fileExists(atPath: bakURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
        }
        try? FileManager.default.moveItem(at: storeURL, to: bakURL)
        pins = []
    }
}

