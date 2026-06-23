import Testing
@testable import Shell

@Test("Bootstrap window graph keeps three-window shell contract")
func bootstrapWindowGraphKeepsThreeWindowContract() {
    let graph = WindowGraph.bootstrap

    #expect(graph.windows.count == 3)
    #expect(graph.windows.map(\.kind) == [.overlay, .pet, .chat])
    #expect(graph.windows.map(\.isInteractive) == [false, true, true])
}
