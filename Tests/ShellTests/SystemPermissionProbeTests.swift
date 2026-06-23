import Testing
@testable import Shell

@MainActor
@Test("status:appleEvents 恒 reserved;其余读注入闭包")
func probeStatusMapping() {
    let probe = SystemPermissionProbe(
        accessibilityStatus: { .granted },
        screenRecordingStatus: { .denied },
        locationStatus: { .notDetermined }
    )
    #expect(probe.status(for: .accessibility) == .granted)
    #expect(probe.status(for: .screenRecording) == .denied)
    #expect(probe.status(for: .location) == .notDetermined)
    #expect(probe.status(for: .appleEvents) == .reserved)
}

@MainActor
@Test("request 按当前态分流:notDetermined→申请;denied→开系统设置;granted→no-op")
func probeRequestRouting() {
    var requested: [String] = []
    var opened: [SystemPermission] = []
    var locState: PermissionStatus = .notDetermined
    let probe = SystemPermissionProbe(
        locationStatus: { locState },
        requestLocation: { requested.append("loc") },
        openSettings: { opened.append($0) }
    )
    // notDetermined → 调申请闭包
    probe.request(.location)
    #expect(requested == ["loc"])
    #expect(opened.isEmpty)
    // denied → 开系统设置
    locState = .denied
    probe.request(.location)
    #expect(requested == ["loc"])      // 不再申请
    #expect(opened == [.location])
    // granted → no-op
    locState = .granted
    probe.request(.location)
    #expect(opened == [.location])     // 没新增
    // reserved → no-op(brief 要求 granted/reserved 都 no-op;虽真实 actionable 权限不会产 reserved,显式验分支)
    locState = .reserved
    probe.request(.location)
    #expect(requested == ["loc"])
    #expect(opened == [.location])
    // appleEvents(reserved)→ no-op,不崩,且不调任何 request/openSettings 闭包
    probe.request(.appleEvents)
    #expect(requested == ["loc"])
    #expect(opened == [.location])
}

@MainActor
@Test("request 分流对 accessibility / screenRecording 同样生效(非仅 location)")
func probeRequestRoutingOtherPermissions() {
    var ax = 0, sr = 0
    var opened: [SystemPermission] = []
    var axState: PermissionStatus = .notDetermined
    let probe = SystemPermissionProbe(
        accessibilityStatus: { axState },
        requestAccessibility: { ax += 1 },
        screenRecordingStatus: { .notDetermined },
        requestScreenRecording: { sr += 1 },
        openSettings: { opened.append($0) }
    )
    probe.request(.accessibility)        // notDetermined → 申请
    probe.request(.screenRecording)      // notDetermined → 申请
    #expect(ax == 1)
    #expect(sr == 1)
    axState = .denied
    probe.request(.accessibility)        // denied → 开系统设置
    #expect(ax == 1)                     // 不再申请
    #expect(opened == [.accessibility])
}
