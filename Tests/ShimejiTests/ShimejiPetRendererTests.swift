import Foundation
import Testing
import Context
import PetBehavior
import Rendering
@testable import Shimeji

/// ShimejiPetRenderer 接线:自管窗口位置标记 + 指针 hijack 转引擎行为(抓起→Dragged / 释放→Thrown)。
/// 合成最小包(dummy 帧,引擎逻辑不依赖图能加载)。
@MainActor
@Suite("ShimejiPetRenderer")
struct ShimejiPetRendererTests {
    static let actionsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <ActionList>
            <Action Name="Stand" Type="Stay" BorderType="Floor">
                <Animation><Pose Image="/stand.png" ImageAnchor="64,128" Velocity="0,0" Duration="50" /></Animation>
            </Action>
            <Action Name="Pinched" Type="Embedded" Class="com.group_finity.mascot.action.Dragged">
                <Animation><Pose Image="/pinch.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" /></Animation>
            </Action>
            <Action Name="Resisting" Type="Embedded" Class="com.group_finity.mascot.action.Regist">
                <Animation><Pose Image="/pinch.png" ImageAnchor="64,128" Velocity="0,0" Duration="8" /></Animation>
            </Action>
            <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall">
                <Animation><Pose Image="/fall.png" ImageAnchor="64,128" Velocity="0,0" Duration="4" /></Animation>
            </Action>
            <Action Name="Dragged" Type="Sequence" Loop="true">
                <ActionReference Name="Pinched"/><ActionReference Name="Resisting"/>
            </Action>
            <Action Name="Thrown" Type="Sequence" Loop="false">
                <ActionReference Name="Falling" InitialVX="${mascot.environment.cursor.dx}" InitialVY="${mascot.environment.cursor.dy}"/>
            </Action>
            <Action Name="Fall" Type="Sequence"><ActionReference Name="Falling"/></Action>
        </ActionList>
    </Mascot>
    """
    static let behaviorsXML = """
    <Mascot xmlns="http://www.group-finity.com/Mascot">
        <BehaviorList>
            <Behavior Name="Fall" Frequency="0" Hidden="true" />
            <Behavior Name="Dragged" Frequency="0" Hidden="true" />
            <Behavior Name="Thrown" Frequency="0" Hidden="true" />
            <Condition Condition="#{mascot.environment.floor.isOn(mascot.anchor)}">
                <Behavior Name="Stand" Frequency="100" />
            </Condition>
        </BehaviorList>
    </Mascot>
    """

    private func makePack() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rend-\(UUID().uuidString)", isDirectory: true)
        let conf = root.appendingPathComponent("conf"), img = root.appendingPathComponent("img")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
        try Data(Self.actionsXML.utf8).write(to: conf.appendingPathComponent("actions.xml"))
        try Data(Self.behaviorsXML.utf8).write(to: conf.appendingPathComponent("behaviors.xml"))
        for n in ["stand.png", "pinch.png", "fall.png"] {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img.appendingPathComponent(n))   // dummy(引擎逻辑不依赖能解码)
        }
        return root
    }

    private func env() -> BehaviorEnvironment {
        BehaviorEnvironment(
            workArea: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1040),
            activeWindow: .invisible,
            screen: BehaviorArea(left: 0, top: 0, right: 1920, bottom: 1080),
            cursor: BehaviorCursor(x: 400, y: 300, dx: 15, dy: -5))
    }

    @Test("drivesOwnWindowPosition = true")
    func ownsPosition() throws {
        let renderer = try #require(ShimejiPetRenderer(
            packDir: try makePack(), anchor: BehaviorPoint(x: 960, y: -50), environment: env()))
        #expect(renderer.drivesOwnWindowPosition == true)
        // 作为 PetRenderer 协议引用也能读到
        let asProtocol: PetRenderer = renderer
        #expect(asProtocol.drivesOwnWindowPosition == true)
    }

    @Test("handlePointerDown → 抓起转 Dragged 行为")
    func pointerDownDrags() throws {
        let packDir = try makePack()
        defer { try? FileManager.default.removeItem(at: packDir) }
        let renderer = try #require(ShimejiPetRenderer(
            packDir: packDir, anchor: BehaviorPoint(x: 960, y: 1040), environment: env(), seed: 5))
        _ = renderer.advance(environment: env())     // 先正常活动一拍
        renderer.handlePointerDown()
        _ = renderer.advance(environment: env())      // tick 让 Dragged 生效
        #expect(renderer.behaviorName == "Dragged")
    }

    @Test("handlePointerUp(拖拽中)→ 甩出转 Thrown 行为")
    func pointerUpThrows() throws {
        let packDir = try makePack()
        defer { try? FileManager.default.removeItem(at: packDir) }
        let renderer = try #require(ShimejiPetRenderer(
            packDir: packDir, anchor: BehaviorPoint(x: 960, y: 1040), environment: env(), seed: 5))
        _ = renderer.advance(environment: env())
        renderer.handlePointerDown()
        _ = renderer.advance(environment: env())
        #expect(renderer.behaviorName == "Dragged")
        renderer.handlePointerUp()
        _ = renderer.advance(environment: env())
        #expect(renderer.behaviorName == "Thrown")
    }
}
