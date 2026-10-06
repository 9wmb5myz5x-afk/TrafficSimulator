//
//  Gridlock.swift
//  TrafficEngine
//
//  Gridlock = a cycle in the wait-for graph. Every few seconds, each vehicle
//  that has been stationary for a while points at the vehicle it is waiting
//  for (its leader; the hindmost vehicle in a full exit lane; the vehicle
//  holding a conflicting reservation). A cycle among those vehicles can never
//  resolve by itself.
//
//  Resolution mimics real traffic, slowly and by priority: the longest-
//  waiting vehicle in the cycle that is held at a stop line gives up its
//  blocked movement and takes another exit from its lane that has room,
//  rerouting from there. Nobody is ever teleported or removed.
//

public struct GridlockState: Codable, Sendable, Equatable {
    var timer: Double = 0
    public var detected: Int = 0
    public var resolved: Int = 0
    /// Detected cycles currently active (for the debug overlay).
    public var activeCycles: [[VehicleID]] = []
}

extension Simulation {

    func updateGridlock(dt: Double) {
        gridlock.timer += dt
        guard gridlock.timer >= 5 else { return }
        gridlock.timer = 0
        let wait = config.gridlockWait
        var waitsFor = [Int](repeating: -1, count: vehicles.count)
        var candidate = [Bool](repeating: false, count: vehicles.count)
        for i in vehicles.indices where vehicles[i].mode == .driving && vehicles[i].stationaryTime >= wait {
            candidate[i] = true
            waitsFor[i] = blocker(of: i) ?? -1
        }
        // Cycle detection (functional graph: each node has at most one successor).
        var colour = [UInt8](repeating: 0, count: vehicles.count)   // 0 new, 1 on stack, 2 done
        var cycles: [[Int]] = []
        for start in vehicles.indices where candidate[start] && colour[start] == 0 {
            var path: [Int] = []
            var x = start
            while x >= 0 && candidate[x] && colour[x] == 0 {
                colour[x] = 1
                path.append(x)
                x = waitsFor[x]
            }
            if x >= 0 && candidate[x] && colour[x] == 1, let k = path.firstIndex(of: x) {
                cycles.append(Array(path[k...]))
            }
            for p in path { colour[p] = 2 }
        }
        let previous = gridlockVehicles
        gridlockVehicles = Set(cycles.flatMap { $0.map { vehicles[$0].id } })
        gridlock.activeCycles = cycles.map { $0.map { vehicles[$0].id } }
        for c in cycles where !c.contains(where: { previous.contains(vehicles[$0].id) }) {
            gridlock.detected += 1
            log(.gridlockDetected, "gridlock of \(c.count) vehicles: " + c.prefix(6).map { "\(vehicles[$0].id)" }.joined(separator: " → "))
        }
        // Spillback lock: a vehicle held ≥ 2 min at the line because its exit
        // never has room (queues from the next junction keep it full while
        // other approaches take the space). Drivers give up and go another way.
        // Starvation: held at the line for over 3 minutes for any mix of
        // reasons (red, conflicts, an exit that is full whenever it is green).
        for i in vehicles.indices where candidate[i] && vehicles[i].stationaryTime >= 120 && !gridlockVehicles.contains(vehicles[i].id) {
            guard case .edge(let e) = vehicles[i].track, let edge = network.edge(e), edge.length - vehicles[i].s < 8,
                  let pc = vehicles[i].plannedConnector, let conn = network.connector(pc) else { continue }
            let full = !exitHasRoom(i, conn)
            guard full || vehicles[i].stationaryTime >= 200 else { continue }
            if !previous.contains(vehicles[i].id) {
                gridlock.detected += 1
                log(.gridlockDetected, full ? "spillback lock: \(vehicles[i].id) held \(Int(vehicles[i].stationaryTime)) s at \(conn.node), \(conn.toEdge) full"
                                            : "starved: \(vehicles[i].id) held \(Int(vehicles[i].stationaryTime)) s at \(conn.node)")
            }
            if releaseByAlternativeExit(i) {
                gridlock.resolved += 1
                log(.gridlockResolved, "\(vehicles[i].id) took another exit")
            } else {
                gridlockVehicles.insert(vehicles[i].id)
            }
        }
        // Queues behind a gridlock are held by it: a stationary vehicle whose
        // wait-for chain leads into a gridlocked vehicle is part of it (reported
        // with it; liveness is judged on the gridlock, not on each queued car).
        if !gridlockVehicles.isEmpty {
            for i in vehicles.indices where candidate[i] && !gridlockVehicles.contains(vehicles[i].id) {
                var x = waitsFor[i], hops = 0
                while x >= 0 && hops < 200 {
                    if gridlockVehicles.contains(vehicles[x].id) { gridlockVehicles.insert(vehicles[i].id); break }
                    if !candidate[x] { break }
                    x = waitsFor[x]; hops += 1
                }
            }
        }
        // Release by priority: the longest waiter at a stop line takes another exit.
        for c in cycles {
            let ranked = c.sorted { vehicles[$0].stationaryTime != vehicles[$1].stationaryTime
                ? vehicles[$0].stationaryTime > vehicles[$1].stationaryTime : vehicles[$0].id.raw < vehicles[$1].id.raw }
            for i in ranked where releaseByAlternativeExit(i) {
                gridlock.resolved += 1
                log(.gridlockResolved, "\(vehicles[i].id) left the gridlock by another exit")
                break
            }
        }
    }

    /// The vehicle `i` is waiting for, if any.
    func blocker(of i: Int) -> Int? {
        let v = vehicles[i]
        switch v.track {
        case .edge(let e):
            guard let edge = network.edge(e) else { return nil }
            if let o = leader(in: laneOcc[laneKey(e, v.lane)], after: v.s, excluding: i),
               o.s - vehicles[Int(o.index)].length - v.s < 8 {
                return Int(o.index)
            }
            guard edge.length - v.s < 6, let pc = v.plannedConnector, let conn = network.connector(pc) else { return nil }
            // Full exit lane → wait for its hindmost vehicle.
            if !exitHasRoom(i, conn) {
                let key = laneKey(conn.toEdge, conn.to.index)
                if let first = laneOcc[key].first { return Int(first.index) }
                for cid in network.connectors(into: conn.toEdge) where network.connector(cid)?.to == conn.to {
                    if let o = connOcc[cid.raw].first { return Int(o.index) }
                }
            }
            for e in network.conflicts.conflicts(of: pc) where e.kind != .diverge {
                if let o = connOcc[e.other.raw].first(where: { Int($0.index) != i }) { return Int(o.index) }
            }
            return nil
        case .connector(let c):
            if let o = leader(in: connOcc[c.raw], after: v.s, excluding: i) { return Int(o.index) }
            guard let conn = network.connector(c) else { return nil }
            return laneOcc[laneKey(conn.toEdge, conn.to.index)].first.map { Int($0.index) }
        }
    }

    /// Give up the blocked movement: take an exit from this lane that has room.
    func releaseByAlternativeExit(_ i: Int) -> Bool {
        let v = vehicles[i]
        guard case .edge(let e) = v.track, let edge = network.edge(e), edge.length - v.s < 8 else { return false }
        let options = network.connectors(from: LaneID(edge: e, index: v.lane)).compactMap { network.connector($0) }
        for conn in options where conn.id != v.plannedConnector && exitHasRoom(i, conn) {
            let exits = [conn.toEdge]
            if let r = router.route(from: e, to: v.destination.edge, firstSteps: exits, seed: UInt64(v.id.raw) &+ 99) {
                replaceRoute(i, with: r)
            } else if let r = cheapestRouteToRegion(from: conn.toEdge, seed: UInt64(v.id.raw) &+ 99), let exit = r.last {
                // No way to its goal from there: leave the map by a real exit.
                replaceRoute(i, with: [e] + r)
                vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
            } else {
                continue
            }
            vehicles[i].stationaryTime = 0
            return true
        }
        return false
    }
}
