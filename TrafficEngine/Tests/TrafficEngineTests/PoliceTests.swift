import XCTest
@testable import TrafficEngine

/// M5: stations, patrols, incidents, dispatch, emergency driving, civilians' response.
final class PoliceTests: XCTestCase {

    /// Residential streets a patrol can drive (not stubs that only lead off the map).
    private func patrolStreets(_ sim: Simulation) -> Set<EdgeID> {
        var s = Set<EdgeID>()
        for b in sim.city.buildings where b.kind.isResidential {
            guard let a = b.access, let e = sim.network.edge(a.edge) else { continue }
            if !(sim.network.node(e.to)?.isRegionalConnection ?? true) { s.insert(a.edge) }
        }
        return s
    }

    func testStationsDeployPatrolsAroundHomes() {
        let sim = ScenarioFactory.make(.suburb, side: .right, seed: 1)
        XCTAssertEqual(sim.police.units.count, Simulation.unitsPerStation)
        let streets = patrolStreets(sim)
        XCTAssertGreaterThan(streets.count, 10)
        let checker = sim.runChecked(seconds: 3 * 3600)
        let visited = streets.filter { sim.police.lastVisit[$0.raw] != nil }
        let coverage = Double(visited.count) / Double(streets.count)
        XCTAssertGreaterThanOrEqual(coverage, 0.8, "patrols visited \(visited.count)/\(streets.count) residential streets")
        XCTAssertEqual(checker.total, 0, checker.summary() + "\n" + checker.samples.prefix(5).map { "\($0)" }.joined(separator: "\n"))
    }

    /// Civilians ahead of a responding unit move towards the kerb (the right
    /// for `.right`, the left for `.left`) and slow below 3 m/s; the unit
    /// reaches the incident.
    func testCiviliansYieldAndTheUnitReachesTheIncident() {
        for side in DrivingSide.allCases {
            var cfg = SimulationConfig(); cfg.incidentsPerThousandPerDay = 0
            let sim = ScenarioFactory.make(.suburb, side: side, seed: 3, config: cfg)
            sim.run(seconds: 600)          // patrols out, morning traffic building up
            // An incident at the home farthest from every unit.
            let units = sim.police.units.compactMap { $0.vehicle.flatMap { sim.index(of: $0) } }.map { sim.vehicles[$0].center }
            let target = sim.city.buildings.filter { $0.kind.isResidential && $0.access != nil }
                .max { a, b in
                    (units.map { $0.distance(to: a.center) }.min() ?? 0) < (units.map { $0.distance(to: b.center) }.min() ?? 0)
                }!
            let incident = sim.createIncident(at: target.id)!
            var ahead: [VehicleID: Double] = [:]     // civilian → seconds spent close ahead of a siren
            var checked = 0, failures: [String] = []
            let checker = sim.runChecked(seconds: 900) {
                var now = Set<VehicleID>()
                // (Not `sirenSources`: its indices go stale once finished cars are compacted away.)
                for (s, p) in sim.vehicles.enumerated() where p.siren && p.mode != .finished {
                    guard case .edge(let e) = p.track else { continue }
                    for (j, v) in sim.vehicles.enumerated() where j != s && v.track == p.track && v.purpose != .emergency && v.mode == .driving {
                        let gap = v.s - p.s
                        guard gap > 5 && gap < 60 else { continue }
                        now.insert(v.id)
                        let t = (ahead[v.id] ?? 0) + sim.config.dt
                        ahead[v.id] = t
                        guard t > 6, let edge = sim.network.edge(e), let lane = edge.lane(v.lane) else { continue }
                        checked += 1
                        let towardKerb = (v.lateral - lane.lateral) * side.kerbSign
                        let nearLine = edge.length - v.s < 35 || v.s < v.length + 4
                        if v.speed >= 3 { failures.append("\(v.id) at \(v.speed) m/s \(Int(gap)) m ahead of a siren") }
                        if !nearLine && v.laneChange == nil && towardKerb < 0.3 && !sim.parkedBeside(j) {
                            failures.append("\(v.id) did not move towards the kerb (\(towardKerb) m)")
                        }
                    }
                }
                for k in ahead.keys where !now.contains(k) { ahead[k] = nil }
            }
            let inc = sim.police.incidents[incident.raw]
            XCTAssertNotNil(inc.arrived, "\(side): the unit reached the incident")
            if let arr = inc.arrived { XCTAssertLessThan(arr - inc.created, 600, "\(side): response time") }
            XCTAssertTrue(failures.isEmpty, "\(side): \(failures.count)/\(checked) checks failed: \(failures.prefix(5))")
            XCTAssertEqual(checker.total, 0, "\(side): " + checker.summary() + "\n" + checker.samples.prefix(5).map { "\($0)" }.joined(separator: "\n"))
        }
    }

    /// Through a red signal only after slowing right down at the line.
    func testSirenEntersOnRedOnlyAfterSlowing() {
        for side in DrivingSide.allCases {
            let (sim, c, arms) = Micro.crossroads(side, cls: .arterial, control: .signal, seed: 5)
            sim.network.updateNode(c) { $0.control.signal.mode = .fixedTime; $0.control.signal.cycleLength = 90 }
            let east = Micro.edges(sim, arm: arms[0], centre: c), west = Micro.edges(sim, arm: arms[2], centre: c)
            var redEntries = 0, fastRedEntries = 0
            sim.onJunctionEntry = { v, conn, ind in
                guard v.siren, conn.node == c else { return }
                if ind == .red {
                    redEntries += 1
                    if v.speed > 3.5 { fastRedEntries += 1 }
                }
            }
            var next = 0.0
            _ = sim.runChecked(seconds: 400) {
                guard sim.time >= next else { return }
                next = sim.time + 23     // arrivals spread over the cycle
                let r = sim.router.route(from: east.inbound, to: west.outbound)!
                if let id = sim.spawnEntering(entry: east.inbound, cls: .police, route: r,
                                              destination: Destination(kind: .exitMap, edge: west.outbound, s: sim.network.edge(west.outbound)!.length),
                                              purpose: .emergency), let i = sim.index(of: id) {
                    sim.vehicles[i].siren = true
                }
            }
            XCTAssertGreaterThan(redEntries, 0, "\(side): some sirens met a red")
            XCTAssertEqual(fastRedEntries, 0, "\(side): entered on red without slowing")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }

    func testMeanResponseTimeIsSensible() {
        for kind in [ScenarioKind.signalGrid, .suburb, .downtown] {
            var cfg = SimulationConfig(); cfg.incidentsPerThousandPerDay = 12
            let sim = ScenarioFactory.make(kind, side: .right, seed: 2, config: cfg)
            sim.run(seconds: 3600)
            guard let mean = sim.police.meanResponseTime else { XCTFail("\(kind): no responses"); continue }
            XCTAssertGreaterThanOrEqual(sim.police.responseTimes.count, 2, "\(kind)")
            XCTAssertTrue((5...600).contains(mean), "\(kind): mean response \(mean) s")
            let coverage = sim.policeCoverage()
            XCTAssertGreaterThan(coverage.count, sim.network.allEdges.count / 2, "\(kind): coverage map")
        }
    }
}
