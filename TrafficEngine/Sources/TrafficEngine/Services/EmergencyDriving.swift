//
//  EmergencyDriving.swift
//  TrafficEngine
//
//  Police units under lights and siren: signal pre-emption and junction
//  holds, proceeding through a red only after slowing and checking, civilians
//  ahead easing to the kerb, and the unit passing on the centre side. Plus the
//  police coverage map.
//

extension Simulation {

    // MARK: - Emergency driving

    /// Pre-emption and junction holds along the unit's approach.
    func updateEmergencyApproach(_ i: Int) {
        let v = vehicles[i]
        guard v.siren else { return }
        switch v.track {
        case .edge(let e):
            guard let edge = network.edge(e), let next = v.nextRouteEdge,
                  let pc = network.connector(from: LaneID(edge: e, index: v.lane), toEdge: next) ?? v.plannedConnector,
                  let conn = network.connector(pc) else { return }
            let d = edge.length - v.s
            if d < 160, network.node(conn.node)?.effectiveControl == .signal, police.preempted[conn.node.raw] == nil {
                signals.preempt(node: conn.node, edge: e)
                police.preempted[conn.node.raw] = v.id.raw
            }
        case .connector:
            break
        }
    }

    func releasePreemptions(of id: VehicleID) {
        for (n, holder) in police.preempted where holder == id.raw {
            signals.clearPreemption(node: NodeID(n))
            police.preempted[n] = nil
        }
    }

    /// A siren vehicle may enter on green as usual; on red / at a stop sign
    /// only after slowing right down at the line and checking the junction is
    /// clear and nobody is about to arrive.
    func emergencyMayProceed(_ i: Int, _ conn: Connector) -> Bool {
        let v = vehicles[i]
        if network.node(conn.node)?.effectiveControl == .signal,
           signals.indication(for: conn.id, at: conn.node) == .green { return true }
        guard let edge = network.edge(conn.fromEdge) else { return false }
        let dEnd = edge.length - v.s
        guard dEnd < 6 && v.speed < 3 else { return false }
        return gapAccepted(i, conn, criticalGap: 3.0) { _ in true }
    }

    // MARK: - Stage (before motion): holds, civilian yielding, kerb shifts

    func updateServices(dt: Double) {
        // Junction holds: nodes a siren vehicle is about to cross.
        police.holdNodes.removeAll(keepingCapacity: true)
        police.holdApproaches.removeAll(keepingCapacity: true)
        // A unit stuck in a queue (stationary 20 s) asks nothing of anyone:
        // holding junctions or slowing traffic for it only spreads the jam.
        let active = sirenSources.filter { vehicles[$0].stationaryTime < 20 }
        for s in active {
            let v = vehicles[s]
            switch v.track {
            case .edge(let e):
                if let edge = network.edge(e), edge.length - v.s < 50, let node = network.edge(e)?.to, v.nextRouteEdge != nil {
                    police.holdNodes.insert(node)
                    police.holdApproaches.insert(e)
                }
            case .connector(let c):
                if let n = network.connector(c)?.node {
                    police.holdNodes.insert(n)
                    // Through the junction: release its pre-emption.
                    if police.preempted[n.raw] == v.id.raw {
                        signals.clearPreemption(node: n)
                        police.preempted[n.raw] = nil
                    }
                }
            }
        }
        // Civilians ahead of a siren (same edge, or the next edge of its route) yield.
        var yielding = [Bool](repeating: false, count: vehicles.count)
        for s in active {
            let p = vehicles[s]
            guard case .edge(let pe) = p.track else { continue }
            var edges: [(EdgeID, Double)] = [(pe, p.s)]   // (edge, s from which "ahead" counts)
            if let next = p.nextRouteEdge, let edge = network.edge(pe), edge.length - p.s < 100 { edges.append((next, -(edge.length - p.s))) }
            for (e, from) in edges {
                guard let edge = network.edge(e) else { continue }
                for lane in edge.lanes {
                    for o in laneOcc[laneKey(e, lane.index)] where Int(o.index) != s {
                        // Ahead, or alongside until the unit is fully past (plus a margin).
                        let ahead = e == pe ? o.s - p.s : o.s - from
                        if ahead > -(vehicles[Int(o.index)].length + 6) && ahead < 100 { yielding[Int(o.index)] = true }
                    }
                }
            }
        }
        let kerb = side.kerbSign
        for i in vehicles.indices {
            var v = vehicles[i]
            guard case .edge(let e) = v.track, let edge = network.edge(e), let lane = edge.lane(v.lane) else { continue }
            // Lateral moves need forward motion (no crabbing at a standstill).
            let rate = max(0.45 * v.speed, 0.15) * dt
            // Only with the whole car on this edge and well before the next line.
            let farFromLine = edge.length - v.s > 30 && v.s > v.length + 3
            var target = 0.0
            switch v.mode {
            case .parkedAtKerb:
                target = parkingShift(v)
                v.stationaryTime = 0     // parked on purpose, not stuck
            case .driving:
                if v.laneChange != nil { v.vehicleShiftReset(); vehicles[i] = v; continue }
                if v.siren {
                    // Pass yielding traffic on the centre side.
                    v.yieldingToEmergency = false
                    // Stay 0.15 m inside the centre line (oncoming traffic on undivided roads).
                    let toCentre = abs(lane.lateral) - edge.roadClass.medianWidth / 2 - 0.15 - v.width / 2
                    let nearGoal = v.isOnFinalEdge && v.destination.kind == .kerb && v.destination.s - v.s < 40
                    target = farFromLine && !nearGoal && sirenNeedsCentreSpace(i, edge: e) ? -max(0, min(1.3, toCentre)) : 0
                    // Easing back towards the kerb: not into a car alongside
                    // (one part-way out of a driveway, a pulled-over car).
                    if target > v.pullOverShift {
                        let step = min(target - v.pullOverShift, rate)
                        if sideStepBlocked(i, edge: edge, lateral: lane.lateral + kerb * (v.pullOverShift + step)) {
                            target = v.pullOverShift
                        }
                    }
                } else {
                    v.yieldingToEmergency = yielding[i] && v.purpose != .emergency
                    // Only the kerb lane pulls over (inner lanes would swing into it).
                    if v.yieldingToEmergency && v.laneChange == nil && farFromLine
                        && edge.lanes.first(where: { $0.kind == .travel && $0.exists(at: v.s) })?.index == v.lane
                        && !parkedBeside(i) {
                        target = min(1.6, lane.width / 2 + edge.roadClass.shoulderWidth - v.width / 2 + 0.5)
                    }
                    // Never ease back into the lane while a siren — or anyone — is alongside.
                    if v.pullOverShift > target && (sirenAlongside(i) || laneOccupiedAlongside(i, edge: e)) { target = v.pullOverShift }
                    if v.laneChange != nil { v.vehicleShiftReset() ; vehicles[i] = v; continue }
                }
            default:
                continue
            }
            let before = v.pullOverShift
            v.pullOverShift += (target - v.pullOverShift).clamped(to: -rate...rate)
            if v.pullOverShift != 0 || before != 0 {
                v.lateral = lane.lateral + kerb * v.pullOverShift
                v.lateralSpeed = kerb * (v.pullOverShift - before) / dt
            }
            vehicles[i] = v
        }
    }

    /// Would vehicle `i`, moved sideways to `lateral`, touch a vehicle beside it?
    func sideStepBlocked(_ i: Int, edge: Edge, lateral: Double) -> Bool {
        let v = vehicles[i]
        var box = v.footprint
        box.center = edge.position(s: max(v.s - v.length / 2, 0), lateral: lateral)
        func hits(_ j: Int) -> Bool {
            guard j != i, j < vehicles.count else { return false }
            let w = vehicles[j]
            guard w.mode != .waitingToEnter, w.mode != .finished, w.center.distance(to: box.center) < 12 else { return false }
            return box.overlaps(w.footprint, margin: 0)
        }
        if kerbside.contains(where: hits) { return true }
        for lane in edge.lanes {
            for o in laneOcc[laneKey(edge.id, lane.index)] where abs(o.s - v.s) < 12 && hits(Int(o.index)) { return true }
        }
        return false
    }

    /// A car parked on the shoulder next to vehicle `i` (no room to pull over).
    func parkedBeside(_ i: Int) -> Bool {
        let v = vehicles[i]
        return kerbside.contains { j in
            j != i && j < vehicles.count && vehicles[j].mode == .parkedAtKerb && vehicles[j].track == v.track
                && vehicles[j].s > v.s - v.length - 8 && vehicles[j].s - vehicles[j].length < v.s + 8
        }
    }

    /// Another vehicle in `i`'s lane overlapping it longitudinally (with a
    /// small margin). A follower queued close behind, or a leader just ahead,
    /// is not alongside: the shift moves the whole body sideways, so easing
    /// back can't touch them (and waiting for them would deadlock the queue).
    func laneOccupiedAlongside(_ i: Int, edge e: EdgeID) -> Bool {
        let v = vehicles[i]
        for o in laneOcc[laneKey(e, v.lane)] where Int(o.index) != i {
            let w = vehicles[Int(o.index)]
            if o.s > v.s - v.length - 0.5 && o.s - w.length < v.s + 0.5 { return true }
        }
        return false
    }

    /// A siren vehicle overlapping vehicle `i` longitudinally on the same edge.
    func sirenAlongside(_ i: Int) -> Bool {
        let v = vehicles[i]
        for s in sirenSources where vehicles[s].track == v.track {
            let w = vehicles[s]
            if w.s > v.s - v.length - 1 && w.s - w.length < v.s + 1 { return true }
        }
        return false
    }

    /// The travel lane nearest the centre of the road at `s`.
    func innermostLane(_ edge: Edge, at s: Double) -> Int? {
        edge.lanes.filter { $0.kind == .travel && $0.exists(at: s) }
            .max { $0.lateral * side.passingLateralSign < $1.lateral * side.passingLateralSign }?.index
    }

    /// A siren vehicle with a yielding (shifted) civilian close ahead in its
    /// lane — passing on the centre side only from the innermost lane.
    func sirenNeedsCentreSpace(_ i: Int, edge e: EdgeID) -> Bool {
        let v = vehicles[i]
        guard let edge = network.edge(e), innermostLane(edge, at: v.s) == v.lane else { return false }
        for o in laneOcc[laneKey(e, v.lane)] where Int(o.index) != i && o.s > v.s - v.length - 6 && o.s - v.s < 60 {
            if vehicles[Int(o.index)].yieldingToEmergency || vehicles[Int(o.index)].mode == .parkedAtKerb { return true }
        }
        return false
    }

    /// Lateral clearance between two vehicles in the same lane (siren passing).
    /// The bodies don't overlap sideways, front or rear (a car still easing
    /// over has its rear nearer its old line), with 0.3 m to spare.
    func laterallyClear(_ a: Vehicle, _ b: Vehicle) -> Bool {
        func span(_ v: Vehicle) -> (Double, Double) {
            let r = v.rearLateral ?? v.lateral
            return (min(v.lateral, r) - v.width / 2, max(v.lateral, r) + v.width / 2)
        }
        let (a0, a1) = span(a), (b0, b1) = span(b)
        return a0 >= b1 + 0.3 || b0 >= a1 + 0.3
    }

    /// Time to reach each edge from the nearest station (police coverage map) [s].
    public func policeCoverage() -> [EdgeID: Double] {
        var dist: [Int: Double] = [:]
        var open = PriorityQueue<(Double, Int)> { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        for b in city.buildings where b.kind == .policeStation {
            guard let a = b.access else { continue }
            dist[a.edge.raw] = 0
            open.push((0, a.edge.raw))
        }
        while let (d, e) = open.pop() {
            guard d <= dist[e] ?? .infinity else { continue }
            for n in network.successors(of: EdgeID(e)) {
                let c = d + (n.raw < router.edgeTime.count ? router.edgeTime[n.raw] : 60)
                if c < dist[n.raw] ?? .infinity { dist[n.raw] = c; open.push((c, n.raw)) }
            }
        }
        var out: [EdgeID: Double] = [:]
        for (k, v) in dist { out[EdgeID(k)] = v }
        return out
    }
}
