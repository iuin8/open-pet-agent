import AppKit
import Foundation
import Testing
@testable import Shell

@Suite("PinStore — Pin 卡片持久化")
struct PinStoreTests {

    // MARK: - Helpers

    private func makeTempStoreURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("petagent-pinstore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("pins.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Init / 空仓库

    @Test("空仓库初始 allPins 为空")
    func emptyOnInit() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)
        let pins = await store.allPins()
        #expect(pins.isEmpty)
    }

    @Test("文件不存在时 load 返回空,无异常")
    func loadFileMissingReturnsEmpty() async throws {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)
        let pins = try await store.load()
        #expect(pins.isEmpty)
    }

    // MARK: - Add / Remove / Update

    @Test("add 一张 pin → allPins 包含 + 落盘文件存在")
    func addSinglePin() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)

        let pin = Pin(content: "hello", origin: NSPoint(x: 100, y: 200))
        let dropped = await store.add(pin)

        #expect(dropped.isEmpty)
        let all = await store.allPins()
        #expect(all.count == 1)
        #expect(all.first?.content == "hello")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("remove 已存在 ID 后该 pin 被删,文件同步")
    func removeExistingPin() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)

        let pin = Pin(content: "x", origin: .zero)
        _ = await store.add(pin)
        await store.remove(id: pin.id)

        let all = await store.allPins()
        #expect(all.isEmpty)
    }

    @Test("remove 不存在的 ID 为 no-op")
    func removeMissingPinIsNoOp() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)

        let pin = Pin(content: "keep", origin: .zero)
        _ = await store.add(pin)
        await store.remove(id: UUID())

        let all = await store.allPins()
        #expect(all.count == 1)
    }

    @Test("updateOrigin 改 origin + 落盘,id 不存在为 no-op")
    func updateOrigin() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)

        let pin = Pin(content: "p", origin: NSPoint(x: 0, y: 0))
        _ = await store.add(pin)
        await store.updateOrigin(id: pin.id, origin: NSPoint(x: 500, y: 600))

        let all = await store.allPins()
        #expect(all.first?.origin == NSPoint(x: 500, y: 600))

        // 不存在 ID no-op
        await store.updateOrigin(id: UUID(), origin: NSPoint(x: 999, y: 999))
        let all2 = await store.allPins()
        #expect(all2.first?.origin == NSPoint(x: 500, y: 600))
    }

    // MARK: - 上限裁剪 (maxPins = 8)

    @Test("add 触发上限 → 返回被裁掉的最旧 pin")
    func addBeyondCapTrimsOldest() async {
        let url = makeTempStoreURL()
        defer { cleanup(url) }
        let store = PinStore(storeURL: url)

        var addedIDs: [UUID] = []
        // 先放满 8 张,createdAt 递增确保排序确定性
        for i in 0..<PinStore.maxPins {
            let pin = Pin(
                content: "p\(i)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(1000 + i)),
                origin: .zero
            )
            addedIDs.append(pin.id)
            _ = await store.add(pin)
        }
        #expect(await store.allPins().count == PinStore.maxPins)

        // 第 9 张:触发裁剪,最旧的(第 0 张)应被丢
        let newPin = Pin(
            content: "newest",
            createdAt: Date(timeIntervalSince1970: 9000),
            origin: .zero
        )
        let dropped = await store.add(newPin)

        #expect(dropped.count == 1)
        #expect(dropped.first?.id == addedIDs[0])
        let all = await store.allPins()
        #expect(all.count == PinStore.maxPins)
        // 最旧 (p0) 被裁,最新 (newest) 在
        #expect(all.contains(where: { $0.content == "newest" }))
        #expect(all.contains(where: { $0.content == "p0" }) == false)
    }

    // MARK: - 持久化 round-trip

    @Test("add 后新 PinStore 实例 load 回相同数据 (round-trip)")
    func persistenceRoundTrip() async throws {
        let url = makeTempStoreURL()
        defer { cleanup(url) }

        // 写入
        do {
            let writer = PinStore(storeURL: url)
            _ = await writer.add(Pin(content: "first", origin: NSPoint(x: 10, y: 20)))
            _ = await writer.add(Pin(content: "second", origin: NSPoint(x: 30, y: 40)))
        }

        // 新实例从磁盘读
        let reader = PinStore(storeURL: url)
        let loaded = try await reader.load()
        #expect(loaded.count == 2)
        #expect(loaded.contains(where: { $0.content == "first" && $0.origin == NSPoint(x: 10, y: 20) }))
        #expect(loaded.contains(where: { $0.content == "second" && $0.origin == NSPoint(x: 30, y: 40) }))
    }

    @Test("clear 后落盘文件内容是空数组,load 回零")
    func clearWipes() async throws {
        let url = makeTempStoreURL()
        defer { cleanup(url) }

        let writer = PinStore(storeURL: url)
        _ = await writer.add(Pin(content: "x", origin: .zero))
        await writer.clear()

        let reader = PinStore(storeURL: url)
        let loaded = try await reader.load()
        #expect(loaded.isEmpty)
    }
}
