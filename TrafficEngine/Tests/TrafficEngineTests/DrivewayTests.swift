import XCTest
@testable import TrafficEngine

/// Cars drive along real driveways between the building and the road.
final class DrivewayTests: XCTestCase {

    /// Every driveway is a smooth path ending at its mouth on the kerb side,
    /// angled into the direction of traffic, with paving to draw.
    func testDrivewayGeometryIsSmoothAndEndsAtTheMouth() {
        for kind in [ScenarioKind.suburb, .downtown, .stressCity] {
            for side in [DrivingSide.right, .left] {
                let sim = ScenarioFactory.make(kind, side: side, seed: 3, config: SimulationConfig())
                var count = 0
                for b in sim.city.buildings {
                    guard let a = b.access, let edge = sim.network.edge(a.edge) else { continue }
                    guard let path = sim.drivewayPath(for: b) else { XCTFail("\(b.id) has no driveway"); continue }
                    count += 1
                    let mouth = edge.position(s: a.s, lateral: a.drivewayLateral)
                    XCTAssertLessThan(path.end.distance(to: mouth), 1e-6)
                    XCTAssertGreaterThan(path.minimumRadius, 1.5, "\(kind) \(side) \(b.id): driveway too tight")
                    // Leaving: heading with the traffic, at the mouth angle.
                    let turn = DMath.angleDifference(edge.reference.tangent(at: a.s).angle, path.endTangent.angle)
                    XCTAssertEqual(abs(turn), Simulation.drivewayMouthAngle, accuracy: 0.05)
                    XCTAssertGreaterThanOrEqual(sim.drivewaySurfaces(for: b).count, 2)
                }
                XCTAssertGreaterThan(count, 50)
            }
        }
    }

    /// Cars leave down the driveway (fading out of the garage), wait at the
    /// mouth and pull out; arriving cars turn off the lane, drive up the
    /// driveway and disappear into the building — all without breaking an
    /// invariant.
    func testCarsUseDriveways() {
        var cfg = SimulationConfig(); cfg.startClock = 7 * 3600
        let sim = ScenarioFactory.make(.suburb, side: .left, seed: 5, config: cfg)
        let checker = InvariantChecker()
        sim.invariantChecker = checker
        var leaving = Set<VehicleID>(), arriving = Set<VehicleID>(), joined = Set<VehicleID>()
        var sawHidden = false, sawFading = false
        for _ in 0..<Int(900 / cfg.dt) {
            sim.step()
            for v in sim.vehicles {
                if v.mode == .onDriveway, let r = v.driveway {
                    if r.inbound { arriving.insert(v.id) } else { leaving.insert(v.id) }
                    if v.visibility == 0 { sawHidden = true }
                    if v.visibility > 0.05 && v.visibility < 0.95 { sawFading = true }
                } else if leaving.contains(v.id) && (v.mode == .pullingOut || v.mode == .driving) {
                    joined.insert(v.id)
                }
            }
        }
        XCTAssertGreaterThan(leaving.count, 20)
        XCTAssertGreaterThan(joined.count, 10, "cars leaving their driveways join the road")
        XCTAssertGreaterThan(arriving.count, 5)
        XCTAssertTrue(sawHidden && sawFading, "cars fade in and out of their garages")
        XCTAssertEqual(checker.total, 0, checker.summary() + "\n" + checker.samples.prefix(3).map { "\($0)" }.joined(separator: "\n"))
    }

    /// A save made with cars on driveways loads and carries on.
    func testDrivewayStateSurvivesSaveAndLoad() throws {
        var cfg = SimulationConfig(); cfg.startClock = 7.5 * 3600
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 6, config: cfg)
        var guardSteps = 0
        repeat { sim.step(); guardSteps += 1 } while !sim.vehicles.contains { $0.mode == .onDriveway } && guardSteps < 20000
        let before = sim.vehicles.filter { $0.mode == .onDriveway }
        XCTAssertFalse(before.isEmpty)
        let data = try JSONEncoder().encode(sim.vehicles)
        let back = try JSONDecoder().decode([Vehicle].self, from: data)
        let after = back.filter { $0.mode == .onDriveway }
        XCTAssertEqual(after.map(\.driveway), before.map(\.driveway))
    }
}
