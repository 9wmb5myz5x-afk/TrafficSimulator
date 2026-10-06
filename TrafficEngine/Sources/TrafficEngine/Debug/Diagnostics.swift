//
//  Diagnostics.swift
//  TrafficEngine
//
//  Human-readable state dumps for debugging (CLI --stuck).
//

func f2(_ x: Double) -> String { "\((x * 100).rounded() / 100)" }

public extension Simulation {
    func diagnose(_ id: VehicleID) -> String {
        ensureIndex()
        guard let i = index(of: id) else { return "\(id): gone" }
        let v = vehicles[i]
        var parts: [String] = ["\(v.id) \(v.cls.rawValue) mode=\(v.mode.rawValue) track=\(String(describing: v.track)) s=\(Int(v.s)) lane=\(v.lane) v=\(f2(v.speed)) stationary=\(Int(v.stationaryTime))s"]
        parts.append("planned=\(v.plannedConnector.map { "\($0)" } ?? "nil") committed=\(v.committed) next=\(v.nextRouteEdge.map { "\($0)" } ?? "nil") lc=\(v.laneChange.map { "\($0.phase.rawValue) \($0.fromLane)->\($0.toLane) u=\(f2($0.progress))" } ?? "nil")")
        if case .edge(let e) = v.track, let edge = network.edge(e) {
            parts.append("dEnd=\(Int(edge.length - v.s)) desired=\(desiredLanes(i, edge: edge).map { $0.sorted() } ?? [])")
            if let pc = v.plannedConnector, let c = network.connector(pc) {
                let room = exitHasRoom(i, c), free = conflictFree(i, c), ctrl = controlAllows(i, c)
                parts.append("room=\(room) conflictFree=\(free) control=\(ctrl) node=\(c.node) ctl=\(network.node(c.node)?.effectiveControl.rawValue ?? "?") ind=\(signals.indication(for: pc, at: c.node).rawValue) hold=\(police.holdNodes.contains(c.node)) shift=\(f2(v.pullOverShift)) lineWait=\(Int(v.lineWait))")
                if !free {
                    for e in network.conflicts.conflicts(of: pc) where e.kind != .diverge {
                        for o in connOcc[e.other.raw] where Int(o.index) != i {
                            parts.append("  blocked by \(vehicles[Int(o.index)].id) on \(e.other) s=\(f2(o.s)) zoneEnd=\(f2(e.otherZoneEnd))")
                        }
                        for j in connCommits[e.other.raw] where Int(j) != i {
                            parts.append("  blocked by commit \(vehicles[Int(j)].id) on \(e.other)")
                        }
                    }
                }
            }
            if let l = leader(in: laneOcc[laneKey(e, v.lane)], after: v.s, excluding: i) {
                let j = Int(l.index)
                parts.append("leader=\(vehicles[j].id) gap=\(f2(l.s - vehicles[j].length - v.s)) leaderTrack=\(vehicles[j].track)")
            }
        }
        if case .connector(let c) = v.track {
            if let o = leader(in: connOcc[c.raw], after: v.s, excluding: i) {
                parts.append("connLeader=\(vehicles[Int(o.index)].id) s=\(f2(o.s))")
            }
            if let conn = network.connector(c) {
                let key = laneKey(conn.toEdge, conn.to.index)
                if let first = laneOcc[key].first {
                    let j = Int(first.index)
                    parts.append("exitLaneLast=\(vehicles[j].id) rear=\(f2(first.s - vehicles[j].length)) speed=\(f2(vehicles[j].speed)) track=\(String(describing: vehicles[j].track))")
                }
                parts.append("connLen=\(f2(conn.length)) to=\(conn.to)")
            }
        }
        return parts.joined(separator: "\n    ")
    }

    /// Per-edge queue report: vehicle count, mean speed, and a diagnosis of
    /// the head of every edge whose mean speed is below `slow` m/s.
    func queueReport(slow: Double = 2) -> String {
        var byEdge: [EdgeID: [Int]] = [:]
        for (i, v) in vehicles.enumerated() {
            if case .edge(let e) = v.track { byEdge[e, default: []].append(i) }
        }
        var lines: [String] = []
        for e in byEdge.keys.sorted(by: { $0.raw < $1.raw }) {
            let idx = byEdge[e]!
            let mean = idx.map { vehicles[$0].speed }.reduce(0, +) / Double(idx.count)
            guard mean < slow, idx.count >= 3, let edge = network.edge(e) else { continue }
            lines.append("\(e) \(edge.from)->\(edge.to) n=\(idx.count) meanV=\(f2(mean)) len=\(Int(edge.length))")
            if let head = idx.max(by: { vehicles[$0].s < vehicles[$1].s }) {
                lines.append("  head " + diagnose(vehicles[head].id))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One-line police report for the CLI.
    func policeSummary() -> String {
        var statuses: [String: Int] = [:]
        for u in police.units { statuses[u.status.rawValue, default: 0] += 1 }
        let st = statuses.keys.sorted().map { $0 + "=" + String(statuses[$0]!) }.joined(separator: " ")
        let mean = police.meanResponseTime.map { f2($0) } ?? "-"
        let p90 = police.p90ResponseTime.map { f2($0) } ?? "-"
        return "police: units=\(police.units.count) \(st) incidents=\(police.incidents.count) responded=\(police.responseTimes.count) mean=\(mean)s p90=\(p90)s"
    }
}
