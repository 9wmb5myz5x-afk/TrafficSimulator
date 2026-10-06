import XCTest
@testable import TrafficEngine

/// Level-3 fuzzing, CI length: random player edits (draw / remove / restyle
/// roads, control overrides, roundabouts, moved junctions, buildings placed
/// and bulldozed, undo / redo) every 20 s while simulating, invariants on
/// every step. The CLI runs the long version (`trafficsim --fuzz`).
final class FuzzTests: XCTestCase {
    func testRandomEditsWhileSimulatingHoldInvariants() {
        for kind in [ScenarioKind.corridor, .signalGrid, .roundaboutVillage] {
            for side in DrivingSide.allCases {
                var cfg = SimulationConfig(); cfg.seed = 7
                let sim = ScenarioFactory.make(kind, side: side, seed: 7, config: cfg)
                let checker = InvariantChecker()
                sim.invariantChecker = checker
                let editor = Editor(sim: sim)
                var fuzz = EditFuzzer(seed: 7)
                let editEvery = Int(20 / cfg.dt)
                for k in 0..<Int(900 / cfg.dt) {
                    if k % editEvery == editEvery - 1 { fuzz.edit(editor) }
                    sim.step()
                }
                XCTAssertGreaterThan(fuzz.applied, 20, "\(kind) \(side): edits were applied")
                XCTAssertEqual(checker.total, 0, "\(kind) \(side): \(checker.summary())\n" + checker.samples.prefix(5).map { "\($0)" }.joined(separator: "\n"))
            }
        }
    }
}
