//
//  StageMotion.swift
//  TrafficEngine
//
//  Longitudinal dynamics. Each vehicle's target acceleration is the minimum
//  of the IDM response to every constraint ahead:
//
//   • leaders in every lane it occupies (both lanes during a lane change),
//     including the rears of vehicles that have just entered the junction
//   • look-ahead across the junction along its planned connector, including
//     vehicles on diverging connectors from the same lane that have not yet
//     separated, then the exit lane, for up to `lookAhead` metres
//   • a virtual stopped obstacle at the stop line when not permitted to enter
//   • the end of a lane that is about to drop
//   • comfortable speed for the curve of the next connector
//   • a courtesy gap for a signalling mandatory lane changer
//
//  Human factors: decisions are revised every reaction time unless the
//  situation demands harder braking (then immediately), and acceleration
//  changes are jerk-limited except in emergencies. Braking never exceeds
//  the emergency limit (≈ 0.8 g).
//

extension Simulation {

    /// Desired speed on a track for this driver.
    func desiredSpeed(_ v: Vehicle, track: Track) -> Double {
        switch track {
        case .edge(let e):
            guard let edge = network.edge(e) else { return 10 }
            var factor = v.driver.speedFactor
            if v.cls.isHeavy { factor = min(factor, v.cls.speedCap) }
            if v.purpose == .patrol { factor = 0.92 }
            if v.siren { factor = 1.35 }
            return edge.speedLimit * factor
        case .connector(let c):
            guard let conn = network.connector(c) else { return 8 }
            return conn.speedLimit * min(v.driver.speedFactor, 1.05) * (v.siren ? 1.1 : 1)
        }
    }

    func updateMotion(dt: Double) {
        let count = vehicles.count
        if stopTargets.count != count { stopTargets = Array(repeating: nil, count: count) }
        if courtesyLeader.count != count { courtesyLeader = Array(repeating: -1, count: count) }
        var targets = [Double](repeating: 0, count: count)
        for i in 0..<count {
            switch vehicles[i].mode {
            case .driving, .pullingIn, .pullingOut: targets[i] = targetAcceleration(i)
            case .parkedAtKerb:
                // Roll on slowly while easing onto the shoulder, then come to rest.
                let v = vehicles[i]
                if v.pullOverShift < parkingShift(v) - 0.4 {
                    targets[i] = IDM.freeAcceleration(v.driver.idm, speed: v.speed, desiredSpeed: 2.0)
                    // Never into the car ahead (one pulled over for a siren, say).
                    if case .edge(let e) = v.track, let o = leader(in: laneOcc[laneKey(e, v.lane)], after: v.s, excluding: i) {
                        let j = Int(o.index)
                        targets[i] = min(targets[i], IDM.acceleration(v.driver.idm, speed: v.speed, desiredSpeed: 2.0,
                                                                      gap: o.s - vehicles[j].length - v.s, leaderSpeed: vehicles[j].speed))
                    }
                } else {
                    targets[i] = -min(v.speed / dt, 2.5)
                }
            case .waitingToEnter, .finished: targets[i] = 0
            }
        }
        for i in 0..<count {
            guard vehicles[i].mode != .finished, vehicles[i].mode != .waitingToEnter else { continue }
            integrate(i, target: targets[i], dt: dt)
        }
    }

    func targetAcceleration(_ i: Int) -> Double {
        let v = vehicles[i]
        let p = v.driver.idm
        var v0 = desiredSpeed(v, track: v.track)
        var a = Double.infinity

        func consider(gap: Double, leaderSpeed: Double) {
            a = min(a, IDM.acceleration(p, speed: v.speed, desiredSpeed: v0, gap: gap, leaderSpeed: leaderSpeed))
        }

        switch v.track {
        case .edge(let eid):
            guard let edge = network.edge(eid) else { return 0 }
            let dEnd = edge.length - v.s
            // Slow for the curve of the connector ahead, and for slower roads
            // beyond it (also past a short link onto the next junction).
            if let pc = v.plannedConnector, let conn = network.connector(pc), dEnd < 200 {
                let sf = min(v.driver.speedFactor, 1.05)
                let decel = p.comfortableDeceleration * 0.6
                v0 = min(v0, IDM.approachSpeed(target: conn.speedLimit * sf, distance: dEnd, decel: decel))
                if let exit = network.edge(conn.toEdge) {
                    var dist = dEnd + conn.length
                    v0 = min(v0, IDM.approachSpeed(target: exit.speedLimit * sf, distance: dist, decel: decel))
                    if exit.length < 60, v.routeIndex + 2 < v.route.count,
                       let c2 = network.connector(from: conn.to, toEdge: v.route[v.routeIndex + 2]).flatMap({ network.connector($0) }) {
                        dist += exit.length
                        v0 = min(v0, IDM.approachSpeed(target: c2.speedLimit * sf, distance: dist, decel: decel))
                        if let e2 = network.edge(c2.toEdge) {
                            v0 = min(v0, IDM.approachSpeed(target: e2.speedLimit * sf, distance: dist + c2.length, decel: decel))
                        }
                    }
                }
            }
            // A junction just beyond a short link: arrive slowly enough to stop
            // comfortably on the link should we have to (closely spaced junctions).
            if let pc = v.plannedConnector, let conn = network.connector(pc), v.routeIndex + 2 < v.route.count,
               let link = network.edge(conn.toEdge), link.length < 45,
               let dc = network.connector(from: conn.to, toEdge: v.route[v.routeIndex + 2]).flatMap({ network.connector($0) }),
               network.degree(of: dc.node) > 2 {
                let room = max(link.length + conn.length * 0.5 - 3, 4)
                let cap = max(6, (2 * p.comfortableDeceleration * 1.3 * room).squareRoot())
                v0 = min(v0, IDM.approachSpeed(target: cap, distance: dEnd, decel: p.comfortableDeceleration * 0.6))
            }
            // A needed lane change still pending: slow down to find a gap — to
            // a crawl for the lane the next turn requires, moderately for
            // pre-positioning — rather than sweep past the turn.
            if v.laneNeed > 0 {
                let crawl = v.laneNeed == 2 ? 2.5 : 8.0
                // Further changes after this one need room of their own.
                let more = Double(max(Int(v.laneNeedCount) - (v.laneChange?.phase == .moving ? 1 : 0) - 1, 0))
                let goal = laneGoal(v, edge: edge)
                let zone = max(goal.zone, 12 + v.length) + 2 + more * 15
                v0 = min(v0, IDM.approachSpeed(target: crawl, distance: goal.distance - zone, decel: p.comfortableDeceleration * 0.7))
            }
            // Leaders in every occupied lane.
            var lanes = [v.lane]
            if let lc = v.laneChange, lc.phase == .moving {
                lanes.append(lc.toLane == v.lane ? lc.fromLane : lc.toLane)
            }
            var hasLeaderOnEdge = false
            for l in lanes {
                let list = laneOcc[laneKey(eid, l)]
                if let o = v.siren ? sirenLeader(in: list, after: v.s, of: i) : leader(in: list, after: v.s, excluding: i) {
                    let j = Int(o.index)
                    consider(gap: o.s - vehicles[j].length - v.s, leaderSpeed: vehicles[j].speed)
                    if l == v.lane { hasLeaderOnEdge = true }
                }
            }
            // Cars off the lane (parked on the shoulder, turning in) that a car
            // pulled over for a siren would still touch.
            if v.pullOverShift > 0.05 {
                for j in kerbside where j != i && j < vehicles.count && vehicles[j].track == v.track {
                    let w = vehicles[j]
                    let gap = w.s - w.length - v.s
                    if gap > -0.5 && gap < 60 && !laterallyClear(v, w) { consider(gap: max(gap, 0.05), leaderSpeed: w.speed) }
                }
            }
            // Through the junction.
            if !hasLeaderOnEdge && dEnd < max(config.lookAhead, v.speed * 5) {
                lookAcrossJunction(i, distance: dEnd, from: LaneID(edge: eid, index: v.lane), consider: consider)
            }
            // A stop line just beyond a short link (also with a leader on this edge).
            if hasLeaderOnEdge, let pc = v.plannedConnector, let conn = network.connector(pc), v.routeIndex + 2 < v.route.count,
               let link = network.edge(conn.toEdge), link.length < 60,
               let dc = network.connector(from: conn.to, toEdge: v.route[v.routeIndex + 2]).flatMap({ network.connector($0) }),
               mustStopAhead(v, dc, distance: dEnd + conn.length + link.length) {
                consider(gap: max(dEnd + conn.length + link.length - 0.3, 0.05), leaderSpeed: 0)
            }
            // Stop line.
            if let d = stopTargets[i] { consider(gap: max(d, 0.05), leaderSpeed: 0) }
            // Lane end.
            if let lane = edge.lane(v.lane), lane.sEnd < edge.length - 1 {
                let movingOut = v.laneChange.map { $0.phase == .moving && $0.toLane != v.lane } ?? false
                if !movingOut { consider(gap: max(lane.sEnd - v.s - 1, 0.05), leaderSpeed: 0) }
            }
            // No undertaking on highways: don't pass a slower vehicle on its kerb side.
            if config.noUndertakingOnHighways && edge.roadClass == .highway && v.speed > 15 && !v.siren {
                let passing = v.lane + 1
                if passing < edge.lanes.count, let o = leader(in: laneOcc[laneKey(eid, passing)], after: v.s, excluding: i) {
                    let j = Int(o.index)
                    if o.s - v.s < 60 && vehicles[j].speed < v.speed {
                        v0 = min(v0, vehicles[j].speed + 2)
                    }
                }
            }
            // Destination.
            // Destination: slow to turn in — from the driveway lane (or while
            // moving into it); otherwise drive on and come round again.
            if v.isOnFinalEdge && v.destination.kind != .exitMap && v.mode == .driving {
                let d = v.destination.s - v.s
                let inLane = v.destinationLane.map { $0 == v.lane || v.laneChange?.toLane == $0 } ?? true
                if d > -2 && inLane && !drivewayBlockedByParkedCar(i) {
                    // Someone else is turning in/out there: wait short of the driveway.
                    if d < 40 && v.destination.kind == .building && drivewayBusy(i) { consider(gap: max(d - 6, 0.05), leaderSpeed: 0) }
                    else { consider(gap: max(d + 3, 0.05), leaderSpeed: 3) }
                }
                // No route beyond this street yet (the stop may be taken and the
                // car will go round again): never arrive at the junction unable to stop.
                if v.nextRouteEdge == nil, let edge = network.edge(eid) {
                    consider(gap: max(edge.length - v.s - 0.5, 0.05), leaderSpeed: 0)
                }
            }
            if v.mode == .pullingIn { v0 = min(v0, 4) }
            if v.mode == .pullingOut { v0 = min(v0, max(v0 * 0.6, 8)) }
            if v.yieldingToEmergency { v0 = min(v0, 1.5) }
        case .connector(let cid):
            guard let conn = network.connector(cid) else { return 0 }
            let list = connOcc[cid.raw]
            var found = false
            if let o = leader(in: list, after: v.s, excluding: i) {
                let j = Int(o.index)
                consider(gap: o.s - vehicles[j].length - v.s, leaderSpeed: vehicles[j].speed)
                found = true
            }
            // Siblings from the same approach lane not yet separated.
            for e in network.conflicts.conflicts(of: cid) where e.kind == .diverge && v.s < e.zoneEnd {
                for o in connOcc[e.other.raw] where o.s > v.s {
                    let j = Int(o.index)
                    if o.s - vehicles[j].length < e.otherZoneEnd {
                        consider(gap: o.s - vehicles[j].length - v.s, leaderSpeed: vehicles[j].speed)
                    }
                }
            }
            if !found {
                let rest = conn.length - v.s
                let exitKey = laneKey(conn.toEdge, conn.to.index)
                if let o = laneOcc[exitKey].first(where: { Int($0.index) != i }) {
                    let j = Int(o.index)
                    consider(gap: rest + o.s - vehicles[j].length, leaderSpeed: vehicles[j].speed)
                }
            }
            // A signal just beyond a short link: keep the speed down and stop
            // on the link if it is not green.
            // Any junction just past a short link (a signal may turn, a yield or
            // a conflicting car may stop us): arrive able to stop on the link.
            if v.routeIndex + 2 < v.route.count, let link = network.edge(conn.toEdge), link.length < 45,
               let dcID = network.connector(from: conn.to, toEdge: v.route[v.routeIndex + 2]),
               let dc = network.connector(dcID), network.degree(of: dc.node) > 2 {
                let rest = conn.length - v.s
                let room = max(link.length - 3, 4)
                let cap = max(6, (2 * p.comfortableDeceleration * 1.3 * room).squareRoot())
                v0 = min(v0, IDM.approachSpeed(target: cap, distance: rest, decel: p.comfortableDeceleration * 0.6))
                if network.node(dc.node)?.effectiveControl == .signal {
                    let ind = signals.indication(for: dcID, at: dc.node)
                    if ind == .red || ind == .yellow { consider(gap: max(rest + link.length - 0.5, 0.05), leaderSpeed: 0) }
                }
            }
            if v.yieldingToEmergency { v0 = min(v0, 3) }
        }
        // Courtesy: open a gap for a signalling mandatory changer.
        if i < courtesyLeader.count, courtesyLeader[i] >= 0 {
            let k = courtesyLeader[i]
            let w = vehicles[k]
            if case .edge = v.track, w.track == v.track {
                consider(gap: w.s - w.length - v.s, leaderSpeed: w.speed)
            }
        }
        if a == .infinity { a = IDM.freeAcceleration(p, speed: v.speed, desiredSpeed: v0) }
        else { a = min(a, IDM.freeAcceleration(p, speed: v.speed, desiredSpeed: v0)) }
        return a
    }

    /// Leaders beyond the stop line: along the planned connector, diverging
    /// siblings that have not separated yet, then the exit lane, repeated for
    /// short roads up to the look-ahead distance.
    func lookAcrossJunction(_ i: Int, distance d0: Double, from lane: LaneID, consider: (Double, Double) -> Void) {
        let v = vehicles[i]
        var dist = d0
        var curLane = lane
        var routeIdx = v.routeIndex
        var planned = v.plannedConnector
        for _ in 0..<3 {
            guard routeIdx + 1 < v.route.count else { return }
            let next = v.route[routeIdx + 1]
            guard let cid = planned ?? network.connector(from: curLane, toEdge: next), let conn = network.connector(cid) else { return }
            // Vehicles on the connector.
            if let o = connOcc[cid.raw].first(where: { Int($0.index) != i }) {
                let j = Int(o.index)
                consider(dist + o.s - vehicles[j].length, vehicles[j].speed)
                return
            }
            for e in network.conflicts.conflicts(of: cid) where e.kind == .diverge {
                for o in connOcc[e.other.raw] {
                    let j = Int(o.index)
                    if j != i && o.s - vehicles[j].length < e.otherZoneEnd {
                        consider(dist + o.s - vehicles[j].length, vehicles[j].speed)
                    }
                }
            }
            dist += conn.length
            let exitKey = laneKey(conn.toEdge, conn.to.index)
            if let o = laneOcc[exitKey].first(where: { Int($0.index) != i }) {
                let j = Int(o.index)
                consider(dist + o.s - vehicles[j].length, vehicles[j].speed)
                return
            }
            guard let exitEdge = network.edge(conn.toEdge) else { return }
            // A stop line just beyond a short link: brake for it now, so the
            // vehicle doesn't enter the link too fast to stop in it.
            if routeIdx + 2 < v.route.count {
                let after = v.route[routeIdx + 2]
                let downstream = network.connector(from: conn.to, toEdge: after)
                    ?? exitEdge.lanes.lazy.compactMap { self.network.connector(from: $0.id, toEdge: after) }.first
                if let dc = downstream.flatMap({ network.connector($0) }),
                   mustStopAhead(v, dc, distance: dist + exitEdge.length) {
                    consider(max(dist + exitEdge.length - 0.3, 0.05), 0)
                }
            }
            dist += exitEdge.length
            if dist > max(config.lookAhead, v.speed * 5) { return }
            curLane = conn.to
            routeIdx += 1
            planned = nil
        }
    }

    /// A siren vehicle passes yielding traffic on the centre side: leaders
    /// that are laterally clear of it don't constrain it.
    func sirenLeader(in list: [Occupant], after s: Double, of i: Int) -> Occupant? {
        // No passing close to the stop line (everyone re-centres there).
        let nearLine = vehicles[i].currentEdge.flatMap { network.edge($0) }.map { $0.length - s < 40 } ?? true
        // Mid lane change: clear where it is going as well as where it is.
        var settled = vehicles[i]
        if let lc = settled.laneChange { settled.lateral = lc.toLateral; settled.rearLateral = nil }
        for o in list where o.s > s && Int(o.index) != i {
            if !nearLine && laterallyClear(vehicles[i], vehicles[Int(o.index)]) && laterallyClear(settled, vehicles[Int(o.index)]) { continue }
            return o
        }
        return nil
    }

    /// Will the vehicle have to stop at the line of `conn`, `distance` ahead?
    /// (Anticipation beyond the next junction; the junction stage decides
    /// for real once the vehicle is on the approach.)
    func mustStopAhead(_ v: Vehicle, _ conn: Connector, distance: Double) -> Bool {
        guard !v.siren, let node = network.node(conn.node) else { return false }
        switch node.effectiveControl {
        case .signal:
            switch signals.indication(for: conn.id, at: conn.node) {
            case .red: return true
            case .yellow, .green:
                // Arriving after it turns red (closely spaced signals): stop.
                return distance / max(v.speed, 1) >= signals.timeUntilRed(for: conn.id, at: conn.node) - 0.05
            default: return false
            }
        case .allWayStop:
            return true
        case .twoWayStop:
            return !network.isMajorApproach(conn.fromEdge, at: conn.node)
        default:
            return false
        }
    }

    func integrate(_ i: Int, target: Double, dt: Double) {
        var v = vehicles[i]
        // Reaction time: gentle changes are acted on only at reaction points;
        // anything calling for noticeably harder braking is acted on at once.
        v.reactionTimer -= dt
        if v.reactionTimer <= 0 || target < v.heldAcceleration - 0.5 {
            v.heldAcceleration = target
            v.reactionTimer = v.driver.reactionTime
        }
        let desired = v.heldAcceleration
        // Jerk limit for comfort, relaxed when hard braking is needed.
        let urgent = desired < -v.driver.idm.comfortableDeceleration * 0.9
        let jerk = urgent ? 30.0 : config.comfortJerk
        var a = min(max(desired, v.acceleration - jerk * dt), v.acceleration + jerk * dt)
        a = max(a, -IDM.emergencyDeceleration)
        // Integrate without reversing.
        var newSpeed = v.speed + a * dt
        var ds: Double
        if newSpeed < 0 {
            ds = a < 0 ? -v.speed * v.speed / (2 * a) : 0
            newSpeed = 0
            a = -v.speed / dt
        } else {
            ds = (v.speed + newSpeed) * 0.5 * dt
        }
        if ds < 0 { ds = 0 }
        v.braking = a < -1.5 || (newSpeed < 0.1 && v.speed < 0.1)
        v.acceleration = a
        v.s += ds
        v.speed = newSpeed
        v.distance += ds
        if newSpeed < 0.5 { v.delay += dt; v.stationaryTime += dt } else { v.stationaryTime = 0 }
        if v.laneChange == nil && v.mode == .driving { v.lateralSpeed = 0 }
        v.rerouteTimer -= dt
        vehicles[i] = v
    }
}
