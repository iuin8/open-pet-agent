import Foundation

/// 内置城市清单。让用户在 Settings 里挑一个,Weather 数据层就拉那个城市的
/// 真实天气。覆盖几个有代表性的纬度/气候带,既能反映用户所在地,也方便
/// 测试雪天物理(挂哈尔滨/海拉尔/雷克雅未克立刻能触发 snowy)。
///
/// 不接 CoreLocation 的原因详见 `WeatherDataProvider.LocationCoordinate`
/// 注释 — SwiftPM CLI app 没法弹 TCC 权限。
public struct CityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let coordinate: LocationCoordinate

    public init(id: String, displayName: String, coordinate: LocationCoordinate) {
        self.id = id
        self.displayName = displayName
        self.coordinate = coordinate
    }
}

public enum CityCatalog {
    /// 全部内置城市。Settings Picker 直接列出 displayName。
    /// 顺序按"用户最可能选"排,默认选项是第一个(北京)。
    public static let all: [CityEntry] = [
        CityEntry(id: "beijing",    displayName: "北京",     coordinate: .init(latitude: 39.9042, longitude: 116.4074)),
        CityEntry(id: "shanghai",   displayName: "上海",     coordinate: .init(latitude: 31.2304, longitude: 121.4737)),
        CityEntry(id: "guangzhou",  displayName: "广州",     coordinate: .init(latitude: 23.1291, longitude: 113.2644)),
        CityEntry(id: "chengdu",    displayName: "成都",     coordinate: .init(latitude: 30.5728, longitude: 104.0668)),
        CityEntry(id: "hangzhou",   displayName: "杭州",     coordinate: .init(latitude: 30.2741, longitude: 120.1551)),
        CityEntry(id: "shenzhen",   displayName: "深圳",     coordinate: .init(latitude: 22.5431, longitude: 114.0579)),
        CityEntry(id: "xian",       displayName: "西安",     coordinate: .init(latitude: 34.3416, longitude: 108.9398)),
        CityEntry(id: "harbin",     displayName: "哈尔滨",   coordinate: .init(latitude: 45.8038, longitude: 126.5350)),
        CityEntry(id: "hailar",     displayName: "海拉尔",   coordinate: .init(latitude: 49.2120, longitude: 119.7710)),
        CityEntry(id: "urumqi",     displayName: "乌鲁木齐", coordinate: .init(latitude: 43.8256, longitude: 87.6168)),
        CityEntry(id: "lhasa",      displayName: "拉萨",     coordinate: .init(latitude: 29.6520, longitude: 91.1721)),
        CityEntry(id: "sanya",      displayName: "三亚",     coordinate: .init(latitude: 18.2528, longitude: 109.5119)),
        // 海外参考点 — 不同气候带方便对比测试
        CityEntry(id: "tokyo",      displayName: "东京",     coordinate: .init(latitude: 35.6762, longitude: 139.6503)),
        CityEntry(id: "newyork",    displayName: "纽约",     coordinate: .init(latitude: 40.7128, longitude: -74.0060)),
        CityEntry(id: "london",     displayName: "伦敦",     coordinate: .init(latitude: 51.5072, longitude: -0.1276)),
        CityEntry(id: "reykjavik",  displayName: "雷克雅未克", coordinate: .init(latitude: 64.1466, longitude: -21.9426))
    ]

    /// UserDefaults key — 城市选择持久化。
    public static let userDefaultsKey = "weatherCityID"

    /// 默认城市(北京)。第一次启动或用户未选时用。
    public static let `default`: CityEntry = all[0]

    /// 按 ID 查找,找不到返回默认。
    public static func city(forID id: String?) -> CityEntry {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return `default`
        }
        return match
    }
}
