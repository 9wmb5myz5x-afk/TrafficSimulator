import XCTest
@testable import TrafficEngine

/// Level-3 invariant soak (CI length). The long soak (≥ 2 sim-hours × 5 seeds)
/// runs through the CLI: `trafficsim --soak`.
final class SoakTests: XCTestCase {

    func makeSim(_ kind: ScenarioKind, side: DrivingSide, seed: UInt64, through: Double) -> Simulation {
        let map = ScenarioNetworks.make(kind, side: side)
        var cfg = SimulationConfig()
        cfg.seed = seed
        let sim = Simulation(network: map.network, terrain: map.terrain, config: cfg)
        sim.setExternalRate(perEntryPerHour: through)
        return sim
    }

    func testAllScenariosBothSidesHoldInvariants() {
        for kind in ScenarioKind.allCases where kind != .stressCity && kind != .emptyLand {   // empty land: see EditTests
            for side in DrivingSide.allCases {
                let sim = makeSim(kind, side: side, seed: 11, through: 200)
                let checker = sim.runChecked(seconds: 180)
                XCTAssertEqual(checker.total, 0, "\(kind) \(side): \(checker.summary())\n" + checker.samples.prefix(5).map { "\($0)" }.joined(separator: "\n"))
                XCTAssertGreaterThan(sim.metrics.aggregate.completedTrips, 0, "\(kind) \(side): trips complete")
            }
        }
    }

    func testDeterministicGivenSameSeed() {
        func run() -> UInt64 {
            let sim = makeSim(.signalGrid, side: .right, seed: 42, through: 240)
            var h = TraceHasher()
            for k in 0..<2400 {
                sim.step()
                if k % 20 == 0 { h.combine(sim.traceHash()) }
            }
            return h.value
        }
        XCTAssertEqual(run(), run())
    }

    func testDifferentSeedsDiffer() {
        let a = makeSim(.signalGrid, side: .right, seed: 1, through: 240)
        let b = makeSim(.signalGrid, side: .right, seed: 2, through: 240)
        a.run(seconds: 60); b.run(seconds: 60)
        XCTAssertNotEqual(a.traceHash(), b.traceHash())
    }
}

final class RoutingTests: XCTestCase {

    func testShortestRouteAcrossGrid() {
        let map = ScenarioNetworks.make(.signalGrid, side: .right)
        let sim = Simulation(network: map.network)
        let net = sim.network
        let entries = sim.regionalEntries()
        let from = entries.entries.first!
        let to = entries.exits.last!
        let r = sim.router.route(from: from, to: to)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.first, from)
        XCTAssertEqual(r?.last, to)
        // Consecutive edges are connected.
        for (a, b) in zip(r!, r!.dropFirst()) { XCTAssertTrue(net.successors(of: a).contains(b)) }
    }

    func testCongestionCostsDivertRoutes() {
        let map = ScenarioNetworks.make(.signalGrid, side: .right)
        let sim = Simulation(network: map.network)
        let entries = sim.regionalEntries()
        let from = entries.entries.first!, to = entries.exits.last!
        let base = sim.router.route(from: from, to: to)!
        // Make the middle of the chosen route very slow.
        for e in base.dropFirst().dropLast() { sim.router.edgeTime[e.raw] *= 50 }
        let detour = sim.router.route(from: from, to: to)!
        XCTAssertNotEqual(base, detour)
    }

    func testLogitPerturbationSharesLoadBetweenEquivalentRoutes() {
        // In a grid, many equal-cost routes exist between opposite corners.
        let map = ScenarioNetworks.make(.signalGrid, side: .right)
        let sim = Simulation(network: map.network)
        let entries = sim.regionalEntries()
        let from = entries.entries.first!, to = entries.exits.last!
        var distinct = Set<[EdgeID]>()
        for seed in 1...40 { if let r = sim.router.route(from: from, to: to, seed: UInt64(seed)) { distinct.insert(r) } }
        XCTAssertGreaterThan(distinct.count, 2, "perturbed costs spread trips over several routes")
    }
}
