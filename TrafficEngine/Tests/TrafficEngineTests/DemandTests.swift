import XCTest
@testable import TrafficEngine

/// M4: buildings, population, schedules and physical spawn/despawn.
final class DemandTests: XCTestCase {

    /// Departures per clock hour over the first simulated weekday.
    private func weekdayDepartures(_ sim: Simulation) -> [Int] {
        // The clock starts Monday 05:00; one day is 86400 / clockScale sim-seconds.
        sim.run(seconds: 19 * 3600 / sim.config.clockScale)
        return Array(sim.metrics.state.departuresByClockHour.prefix(24))
    }

    func testWeekdayDemandHasMorningAndEveningPeaks() {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 3)
        let d = weekdayDepartures(sim)
        let am = d[6...9].max()!
        let pm = d[15...18].max()!
        let trough = d[10...14].min()!
        XCTAssertGreaterThan(trough, 0, "midday has some traffic: \(d)")
        XCTAssertGreaterThanOrEqual(Double(am), 2 * Double(trough), "AM peak ≥ 2× midday trough: \(d)")
        XCTAssertGreaterThanOrEqual(Double(pm), 2 * Double(trough), "PM peak ≥ 2× midday trough: \(d)")
        XCTAssertLessThan(d[1...4].reduce(0, +), am, "night is quiet: \(d)")
    }

    func testDemandScalesWithPopulation() {
        // Residents' departures (trucks excluded) from 05:00 to 10:00.
        func morningDepartures(removingEvery k: Int?) -> (departures: Int, population: Int) {
            let sim = ScenarioFactory.make(.suburb, side: .right, seed: 5)
            sim.setExternalRate(perEntryPerHour: 0)
            if let k {
                // Thin out homes and workplaces alike, so the job mix (and so
                // the trip rate per resident) stays the same.
                for kind in [BuildingKind.house, .townhouse, .apartment, .shop, .office, .factory] {
                    for (n, b) in sim.city.buildings.filter({ $0.kind == kind }).enumerated() where n % k != 0 { sim.removeBuilding(b.id) }
                }
            }
            let population = sim.city.population
            var seen = Set<VehicleID>()
            for _ in 0..<Int(5 * 3600 / sim.config.clockScale / sim.config.dt) {
                sim.step()
                for v in sim.vehicles where v.cls != .truck && v.person != nil { seen.insert(v.id) }
            }
            return (seen.count, population)
        }
        let full = morningDepartures(removingEvery: nil)
        let third = morningDepartures(removingEvery: 3)
        XCTAssertGreaterThan(full.departures, 100)
        let popRatio = Double(third.population) / Double(full.population)
        let demandRatio = Double(third.departures) / Double(full.departures)
        XCTAssertLessThan(popRatio, 0.5)
        XCTAssertEqual(demandRatio, popRatio, accuracy: popRatio * 0.3,
                       "departures scale with residents: pop \(third.population)/\(full.population), trips \(third.departures)/\(full.departures)")
    }

    func testDemandMultiplierScalesTrips() {
        func departures(_ m: Double) -> Int {
            var cfg = SimulationConfig()
            cfg.demandMultiplier = m
            let sim = ScenarioFactory.make(.suburb, side: .right, seed: 8, config: cfg)
            sim.setExternalRate(perEntryPerHour: 0)
            sim.run(seconds: 5 * 3600 / sim.config.clockScale)
            return sim.metrics.state.departuresByClockHour.reduce(0, +)
        }
        let one = Double(departures(1)), two = Double(departures(2))
        XCTAssertEqual(two / one, 2, accuracy: 0.5)
    }

    /// Vehicles never appear or vanish on a live lane: they start parked off
    /// the carriageway (in a driveway) or at the map boundary, and end by
    /// pulling into a driveway or by driving off the map.
    func testVehiclesAppearAndDisappearPhysically() {
        let sim = ScenarioFactory.make(.suburb, side: .left, seed: 2)
        var seen = Set<VehicleID>()
        var last: [VehicleID: Vehicle] = [:]
        var driveways = 0, boundary = 0, pulledIn = 0, leftMap = 0
        let steps = Int(2700 / sim.config.dt)   // 05:00 → 11:00
        for _ in 0..<steps {
            sim.step()
            var now: [VehicleID: Vehicle] = [:]
            for v in sim.vehicles {
                now[v.id] = v
                guard !seen.contains(v.id) else { continue }
                seen.insert(v.id)
                guard case .edge(let e) = v.track, let edge = sim.network.edge(e), let lane = edge.lane(v.lane) else {
                    XCTFail("\(v.id) appeared off an edge: \(v.track)"); continue
                }
                if v.mode == .waitingToEnter || v.mode == .pullingOut {
                    XCTAssertGreaterThan(abs(v.lateral - lane.lateral), lane.width / 2 + 1, "\(v.id) appeared in a lane")
                    driveways += 1
                } else {
                    XCTAssertTrue(sim.network.node(edge.from)?.isRegionalConnection ?? false, "\(v.id) appeared mid-network on \(e)")
                    XCTAssertLessThan(v.s, v.length + 1, "\(v.id) appeared beyond the boundary")
                    boundary += 1
                }
            }
            for (id, v) in last where now[id] == nil {
                if v.mode == .pullingIn {
                    pulledIn += 1
                } else {
                    guard case .edge(let e) = v.track, let edge = sim.network.edge(e) else {
                        XCTFail("\(id) vanished off an edge"); continue
                    }
                    XCTAssertTrue(sim.network.node(edge.to)?.isRegionalConnection ?? false, "\(id) vanished mid-network on \(e)")
                    XCTAssertGreaterThan(v.s, edge.length - 1, "\(id) vanished before reaching the boundary")
                    leftMap += 1
                }
            }
            last = now
        }
        XCTAssertGreaterThan(driveways, 20)
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertGreaterThan(pulledIn, 10)
        XCTAssertGreaterThan(leftMap, 0)
    }

    func testResidentsReturnHomeByNight() {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 4)
        sim.run(seconds: 21 * 3600 / sim.config.clockScale)   // to 02:00 Tuesday
        let away = sim.city.people.filter { $0.at != $0.home && $0.role != .trucker }.count
        XCTAssertLessThan(Double(away), Double(sim.city.people.count) * 0.01, "almost everyone is home at 2 am")
        XCTAssertGreaterThan(sim.metrics.aggregate.completedTrips, 300)
    }

    func testPlacementRules() {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 1)
        let net = sim.network
        // On a road: refused.
        let anyNode = net.allNodes.first { !$0.isRegionalConnection }!
        if case .success = sim.placeBuilding(.house, at: anyNode.position) { XCTFail("house on a junction") }
        // Far from any road: refused.
        if case .success = sim.placeBuilding(.house, at: Vector2(-5000, -5000)) { XCTFail("house off the map") }
        // Every placed building has a driveway clear of the junctions on a non-highway road.
        for b in sim.city.buildings {
            guard let a = b.access, let e = net.edge(a.edge) else { XCTFail("\(b.id) has no access"); continue }
            XCTAssertNotEqual(e.roadClass, .highway)
            XCTAssertLessThanOrEqual(a.s, max(e.length - 35, e.length * 0.5) + 1e-6)
        }
    }
}

final class RouterLoopTests: XCTestCase {
    /// Regression: a car that pulls out of a driveway past its destination on
    /// the same edge (or misses a turn there) must be routed round the block,
    /// not given the one-edge route "stay here" (it then ran into the stop line).
    func testRouteLeavingTheGoalEdgeComesBack() {
        let map = ScenarioNetworks.make(.signalGrid, side: .right)
        let sim = Simulation(network: map.network)
        let e = sim.network.allEdges.first { !(sim.network.node($0.from)?.isRegionalConnection ?? true) && !(sim.network.node($0.to)?.isRegionalConnection ?? true) }!.id
        XCTAssertEqual(sim.router.route(from: e, to: e), [e])
        let loop = sim.router.route(from: e, to: e, firstSteps: sim.network.successors(of: e))
        XCTAssertNotNil(loop)
        XCTAssertGreaterThan(loop!.count, 2)
        XCTAssertEqual(loop!.first, e)
        XCTAssertEqual(loop!.last, e)
    }
}
