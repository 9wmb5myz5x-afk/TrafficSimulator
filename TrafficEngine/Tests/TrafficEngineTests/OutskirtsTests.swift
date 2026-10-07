import XCTest
@testable import TrafficEngine

/// The countryside around the map: roads carry on, fields fill the band.
final class OutskirtsTests: XCTestCase {

    func testRegionalRoadsCarryOnIntoTheCountryside() {
        for kind in ScenarioKind.allCases {
            let sim = ScenarioFactory.make(kind, side: .right, seed: 2, config: SimulationConfig())
            let o = sim.outskirts(margin: 900)
            let regional = sim.network.allNodes.filter(\.isRegionalConnection)
            XCTAssertEqual(o.roads.count, regional.count, "\(kind)")
            let mid = (o.inner.min + o.inner.max) * 0.5
            for r in o.roads {
                // Leaves from a connection and heads away from town, well past the margin.
                XCTAssertTrue(regional.contains { $0.position.distance(to: r.line.start) < 1e-6 })
                XCTAssertGreaterThan(r.line.end.distance(to: mid), r.line.start.distance(to: mid) + 900)
                XCTAssertGreaterThan(r.halfWidth, 3)
            }
            // Fields all around, none inside the map.
            XCTAssertGreaterThan(o.fields.count, 40, "\(kind)")
            for f in o.fields {
                let c = f.polygon.reduce(Vector2.zero, +) * (1.0 / Double(f.polygon.count))
                let inside = c.x > o.inner.min.x && c.x < o.inner.max.x && c.y > o.inner.min.y && c.y < o.inner.max.y
                XCTAssertFalse(inside, "\(kind): a field inside the map")
            }
            XCTAssertEqual(sim.outskirts(margin: 900), o, "deterministic")
        }
    }
}
