import Testing
@testable import Shell

@Test("四项权限 + 文案/可操作性")
func systemPermissionMetadata() {
    #expect(SystemPermission.allCases.count == 4)
    #expect(SystemPermission.accessibility.displayName == "辅助功能")
    #expect(SystemPermission.screenRecording.displayName == "屏幕录制")
    #expect(SystemPermission.location.displayName == "位置")
    #expect(SystemPermission.appleEvents.displayName == "Apple Events")
    // appleEvents 不可操作(只读展示「已声明·未使用」)
    #expect(SystemPermission.appleEvents.isActionable == false)
    for p in SystemPermission.allCases where p != .appleEvents {
        #expect(p.isActionable)
        #expect(!p.purpose.isEmpty)
        #expect(!p.symbolName.isEmpty)
    }
}

@Test("PermissionStatus 四态可等值")
func permissionStatusEquatable() {
    #expect(PermissionStatus.granted == .granted)
    #expect(PermissionStatus.denied != .granted)
}
