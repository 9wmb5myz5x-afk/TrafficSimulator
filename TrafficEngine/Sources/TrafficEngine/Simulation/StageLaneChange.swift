//
//  StageLaneChange.swift
//  TrafficEngine
//
//  Lane changes are continuous manoeuvres:
//
//   1. Decide (MOBIL). Discretionary changes use politeness, a threshold and
//      the keep-to-the-kerb bias. Mandatory changes are route-driven, with an
//      urgency that rises as the junction approaches.
//   2. Signal for the driver's signalling time (≥ 1.5 s), re-checking safety.
//      While a mandatory changer signals, a polite follower in the target
//      lane may open a gap (cooperative yielding).
//   3. Move laterally over 3–5 s (scaled with speed) along a quintic profile.
//      During the move the vehicle occupies both lanes (see StageIndex).
//   4. Abort and return if the target lane becomes unsafe mid-manoeuvre.
//
//  Pre-positioning: drivers look ahead along the route (two junctions when
//  the next road is short) and move to a lane serving their movement well
//  before the junction. A driver who cannot get over misses the turn and
//  reroutes from the lane they are in, rather than stopping in the lane.
//

extension Simulation {

    /// Lateral-motion duration of a lane change at speed v [s].
    func laneChangeDuration(speed v: Double) -> Double {
        3.0 + 2.0 * min(v / 25.0, 1.0)
    }

    func updateLaneChanges(dt: Double) {
        if courtesyLeader.count != vehicles.count { courtesyLeader = Array(repeating: -1, count: vehicles.count) }
        for i in vehicles.indices { courtesyLeader[i] = -1 }
        for i in vehicles.indices {
            guard vehicles[i].mode == .driving, case .edge(let eid) = vehicles[i].track,
                  let edge = network.edge(eid) else { continue }
            if vehicles[i].laneChange != nil {
                progressLaneChange(i, edge: edge, dt: dt)
            } else if vehicles[i].pullOverShift != 0 || vehicles[i].yieldingToEmergency || vehicles[i].committed {
                continue   // pulled over for an emergency vehicle, or committed to a junction path: stay in lane
            } else {
                considerLaneChange(i, edge: edge)
            }
        }
    }

    // MARK: - Route lanes

    /// Lanes of the current edge from which the route can continue, and
    /// whether the vehicle should already be positioning for them.
    /// Lanes that can make the next movement at all.
    func requiredLanes(_ i: Int, edge: Edge) -> Set<Int>? {
        let v = vehicles[i]
        guard let next = v.nextRouteEdge else { return desiredLanes(i, edge: edge) }
        let serving = servingLanes(edge.id, next)
        return serving.isEmpty ? nil : serving
    }

    /// Lanes of `edge` with a movement into `next` (memoised per network version).
    func servingLanes(_ edge: EdgeID, _ next: EdgeID) -> Set<Int> {
        let key = LaneChoiceKey(edge: Int32(edge.raw), next: Int32(next.raw), after: -2)
        if let c = laneChoiceCache[key] { return c }
        let s = Set(network.lanesServing(edge: edge, next: next))
        laneChoiceCache[key] = s
        return s
    }

    func desiredLanes(_ i: Int, edge: Edge) -> Set<Int>? {
        let v = vehicles[i]
        guard let next = v.nextRouteEdge else {
            // Final edge: kerbside destinations need the lane next to the driveway.
            if v.destination.kind == .exitMap { return nil }
            if let l = v.destinationLane, edge.lane(l) != nil { return [l] }
            let kerb = edge.lanes.filter { $0.kind == .travel }.min { $0.index < $1.index }?.index ?? 0
            return [kerb]
        }
        var serving = servingLanes(edge.id, next)
        guard !serving.isEmpty else { return nil }
        // Emergency vehicles keep to the innermost lane while far from the junction.
        if v.siren, edge.length - v.s > 120, let inner = innermostLane(edge, at: v.s) {
            return [inner]
        }
        // Look two junctions ahead when the next road is short.
        if let nextEdge = network.edge(next), v.routeIndex + 2 < v.route.count,
           nextEdge.length < nextEdge.roadClass.prepositionDistance {
            let after = v.route[v.routeIndex + 2]
            let key = LaneChoiceKey(edge: Int32(edge.id.raw), next: Int32(next.raw), after: Int32(after.raw))
            if let c = laneChoiceCache[key] { return c }
            defer { laneChoiceCache[key] = serving }
            let good = servingLanes(next, after)
            // Lanes that land on (or, when the good lane is a pocket that opens
            // later, nearest to) the lanes serving the turn after.
            func miss(_ l: Int) -> Int {
                guard let c = network.connector(from: LaneID(edge: edge.id, index: l), toEdge: next),
                      let conn = network.connector(c) else { return Int.max }
                return good.map { abs($0 - conn.to.index) }.min() ?? Int.max
            }
            if let best = serving.map(miss).min(), best < Int.max {
                let refined = serving.filter { miss($0) == best }
                if !refined.isEmpty { serving = refined }
            }
        }
        return serving
    }

    /// Where lane positioning must be complete: the driveway of a kerbside
    /// destination on this edge, else the junction (minus its no-change zone).
    func laneGoal(_ v: Vehicle, edge: Edge) -> (distance: Double, zone: Double) {
        if v.isOnFinalEdge && v.destination.kind != .exitMap {
            return (v.destination.s - v.s, 6)
        }
        return (edge.length - v.s, edge.roadClass.noLaneChangeZone)
    }

    /// Adjacent lane index one step towards `target` lanes, if any.
    func stepToward(_ lane: Int, _ targets: Set<Int>) -> Int? {
        guard !targets.contains(lane), let nearest = targets.min(by: { abs($0 - lane) < abs($1 - lane) || (abs($0 - lane) == abs($1 - lane) && $0 < $1) }) else { return nil }
        return nearest > lane ? lane + 1 : lane - 1
    }

    /// Distance a lane change needs before the stop line: the driver can brake
    /// while moving over, so it is the larger of the comfortable stopping
    /// distance and the distance covered during the move while braking.
    func laneChangeRoom(_ v: Vehicle) -> Double {
        let b = v.driver.idm.comfortableDeceleration
        let t = laneChangeDuration(speed: v.speed)
        let stop = v.speed * v.speed / (2 * b)
        let tStop = v.speed / b
        let during = t < tStop ? v.speed * t - 0.5 * b * t * t : stop
        return max(stop, during) + v.speed * 0.5 + 4
    }

    // MARK: - Decision

    func considerLaneChange(_ i: Int, edge: Edge) {
        let v = vehicles[i]
        vehicles[i].laneNeed = 0
        guard let cur = edge.lane(v.lane) else { return }
        let dEnd = edge.length - v.s
        let noChange = edge.roadClass.noLaneChangeZone
        // Not right after entering the edge (junction exit) and not too close to the line.
        if v.s < 8 { return }
        let required = requiredLanes(i, edge: edge)
        var targets = desiredLanes(i, edge: edge)
        // Preferred (look-ahead) lanes only matter while there is room to reach them.
        if let r = required, r.contains(v.lane), dEnd < noChange + 30 { targets = r }
        let laneEndsAhead = cur.sEnd < edge.length - 1
        var mandatoryTarget: Int?
        var urgency = 0.0
        // A kerbside destination on this edge: the driveway is the goal, not the junction.
        let goal = laneGoal(v, edge: edge)
        if let t = targets, !t.contains(v.lane) {
            mandatoryTarget = stepToward(v.lane, t)
            let changes = Double(t.map { abs($0 - v.lane) }.min() ?? 1)
            let room = goal.distance - goal.zone - laneChangeRoom(v)
            urgency = (1 - room / (changes * edge.roadClass.prepositionDistance)).clamped(to: 0...1)
            if room > changes * edge.roadClass.prepositionDistance { mandatoryTarget = nil }   // not yet
            if mandatoryTarget != nil {
                vehicles[i].laneNeed = required.map { $0.contains(v.lane) } == false ? 2 : 1
                vehicles[i].laneNeedCount = UInt8(min(changes, 4))
            }
        }
        if laneEndsAhead {
            // Lane drop / acceleration lane: merge towards the centre before it ends.
            let inward = v.lane + 1 < edge.lanes.count ? v.lane + 1 : v.lane - 1
            let room = cur.sEnd - v.s
            if room < 250 { mandatoryTarget = inward; urgency = max(urgency, (1 - room / 250).clamped(to: 0...1)) }
        }

        // Passed the driveway (or reached it in the wrong lane): go round the block.
        if v.isOnFinalEdge, v.destination.kind != .exitMap, v.mode == .driving {
            let dGoal = v.destination.s - v.s
            let wrongLane = v.destinationLane.map { $0 != v.lane } ?? false
            let passed = v.destination.kind == .kerb ? dGoal < -16 : dGoal < -6
            if passed || (v.destination.kind == .building && wrongLane && dGoal < 1) {
                vehicles[i].missedTurns += 1
                metrics.recordMissedTurn()
                log(.missedTurn, "\(v.id) missed its destination on \(edge.id) lane=\(v.lane) d=\(Int(dGoal))")
                circleBack(i, edge: edge)
                return
            }
        }

        // Missed turn: can no longer get over → continue from this lane and reroute,
        // rather than stopping dead in the lane. At speed this happens at the
        // no-change zone; in a queue, after a final-chance squeeze has failed.
        let commitZone = commitDistance(v) + 5
        if let t = required, !t.contains(v.lane), !laneEndsAhead,
           (dEnd < max(noChange, commitZone) && v.speed > 3) || (v.speed < 2 && (dEnd < 8 || v.stationaryTime > 25)) {
            missTurnAndReroute(i, edge: edge)
            return
        }

        // Stagger discretionary evaluation (≈ every 0.5 s per vehicle).
        let discretionaryTurn = (stepCount + v.id.raw) % 10 == 0
        if mandatoryTarget == nil && !discretionaryTurn { return }
        // Within the no-change zone only a low-speed final-chance squeeze is allowed.
        if dEnd < noChange && !(mandatoryTarget != nil && v.speed < 4 && dEnd > 12 + v.length) { return }

        var bestTarget: Int?
        var bestIncentive = 0.0
        let candidates: [Int] = mandatoryTarget.map { [$0] } ?? [v.lane - 1, v.lane + 1]
        for t in candidates {
            guard let lane = edge.lane(t), lane.exists(at: v.s) else { continue }
            // Lanes must be laterally adjacent.
            guard abs(abs(lane.lateral - cur.lateral) - lane.width) < 0.1 else { continue }
            // The target lane must continue long enough for the manoeuvre (pockets excepted).
            let manoeuvre = laneChangeRoom(v)
            if lane.sEnd < min(edge.length - 1, v.s + manoeuvre) { continue }
            // Discretionary: never move away from the route lanes near the junction,
            // and never into a turn pocket that does not serve the route.
            if mandatoryTarget == nil {
                if let tg = targets {
                    let before = tg.map { abs($0 - v.lane) }.min() ?? 0
                    let after = tg.map { abs($0 - t) }.min() ?? 0
                    if after > before && dEnd < 2.5 * edge.roadClass.prepositionDistance { continue }
                    if lane.kind != .travel && !tg.contains(t) { continue }
                } else if lane.kind != .travel {
                    continue
                }
                if lane.kind == .acceleration { continue }
            }
            guard let sit = mobilSituation(i, edge: edge, from: v.lane, to: t) else { continue }
            let mandatory = mandatoryTarget == t
            if mandatory {
                // Safety only, with a braking tolerance that grows with urgency.
                let bSafe = v.driver.mobil.safeDeceleration + 1.0 * urgency
                if sit.newFollowerAfter >= -bSafe {
                    bestTarget = t; bestIncentive = 1
                }
            } else {
                let towardsPassing = (lane.lateral - cur.lateral) * side.passingLateralSign > 0
                var bias = v.driver.mobil.keepKerbBias * (edge.roadClass == .highway ? 1.0 : 0.4)
                if !towardsPassing { bias = -bias }
                // Undertaking (moving kerb-ward to pass a slower vehicle): discouraged on highways.
                if edge.roadClass == .highway && !towardsPassing && config.noUndertakingOnHighways,
                   let o = leader(in: laneOcc[laneKey(edge.id, v.lane)], after: v.s, excluding: i),
                   o.s - v.s < 100, vehicles[Int(o.index)].speed < v.speed - 1 {
                    bias += 1.0
                }
                // Pre-positioning bonus when moving towards the route lanes.
                if let tg = targets, (tg.map { abs($0 - t) }.min() ?? 0) < (tg.map { abs($0 - v.lane) }.min() ?? 0) {
                    bias -= 0.6
                }
                if MOBIL.isSafe(v.driver.mobil, sit) {
                    let inc = MOBIL.incentive(v.driver.mobil, sit, bias: bias)
                    if inc > bestIncentive { bestIncentive = inc; bestTarget = t }
                }
            }
        }
        if let t = bestTarget, let lane = edge.lane(t) {
            let mandatory = mandatoryTarget == t
            vehicles[i].laneChange = LaneChange(
                fromLane: v.lane, toLane: t, phase: .signalling,
                duration: laneChangeDuration(speed: v.speed), mandatory: mandatory,
                fromLateral: cur.lateral, toLateral: lane.lateral)
        } else if let t = mandatoryTarget, let lane = edge.lane(t), lane.exists(at: v.s) {
            // Signal anyway: the intention invites cooperation.
            vehicles[i].laneChange = LaneChange(
                fromLane: v.lane, toLane: t, phase: .signalling,
                duration: laneChangeDuration(speed: v.speed), mandatory: true,
                fromLateral: cur.lateral, toLateral: lane.lateral)
        }
    }

    /// Accelerations of the changer and the affected followers before/after a change.
    func mobilSituation(_ i: Int, edge: Edge, from: Int, to: Int) -> MOBIL.Situation? {
        let v = vehicles[i]
        let fromKey = laneKey(edge.id, from), toKey = laneKey(edge.id, to)
        let limit = desiredSpeed(v, track: v.track)
        // Physical clearances.
        let tLead = leader(in: laneOcc[toKey], after: v.s - 1e-9, excluding: i)
        let tFoll = follower(in: laneOcc[toKey], before: v.s + 1e-9, excluding: i)
        if let o = tLead {
            let gap = o.s - vehicles[Int(o.index)].length - v.s
            if gap < 1.0 { return nil }
        }
        if let o = tFoll {
            let k = Int(o.index)
            let gap = v.s - v.length - o.s
            if gap < 1.0 + vehicles[k].speed * 0.4 { return nil }
        }
        func accel(_ k: Int, behind lead: Occupant?, limit: Double) -> Double {
            let w = vehicles[k]
            guard let l = lead else { return IDM.freeAcceleration(w.driver.idm, speed: w.speed, desiredSpeed: limit) }
            let j = Int(l.index)
            let gap = l.s - vehicles[j].length - (k == i ? v.s : positionOnSameEdge(k))
            return IDM.acceleration(w.driver.idm, speed: w.speed, desiredSpeed: limit, gap: gap, leaderSpeed: vehicles[j].speed)
        }
        let cLead = leader(in: laneOcc[fromKey], after: v.s, excluding: i)
        let selfCurrent = accel(i, behind: cLead, limit: limit)
        var selfTarget = accel(i, behind: tLead, limit: limit)
        // Lane-specific constraints: a lane that ends soon, no-undertaking.
        if let lane = edge.lane(to), lane.sEnd < edge.length - 1 {
            let d = lane.sEnd - v.s
            selfTarget = min(selfTarget, IDM.acceleration(v.driver.idm, speed: v.speed, desiredSpeed: limit, gap: d, leaderSpeed: 0))
        }
        var nb = 0.0, na = 0.0, ob = 0.0, oa = 0.0
        if let f = tFoll {
            let k = Int(f.index)
            let wLimit = desiredSpeed(vehicles[k], track: vehicles[k].track)
            nb = accel(k, behind: leader(in: laneOcc[toKey], after: f.s, excluding: k), limit: wLimit)
            let gap = v.s - v.length - f.s
            na = IDM.acceleration(vehicles[k].driver.idm, speed: vehicles[k].speed, desiredSpeed: wLimit, gap: gap, leaderSpeed: v.speed)
        }
        if let f = follower(in: laneOcc[fromKey], before: v.s, excluding: i) {
            let k = Int(f.index)
            let wLimit = desiredSpeed(vehicles[k], track: vehicles[k].track)
            let gap = v.s - v.length - f.s
            ob = IDM.acceleration(vehicles[k].driver.idm, speed: vehicles[k].speed, desiredSpeed: wLimit, gap: gap, leaderSpeed: v.speed)
            oa = accel(k, behind: cLead, limit: wLimit)
        }
        return MOBIL.Situation(selfCurrent: selfCurrent, selfTarget: selfTarget, newFollowerBefore: nb,
                               newFollowerAfter: na, oldFollowerBefore: ob, oldFollowerAfter: oa)
    }

    @inline(__always)
    func positionOnSameEdge(_ k: Int) -> Double { vehicles[k].s }

    // MARK: - Manoeuvre

    func progressLaneChange(_ i: Int, edge: Edge, dt: Double) {
        guard var lc = vehicles[i].laneChange else { return }
        let v = vehicles[i]
        lc.elapsed += dt
        let dEnd = edge.length - v.s
        switch lc.phase {
        case .signalling:
            let minSignal = lc.mandatory ? 1.5 : v.driver.signalTime
            // Is it still wanted?
            let targets = desiredLanes(i, edge: edge)
            if !lc.mandatory && lc.elapsed > 4 { vehicles[i].laneChange = nil; return }
            if lc.mandatory, let t = targets, t.contains(v.lane), !(edge.lane(v.lane).map { $0.sEnd < edge.length - 1 } ?? false) {
                vehicles[i].laneChange = nil; return
            }
            guard let target = edge.lane(lc.toLane), target.exists(at: v.s) else {
                if lc.elapsed > 8 { vehicles[i].laneChange = nil } else { vehicles[i].laneChange = lc }
                return
            }
            // Room to finish the move before the line, braking comfortably during it if needed?
            // Discretionary changes don't brake for the move: they need constant-speed room.
            let need = lc.mandatory ? laneChangeRoom(v)
                : v.speed * laneChangeDuration(speed: v.speed) + edge.roadClass.noLaneChangeZone + 5
            let squeeze = lc.mandatory && v.speed < 4 && dEnd > 12 + v.length
            let hasRoom = dEnd - need > 0 || squeeze
            if !hasRoom && (!lc.mandatory || dEnd < 6) { vehicles[i].laneChange = nil; return }
            let sit = mobilSituation(i, edge: edge, from: lc.fromLane, to: lc.toLane)
            trace(i, "signalling sit=\(String(describing: sit)) room=\(hasRoom) need=\(need) dEnd=\(dEnd)")
            var safe = sit.map { $0.newFollowerAfter >= -(v.driver.mobil.safeDeceleration + (lc.mandatory ? 0.8 : 0)) } ?? false
            // Zipper fairness in a crawling queue: the driver behind lets one car
            // in, then gets to move up before letting in the next.
            if safe && v.speed < 4, let f = follower(in: laneOcc[laneKey(edge.id, lc.toLane)], before: v.s + v.length * 0.5, excluding: i) {
                let w = vehicles[Int(f.index)]
                if w.speed < 2 && v.s - v.length - f.s < 10 && time - w.letInAt < 20 { safe = false }
            }
            if lc.mandatory, !safe { requestCourtesy(i, edge: edge, toLane: lc.toLane) }
            // A mandatory change that cannot happen in a stopped queue: give up and reroute.
            if lc.mandatory && !safe && v.speed < 2 && (v.stationaryTime > 25 || dEnd < 8),
               let t = requiredLanes(i, edge: edge), !t.contains(v.lane), !(edge.lane(v.lane).map { $0.sEnd < edge.length - 1 } ?? false) {
                vehicles[i].laneChange = nil
                missTurnAndReroute(i, edge: edge)
                return
            }
            if !lc.mandatory, let s = sit, MOBIL.incentive(v.driver.mobil, s, bias: 0) < -0.3 {
                vehicles[i].laneChange = nil; return
            }
            if lc.elapsed >= minSignal && safe && hasRoom {
                lc.phase = .moving
                // Merging into a slow queue: the driver behind has let us in.
                if v.speed < 4, let f = follower(in: laneOcc[laneKey(edge.id, lc.toLane)], before: v.s + v.length * 0.5, excluding: i),
                   v.s - v.length - f.s < 10 {
                    vehicles[Int(f.index)].letInAt = time
                }
                lc.elapsed = 0
                lc.progress = 0
                lc.duration = laneChangeDuration(speed: v.speed)
                lc.fromLateral = edge.lane(lc.fromLane)?.lateral ?? v.lateral
                lc.toLateral = target.lateral
            }
            vehicles[i].laneChange = lc
        case .moving:
            // Lateral rate limited so the yaw angle stays plausible at low speed.
            let dLat = abs(lc.toLateral - lc.fromLateral)
            var du = dt / lc.duration
            // Up to ~25° of yaw at a crawl (squeezing into a queue), less at speed.
            // A stopped car can still finish edging into the next lane slowly.
            let maxLateralSpeed = v.speed < 5 ? max(0.45 * v.speed, 0.25) : 0.3 * v.speed
            if dLat > 0.01 { du = min(du, dt * maxLateralSpeed / (1.875 * dLat)) }
            // Abort if the target lane became unsafe early in the move.
            // (A drift back onto the centre of its own lane never aborts.)
            if !lc.aborted && lc.fromLane != lc.toLane && lc.progress < 0.5 && !targetStillSafe(i, edge: edge, lane: lc.toLane) {
                trace(i, "abort at progress \(lc.progress)")
                lc.aborted = true
                swap(&lc.fromLane, &lc.toLane)
                swap(&lc.fromLateral, &lc.toLateral)
                lc.progress = 1 - lc.progress
                vehicles[i].lane = lc.fromLane == vehicles[i].lane ? vehicles[i].lane : vehicles[i].lane
            }
            lc.progress = min(1, lc.progress + du)
            let f = smootherStep(lc.progress)
            let newLat = lc.fromLateral + (lc.toLateral - lc.fromLateral) * f
            vehicles[i].lateralSpeed = (newLat - vehicles[i].lateral) / dt
            vehicles[i].lateral = newLat
            // The vehicle "belongs" to the target lane from mid-manoeuvre.
            if lc.progress >= 0.5 { vehicles[i].lane = lc.toLane } else { vehicles[i].lane = lc.fromLane }
            // The manoeuvre (and the claim on the old lane) ends only once the
            // rear of the vehicle has also left the old lane.
            let rearSettled = abs((vehicles[i].rearLateral ?? lc.toLateral) - lc.toLateral) < 0.35
            if lc.progress >= 1 && rearSettled {
                vehicles[i].lane = lc.toLane
                vehicles[i].lateral = lc.toLateral
                vehicles[i].lateralSpeed = 0
                vehicles[i].laneChange = nil
                return
            }
            vehicles[i].laneChange = lc
        }
    }

    /// Mid-manoeuvre safety: the new follower can still avoid us and the new leader is not too close.
    func targetStillSafe(_ i: Int, edge: Edge, lane: Int) -> Bool {
        let v = vehicles[i]
        let key = laneKey(edge.id, lane)
        if let f = follower(in: laneOcc[key], before: v.s, excluding: i) {
            let k = Int(f.index)
            let gap = v.s - v.length - f.s
            if gap < 0.5 { return false }
            let w = vehicles[k]
            let a = IDM.acceleration(w.driver.idm, speed: w.speed, desiredSpeed: desiredSpeed(w, track: w.track),
                                     gap: gap, leaderSpeed: v.speed)
            // Abort only if the follower would need clearly more than the safe braking budget.
            if a < -min(IDM.emergencyDeceleration * 0.85, v.driver.mobil.safeDeceleration * 1.5) { return false }
        }
        if let l = leader(in: laneOcc[key], after: v.s, excluding: i) {
            if l.s - vehicles[Int(l.index)].length - v.s < 0.5 { return false }
        }
        return true
    }

    /// Ask the follower in the target lane to make room for a signalling mandatory changer.
    func requestCourtesy(_ i: Int, edge: Edge, toLane: Int) {
        let v = vehicles[i]
        let key = laneKey(edge.id, toLane)
        guard let f = follower(in: laneOcc[key], before: v.s + v.length * 0.5, excluding: i) else { return }
        let k = Int(f.index)
        let w = vehicles[k]
        guard w.driver.mobil.politeness >= 0.2 || v.siren else { return }
        // Only if yielding costs it no more than comfortable braking.
        let gap = v.s - v.length - f.s
        let a = IDM.acceleration(w.driver.idm, speed: w.speed, desiredSpeed: max(w.speed, 1), gap: gap, leaderSpeed: v.speed)
        // One at a time: a driver who has just let someone in moves up first.
        if a >= -w.driver.idm.comfortableDeceleration && (time - w.letInAt >= 20 || v.siren) { courtesyLeader[k] = i }
    }

    func missTurnAndReroute(_ i: Int, edge: Edge) {
        let v = vehicles[i]
        let exits = network.connectors(from: LaneID(edge: edge.id, index: v.lane)).compactMap { network.connector($0)?.toEdge }
        guard !exits.isEmpty else { return }
        vehicles[i].missedTurns += 1
        metrics.recordMissedTurn()
        if let r = router.route(from: edge.id, to: v.destination.edge, firstSteps: exits, seed: UInt64(v.id.raw) &* 31 &+ UInt64(v.missedTurns)) {
            replaceRoute(i, with: r)
        } else if let r = cheapestRouteToRegion(from: exits[0], seed: UInt64(v.id.raw) &* 31 &+ UInt64(v.missedTurns)), let exit = r.last {
            // No way back to the destination from here: leave the map by a real exit.
            replaceRoute(i, with: [edge.id] + r)
            vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
        } else {
            // Take the first exit and plan again from there.
            replaceRoute(i, with: [edge.id, exits[0]])
        }
        log(.missedTurn, "\(v.id) missed its turn on \(edge.id) lane=\(v.lane) need=\(requiredLanes(i, edge: edge).map { $0.sorted() } ?? []) v=\(Int(v.speed)) dEnd=\(Int(edge.length - v.s)) stationary=\(Int(v.stationaryTime)) lc=\(v.laneChange != nil)")
    }

    /// Replace the remainder of the route, keeping the current edge.
    func replaceRoute(_ i: Int, with path: [EdgeID]) {
        guard let cur = vehicles[i].currentEdge, path.first == cur else { return }
        setRoute(i, path)
    }

    /// Start a new route from the current edge. A commitment to the next
    /// junction stands if the new route leaves it the same way (a re-plan
    /// must not make a car brake hard at the line it was already crossing).
    func setRoute(_ i: Int, _ path: [EdgeID]) {
        let oldNext = vehicles[i].nextRouteEdge
        vehicles[i].route = path
        vehicles[i].routeIndex = 0
        if vehicles[i].nextRouteEdge != oldNext || oldNext == nil {
            vehicles[i].plannedConnector = nil
            vehicles[i].committed = false
        }
    }
}
