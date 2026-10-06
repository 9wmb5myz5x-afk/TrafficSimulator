import XCTest
import Foundation
@testable import TrafficEngine

/// Debugging harness (no-op unless env K is set). Replays a fuzz run (env: K=scenario S=side SEED V=vehicle FROM TO EVERY) and traces one vehicle.
final class TraceHarnessTests: XCTestCase {
    func testTrace() throws {
        let env = ProcessInfo.processInfo.environment
        guard let k = env["K"], let kind = ScenarioKind(rawValue: k) else { return }
        let side = DrivingSide(rawValue: env["S"] ?? "right") ?? .right
        let seed = UInt64(env["SEED"] ?? "1") ?? 1
        let vid = Int(env["V"] ?? "0") ?? 0
        let from = Double(env["FROM"] ?? "0") ?? 0, to = Double(env["TO"] ?? "0") ?? 0
        let every = Double(env["EVERY"] ?? "30") ?? 30
        var cfg = SimulationConfig(); cfg.seed = seed
        let sim = ScenarioFactory.make(kind, side: side, seed: seed, config: cfg)
        let editor = Editor(sim: sim)
        var fuzz = EditFuzzer(seed: seed)
        let editEvery = max(1, Int(every / cfg.dt))
        let fuzzing = env["NOFUZZ"] == nil
        var k2 = 0
        while sim.time < to {
            if fuzzing && k2 % editEvery == editEvery - 1 {
                let w = fuzz.edit(editor)
                if sim.time > from - 60 || env["SHORT"] != nil { print(String(format: "EDIT t=%.2f ", sim.time) + w) }
                if env["SHORT"] != nil {
                    let ring = Set(sim.network.data.roundabouts.compactMap { $0 }.flatMap { $0.ringRoads.map { $0.raw } })
                    let short = sim.network.allEdges.filter { $0.length < 18 && !ring.contains($0.road.raw) }.map { "\($0.id)=\(Int($0.length))" }
                    if !short.isEmpty { print("  SHORT", short) }
                }
            }
            sim.step()
            k2 += 1
            if let c = env["WATCHCONN"].flatMap(Int.init), sim.time >= from, k2 % 40 == 0, let conn = sim.network.connector(ConnectorID(c)) {
                let st = sim.signals.state(for: conn.node)
                print(String(format: "W t=%.1f ", sim.time), sim.signals.indication(for: ConnectorID(c), at: conn.node), st.map { "\($0.phase) \($0.interval) cc=\(Int($0.cycleClock))" } ?? "-", sim.signals.plan(for: conn.node).map { "cycle=\($0.cycle) mode=\($0.mode)" } ?? "")
            }
            if env["LEAD"] != nil, sim.time >= from, k2 % (Int(env["EACH"] ?? "4") ?? 4) == 0, let i = sim.index(of: VehicleID(vid)), case .edge(let e) = sim.vehicles[i].track {
                sim.ensureIndex()
                let v = sim.vehicles[i]
                let lead = sim.leader(in: sim.laneOcc[sim.laneKey(e, v.lane)], after: v.s, excluding: i).map { sim.vehicles[Int($0.index)] }
                print(String(format: "L t=%.1f s=%.2f v=%.2f lane=%d stat=%.0f", sim.time, v.s, v.speed, v.lane, v.stationaryTime),
                      lead.map { "lead=\($0.id) s=\(String(format: "%.2f", $0.s)) v=\(String(format: "%.2f", $0.speed)) mode=\($0.mode) lane=\($0.lane) lc=\($0.laneChange.map { "\($0.fromLane)->\($0.toLane)" } ?? "-")" } ?? "no leader")
            }
            if sim.time >= from, k2 % (Int(env["EACH"] ?? "4") ?? 4) == 0, let v = sim.vehicle(VehicleID(vid)) {
                print(String(format: "t=%.2f %@ s=%.2f lane=%d lat=%.2f v=%.2f mode=%@ pc=%@ com=%d next=%@ route=%@ ri=%d dest=%@/%.0f", sim.time,
                             "\(v.track)" as NSString, v.s, v.lane, v.lateral, v.speed, v.mode.rawValue as NSString,
                             (v.plannedConnector.map { "\($0)" } ?? "-") as NSString, v.committed ? 1 : 0,
                             (v.nextRouteEdge.map { "\($0)" } ?? "-") as NSString, "\(v.route)" as NSString, v.routeIndex,
                             "\(v.destination.kind.rawValue):\(v.destination.edge)" as NSString, v.destination.s) + String(format: " hdg=%.3f front=(%.2f,%.2f)", v.heading, v.front.x, v.front.y) + " lc=\(v.laneChange.map { "\($0.phase) \($0.fromLane)->\($0.toLane) \($0.fromLateral)->\($0.toLateral) p=\($0.progress)" } ?? "-")")
            }
        }
        if let e = env["EDGE"].flatMap(Int.init), let edge = sim.network.edge(EdgeID(e)) {
            print("EDGE", e, "len", edge.length, "lanes", edge.lanes.map { ($0.index, $0.lateral, $0.kind) }, "kerbRange", sim.kerbRange(EdgeID(e), 5.0))
        }
        if let c = env["SIGCONN"].flatMap(Int.init), c < sim.signals.protectedPhase.count {
            print("SIG conn", c, "protected", sim.signals.protectedPhase[c], "permitted", sim.signals.permittedPhase[c],
                  "incoming", sim.network.connector(ConnectorID(c)).map { sim.network.incoming($0.node).count } ?? -1)
            if let conn = sim.network.connector(ConnectorID(c)), let st = sim.signals.state(for: conn.node), let plan = sim.signals.plan(for: conn.node) {
                print("SIG preempt", st.preemptPhase, "used", (1...8).filter { plan.used($0) }, "mode", plan.mode)
            }
        }
        if env["ORIGIN"] != nil, let v = sim.vehicle(VehicleID(vid)), let o = v.origin, let b = sim.city.building(o) {
            print("ORIGIN", o, b.kind, b.center, "access", String(describing: b.access))
            if let a = b.access, let r = sim.network.road(a.road) { print(" road", r.id, r.roadClass, "oneWay", r.isOneWay, "fwd", r.lanesForward, "back", r.lanesBackward, "recomputed", String(describing: sim.accessPoint(for: b.center)?.0)) }
        }
        if env["PROBE"] != nil, let v = sim.vehicle(VehicleID(vid)) {
            print("PROBE", v.id, v.mode, "center", v.center, "front", v.front, "width", v.width)
            for e in sim.network.allEdges {
                let d = e.reference.project(v.center).distance
                if d < 15 { print("  near", e.id, e.road, "d", d, "half", e.lanes.map { abs($0.lateral) + $0.width / 2 }.max() ?? 0) }
            }
        }
        if env["DIAG"] != nil {
            print(sim.diagnose(VehicleID(vid)))
            for (k, u) in sim.police.units.enumerated() { print("UNIT", k, u.status, String(describing: u.vehicle), String(describing: u.incident), u.timer) }
            if let i = sim.index(of: VehicleID(vid)) { print("arrived", sim.arrivedAtKerbGoal(i), "free", sim.kerbSpotFree(i), "edgeLen", sim.network.edge(sim.vehicles[i].currentEdge ?? EdgeID(0))?.length ?? -1, "kerbRange", sim.kerbRange(sim.vehicles[i].destination.edge, 5)) }
        }
        if let c = env["CONN"].flatMap(Int.init), let conn = sim.network.connector(ConnectorID(c)) {
            print("CONN", c, "node", conn.node, "turn", conn.turn, "len", conn.length, "minR", conn.path.minimumRadius, "from", conn.from, "to", conn.to)
            let n = conn.node
            for road in sim.network.roads(at: n) { print(" road", road.id, road.roadClass, sim.network.centreline(of: road.id)?.points.prefix(3) ?? []) }
            print(" pts", conn.path.points)
        }
    }
}

final class ShortEdgeReportTests: XCTestCase {
    func testListShortEdges() {
        guard ProcessInfo.processInfo.environment["SHORTLIST"] != nil else { return }
        for kind in ScenarioKind.allCases {
            for side in DrivingSide.allCases {
                let net = ScenarioNetworks.make(kind, side: side).network
                let ring = Set(net.data.roundabouts.compactMap { $0 }.flatMap { $0.ringRoads.map { $0.raw } })
                let short = net.allEdges.filter { $0.length < 18 }.map { "\($0.id)\(ring.contains($0.road.raw) ? "r" : "")=\(String(format: "%.1f", $0.length))" }
                print("SHORT", kind, side, short)
            }
        }
    }
}
