import XCTest
@testable import TrafficEngine

/// The network's `geometryVersion` moves only when its shape does, so a
/// control change (which the warrant review makes many times an hour on a
/// busy map) doesn't make the city and the renderer redo the whole map.
final class NetworkVersionTests: XCTestCase {

    func testControlChangeKeepsGeometryVersion() {
        for kind in [ScenarioKind.downtown, .stressCity] {
            let sim = ScenarioFactory.make(kind, side: .right, seed: 1, config: SimulationConfig())
            let net = sim.network
            guard let n = net.allNodes.first(where: { net.degree(of: $0.id) >= 3 && !$0.isRegionalConnection }) else {
                XCTFail("\(kind): no junction"); continue
            }
            let accessBefore = sim.city.buildings.map(\.access)
            let v0 = net.version, g0 = net.geometryVersion
            net.updateNode(n.id) { $0.warrantControl = $0.warrantControl == .signal ? .allWayStop : .signal }
            sim.networkDidChange()
            XCTAssertGreaterThan(net.version, v0, "\(kind): the control change rebuilt the network")
            XCTAssertEqual(net.geometryVersion, g0, "\(kind): but not its shape")
            XCTAssertEqual(sim.city.buildings.map(\.access), accessBefore, "\(kind): driveways stay put")
            for _ in 0..<200 { sim.step() }
        }
    }

    func testShapeChangeBumpsGeometryVersion() throws {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 2, config: SimulationConfig())
        let g0 = sim.network.geometryVersion
        let b = sim.terrain
        let editor = Editor(sim: sim)
        _ = try editor.drawRoad([Vector2(b.minCorner.x + 40, b.minCorner.y + 40), Vector2(b.minCorner.x + 140, b.minCorner.y + 45)], roadClass: .local)
        sim.networkDidChange()
        XCTAssertGreaterThan(sim.network.geometryVersion, g0, "a new road changes the shape")
    }
}
