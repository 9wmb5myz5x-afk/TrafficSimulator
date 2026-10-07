import XCTest
@testable import TrafficEngine

final class TrafficLevelTests: XCTestCase {

    /// Raising the traffic level mid-morning fills the roads within minutes,
    /// without breaking any invariant.
    func testRaisingTrafficLevelAddsTrafficAtOnce() {
        var cfg = SimulationConfig(); cfg.seed = 3
        cfg.startClock = 7.5 * 3600
        let base = ScenarioFactory.make(.suburb, side: .right, seed: 3, config: cfg)
        let busy = ScenarioFactory.make(.suburb, side: .right, seed: 3, config: cfg)
        let checker = InvariantChecker()
        busy.invariantChecker = checker
        for _ in 0..<Int(120 / cfg.dt) { base.step(); busy.step() }
        busy.setTrafficLevel(4)
        XCTAssertEqual(busy.trafficLevel, 4)
        var peakBase = 0, peakBusy = 0
        for _ in 0..<Int(600 / cfg.dt) {
            base.step(); busy.step()
            peakBase = max(peakBase, base.vehicles.count)
            peakBusy = max(peakBusy, busy.vehicles.count)
        }
        XCTAssertGreaterThan(peakBusy, peakBase * 2, "level 4 should at least double the traffic (\(peakBase) → \(peakBusy))")
        XCTAssertEqual(checker.total, 0, checker.samples.prefix(3).map { "\($0)" }.joined(separator: "\n"))
    }

    func testTrafficLevelIsClampedAndCanBeLowered() {
        let sim = ScenarioFactory.make(.signalGrid, side: .left, seed: 1, config: SimulationConfig())
        sim.setTrafficLevel(50)
        XCTAssertEqual(sim.trafficLevel, Simulation.trafficLevelRange.upperBound)
        sim.setTrafficLevel(0.5)
        XCTAssertEqual(sim.trafficLevel, 0.5)
    }
}
