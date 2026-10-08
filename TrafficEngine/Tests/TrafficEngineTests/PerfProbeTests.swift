import XCTest
import Foundation
@testable import TrafficEngine

/// Timings of the work behind taps and map updates, printed as a `PERF`
/// line per map, with generous budgets (several times what a CI runner
/// takes) so a change that makes a tap or a control switch slow fails here.
final class PerfProbeTests: XCTestCase {
    func ms(_ body: () -> Void) -> Double {
        let t = Date(); body(); return Date().timeIntervalSince(t) * 1000
    }
    func testProbe() {
        for kind in [ScenarioKind.downtown, .suburb, .stressCity] {
            var cfg = SimulationConfig(); cfg.startClock = 7 * 3600
            let sim = ScenarioFactory.make(kind, side: .right, seed: 1, config: cfg)
            sim.run(seconds: 600)
            let editor = Editor(sim: sim)
            var line = "PERF \(kind) b=\(sim.city.buildings.count) roads=\(sim.network.allRoads.count) veh=\(sim.vehicles.count)"
            var budgets: [(String, Double, Double)] = []        // name, measured, budget (ms)
            func timed(_ name: String, budget: Double, per: Int = 1, _ body: () -> Void) -> Double {
                let t = ms { for _ in 0..<per { body() } } / Double(per)
                budgets.append((name, t, budget))
                return t
            }
            line += String(format: " step=%.2f", timed("step", budget: 40, per: 20) { sim.step() })
            line += String(format: " renderAll=%.1f", ms { _ = RenderGeometryBuilder.all(sim.network) })
            line += String(format: " outskirts=%.1f", ms { _ = sim.outskirts(margin: 1100) })
            line += String(format: " driveways=%.1f", ms { _ = sim.city.buildings.flatMap { sim.drivewayStrokes(for: $0) } })
            line += String(format: " cityNetChange=%.1f", ms { sim.city.networkDidChange(sim) })
            // A control change at one junction (what the warrant review does).
            if let n = sim.network.allNodes.first(where: { sim.network.degree(of: $0.id) >= 3 && !$0.isRegionalConnection }) {
                line += String(format: " controlChange=%.1f", timed("controlChange", budget: 120) {
                    sim.network.updateNode(n.id) { $0.warrantControl = $0.warrantControl == .signal ? .allWayStop : .signal }
                    sim.networkDidChange()
                })
            }
            let v = sim.vehicles.first { $0.mode == .driving }
            line += String(format: " hitTest=%.2f", timed("hitTest", budget: 5, per: 10) { _ = sim.hitTest(v?.center ?? .zero, radius: 10) })
            if let v { line += String(format: " inspectVeh=%.2f", timed("inspectVeh", budget: 5, per: 10) { _ = sim.inspect(.vehicle(v.id)) }) }
            if let b = sim.city.buildings.first { line += String(format: " inspectBld=%.2f", timed("inspectBld", budget: 5, per: 10) { _ = sim.inspect(.building(b.id)) }) }
            if let n = sim.network.allNodes.first(where: { sim.network.degree(of: $0.id) >= 3 }) { line += String(format: " inspectJct=%.2f", timed("inspectJct", budget: 5) { _ = sim.inspect(.junction(n.id)) }) }
            if let r = sim.network.allRoads.first { line += String(format: " inspectRoad=%.2f", timed("inspectRoad", budget: 5) { _ = sim.inspect(.road(r.id)) }) }
            line += String(format: " coverage=%.1f", ms { _ = sim.policeCoverage() })
            // Making a save runs on the simulation queue (autosaves); encoding
            // and writing it run in the background.
            var save: SaveFile?
            line += String(format: " makeSave=%.1f", timed("makeSave", budget: 60) { save = sim.makeSave(name: "x") })
            line += String(format: " encodeSave=%.1f", ms { _ = try? JSONEncoder().encode(save) })
            let b = sim.terrain
            line += String(format: " preview=%.1f", timed("preview", budget: 300) { _ = editor.previewRoad([Vector2(b.minCorner.x + 50, 3), Vector2(b.maxCorner.x - 50, 9)], roadClass: .local) })
            // How often does the warrant review change a control during an hour?
            let v0 = sim.network.version
            sim.run(seconds: 3600 / sim.config.clockScale)
            line += " netChangesPerSimHour=\(sim.network.version - v0)"
            print(line)
            for (name, t, budget) in budgets {
                XCTAssertLessThan(t, budget, "\(kind): \(name) took \(t) ms")
            }
        }
    }
}
