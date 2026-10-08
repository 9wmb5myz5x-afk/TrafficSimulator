import XCTest
import Foundation
@testable import TrafficEngine

/// Timings of the work behind taps and map updates (not a pass/fail test).
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
            line += String(format: " step=%.2f", ms { for _ in 0..<20 { sim.step() } } / 20)
            line += String(format: " renderAll=%.1f", ms { _ = RenderGeometryBuilder.all(sim.network) })
            line += String(format: " outskirts=%.1f", ms { _ = sim.outskirts(margin: 1100) })
            line += String(format: " driveways=%.1f", ms { _ = sim.city.buildings.flatMap { sim.drivewayStrokes(for: $0) } })
            line += String(format: " cityNetChange=%.1f", ms { sim.city.networkDidChange(sim) })
            // A control change at one junction (what the warrant review does).
            if let n = sim.network.allNodes.first(where: { sim.network.degree(of: $0.id) >= 3 && !$0.isRegionalConnection }) {
                line += String(format: " controlChange=%.1f", ms {
                    sim.network.updateNode(n.id) { $0.warrantControl = $0.warrantControl == .signal ? .allWayStop : .signal }
                    sim.networkDidChange()
                })
            }
            let v = sim.vehicles.first { $0.mode == .driving }
            line += String(format: " hitTest=%.2f", ms { for _ in 0..<10 { _ = sim.hitTest(v?.center ?? .zero, radius: 10) } } / 10)
            if let v { line += String(format: " inspectVeh=%.2f", ms { for _ in 0..<10 { _ = sim.inspect(.vehicle(v.id)) } } / 10) }
            if let b = sim.city.buildings.first { line += String(format: " inspectBld=%.2f", ms { for _ in 0..<10 { _ = sim.inspect(.building(b.id)) } } / 10) }
            if let n = sim.network.allNodes.first(where: { sim.network.degree(of: $0.id) >= 3 }) { line += String(format: " inspectJct=%.2f", ms { _ = sim.inspect(.junction(n.id)) }) }
            if let r = sim.network.allRoads.first { line += String(format: " inspectRoad=%.2f", ms { _ = sim.inspect(.road(r.id)) }) }
            line += String(format: " coverage=%.1f", ms { _ = sim.policeCoverage() })
            line += String(format: " save=%.1f", ms { let s = sim.makeSave(name: "x"); _ = try? JSONEncoder().encode(s) })
            let b = sim.terrain
            line += String(format: " preview=%.1f", ms { _ = editor.previewRoad([Vector2(b.minCorner.x + 50, 3), Vector2(b.maxCorner.x - 50, 9)], roadClass: .local) })
            // How often does the warrant review change a control during an hour?
            let v0 = sim.network.version
            sim.run(seconds: 3600 / sim.config.clockScale)
            line += " netChangesPerSimHour=\(sim.network.version - v0)"
            print(line)
        }
    }
}
