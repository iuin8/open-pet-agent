// Tests/AppTests/LocationAuthorizingTests.swift
// Task 6: LocationAuthorizing 协议 + 纯映射函数测试。
// ⚠️ 铁律:本文件**不实例化** CoreLocationCoordinateAdapter —— 真实现会建
//   CLLocationManager,SwiftPM CLI 下触发 TCC 拦截导致启动被阻。
//   只测 `static mapAuthStatus` 纯映射 + 自建 mock 协议实现。
import Testing
import CoreLocation
import Shell
import Weather
@testable import App

@Test("CLAuthorizationStatus → PermissionStatus 映射")
func locationAuthMapping() {
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.authorizedAlways) == .granted)
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.authorized) == .granted)
    // .authorizedWhenInUse 在 macOS 标 `@available(macOS, unavailable)`:switch pattern 能列(实现里有),
    // 但作为值引用在 macOS 是编译错误,故只在 iOS 断言;macOS 上 CLLocationManager 不会产此 case。
    #if os(iOS)
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.authorizedWhenInUse) == .granted)
    #endif
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.denied) == .denied)
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.restricted) == .denied)
    #expect(CoreLocationCoordinateAdapter.mapAuthStatus(.notDetermined) == .notDetermined)
}

@MainActor
@Test("mock LocationAuthorizing:授权流 + 坐标回调")
func mockLocationAuthorizing() {
    final class MockLoc: LocationAuthorizing {
        var permissionStatus: PermissionStatus = .notDetermined
        var requested = false
        func requestAuthorization() { requested = true; permissionStatus = .granted }
        func requestOneShotLocation(_ completion: @escaping (LocationCoordinate?) -> Void) {
            completion(LocationCoordinate(latitude: 1, longitude: 2))
        }
        func reverseGeocode(_ coordinate: LocationCoordinate, completion: @escaping (String?) -> Void) {
            completion("测试市")
        }
    }
    let m = MockLoc()
    #expect(m.permissionStatus == .notDetermined)
    m.requestAuthorization()
    #expect(m.requested)
    #expect(m.permissionStatus == .granted)
    var got: LocationCoordinate?
    m.requestOneShotLocation { got = $0 }
    #expect(got == LocationCoordinate(latitude: 1, longitude: 2))
    var city: String?
    m.reverseGeocode(LocationCoordinate(latitude: 1, longitude: 2)) { city = $0 }
    #expect(city == "测试市")
}
