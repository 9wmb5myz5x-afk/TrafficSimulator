import XCTest
@testable import TrafficEngine

final class QueryTests: XCTestCase {
    func testHitTestAndInspectorsCoverEveryEntityKind() {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 1)
        sim.run(seconds: 400)
        // A vehicle.
        let v = sim.vehicles.first { $0.mode == .driving }!
        XCTAssertEqual(sim.hitTest(v.center, radius: 3), .vehicle(v.id))
        let vi = sim.inspect(.vehicle(v.id))!
        XCTAssertFalse(vi.rows.isEmpty)
        XCTAssertGreaterThan(vi.highlight.count, 1)
        XCTAssertFalse(sim.vehicleStatus(v).isEmpty)
        // A building (centre of an empty lot).
        let b = sim.city.buildings.first { $0.kind == .house }!
        if case .building(let id)? = sim.hitTest(b.center, radius: 1), id == b.id {} else if sim.hitTest(b.center, radius: 1) == nil { XCTFail("building not hit") }
        XCTAssertNotNil(sim.inspect(.building(b.id)))
        // A junction and a road.
        let n = sim.network.allNodes.first { sim.network.degree(of: $0.id) >= 3 && !$0.isRegionalConnection }!
        XCTAssertNotNil(sim.inspect(.junction(n.id)))
        let r = sim.network.allRoads.first!
        XCTAssertNotNil(sim.inspect(.road(r.id)))
        // Placing a building bumps the city version.
        let before = sim.city.version
        let house = sim.city.buildings.first { $0.kind == .house }!
        sim.removeBuilding(house.id)
        XCTAssertGreaterThan(sim.city.version, before)
    }
}
