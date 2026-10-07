//
//  StageIndex.swift
//  TrafficEngine
//
//  Spatial indexing: every lane and connector keeps the vehicles on it
//  sorted by arc length.
//
//   • A vehicle changing lanes is listed in *both* lanes, so followers in
//     both lanes treat it as a leader and it respects leaders in both.
//   • A vehicle whose front has crossed onto a connector is also listed at
//     the end of its approach lane (s beyond the lane end) until its rear
//     clears it, and a vehicle whose front is on the exit lane stays listed on
//     its connector until its rear has left the junction. Footprints are
//     therefore always visible to followers and to conflict checks.
//

extension Simulation {

    func rebuildIndex() {
        indexStale = false
        for k in laneOcc.indices where !laneOcc[k].isEmpty { laneOcc[k].removeAll(keepingCapacity: true) }
        for k in connOcc.indices where !connOcc[k].isEmpty { connOcc[k].removeAll(keepingCapacity: true) }
        for k in connCommits.indices where !connCommits[k].isEmpty { connCommits[k].removeAll(keepingCapacity: true) }
        sirenSources.removeAll(keepingCapacity: true)
        kerbside.removeAll(keepingCapacity: true)

        for i in vehicles.indices {
            let v = vehicles[i]
            switch v.mode {
            case .parkedAtKerb, .pullingIn, .pullingOut, .waitingToEnter, .onDriveway: kerbside.append(i)
            default: break
            }
            if v.mode == .finished || v.mode == .waitingToEnter { continue }
            if v.mode == .onDriveway {
                // A car turning in stays in its lane (to the cars behind it)
                // until its rear is clear of the lane.
                guard let run = v.driveway, run.inbound, case .edge(let e) = v.track,
                      let edge = network.edge(e), let lane = edge.lane(v.lane) else { continue }
                let rear = run.path.extendedPoint(at: run.s - v.length)
                if abs(edge.reference.project(rear).lateral - lane.lateral) < lane.width * 0.5 + v.width * 0.5 + 0.6 {
                    laneOcc[laneKey(e, v.lane)].append(Occupant(s: v.s, index: Int32(i)))
                }
                continue
            }
            let idx = Int32(i)
            if v.siren { sirenSources.append(i) }
            switch v.track {
            case .edge(let e):
                // Vehicles parked on the shoulder or turning into a driveway
                // leave the lane once clear of it. A car pulling out is in the
                // lane (to followers) from the moment it starts moving.
                // (Only once its whole body is clear of a car driving in the lane.)
                if v.mode == .parkedAtKerb && v.pullOverShift > v.width + 0.35 { continue }
                // A car turning in leaves once front and rear are clear of the
                // lane and of the strip where cars pull over for a siren.
                if v.mode == .pullingIn, let edge = network.edge(e), let lane = edge.lane(v.lane) {
                    let clear = lane.width * 0.5 + v.width * 0.5 + 1.8
                    if min(abs(v.lateral - lane.lateral), abs((v.rearLateral ?? v.lateral) - lane.lateral)) > clear { continue }
                }
                laneOcc[laneKey(e, v.lane)].append(Occupant(s: v.s, index: idx))
                if let lc = v.laneChange, lc.phase == .moving {
                    let other = lc.toLane == v.lane ? lc.fromLane : lc.toLane
                    if other != v.lane { laneOcc[laneKey(e, other)].append(Occupant(s: v.s, index: idx)) }
                }
                if case .connector(let c)? = v.tailTrack, v.s < v.length {
                    connOcc[c.raw].append(Occupant(s: v.tailTrackLength + v.s, index: idx))
                }
            case .connector(let c):
                connOcc[c.raw].append(Occupant(s: v.s, index: idx))
                if case .edge(let e)? = v.tailTrack, v.s < v.length, let conn = network.connector(c) {
                    laneOcc[laneKey(e, conn.from.index)].append(Occupant(s: v.tailTrackLength + v.s, index: idx))
                }
            }
            if v.committed, let pc = v.plannedConnector, case .edge = v.track {
                connCommits[pc.raw].append(idx)
            }
        }
        for k in laneOcc.indices where laneOcc[k].count > 1 { sortOccupants(&laneOcc[k]) }
        for k in connOcc.indices where connOcc[k].count > 1 { sortOccupants(&connOcc[k]) }
    }

    @inline(__always)
    func sortOccupants(_ a: inout [Occupant]) {
        // Insertion sort: lists are short and mostly sorted.
        if a.count < 2 { return }
        for i in 1..<a.count {
            let x = a[i]
            var j = i - 1
            while j >= 0 && (a[j].s > x.s || (a[j].s == x.s && a[j].index > x.index)) {
                a[j + 1] = a[j]
                j -= 1
            }
            a[j + 1] = x
        }
    }

    // MARK: - Neighbour queries

    /// First occupant strictly ahead of `s` (excluding `me`).
    @inline(__always)
    func leader(in list: [Occupant], after s: Double, excluding me: Int) -> Occupant? {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if list[mid].s <= s { lo = mid + 1 } else { hi = mid }
        }
        // Equal-s neighbours (side by side) count as leaders too: check backwards.
        var k = lo - 1
        while k >= 0 && list[k].s == s {
            if Int(list[k].index) != me { return list[k] }
            k -= 1
        }
        var j = lo
        while j < list.count {
            if Int(list[j].index) != me { return list[j] }
            j += 1
        }
        return nil
    }

    /// Closest occupant at or behind `s` (excluding `me`).
    @inline(__always)
    func follower(in list: [Occupant], before s: Double, excluding me: Int) -> Occupant? {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if list[mid].s < s { lo = mid + 1 } else { hi = mid }
        }
        var j = lo - 1
        while j >= 0 {
            if Int(list[j].index) != me { return list[j] }
            j -= 1
        }
        return nil
    }

    /// The vehicle closest to the start of a lane (smallest s).
    func lastVehicle(onLane key: Int) -> Occupant? { laneOcc[key].first }

    /// Rear arc length of the hindmost vehicle on a lane, if any.
    func rearmostRear(onLane key: Int) -> Double? {
        var best: Double?
        for o in laneOcc[key] {
            let r = o.s - vehicles[Int(o.index)].length
            if best == nil || r < best! { best = r }
        }
        return best
    }
}
