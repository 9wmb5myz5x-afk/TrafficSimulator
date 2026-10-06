import XCTest
@testable import TrafficEngine

final class EditTests: XCTestCase {

    /// A road drawn across the corridor creates a junction there; traffic keeps
    /// flowing without violations; undo / redo restore the network exactly.
    func testDrawCrossingRoadCreatesJunctionAndUndoes() throws {
        for side in [DrivingSide.right, .left] {
            let sim = ScenarioFactory.make(.corridor, side: side, seed: 3)
            sim.invariantChecker = InvariantChecker()
            sim.run(seconds: 300)
            let editor = Editor(sim: sim)
            let before = sim.network.data
            let nodesBefore = sim.network.allNodes.count
            // North–south street crossing the arterial at x = 300 (the arterial is near y ≈ -10 there).
            let made = try editor.drawRoad([Vector2(300, -200), Vector2(302, -60), Vector2(300, 120), Vector2(298, 220)],
                                           roadClass: .local)
            XCTAssertEqual(made.count, 2, "\(side): split into two roads at the crossing")
            let junction = sim.network.allNodes.first { sim.network.degree(of: $0.id) == 4 }
            XCTAssertNotNil(junction, "\(side): a 4-way junction where the roads cross")
            XCTAssertEqual(sim.network.allNodes.count, nodesBefore + 3, "\(side): two ends + the crossing")
            XCTAssertTrue(editor.canUndo)

            sim.run(seconds: 600)
            XCTAssertEqual(sim.invariantChecker?.total, 0, "\(side): \(sim.invariantChecker?.summary() ?? "") \(sim.invariantChecker?.samples.map { $0.description } ?? [])")

            editor.undo()
            XCTAssertEqual(sim.network.data, before, "\(side): undo restores the network")
            XCTAssertTrue(editor.canRedo)
            sim.run(seconds: 300)
            XCTAssertEqual(sim.invariantChecker?.total, 0, "\(side) after undo: \(sim.invariantChecker?.summary() ?? "")")

            editor.redo()
            XCTAssertNotNil(sim.network.allNodes.first { sim.network.degree(of: $0.id) == 4 }, "\(side): redo")
            sim.run(seconds: 300)
            XCTAssertEqual(sim.invariantChecker?.total, 0, "\(side) after redo: \(sim.invariantChecker?.summary() ?? "")")
        }
    }

    func testStockMapsHaveNoOverlappingCarriageways() {
        for kind in ScenarioKind.allCases {
            for side in DrivingSide.allCases {
                let m = ScenarioNetworks.make(kind, side: side)
                let found = Editor.encroachments(m.network)
                let what = found.map { k in k.dropFirst(8).split(separator: ",").compactMap { Int($0) }.map { r -> String in
                    let road = m.network.road(RoadID(r))
                    return "R\(r) \(road.map { "\($0.roadClass) lvl\($0.level) oneWay=\($0.isOneWay)" } ?? "?") nodes=\(m.network.allEdges.filter { $0.road == RoadID(r) }.map { "\($0.from)->\($0.to)" })"
                }.joined(separator: " | ") }
                XCTAssertEqual(found, [], "\(kind) \(side) \(what)")
            }
        }
    }

    func testValidationRejectsBadInput() {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 1)
        let editor = Editor(sim: sim)
        XCTAssertThrowsError(try editor.drawRoad([Vector2(0, 100), Vector2(5, 100)], roadClass: .local))
        XCTAssertThrowsError(try editor.drawRoad([Vector2(0, 100), Vector2(0, 5000)], roadClass: .local))
        XCTAssertThrowsError(try editor.drawRoad([Vector2(0, 100), Vector2(100, 100)], roadClass: .local, lanes: 7))
        XCTAssertThrowsError(try editor.bulldoze(at: Vector2(0, 280), radius: 5))
        XCTAssertFalse(editor.canUndo, "failed edits leave no history")
    }

    /// Changing, re-controlling and removing roads keep the simulation valid.
    func testRoadAndJunctionEditsWhileSimulating() throws {
        let sim = ScenarioFactory.make(.signalGrid, side: .right, seed: 2)
        sim.invariantChecker = InvariantChecker()
        sim.run(seconds: 400)
        let editor = Editor(sim: sim)
        let junction = sim.network.allNodes.first { sim.network.degree(of: $0.id) == 4 }!
        try editor.setControl(junction.id, to: .allWayStop, locked: true)
        sim.run(seconds: 200)
        let road = sim.network.allRoads.first { $0.a == junction.id || $0.b == junction.id }!
        try editor.changeRoad(road.id, roadClass: .collector, lanes: 1)
        sim.run(seconds: 200)
        try editor.removeRoad(road.id)
        XCTAssertNil(sim.network.road(road.id))
        sim.run(seconds: 400)
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        editor.undo(); editor.undo(); editor.undo()
        XCTAssertNotNil(sim.network.road(road.id))
        sim.run(seconds: 300)
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
    }

    func testPlaceAndBulldozeBuildingWithUndo() throws {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 5)
        let editor = Editor(sim: sim)
        let count = sim.city.buildings.count
        // Find a free spot beside the arterial.
        var placed: BuildingID?
        search: for y in [-40.0, 40, -55, 55, -70, 70] {
            for x in stride(from: -650.0, through: 650, by: 7) {
                if case .success(let id) = editor.placeBuilding(.house, at: Vector2(x, y)) { placed = id; break search }
            }
        }
        let id = try XCTUnwrap(placed, "found somewhere to build")
        XCTAssertEqual(sim.city.buildings.count, count + 1)
        let b = try XCTUnwrap(sim.city.building(id))
        try editor.bulldoze(at: b.center, radius: 4)
        XCTAssertEqual(sim.city.buildings.count, count)
        editor.undo()
        XCTAssertEqual(sim.city.buildings.count, count + 1, "undo bulldoze")
        editor.undo()
        XCTAssertEqual(sim.city.buildings.count, count, "undo place")
        editor.redo()
        XCTAssertEqual(sim.city.buildings.count, count + 1, "redo place")
        sim.run(seconds: 300)
    }

    /// The sandbox flow: from empty land, draw a street off the regional road,
    /// add homes, a shop and a police station; trips start and a patrol car
    /// heads out — with no invariant violations.
    func testBuildSmallTownFromEmptyLand() throws {
        for side in [DrivingSide.right, .left] {
            var cfg = SimulationConfig()
            cfg.startClock = 7 * 3600
            let sim = ScenarioFactory.make(.emptyLand, side: side, seed: 2, config: cfg)
            sim.invariantChecker = InvariantChecker()
            XCTAssertEqual(sim.city.buildings.count, 0)
            let editor = Editor(sim: sim)
            let roads = try editor.drawRoad([Vector2(-520, 0), Vector2(-350, 10), Vector2(-150, 0)], roadClass: .local)
            XCTAssertFalse(roads.isEmpty)
            try editor.drawRoad([Vector2(-350, 10), Vector2(-350, 200)], roadClass: .local)
            var homes = 0
            for x in stride(from: -480.0, through: -180, by: 25) {
                if case .success = editor.placeBuilding(.house, near: Vector2(x, 30), search: 12) { homes += 1 }
            }
            for y in stride(from: 60.0, through: 180, by: 25) {
                if case .success = editor.placeBuilding(.townhouse, near: Vector2(-325, y), search: 12) { homes += 1 }
            }
            XCTAssertGreaterThan(homes, 10, "\(side)")
            guard case .success = editor.placeBuilding(.shop, near: Vector2(-300, -30), search: 20),
                  case .success = editor.placeBuilding(.office, near: Vector2(-220, -30), search: 20),
                  case .success = editor.placeBuilding(.policeStation, near: Vector2(-420, -35), search: 25) else {
                return XCTFail("\(side): could not place the shop / office / police station")
            }
            var sawPatrol = false
            sim.run(seconds: 3600 * 2 / 8)    // two clock hours with the default 8× clock
            for _ in 0..<Int(1800 / sim.config.dt) {
                sim.step()
                if sim.vehicles.contains(where: { $0.cls == .police && $0.mode == .driving }) { sawPatrol = true }
            }
            XCTAssertGreaterThan(sim.city.population, 20, "\(side): people moved in")
            XCTAssertGreaterThan(sim.metrics.aggregate.completedTrips, 5, "\(side): trips happen")
            XCTAssertTrue(sawPatrol, "\(side): a patrol car drives out")
            XCTAssertEqual(sim.invariantChecker?.total, 0, "\(side): \(sim.invariantChecker?.summary() ?? "") \(sim.invariantChecker?.samples.prefix(8).map { $0.description } ?? [])")
        }
    }
}
