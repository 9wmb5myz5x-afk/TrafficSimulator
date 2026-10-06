//
//  StageTracks.swift
//  TrafficEngine
//
//  Moving across boundaries: stop line → connector → exit lane, leaving the
//  map, en-route rerouting, and the derived pose (front, centre, heading)
//  used by rendering and the invariant checks.
//

extension Simulation {

    func advanceTracks() {
        for i in vehicles.indices {
            guard vehicles[i].mode != .finished, vehicles[i].mode != .waitingToEnter else { continue }
            var guardCount = 0
            while guardCount < 3 {
                guardCount += 1
                if !crossBoundary(i) { break }
            }
            // The rear has left the previous track.
            if vehicles[i].tailTrack != nil && vehicles[i].s >= vehicles[i].length + 0.2 {
                vehicles[i].tailTrack = nil
            }
        }
    }

    /// Returns true if the vehicle moved onto a new track (so another check is needed).
    func crossBoundary(_ i: Int) -> Bool {
        let v = vehicles[i]
        switch v.track {
        case .edge(let eid):
            guard let edge = network.edge(eid) else { vehicles[i].mode = .finished; return false }
            guard v.s >= edge.length else { return false }
            if v.isOnFinalEdge {
                if v.destination.kind == .exitMap {
                    // Leaving the map: removed once the rear has passed the boundary.
                    if v.s - v.length >= edge.length { finishTrip(i) }
                    return false
                }
                // Overshot a kerbside destination: go around again.
                if v.mode == .driving { circleBack(i, edge: edge) }
                if vehicles[i].isOnFinalEdge { return false }
            }
            guard vehicles[i].committed, let pc = vehicles[i].plannedConnector, let conn = network.connector(pc),
                  conn.from.edge == eid else {
                // Should not happen: the stop-line obstacle prevents it. Record it.
                if debugForcedStops && v.speed > 0 {
                    print("FORCED \(v.id) t=\(time) speed=\(v.speed) committed=\(v.committed) planned=\(String(describing: v.plannedConnector)) lane=\(v.lane) lc=\(String(describing: v.laneChange)) next=\(String(describing: v.nextRouteEdge)) stop=\(String(describing: i < stopTargets.count ? stopTargets[i] : nil)) acc=\(v.acceleration) held=\(v.heldAcceleration)")
                }
                vehicles[i].s = edge.length
                vehicles[i].speed = 0
                vehicles[i].acceleration = 0
                metrics.recordForcedStop()
                invariantChecker?.recordForcedStop(vehicles[i], time: time)
                return false
            }
            recordEntryForWarrants(node: conn.node, approach: eid)
            if let hook = onJunctionEntry { hook(vehicles[i], conn, signals.indication(for: pc, at: conn.node)) }
            vehicles[i].tailTrack = .edge(eid)
            vehicles[i].tailTrackLength = edge.length
            vehicles[i].track = .connector(pc)
            vehicles[i].laneNeed = 0
            vehicles[i].s -= edge.length
            vehicles[i].lateral = 0
            vehicles[i].lateralSpeed = 0
            vehicles[i].bodyYaw = 0
            vehicles[i].committed = false
            vehicles[i].stopArrival = nil
            vehicles[i].lineWait = 0
            vehicles[i].laneChange = nil
            // Control delay on this approach: actual minus free-flow time.
            let free = (edge.length - v.edgeEnterS) / max(edge.speedLimit, 1)
            metrics.recordControlDelay(node: conn.node, delay: (time - v.edgeEnterTime) - free,
                                       signalised: network.node(conn.node)?.effectiveControl == .signal)
            return true
        case .connector(let cid):
            guard let conn = network.connector(cid), let exitEdge = network.edge(conn.toEdge),
                  let lane = exitEdge.lane(conn.to.index) else { vehicles[i].mode = .finished; return false }
            guard v.s >= conn.length else { return false }
            vehicles[i].tailTrack = .connector(cid)
            vehicles[i].tailTrackLength = conn.length
            vehicles[i].track = .edge(conn.toEdge)
            vehicles[i].s -= conn.length
            vehicles[i].lane = conn.to.index
            vehicles[i].lateral = lane.lateral
            vehicles[i].plannedConnector = nil
            vehicles[i].committed = false
            vehicles[i].edgeEnterTime = time
            vehicles[i].edgeEnterS = 0
            // Advance the route cursor to the edge we just entered.
            if let k = vehicles[i].route[vehicles[i].routeIndex...].firstIndex(of: conn.toEdge) {
                vehicles[i].routeIndex = k
            } else {
                // Off-route (missed turn): plan again from here.
                vehicles[i].route = [conn.toEdge]
                vehicles[i].routeIndex = 0
                rerouteFrom(i, edge: conn.toEdge, force: true)
            }
            if vehicles[i].isOnFinalEdge && vehicles[i].destination.edge != conn.toEdge {
                // The route ran out short of the destination: plan on from here.
                rerouteFrom(i, edge: conn.toEdge, force: true)
            } else if vehicles[i].rerouteTimer <= 0 {
                vehicles[i].rerouteTimer = config.rerouteInterval
                rerouteFrom(i, edge: conn.toEdge, force: false)
            }
            return true
        }
    }

    func finishTrip(_ i: Int) {
        let v = vehicles[i]
        vehicles[i].mode = .finished
        metrics.recordCompletion(tripTime: time - v.spawnTime, distance: v.distance, delay: v.delay)
        tripDidFinish(v)
    }

    /// Missed a kerbside destination: loop round to reach it again.
    func circleBack(_ i: Int, edge: Edge) {
        let succ = network.successors(of: edge.id)
        let goal = vehicles[i].destination.edge
        let seed = UInt64(vehicles[i].id.raw) &* 977 &+ UInt64(vehicles[i].missedTurns)
        func leave(_ r: [EdgeID], comingBack: Bool) {
            guard let exit = r.last else { return }
            vehicles[i].route = r
            vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
            vehicles[i].viaRegion = comingBack
        }
        if !succ.isEmpty, let r = router.route(from: edge.id, to: goal, firstSteps: succ, seed: seed) {
            vehicles[i].route = r
        } else if vehicles[i].person != nil, let r = cheapestRouteToRegion(from: edge.id, seed: seed, thenTo: goal) {
            // No way round inside the map: turn round beyond its edge.
            leave(r, comingBack: true)
        } else if let r = cheapestRouteToRegion(from: edge.id, seed: seed) {
            leave(r, comingBack: false)
        } else {
            vehicles[i].route = [edge.id]
            vehicles[i].destination = Destination(kind: .exitMap, edge: edge.id, s: edge.length)
        }
        vehicles[i].routeIndex = 0
    }

    /// En-route rerouting with hysteresis: switch only if meaningfully better.
    func rerouteFrom(_ i: Int, edge: EdgeID, force: Bool) {
        let v = vehicles[i]
        guard v.purpose != .patrol || force else { return }
        let seed = UInt64(v.id.raw) &* 0x9E37 &+ UInt64(v.missedTurns)
        // Already past the destination on its own edge: go round the block.
        let passed = edge == v.destination.edge && v.currentEdge == edge && v.s > v.destination.s - 3
        let firstSteps = passed ? network.successors(of: edge) : nil
        guard let alt = router.route(from: edge, to: v.destination.edge, firstSteps: firstSteps, seed: seed) else {
            if force {
                // Unreachable now (edited network): leave the map by the nearest
                // exit, or — with none reachable — where it is.
                if let r = cheapestRouteToRegion(from: edge, seed: seed), let exit = r.last, r.first == edge {
                    vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
                    vehicles[i].route = r
                } else {
                    vehicles[i].destination = Destination(kind: .exitMap, edge: edge, s: network.edge(edge)?.length ?? 0)
                    vehicles[i].route = [edge]
                }
                vehicles[i].routeIndex = 0
            }
            return
        }
        if force {
            vehicles[i].route = alt
            vehicles[i].routeIndex = 0
            return
        }
        guard let k = v.route.firstIndex(of: edge) else { return }
        let current = router.cost(of: v.route[k...])
        let candidate = router.cost(of: alt[...])
        if candidate < current * (1 - config.rerouteRelativeGain) && current - candidate > config.rerouteAbsoluteGain {
            vehicles[i].route = alt
            vehicles[i].routeIndex = 0
            metrics.recordReroute()
        }
    }

    // MARK: - Pose

    func updatePose(_ v: inout Vehicle) {
        if v.mode == .waitingToEnter { return }
        let front = position(on: v.track, s: v.s, lateral: v.lateral)
        let rearS = v.s - v.length
        var rear: Vector2
        if rearS >= 0 || v.tailTrack == nil {
            // Body yaw during lateral motion: the rear lags the front laterally.
            // Yaw is a continuous state; it only changes while the car rolls.
            do {
                let target = v.speed > 0.2 ? DMath.atan2(v.lateralSpeed, v.speed).clamped(to: -0.45...0.45) : 0
                let maxStep = (0.6 * v.speed + 0.3) * config.dt / max(v.length, 1)
                v.bodyYaw += (target - v.bodyYaw).clamped(to: -maxStep...maxStep)
            }
            // The rear traces the path the front already drove, so it stays
            // between where the manoeuvre started and where the front is now.
            var target = v.lateral - DMath.sin(v.bodyYaw) * v.length
            let origin = v.laneChange?.fromLateral ?? v.lateral
            target = target.clamped(to: min(origin, v.lateral)...max(origin, v.lateral))
            // The rear lateral is continuous: it moves at most as fast as the front does.
            let prev = v.rearLateral ?? target
            let rate = (0.6 * v.speed + 0.3) * config.dt
            let rearLat = prev + (target - prev).clamped(to: -rate...rate)
            v.rearLateral = rearLat
            rear = position(on: v.track, s: rearS, lateral: rearLat)
        } else {
            var tailLat = 0.0
            if case .edge(let te)? = v.tailTrack, case .connector(let c) = v.track, let conn = network.connector(c) {
                // Rear still on the approach lane: settle onto the lane centre continuously.
                let target = network.edge(te)?.lane(conn.from.index)?.lateral ?? 0
                let prev = v.rearLateral ?? target
                let rate = (0.6 * v.speed + 0.3) * config.dt
                tailLat = prev + (target - prev).clamped(to: -rate...rate)
                v.rearLateral = tailLat
            } else if case .connector(let c)? = v.tailTrack, case .edge = v.track, let conn = network.connector(c) {
                // Rear still in the junction: it joins this edge at the lane the
                // connector ends in, so the rear lateral carries on from there.
                v.rearLateral = network.edge(conn.toEdge)?.lane(conn.to.index)?.lateral
            } else {
                v.rearLateral = nil
            }
            rear = position(on: v.tailTrack!, s: v.tailTrackLength + rearS, lateral: tailLat)
        }
        var axis = front - rear
        if axis.length < 0.5 { axis = tangent(on: v.track, s: max(v.s, 0)) }
        v.front = front
        v.heading = axis.angle
        let dir = axis.normalized
        v.center = front - dir * (v.length / 2)
    }

    // MARK: - Edits

    /// After a network edit: vehicles keep their place in the world. Those on
    /// roads whose geometry is unchanged stay put; those on reshaped or split
    /// roads are re-anchored to whichever new carriageway lies under them (so
    /// nothing jumps); those left with no road under them leave gracefully.
    /// Routes and destinations are repaired, and recomputed when broken.
    func reconcileVehiclesAfterEdit(oldRefs: [Polyline?], oldLanes: [[Double]]) {
        // Map old connector ids to new ones by movement (from lane, to lane).
        var lookup: [MovementKey: ConnectorID] = [:]
        for c in network.connectors { lookup[MovementKey(from: c.from, to: c.to)] = c.id }
        let old = movementKeys
        movementKeys = network.connectors.map { MovementKey(from: $0.from, to: $0.to) }
        func remap(_ c: ConnectorID) -> ConnectorID? {
            guard c.raw < old.count else { return nil }
            return lookup[old[c.raw]]
        }
        // Where everyone is now: an edit must not visibly move anyone.
        var before: [Int: (front: Vector2, heading: Double)] = [:]
        for v in vehicles where v.mode != .finished && v.mode != .waitingToEnter { before[v.id.raw] = (v.front, v.heading) }
        func unchanged(_ e: EdgeID) -> Bool {
            guard let edge = network.edge(e) else { return false }
            guard e.raw < oldRefs.count, let o = oldRefs[e.raw] else { return true }
            let lanesSame = e.raw >= oldLanes.count || oldLanes[e.raw] == edge.lanes.map { $0.lateral }
            return o.points == edge.reference.points && lanesSame
        }
        // Roads that are new or reshaped: a car beside the carriageway (parked,
        // in a driveway, pulled over) that one of them now runs over leaves.
        let changed = network.allEdges.filter { $0.id.raw >= oldRefs.count || oldRefs[$0.id.raw] == nil || !unchanged($0.id) }
        func runOver(_ v: Vehicle) -> Bool {
            guard let cur = v.currentEdge.flatMap({ network.edge($0) }) else { return false }
            for other in changed where other.road != cur.road {
                let b = other.reference.bounds
                let half = (other.lanes.map { abs($0.lateral) + $0.width / 2 }.max() ?? 3.5) + v.width / 2 + 0.3
                for p in [v.front, v.center] {
                    guard p.x > b.min.x - half, p.x < b.max.x + half, p.y > b.min.y - half, p.y < b.max.y + half else { continue }
                    if other.reference.project(p).distance < half { return true }
                }
            }
            return false
        }
        for i in vehicles.indices {
            var v = vehicles[i]
            if v.mode == .finished { continue }
            if !changed.isEmpty, v.mode != .waitingToEnter, v.mode != .driving || v.pullOverShift != 0, runOver(v) {
                v.mode = .finished; vehicles[i] = v; continue
            }
            if v.mode == .waitingToEnter || v.mode == .pullingOut {
                // Still in (or leaving) the driveway: it must be the same driveway.
                let same: Bool
                if let o = v.origin {
                    let acc = city.building(o)?.access
                    same = acc.map { $0.edge == v.currentEdge && abs($0.s - v.s) < 30 } ?? false
                } else {
                    same = true      // entering at the map edge
                }
                if !same || !unchanged(v.currentEdge ?? EdgeID(-1)) { v.mode = .finished; vehicles[i] = v; continue }
                if v.mode == .waitingToEnter { continue }
            }
            if let pc = v.plannedConnector { v.plannedConnector = remap(pc) }
            if case .connector(let tc)? = v.tailTrack { v.tailTrack = remap(tc).map { .connector($0) } }
            if case .edge(let te)? = v.tailTrack, !unchanged(te) { v.tailTrack = nil }
            var moved = false
            switch v.track {
            case .edge(let e):
                if unchanged(e) {
                    let edge = network.edge(e)!
                    if edge.lane(v.lane) == nil {
                        v.lane = edge.lanes.filter { $0.kind == .travel }.first?.index ?? 0
                        v.laneChange = nil
                    }
                    // Re-centre only vehicles simply driving in their lane (a no-op
                    // unless the lane itself moved); cars pulling into or out of a
                    // driveway, parked or pulled over keep their position.
                    if v.laneChange == nil, v.mode == .driving, v.pullOverShift == 0, let l = edge.lane(v.lane) { v.lateral = l.lateral }
                    if let lc = v.laneChange, edge.lane(lc.toLane) == nil || edge.lane(lc.fromLane) == nil {
                        v.laneChange = nil
                        v.lateral = edge.lane(v.lane)?.lateral ?? v.lateral
                    }
                } else {
                    // Parked, pulling in or out, or pulled over for a siren: their
                    // place depends on the kerb, which moved — they leave.
                    if v.mode != .driving || v.pullOverShift != 0 { v.mode = .finished; vehicles[i] = v; continue }
                    guard let a = anchorOnEdges(v.front, direction: Vector2.unit(angle: v.heading)),
                          let edge = network.edge(a.edge) else { v.mode = .finished; vehicles[i] = v; continue }
                    v.track = .edge(a.edge)
                    v.s = a.s
                    // Same lateral frame (a split or re-joined road): keep lane and manoeuvre as they are.
                    func laneAt(_ k: Int, _ lat: Double) -> Bool { edge.lane(k).map { abs($0.lateral - lat) < 0.05 } ?? false }
                    let sameFrame = abs(a.lateral - v.lateral) < 0.2
                        && (v.laneChange.map { laneAt($0.fromLane, $0.fromLateral) && laneAt($0.toLane, $0.toLateral) }
                            ?? (v.pullOverShift != 0 || laneAt(v.lane, v.lateral)))
                    if !sameFrame {
                        let ok = edge.lanes.filter { $0.sStart <= a.s && $0.sEnd >= a.s }
                        let lane = ok.min { abs($0.lateral - a.lateral) < abs($1.lateral - a.lateral) } ?? edge.lanes[0]
                        v.lane = lane.index
                        v.laneChange = nil
                        v.lateral = a.lateral
                        // Left outside the (narrowed) carriageway: it leaves.
                        let lats = edge.lanes.map { $0.lateral }
                        let margin = edge.laneWidth / 2 + edge.roadClass.shoulderWidth
                        if a.lateral < (lats.min() ?? 0) - margin || a.lateral > (lats.max() ?? 0) + margin {
                            v.mode = .finished; vehicles[i] = v; continue
                        }
                        // Drift smoothly onto the new lane centre (no jump).
                        if v.mode == .driving && v.pullOverShift == 0 && abs(a.lateral - lane.lateral) > 0.02 {
                            v.laneChange = LaneChange(fromLane: lane.index, toLane: lane.index, phase: .moving,
                                                      duration: 3, mandatory: false,
                                                      fromLateral: a.lateral, toLateral: lane.lateral)
                        }
                    }
                    v.edgeEnterS = a.s
                    v.edgeEnterTime = time
                    // Rear: on whichever carriageway is behind it.
                    if a.s < v.length {
                        let rearP = v.front - Vector2.unit(angle: v.heading) * v.length
                        if case .connector(let tc)? = v.tailTrack, network.connector(tc)?.to.edge == a.edge {
                            // Rear still in the junction it came through.
                        } else if let r = anchorOnEdges(rearP, direction: Vector2.unit(angle: v.heading)), r.edge != a.edge,
                           let re = network.edge(r.edge) {
                            v.tailTrack = .edge(r.edge)
                            v.tailTrackLength = re.length
                        } else {
                            v.tailTrack = nil
                        }
                    }
                    moved = true
                }
            case .connector(let c):
                guard let nc = remap(c), let conn = network.connector(nc) else {
                    v.mode = .finished; vehicles[i] = v; continue
                }
                v.track = .connector(nc)
                v.s = min(conn.path.project(v.front).s, conn.length)
            }
            v.committed = v.committed && v.plannedConnector != nil
            // Destinations: buildings follow their (re-anchored) driveway; other
            // destinations on reshaped roads move to the carriageway under them.
            if let b = v.destination.building {
                if let acc = city.building(b)?.access {
                    v.destination.edge = acc.edge
                    v.destination.s = acc.s
                    v.destinationLane = acc.lane
                } else {
                    v.destination.kind = .exitMap
                    v.destination.building = nil
                }
            } else if !unchanged(v.destination.edge) {
                if let d = reanchor(v.destination, cls: v.cls, oldRefs: oldRefs) {
                    v.destination = d
                } else {
                    v.destination.kind = .exitMap
                    v.destination.building = nil
                    v.destination.edge = v.currentEdge ?? v.destination.edge
                }
            }
            vehicles[i] = v
            // Routes: the current edge must be in the route and every later step connected.
            guard case .edge(let cur) = vehicles[i].track else {
                if !routeIntact(vehicles[i]) { vehicles[i].mode = .finished }
                continue
            }
            if moved || !routeIntact(vehicles[i]) || network.edge(vehicles[i].destination.edge) == nil {
                if network.edge(vehicles[i].destination.edge) == nil {
                    vehicles[i].destination = Destination(kind: .exitMap, edge: cur, s: network.edge(cur)?.length ?? 0)
                }
                vehicles[i].plannedConnector = nil
                vehicles[i].committed = false
                vehicles[i].route = [cur]
                vehicles[i].routeIndex = 0
                rerouteFrom(i, edge: cur, force: true)
                if vehicles[i].route.first != cur {
                    vehicles[i].route = [cur]
                    vehicles[i].routeIndex = 0
                }
            }
            // Already too close to a (new or changed) junction to stop: let it through.
            let v2 = vehicles[i]
            if !v2.committed, v2.mode == .driving, let edge = network.edge(cur), let next = v2.nextRouteEdge {
                let dEnd = edge.length - v2.s
                if dEnd < v2.speed * v2.speed / 6 + 1 && v2.laneChange != nil {
                    // Mid-lane-change right in front of a new junction: it can
                    // neither stop nor commit to one path — it leaves.
                    vehicles[i].mode = .finished
                } else if dEnd < v2.speed * v2.speed / 6 + 1,
                   let pc = network.connector(from: LaneID(edge: cur, index: v2.lane), toEdge: next) {
                    vehicles[i].plannedConnector = pc
                    vehicles[i].committed = true
                }
            }
        }
        // Anyone the edit would visibly move (a lane that shifted, a road
        // reshaped under them) leaves the simulation instead of jumping.
        var removed: Set<Int> = []
        for i in vehicles.indices where vehicles[i].mode != .finished && vehicles[i].mode != .waitingToEnter {
            guard let b = before[vehicles[i].id.raw] else { continue }
            var probe = vehicles[i]
            updatePose(&probe)
            if probe.front.distance(to: b.front) > 0.3 || abs(DMath.angleDifference(probe.heading, b.heading)) > 0.12 {
                vehicles[i].mode = .finished
            }
        }
        for v in vehicles where v.mode == .finished { removed.insert(v.id.raw) }
        if !removed.isEmpty {
            // Their occupants are back where they started from.
            for k in city.people.indices {
                guard let vid = city.people[k].vehicle, removed.contains(vid.raw) else { continue }
                city.people[k].vehicle = nil
                city.people[k].inRegion = nil
                city.people[k].at = city.building(city.people[k].home) != nil ? city.people[k].home : nil
                city.people[k].plan = []
            }
            for i in vehicles.indices where vehicles[i].mode == .finished {
                if let o = vehicles[i].origin, city.buildingSlots[o.raw]?.drivewayVehicle == vehicles[i].id {
                    city.buildingSlots[o.raw]?.drivewayVehicle = nil
                }
            }
        }
        // Police cars off the map keep a destination for when they drive back in.
        for (key, var re) in police.reentries where !unchanged(re.destination.edge) {
            if let d = reanchor(re.destination, cls: .police, oldRefs: oldRefs) {
                re.destination = d
                police.reentries[key] = re
            } else if let e = network.allEdges.first(where: { network.edge($0.id)?.length ?? 0 > 80 && !network.successors(of: $0.id).isEmpty }) {
                re.destination = Destination(kind: .kerb, edge: e.id, s: kerbRange(e.id, VehicleClass.police.length).lowerBound)
                police.reentries[key] = re
            }
        }
        compact()
    }

    /// Move a destination on a reshaped road to the same place on the new
    /// carriageway (kerb stops stay within the usable stretch).
    func reanchor(_ d: Destination, cls: VehicleClass, oldRefs: [Polyline?]) -> Destination? {
        guard d.edge.raw >= 0, d.edge.raw < oldRefs.count, let o = oldRefs[d.edge.raw] else { return nil }
        let s = min(max(d.s, 0), o.length)
        guard let a = anchorOnEdges(o.point(at: s), direction: o.tangent(at: s)), let edge = network.edge(a.edge) else { return nil }
        var out = d
        out.edge = a.edge
        switch d.kind {
        case .exitMap: out.s = edge.length
        case .kerb: out.s = a.s.clamped(to: kerbRange(a.edge, cls.length))
        case .building: out.s = min(a.s, edge.length)
        }
        return out
    }

    /// The route from the vehicle's position onward exists and is connected.
    func routeIntact(_ v: Vehicle) -> Bool {
        guard v.routeIndex < v.route.count, v.route.last == v.destination.edge else { return false }
        if case .edge(let e) = v.track, v.route[v.routeIndex] != e { return false }
        for k in v.routeIndex..<v.route.count {
            guard network.edge(v.route[k]) != nil else { return false }
            if k + 1 < v.route.count && !network.successors(of: v.route[k]).contains(v.route[k + 1]) { return false }
        }
        if case .connector(let c) = v.track {
            guard let conn = network.connector(c), v.routeIndex + 1 < v.route.count,
                  conn.to.edge == v.route[v.routeIndex + 1] else { return false }
        }
        return network.edge(v.destination.edge) != nil
    }

    /// The carriageway under a world point heading in `direction`, if any.
    func anchorOnEdges(_ p: Vector2, direction: Vector2) -> (edge: EdgeID, s: Double, lateral: Double)? {
        var best: (edge: EdgeID, s: Double, lateral: Double, d: Double)?
        for case let edge? in network.edges {
            let b = edge.reference.bounds
            let lats = edge.lanes.map { abs($0.lateral) }
            let reach = (lats.max() ?? 0) + edge.laneWidth / 2 + 3
            guard p.x > b.min.x - reach, p.y > b.min.y - reach, p.x < b.max.x + reach, p.y < b.max.y + reach else { continue }
            let pr = edge.reference.project(p)
            guard pr.distance < reach, pr.s > 0.01 || edge.reference.start.distance(to: p) < reach,
                  edge.reference.tangent(at: pr.s).dot(direction) > 0.7 else { continue }
            // Off the ends of the carriageway does not count.
            if pr.s <= 0.01 && (p - edge.reference.start).dot(edge.reference.startTangent) < -0.5 { continue }
            if pr.s >= edge.length - 0.01 && (p - edge.reference.end).dot(edge.reference.endTangent) > 0.5 { continue }
            if best == nil || pr.distance < best!.d { best = (edge.id, pr.s, pr.lateral, pr.distance) }
        }
        return best.map { ($0.edge, $0.s, $0.lateral) }
    }
}
