//
//  StageJunctions.swift
//  TrafficEngine
//
//  Right of way and junction safety.
//
//  Every approaching vehicle plans the connector it will use. To enter, it
//  must *commit* (reserve) that connector, which requires:
//
//   1. Exit room ("don't block the box"): the exit lane has space for it
//      after everyone already in or committed to the junction.
//   2. Conflict safety: no vehicle on — or committed to — a conflicting
//      connector has yet to clear its conflict zone. Zones come from swept
//      footprints (ConflictMap), so two footprints can never overlap inside
//      the junction.
//   3. The control rule: signal indication, stop sign (full stop, FCFS),
//      yield / priority, with time-based gap acceptance against approaching
//      priority traffic (HCM critical gaps, per-driver factor).
//
//  A vehicle commits only once it is within its comfortable stopping
//  distance, so a refused permission never forces harsh braking. Commitments
//  are evaluated in order of distance to the line (ties by id), so the result
//  is deterministic and fair.
//

/// HCM 7th ed. base critical headways [s] (two-lane major street) and others.
public enum CriticalGap {
    public static let majorAcross = 4.1      // left from major / permitted left at a signal
    public static let minorKerb = 6.2        // right from minor (also turn on red)
    public static let minorThrough = 6.5
    public static let minorAcross = 7.1
    public static let roundaboutEntry = 4.5  // HCM roundabout critical headway (single lane)
    public static let uncontrolled = 4.0
}

extension Simulation {

    /// Distance before the stop line within which junction logic engages [m].
    func approachRange(_ v: Vehicle) -> Double {
        max(60, v.speed * v.speed / 2.0 + v.speed * 2 + 25)
    }

    /// Distance to the stop line inside which the driver must decide.
    func commitDistance(_ v: Vehicle) -> Double {
        v.speed * v.speed / (2 * v.driver.idm.comfortableDeceleration) + v.speed * 0.6 + 2.0
    }

    // MARK: - Stage

    func updateJunctions(dt: Double) {
        let count = vehicles.count
        if stopTargets.count != count { stopTargets = Array(repeating: nil, count: count) }
        for i in 0..<count { stopTargets[i] = nil }

        // 1. Approach bookkeeping and connector planning.
        for i in 0..<count {
            guard vehicles[i].mode == .driving || vehicles[i].mode == .pullingOut, case .edge(let eid) = vehicles[i].track,
                  let edge = network.edge(eid) else { continue }
            let dEnd = edge.length - vehicles[i].s
            // Stop-line bookkeeping (stop signs, FCFS, waiting time).
            if dEnd < 4 && vehicles[i].speed < 0.15 {
                if vehicles[i].stopArrival == nil { vehicles[i].stopArrival = time }
                vehicles[i].lineWait += dt
                if vehicles[i].lineWait > 60, let n = network.node(edge.to), n.effectiveControl != .signal {
                    recordLineWaitForWarrants(node: n.id, wait: vehicles[i].lineWait)
                }
            } else if dEnd > 6 {
                vehicles[i].stopArrival = nil
                vehicles[i].lineWait = 0
            }
            guard let next = vehicles[i].nextRouteEdge else {
                vehicles[i].plannedConnector = nil
                continue
            }
            var planned = network.connector(from: LaneID(edge: eid, index: vehicles[i].lane), toEdge: next)
            // Re-planned while committed and too close to stop comfortably:
            // take the committed turn anyway and plan again from beyond it.
            if planned != vehicles[i].plannedConnector, vehicles[i].committed, let old = vehicles[i].plannedConnector,
               let oc = network.connector(old), oc.from == LaneID(edge: eid, index: vehicles[i].lane), dEnd < commitDistance(vehicles[i]) + 2 {
                // (No way on from there: it plans again once through.)
                let onward = router.route(from: oc.toEdge, to: vehicles[i].destination.edge, seed: UInt64(vehicles[i].id.raw)) ?? [oc.toEdge]
                vehicles[i].route = [eid] + onward
                vehicles[i].routeIndex = 0
                planned = old
            }
            if planned != vehicles[i].plannedConnector {
                vehicles[i].plannedConnector = planned
                vehicles[i].committed = false
            }
        }
        rebuildCommitIndex()

        // 2. Re-check commitments against a changing signal (dilemma zone):
        //    keep a commitment only if the vehicle clears the stop line before
        //    red; otherwise stop (comfortably if possible, harder if needed).
        //    Kerb turners stop too and may then turn on red after a full stop.
        for i in 0..<count where vehicles[i].committed {
            guard case .edge(let eid) = vehicles[i].track, let pc = vehicles[i].plannedConnector,
                  let conn = network.connector(pc), let edge = network.edge(eid),
                  network.node(conn.node)?.effectiveControl == .signal else { continue }
            let ind = signals.indication(for: pc, at: conn.node)
            guard ind == .yellow || ind == .red else { continue }
            let v = vehicles[i]
            let dEnd = edge.length - v.s
            let reachesBeforeRed = v.speed > 0.5 && dEnd / v.speed < signals.timeUntilRed(for: pc, at: conn.node) - 0.05
            if reachesBeforeRed { continue }
            let usable = dEnd - 0.5 - v.speed * 0.15
            let need = usable > 0.2 ? IDM.stoppingDeceleration(speed: v.speed, distance: usable) : .infinity
            if need <= IDM.emergencyDeceleration * 0.9 { vehicles[i].committed = false }
        }
        rebuildCommitIndex()

        // 3. Candidates: the front-most uncommitted vehicle of each approach lane.
        var candidates: [(d: Double, i: Int)] = []
        for i in 0..<count {
            let v = vehicles[i]
            guard v.mode == .driving || v.mode == .pullingOut, !v.committed, case .edge(let eid) = v.track,
                  let edge = network.edge(eid), v.nextRouteEdge != nil else { continue }
            let dEnd = edge.length - v.s
            guard dEnd <= approachRange(v) else { continue }
            if v.mode == .pullingOut || abs(v.pullOverShift) > 0.05 {
                // Still pulling out / pulled over for a siren: re-centre before the junction.
                stopTargets[i] = max(dEnd - 0.3, 0)
                continue
            }
            if let lc = v.laneChange, lc.phase == .moving {
                // Finish the lateral move before entering the junction.
                let tLeft = (1 - lc.progress) * lc.duration
                let remaining = v.speed * tLeft + 2
                if remaining > dEnd - 1 {
                    stopTargets[i] = max(dEnd - 0.3, 0)
                    continue
                }
            }
            if let leadIdx = laneLeaderOnEdge(i), !vehicles[leadIdx].committed {
                // Queued behind an uncommitted vehicle: hold at the line too.
                stopTargets[i] = max(dEnd - 0.3, 0)
                continue
            }
            candidates.append((dEnd, i))
        }
        // Long-waiting vehicles (≥ 15 s at the line) are served first when room
        // frees up — real drivers let them in; otherwise nearest first.
        candidates.sort { a, b in
            let la = vehicles[a.i].lineWait >= 15, lb = vehicles[b.i].lineWait >= 15
            if la != lb { return la }
            return a.d != b.d ? a.d < b.d : vehicles[a.i].id.raw < vehicles[b.i].id.raw
        }

        for (dEnd, i) in candidates {
            guard let pc = vehicles[i].plannedConnector, let conn = network.connector(pc) else {
                stopTargets[i] = max(dEnd - 0.3, 0)
                continue
            }
            let permitted = mayEnter(i, conn)
            let atLine = dEnd < 3 && vehicles[i].speed < 0.5
            if permitted && (dEnd <= commitDistance(vehicles[i]) || atLine) {
                vehicles[i].committed = true
                connCommits[pc.raw].append(Int32(i))
                onCommit?(vehicles[i], conn)
            } else if !permitted {
                stopTargets[i] = max(dEnd - 0.3, 0)
            }
        }

        // Followers behind an uncommitted leader just car-follow; vehicles
        // in a lane that does not serve their route stop at the line.
        for i in 0..<count {
            let v = vehicles[i]
            guard v.mode == .driving || v.mode == .pullingOut, case .edge(let eid) = v.track, let edge = network.edge(eid),
                  v.nextRouteEdge != nil, v.plannedConnector == nil else { continue }
            let dEnd = edge.length - v.s
            if dEnd <= approachRange(v) { stopTargets[i] = max(dEnd - 0.3, 0) }
        }
    }

    func rebuildCommitIndex() {
        for k in connCommits.indices where !connCommits[k].isEmpty { connCommits[k].removeAll(keepingCapacity: true) }
        for i in vehicles.indices where vehicles[i].committed {
            if case .edge = vehicles[i].track, let pc = vehicles[i].plannedConnector {
                connCommits[pc.raw].append(Int32(i))
            }
        }
    }

    /// The vehicle directly ahead in the same lane on the same edge (not a tail).
    func laneLeaderOnEdge(_ i: Int) -> Int? {
        let v = vehicles[i]
        guard case .edge(let eid) = v.track, let edge = network.edge(eid) else { return nil }
        let list = laneOcc[laneKey(eid, v.lane)]
        guard let o = leader(in: list, after: v.s, excluding: i) else { return nil }
        let j = Int(o.index)
        // Entries beyond the lane end are rears of vehicles already in the junction.
        if o.s > edge.length + 1e-6 { return nil }
        if case .edge(let ej) = vehicles[j].track, ej == eid { return j }
        return nil
    }

    // MARK: - Permission

    func mayEnter(_ i: Int, _ conn: Connector) -> Bool {
        guard exitHasRoom(i, conn) else { return false }
        guard conflictFree(i, conn) else { return false }
        if police.holdNodes.contains(conn.node) && !vehicles[i].siren && !police.holdApproaches.contains(conn.fromEdge) { return false }
        return controlAllows(i, conn)
    }

    func exitHasRoom(_ i: Int, _ conn: Connector) -> Bool {
        let v = vehicles[i]
        guard let exitEdge = network.edge(conn.toEdge) else { return false }
        let key = laneKey(conn.toEdge, conn.to.index)
        let need = v.length + v.driver.idm.minGap
        var available = exitEdge.length
        for o in laneOcc[key] {
            let j = Int(o.index)
            let rear = o.s - vehicles[j].length
            // A moving vehicle will have cleared some room by the time we arrive.
            let cleared = min(vehicles[j].speed * 2.5, 30)
            available = min(available, rear + cleared)
        }
        var consumed = 0.0
        for cid in network.connectors(into: conn.toEdge) {
            guard let c = network.connector(cid), c.to == conn.to else { continue }
            for o in connOcc[cid.raw] {
                let j = Int(o.index)
                if j == i { continue }
                if case .connector(let cc) = vehicles[j].track, cc == cid {
                    consumed += vehicles[j].length + vehicles[j].driver.idm.minGap
                }
            }
            for j32 in connCommits[cid.raw] where Int(j32) != i {
                consumed += vehicles[Int(j32)].length + vehicles[Int(j32)].driver.idm.minGap
            }
        }
        if available - consumed >= need { return true }
        // A lane shorter than one vehicle may still be entered when empty.
        return exitEdge.length < need + 1 && consumed == 0 && available >= exitEdge.length - 0.5
    }

    func conflictFree(_ i: Int, _ conn: Connector) -> Bool {
        var myClear: Double?
        for e in network.conflicts.conflicts(of: conn.id) where e.kind != .diverge {
            for o in connOcc[e.other.raw] {
                let j = Int(o.index)
                if j == i { continue }
                let rear = o.s - vehicles[j].length
                if rear < e.otherZoneEnd + 0.3 { return false }
            }
            for j32 in connCommits[e.other.raw] where Int(j32) != i {
                // A committed vehicle still on its approach only blocks if it
                // reaches the shared zone before we have cleared it (with a
                // margin) — otherwise one far-off commitment would freeze the
                // junction for everyone else.
                let j = Int(j32)
                guard case .edge(let ej) = vehicles[j].track, let edgeJ = network.edge(ej),
                      let myEdge = network.edge(conn.fromEdge) else { return false }
                if myClear == nil {
                    myClear = timeToCover(vehicles[i], distance: max(myEdge.length - vehicles[i].s, 0) + e.zoneEnd + vehicles[i].length)
                }
                let theirs = timeToCover(vehicles[j], distance: max(edgeJ.length - vehicles[j].s, 0) + e.otherZoneStart)
                let margin = e.kind == .merge ? 3.5 : 2.5
                if theirs < myClear! + margin { return false }
            }
        }
        return true
    }

    // MARK: - Control rules

    func controlAllows(_ i: Int, _ conn: Connector) -> Bool {
        guard let node = network.node(conn.node) else { return true }
        let v = vehicles[i]
        if v.siren { return emergencyMayProceed(i, conn) }
        let fullyStopped = v.stopArrival != nil
        switch node.effectiveControl {
        case .signal:
            let ind = signals.indication(for: conn.id, at: conn.node)
            switch ind {
            case .green:
                return true
            case .permissive:
                return gapAccepted(i, conn, criticalGap: CriticalGap.majorAcross) { other in
                    let oi = self.signals.indication(for: other.id, at: other.node)
                    return oi == .green || oi == .yellow
                }
            case .yellow:
                // Dilemma zone: go only if the line can be cleared before red and
                // stopping would need more than comfortable braking.
                guard let edge = network.edge(conn.fromEdge) else { return false }
                let dEnd = edge.length - v.s
                let need = IDM.stoppingDeceleration(speed: v.speed, distance: max(dEnd - 0.5, 0.1))
                let clears = v.speed > 0.5 && dEnd / v.speed < signals.timeUntilRed(for: conn.id, at: conn.node) - 0.05
                return clears && need > v.driver.idm.comfortableDeceleration
            case .red:
                guard isTurnOnRedAllowed(i, conn, indication: ind), fullyStopped else { return false }
                return gapAccepted(i, conn, criticalGap: CriticalGap.minorKerb) { other in
                    let oi = self.signals.indication(for: other.id, at: other.node)
                    return oi != .red
                }
            }
        case .allWayStop:
            guard fullyStopped else { return false }
            return firstComeFirstServed(i, conn)
        case .twoWayStop, .yield:
            let major = network.isMajorApproach(conn.fromEdge, at: conn.node)
            if !major && node.effectiveControl == .twoWayStop && !fullyStopped { return false }
            let isRing = network.allRoundabouts.contains { $0.ringNodes.contains(conn.node) }
            let tc: Double
            if major { tc = CriticalGap.majorAcross }
            else if isRing { tc = CriticalGap.roundaboutEntry }
            else if conn.turn.isAcross(side) { tc = CriticalGap.minorAcross }
            else if conn.turn == .straight { tc = CriticalGap.minorThrough }
            else { tc = CriticalGap.minorKerb }
            return gapAccepted(i, conn, criticalGap: tc) { other in
                self.priorityAtPriorityJunction(other, over: conn)
            }
        case .uncontrolled, .auto, .roundabout:
            return gapAccepted(i, conn, criticalGap: CriticalGap.uncontrolled) { other in
                self.kerbSidePriority(other, over: conn)
            }
        }
    }

    func isTurnOnRedAllowed(_ i: Int, _ conn: Connector, indication: SignalIndication) -> Bool {
        guard indication == .red, conn.turn.isKerbSide(side) else { return false }
        let nodeSetting = network.node(conn.node)?.control.turnOnRed
        return nodeSetting ?? config.turnOnRed
    }

    /// Major approaches beat minor ones; across turns yield to the opposing stream.
    func priorityAtPriorityJunction(_ other: Connector, over mine: Connector) -> Bool {
        let mineMajor = network.isMajorApproach(mine.fromEdge, at: mine.node)
        let otherMajor = network.isMajorApproach(other.fromEdge, at: other.node)
        if otherMajor != mineMajor { return otherMajor }
        if mine.turn.isAcross(side) && !other.turn.isAcross(side) { return true }
        if other.turn.isAcross(side) && !mine.turn.isAcross(side) { return false }
        return mineMajor ? false : kerbSidePriority(other, over: mine)
    }

    /// "Yield to the right" (to the left for `.left`), and across turns yield to oncoming traffic.
    func kerbSidePriority(_ other: Connector, over mine: Connector) -> Bool {
        guard let me = network.edge(mine.fromEdge), let them = network.edge(other.fromEdge) else { return false }
        let dm = me.reference.endTangent, dt = them.reference.endTangent
        if dm.dot(dt) < -0.7 {
            // Oncoming: an across turn yields to the oncoming through/kerb movement.
            return mine.turn.isAcross(side) && !other.turn.isAcross(side)
        }
        let cross = dm.cross(dt)
        return side == .right ? cross > 0.3 : cross < -0.3
    }

    /// All-way stop: serve in order of arrival at the stop line among
    /// conflicting movements; non-conflicting ones may go together.
    func firstComeFirstServed(_ i: Int, _ conn: Connector) -> Bool {
        guard let myArrival = vehicles[i].stopArrival else { return false }
        for e in network.conflicts.conflicts(of: conn.id) where e.kind != .diverge {
            guard let other = network.connector(e.other), let j = frontVehicle(onLane: other.from) else { continue }
            let w = vehicles[j]
            guard w.plannedConnector == other.id, let arr = w.stopArrival else { continue }
            // Held for an emergency vehicle: not taking its turn now.
            if police.holdNodes.contains(conn.node) && !police.holdApproaches.contains(other.fromEdge) && !w.siren { continue }
            if arr < myArrival - 1e-9 || (abs(arr - myArrival) < 1e-9 && w.id.raw < vehicles[i].id.raw) { return false }
        }
        return true
    }

    /// The front-most vehicle on a lane that is still before the stop line.
    func frontVehicle(onLane lane: LaneID) -> Int? {
        guard let edge = network.edge(lane.edge) else { return nil }
        let list = laneOcc[laneKey(lane.edge, lane.index)]
        var k = list.count - 1
        while k >= 0 {
            let j = Int(list[k].index)
            if list[k].s <= edge.length + 1e-6, case .edge(let e) = vehicles[j].track, e == lane.edge, vehicles[j].lane == lane.index {
                return j
            }
            k -= 1
        }
        return nil
    }

    /// Time-based gap acceptance: every approaching vehicle on a conflicting
    /// movement that has priority must be at least `criticalGap` (scaled by
    /// the driver's gap factor) away from the conflict zone, measured from the
    /// moment this vehicle reaches its stop line.
    func gapAccepted(_ i: Int, _ conn: Connector, criticalGap: Double, hasPriority: (Connector) -> Bool) -> Bool {
        let v = vehicles[i]
        guard let myEdge = network.edge(conn.fromEdge) else { return false }
        let myLineTime = timeToCover(v, distance: max(myEdge.length - v.s, 0))
        // Impatience at stop/yield lines: after ~20 s drivers accept
        // progressively shorter gaps, down to 70 % of their critical gap after
        // 80 s (waiting-time-dependent gap acceptance; Mahmassani & Sheffi
        // 1981). Not at signals, where the cycle relieves the wait.
        let signalised = network.node(conn.node)?.effectiveControl == .signal
        let impatience = signalised ? 1 : 1 - 0.3 * ((v.lineWait - 20) / 60).clamped(to: 0...1)
        let tc = criticalGap * v.driver.gapFactor * impatience
        for e in network.conflicts.conflicts(of: conn.id) where e.kind != .diverge {
            guard let other = network.connector(e.other), hasPriority(other) else { continue }
            guard let j = frontVehicle(onLane: other.from), j != i else { continue }
            let w = vehicles[j]
            if let pc = w.plannedConnector, pc != other.id {
                // It will take another movement: does that one conflict with ours?
                if !network.conflicts.conflicts(of: conn.id).contains(where: { $0.other == pc && $0.kind != .diverge }) { continue }
            }
            guard let otherEdge = network.edge(other.fromEdge) else { continue }
            let dToLine = otherEdge.length - w.s
            // Far enough to be irrelevant: judged in time, not metres (150 m
            // is only 5 s at highway speed).
            if dToLine > max(150, w.speed * (tc + myLineTime + 4)) { continue }
            // Courtesy: a priority vehicle waiting at its own line that arrived
            // after us is not a gap constraint (prevents yield-to-right deadlock).
            if let arr = w.stopArrival, let mine = v.stopArrival,
               (mine < arr || (mine == arr && v.id.raw < w.id.raw)), w.lineWait > 1.5 { continue }
            // Courtesy in congestion: a slow, queued priority driver waves through
            // someone who has been waiting a long time at the line.
            if v.lineWait >= 15 && w.speed < 3 && dToLine > 0.5 { continue }
            let tOther = timeToCover(w, distance: dToLine + e.otherZoneStart)
            if tOther < tc + myLineTime { return false }
        }
        return true
    }

    /// Estimated time to travel `distance` from the current speed, allowing
    /// moderate acceleration up to the speed limit.
    func timeToCover(_ v: Vehicle, distance: Double) -> Double {
        let d = max(distance, 0)
        let vmax = max(speedLimit(of: v.track) * v.driver.speedFactor, 1)
        let a = 1.5
        let s = v.speed
        if s >= vmax - 0.1 { return d / max(s, 0.1) }
        // Accelerate to vmax, then cruise.
        let tAcc = (vmax - s) / a
        let dAcc = s * tAcc + 0.5 * a * tAcc * tAcc
        if d <= dAcc { return (-s + (s * s + 2 * a * d).squareRoot()) / a }
        return tAcc + (d - dAcc) / vmax
    }
}
