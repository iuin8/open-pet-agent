import Testing
@testable import App

@MainActor
@Suite("IdleSleepingFanout")
struct IdleSleepingFanoutTests {
    @Test("多订阅者都收到同一布尔")
    func fanout() {
        let fanout = IdleSleepingFanout()
        var a: [Bool] = []
        var b: [Bool] = []
        fanout.subscribe { a.append($0) }
        fanout.subscribe { b.append($0) }
        fanout.emit(true)
        fanout.emit(false)
        #expect(a == [true, false])
        #expect(b == [true, false])
    }
}
