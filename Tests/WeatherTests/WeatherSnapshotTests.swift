import Foundation
import Testing
@testable import Weather

@Suite("WeatherSnapshot")
struct WeatherSnapshotTests {
    @Test("两个字段全相同的 snapshot equality 为 true")
    func equalityHoldsForIdenticalFields() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = WeatherSnapshot(
            temperature: 5.0,
            windSpeed: 3.2,
            windDirection: 90,
            condition: .snowy,
            timestamp: date
        )
        let b = WeatherSnapshot(
            temperature: 5.0,
            windSpeed: 3.2,
            windDirection: 90,
            condition: .snowy,
            timestamp: date
        )
        #expect(a == b)
    }

    @Test("不同 temperature 视为不同 snapshot")
    func equalityFailsForDifferentTemperature() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = WeatherSnapshot(
            temperature: 5.0,
            windSpeed: 3.2,
            windDirection: 90,
            condition: .snowy,
            timestamp: date
        )
        let b = WeatherSnapshot(
            temperature: -3.0,
            windSpeed: 3.2,
            windDirection: 90,
            condition: .snowy,
            timestamp: date
        )
        #expect(a != b)
    }

    @Test("负 windSpeed 会被 clamp 到 0(不可能负风速)")
    func windSpeedClampsToNonNegative() {
        let snap = WeatherSnapshot(
            temperature: 0,
            windSpeed: -5,
            windDirection: 0,
            condition: .windy
        )
        #expect(snap.windSpeed == 0)
    }

    @Test("超 360 的 windDirection 包裹回 [0, 360)")
    func windDirectionWrapsToValidRange() {
        let snap = WeatherSnapshot(
            temperature: 0,
            windSpeed: 0,
            windDirection: 450,
            condition: .sunny
        )
        #expect(snap.windDirection == 90)
    }

    @Test("负 windDirection 也包裹到 [0, 360)")
    func negativeWindDirectionWraps() {
        let snap = WeatherSnapshot(
            temperature: 0,
            windSpeed: 0,
            windDirection: -30,
            condition: .sunny
        )
        #expect(snap.windDirection == 330)
    }
}
