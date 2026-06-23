// Sources/App/CoreLocationCoordinateAdapter.swift
// App 层 CoreLocation 包装。Weather 模块保持 CoreLocation-free(见 WeatherDataProvider.swift 注释)。
//
// **懒建** CLLocationManager:仅设置面板查状态 / 自动定位开启时才建,
// 不在 app 启动时建 —— 启动建会触发 TCC dialog 莫名拦截,尤其 `swift run` CLI。
import CoreLocation
import Rendering
import Shell
import Weather

/// App 层位置授权协议。Weather 模块依赖此协议(通过 App 注入),保持自身 CoreLocation-free。
@MainActor
public protocol LocationAuthorizing: AnyObject {
    /// 当前位置授权状态。
    var permissionStatus: PermissionStatus { get }
    /// 请求"使用期间"位置授权(弹系统授权框)。
    func requestAuthorization()
    /// 请求一次性位置坐标;已授权时回调坐标,未授权或失败时回调 nil。
    func requestOneShotLocation(_ completion: @escaping (LocationCoordinate?) -> Void)
    /// 把坐标逆地理编码成城市名(失败回 nil)。供「自动跟随位置」显示真实城市,让用户判断定位是否准。
    func reverseGeocode(_ coordinate: LocationCoordinate, completion: @escaping (String?) -> Void)
}

/// `LocationAuthorizing` 的真实实现:包装 `CLLocationManager`,懒建避免启动时 TCC 拦截。
@MainActor
public final class CoreLocationCoordinateAdapter: NSObject, LocationAuthorizing, @preconcurrency CLLocationManagerDelegate {

    // MARK: - 懒建 CLLocationManager

    /// 仅在首次访问 permissionStatus / requestAuthorization / requestOneShotLocation 时才建。
    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()

    /// 逆地理编码器(坐标 → 城市名)。懒建避免无谓开销。
    private lazy var geocoder = CLGeocoder()

    /// 一次性定位回调;收到结果后清空。
    private var oneShot: ((LocationCoordinate?) -> Void)?

    /// 一次性定位的代次令牌:每次发起 requestLocation 自增,用于让超时只杀**自己那次**请求
    /// (新请求 / didUpdate / didFail 都会自增 → 旧请求的待发超时自动作废)。
    private var oneShotGeneration = 0

    // MARK: - 静态纯映射(供单元测试独立调用,不触碰真 manager)

    /// `CLAuthorizationStatus` → `PermissionStatus` 纯映射。
    /// `nonisolated` + `static`:不依赖 actor 状态,测试直接同步调用无需 await。
    public nonisolated static func mapAuthStatus(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorizedAlways, .authorized, .authorizedWhenInUse:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    // MARK: - LocationAuthorizing

    /// 当前位置授权状态。访问此属性会触发懒建 `manager`(即首次查状态就建 CLLocationManager)。
    public var permissionStatus: PermissionStatus {
        Self.mapAuthStatus(manager.authorizationStatus)
    }

    public func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    public func requestOneShotLocation(_ completion: @escaping (LocationCoordinate?) -> Void) {
        if let pending = oneShot { pending(nil) }   // 旧请求以 nil 明确结束，避免静默丢弃
        oneShot = completion
        switch permissionStatus {
        case .granted:
            startOneShotRequest()
        case .notDetermined:
            // 首次未决定:先弹授权框,授权跃迁到 granted 后由 didChangeAuthorization 补取
            // (不在此处直接 nil → 根治「首次开关点了允许后天气没反应、要再 toggle」)。
            manager.requestWhenInUseAuthorization()
        case .denied, .reserved:
            oneShot = nil
            completion(nil)
        }
    }

    public func reverseGeocode(_ coordinate: LocationCoordinate, completion: @escaping (String?) -> Void) {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        Task { @MainActor in
            // async API + @MainActor Task:completion 在主 actor 调,免 Sendable 麻烦。
            let placemarks = try? await geocoder.reverseGeocodeLocation(loc)
            // 城市名优先 locality(市),回落 subAdministrativeArea(区/县)/ administrativeArea(省)。
            completion(placemarks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea })
        }
    }

    /// 发起一次 `requestLocation` + 挂 10s 超时(代次令牌防误杀新请求)。
    /// 室内无信号 / 定位漂移导致回调永不来时,超时以 nil 结束 → 上层天气回落城市坐标。
    private func startOneShotRequest() {
        oneShotGeneration += 1
        let gen = oneShotGeneration
        manager.requestLocation()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard oneShotGeneration == gen, let pending = oneShot else { return }   // 已被新请求/回调取代
            oneShot = nil
            SnowDiagnostics.log("locationTimeout gen=\(gen)")
            pending(nil)
        }
    }

    // MARK: - CLLocationManagerDelegate

    /// 授权态跃迁(用户在系统框点允许/拒绝后回调)。首次 notDetermined→granted 时补发取位。
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CLLocationManagerDelegate 回调投递在 main → 跳回 MainActor 安全访问 oneShot。
        MainActor.assumeIsolated {
            switch Self.mapAuthStatus(manager.authorizationStatus) {
            case .granted:
                if oneShot != nil { startOneShotRequest() }
            case .denied:
                let pending = oneShot
                oneShot = nil
                pending?(nil)
            case .notDetermined, .reserved:
                break
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        oneShotGeneration += 1   // 作废该请求的待发超时
        let coord = locations.last.map {
            LocationCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        oneShot?(coord)
        oneShot = nil
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        oneShotGeneration += 1   // 作废该请求的待发超时
        SnowDiagnostics.log("locationFailed error=\(error)")
        oneShot?(nil)
        oneShot = nil
    }
}
