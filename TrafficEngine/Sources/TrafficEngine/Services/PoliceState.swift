//
//  PoliceState.swift
//  TrafficEngine
//
//  Police stations, patrol units, incidents and emergency response.
//
//   station ─deploy→ patrol (random-waypoint walk weighted by home density
//   and by how long ago a unit last drove the street; occasional kerb
//   breaks) ─dispatch→ respond (lights & siren, pre-emption, through a red
//   only after slowing and checking) ─arrive→ on scene (parked at the kerb,
//   hazards on) ─clear→ patrol.
//
//  Incidents are generated at a rate proportional to population, less often
//  on recently patrolled streets. The nearest available unit *by travel
//  time* responds. Civilians ahead of a siren pull towards the kerb and slow
//  down; the unit passes on the centre side.
//

public enum PoliceUnitStatus: String, Codable, Sendable {
    case inStation, deploying, patrolling, patrolBreak, responding, onScene
}

public struct PoliceUnit: Codable, Sendable, Equatable {
    public var station: BuildingID
    public var status: PoliceUnitStatus = .inStation
    public var vehicle: VehicleID?
    public var incident: IncidentID?
    /// Time left in a patrol break / on scene [s].
    public var timer: Double = 0
    /// Earliest time this unit leaves the station (staggered deployment).
    public var deployAt: Double = 0
}

public enum IncidentStatus: String, Codable, Sendable { case waiting, assigned, onScene, cleared }

public struct Incident: Codable, Sendable, Equatable, Identifiable {
    public let id: IncidentID
    public var building: BuildingID
    public var status: IncidentStatus = .waiting
    public var created: Double
    public var dispatched: Double?
    public var arrived: Double?
    public var cleared: Double?
    public var unit: Int?
    /// Sampled time the unit spends on scene [s].
    public var serviceTime: Double
}

struct Reentry: Codable, Sendable, Equatable {
    var destination: Destination
    var siren: Bool
    var purpose: TripPurpose
    var at: Double?
}

public struct PoliceState: Codable, Sendable {
    public internal(set) var units: [PoliceUnit] = []
    public internal(set) var incidents: [Incident] = []
    /// Junctions an emergency vehicle is about to cross: civilians hold position
    /// (except those on the unit's own approach, who clear the way).
    public var holdNodes: Set<NodeID> = []
    var holdApproaches: Set<EdgeID> = []
    /// Last time a police unit drove each edge (by edge raw id).
    var lastVisit: [Int: Double] = [:]
    var incidentAccumulator: Double = 0
    var nextIncident = 0
    /// Response times (creation → arrival) of the most recent incidents [s].
    public internal(set) var responseTimes: [Double] = []
    var preempted: [Int: Int] = [:]    // node raw → vehicle raw holding a pre-emption
    /// Units turning round beyond the map edge: old vehicle raw id → where to resume.
    var reentries: [Int: Reentry] = [:]
    public init() {}

    public var meanResponseTime: Double? {
        responseTimes.isEmpty ? nil : responseTimes.reduce(0, +) / Double(responseTimes.count)
    }
    public var p90ResponseTime: Double? {
        guard !responseTimes.isEmpty else { return nil }
        let s = responseTimes.sorted()
        return s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.up)) - 1)]
    }
    public var activeIncidents: [Incident] { incidents.filter { $0.status != .cleared } }
}

extension Simulation {

    // MARK: - Stations

    static let unitsPerStation = 3

    func registerPoliceStation(_ id: BuildingID) {
        for k in 0..<Self.unitsPerStation {
            police.units.append(PoliceUnit(station: id, deployAt: time + Double(k) * 20 + 2))
        }
    }

    func removePoliceStation(_ id: BuildingID) {
        for k in police.units.indices where police.units[k].station == id {
            if let vid = police.units[k].vehicle, let i = index(of: vid) {
                // The car stays on the road as an ordinary vehicle and leaves the map.
                vehicles[i].siren = false
                vehicles[i].hazard = false
                if vehicles[i].mode == .parkedAtKerb && unparkIfClear(i) == false { vehicles[i].mode = .finished }
                var leaving = false
                if vehicles[i].mode == .driving, case .edge(let e) = vehicles[i].track { leaving = circleBackToExit(i, from: e) }
                // No way off the map (or mid-junction, in a driveway): it just goes.
                if !leaving { vehicles[i].mode = .finished }
            }
            if let inc = police.units[k].incident, inc.raw < police.incidents.count {
                police.incidents[inc.raw].status = .waiting
                police.incidents[inc.raw].unit = nil
            }
        }
        police.units.removeAll { $0.station == id }
        for k in police.incidents.indices where police.incidents[k].unit.map({ $0 >= police.units.count }) == true {
            police.incidents[k].unit = nil
            police.incidents[k].status = .waiting
        }
    }

    @discardableResult
    private func circleBackToExit(_ i: Int, from e: EdgeID) -> Bool {
        guard let r = cheapestRouteToRegion(from: e, seed: UInt64(vehicles[i].id.raw)), let exit = r.last else { return false }
        setRoute(i, r)
        vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
        vehicles[i].purpose = .through
        return true
    }

    // MARK: - Incidents

    /// Create an incident at a building now (the generator, tests, the UI).
    @discardableResult
    public func createIncident(at building: BuildingID) -> IncidentID? {
        guard city.building(building)?.access != nil else { return nil }
        let id = IncidentID(police.nextIncident)
        police.nextIncident += 1
        let service = rng.nextDouble(in: 120..<360)
        police.incidents.append(Incident(id: id, building: building, created: time, serviceTime: service))
        log(.incident, "\(id) at \(building)")
        return id
    }

    func generateIncidents(dt: Double) {
        guard !police.units.isEmpty else { return }
        let perClockDay = Double(currentPopulation()) / 1000 * config.incidentsPerThousandPerDay
        police.incidentAccumulator += perClockDay / 86400 * config.clockScale * dt
        guard police.incidentAccumulator >= 1 else { return }
        police.incidentAccumulator -= 1
        // Where: weighted by occupants, halved on recently patrolled streets.
        let candidates = city.buildings.filter { $0.access != nil && $0.kind != .policeStation }
        guard !candidates.isEmpty else { return }
        let w = candidates.map { b -> Double in
            let base = Double(b.residents.count) + Double(b.jobs) * 0.5 + 1
            let edge = b.access!.edge.raw
            let recent = police.lastVisit[edge].map { time - $0 < 1200 } ?? false
            return base * (recent ? 0.5 : 1)
        }
        if let k = rng.pickWeighted(w) { createIncident(at: candidates[k].id) }
    }

    // MARK: - Stage (after motion)

    func updateServicesPostStep(dt: Double) {
        guard !police.units.isEmpty || !police.incidents.isEmpty else { return }
        generateIncidents(dt: dt)
        for k in police.units.indices { updateUnit(k, dt: dt) }
        if stepCount % 20 == 0 { dispatchIncidents() }   // once a second
        // Coverage bookkeeping.
        for u in police.units {
            if let vid = u.vehicle, let i = index(of: vid), case .edge(let e) = vehicles[i].track {
                police.lastVisit[e.raw] = time
            }
        }
        // Pre-emptions end when the unit is gone or silent, has passed the
        // junction (no longer approaching or in it), or has been standing for
        // 45 s (stuck in a queue: holding the green starves everyone else).
        for (n, holder) in police.preempted {
            var keep = false
            if let i = index(of: VehicleID(holder)), vehicles[i].siren, vehicles[i].stationaryTime < 45 {
                switch vehicles[i].track {
                case .edge(let e): keep = network.edge(e)?.to.raw == n
                case .connector(let c): keep = network.connector(c)?.node.raw == n
                }
            }
            if !keep {
                signals.clearPreemption(node: NodeID(n))
                police.preempted[n] = nil
            }
        }
    }

    private func updateUnit(_ k: Int, dt: Double) {
        var u = police.units[k]
        defer { police.units[k] = u }
        let vi = u.vehicle.flatMap { index(of: $0) }
        if let old = u.vehicle, vi == nil, var re = police.reentries[old.raw] {
            // Turning round beyond the map edge: drive back in after a short while.
            if re.at == nil { re.at = time + 20; police.reentries[old.raw] = re }
            guard time >= re.at!, let r = cheapestRouteFromRegion(to: re.destination.edge, seed: UInt64(old.raw)),
                  let entry = r.first,
                  let id = spawnEntering(entry: entry, cls: .police, route: r, destination: re.destination, purpose: re.purpose),
                  let i = index(of: id) else { return }
            vehicles[i].siren = re.siren
            vehicles[i].driver = policeDriver()
            vehicles[i].destinationLane = network.edge(re.destination.edge)?.lanes.filter({ $0.kind == .travel }).min(by: { $0.index < $1.index })?.index
            u.vehicle = id
            police.reentries[old.raw] = nil
            return
        }
        if u.vehicle != nil && vi == nil {
            // The car is gone (edited road, left the map): back to the station.
            u.vehicle = nil
            u.status = .inStation
            u.deployAt = time + 30
            if let inc = u.incident, inc.raw < police.incidents.count, police.incidents[inc.raw].status != .cleared {
                police.incidents[inc.raw].status = .waiting
                police.incidents[inc.raw].unit = nil
            }
            u.incident = nil
            return
        }
        switch u.status {
        case .inStation:
            if time >= u.deployAt, let id = deployUnit(&u) { u.vehicle = id; u.status = .deploying }
        case .deploying:
            guard let i = vi else { return }
            if vehicles[i].mode == .driving {
                vehicles[i].origin.map { city.buildingSlots[$0.raw]?.drivewayVehicle = nil }
                u.status = u.incident == nil ? .patrolling : .responding
                if u.incident == nil { newPatrolLeg(i) }
            }
        case .patrolling:
            guard let i = vi else { return }
            if arrivedAtKerbGoal(i) {
                if rng.chance(0.25) && kerbSpotFree(i) {
                    startParking(i)
                    u.status = .patrolBreak
                    u.timer = rng.nextDouble(in: 45..<150)
                } else if !newPatrolLeg(i) {
                    // Nowhere reachable to patrol (an edited, disconnected
                    // network): wait at the kerb, or leave and redeploy later.
                    if kerbSpotFree(i) {
                        startParking(i)
                        u.status = .patrolBreak
                        u.timer = 120
                    } else {
                        vehicles[i].mode = .finished
                    }
                }
            }
        case .patrolBreak:
            guard let i = vi else { return }
            if vehicles[i].mode == .parkedAtKerb {
                u.timer -= dt
                if u.timer <= 0 && unparkIfClear(i) { newPatrolLeg(i); u.status = .patrolling }
            }
        case .responding:
            guard let i = vi, let inc = u.incident, inc.raw < police.incidents.count else { return }
            // Dispatched while parked (a patrol break): pull out as soon as
            // there is a gap; no signal pre-emption until it is moving.
            if vehicles[i].mode == .parkedAtKerb {
                _ = unparkIfClear(i)
                return
            }
            updateEmergencyApproach(i)
            if arrivedAtKerbGoal(i) && !kerbSpotFree(i) {
                // Spot taken (driveway, another car): stop a little further on,
                // or go round the block if the street has no room left ahead.
                let d = vehicles[i].destination
                if let s = findKerbSpot(edge: d.edge, near: d.s, length: vehicles[i].length), s > vehicles[i].s + 8 {
                    vehicles[i].destination.s = s
                } else if case .edge(let e) = vehicles[i].track, let edge = network.edge(e) {
                    // Nothing free ahead: round the block to the nearest free spot.
                    vehicles[i].destination.s = findKerbSpot(edge: d.edge, near: d.s, length: vehicles[i].length) ?? kerbRange(d.edge, vehicles[i].length).lowerBound
                    circleBack(i, edge: edge)
                }
            } else if arrivedAtKerbGoal(i) {
                startParking(i)
                vehicles[i].siren = false
                vehicles[i].hazard = true
                releasePreemptions(of: vehicles[i].id)
                police.incidents[inc.raw].status = .onScene
                police.incidents[inc.raw].arrived = time
                let rt = time - police.incidents[inc.raw].created
                police.responseTimes.append(rt)
                if police.responseTimes.count > 100 { police.responseTimes.removeFirst() }
                log(.arrivedOnScene, "unit \(k) at \(police.incidents[inc.raw].building) after \(Int(rt)) s")
                u.status = .onScene
                u.timer = police.incidents[inc.raw].serviceTime
            }
        case .onScene:
            guard let i = vi, let inc = u.incident else { return }
            if vehicles[i].mode == .parkedAtKerb {
                u.timer -= dt
                if u.timer <= 0 && unparkIfClear(i) {
                    if inc.raw < police.incidents.count {
                        police.incidents[inc.raw].status = .cleared
                        police.incidents[inc.raw].cleared = time
                        log(.incidentCleared, "\(inc) cleared")
                    }
                    vehicles[i].hazard = false
                    u.incident = nil
                    u.status = .patrolling
                    newPatrolLeg(i)
                }
            }
        }
    }

    /// Put a unit's car in its station's driveway.
    private func deployUnit(_ u: inout PoliceUnit) -> VehicleID? {
        guard let b = city.building(u.station), let access = b.access, drivewayHolder(b.id) == nil else { return nil }
        guard let id = addVehicle(cls: .police, driver: policeDriver(), edge: access.edge, lane: access.lane, s: access.s,
                                  speed: 0, route: [access.edge],
                                  destination: Destination(kind: .kerb, edge: access.edge, s: max((network.edge(access.edge)?.length ?? 0) - 12, access.s)),
                                  purpose: .patrol, mode: .onDriveway),
              let i = index(of: id) else { return nil }
        vehicles[i].origin = b.id
        startLeaving(i, from: b)
        kerbside.append(i)
        city.buildingSlots[b.id.raw]?.drivewayVehicle = id
        if u.incident == nil { newPatrolLeg(i) }
        return id
    }

    private func policeDriver() -> Driver {
        var d = Driver.sample(for: .police, rng: &rng, meanAggressiveness: 0.3)
        d.speedFactor = 0.92        // patrols cruise slightly below the limit
        d.mobil.politeness = 0.5
        return d
    }

    // MARK: - Routing (with turning round beyond the map edge)

    /// A route for a unit on `e` (at `s`) to `dest`: direct when possible,
    /// otherwise off the map and back in (`via`). `cost` is the estimated time.
    func plannedUnitRoute(from e: EdgeID, s: Double, to dest: Destination, seed: UInt64) -> (route: [EdgeID], via: Bool, cost: Double)? {
        if e == dest.edge && dest.s > s + 10 { return ([e], false, 0) }
        if let r = router.route(from: e, to: dest.edge, firstSteps: e == dest.edge ? network.successors(of: e) : nil, seed: seed) {
            return (r, false, router.cost(of: r[...]))
        }
        guard let out = cheapestRouteToRegion(from: e, seed: seed, thenTo: dest.edge),
              let back = cheapestRouteFromRegion(to: dest.edge, seed: seed) else { return nil }
        return (out, true, router.cost(of: out[...]) + 20 + router.cost(of: back[...]))
    }

    /// Send unit vehicle `i` to `dest` along a planned route.
    func steer(_ i: Int, along plan: (route: [EdgeID], via: Bool, cost: Double), to dest: Destination) {
        setRoute(i, plan.route)
        if plan.via, let exit = plan.route.last {
            vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
            police.reentries[vehicles[i].id.raw] = Reentry(destination: dest, siren: vehicles[i].siren, purpose: vehicles[i].purpose, at: nil)
        } else {
            vehicles[i].destination = dest
            police.reentries[vehicles[i].id.raw] = nil
        }
        // Kerb goals are reached from the kerb lane.
        vehicles[i].destinationLane = dest.kind == .kerb
            ? network.edge(dest.edge)?.lanes.filter({ $0.kind == .travel }).min(by: { $0.index < $1.index })?.index : nil
    }

    // MARK: - Patrol

    /// Pick the next patrol waypoint: a residential street, weighted by homes
    /// and by how long since a unit last drove it.
    @discardableResult
    func newPatrolLeg(_ i: Int) -> Bool {
        guard case .edge(let cur) = vehicles[i].track else { return false }
        var weight: [Int: Double] = [:]
        for b in city.buildings where b.kind.isResidential {
            guard let a = b.access else { continue }
            weight[a.edge.raw, default: 0] += Double(max(b.residents.count, 1))
        }
        if weight.isEmpty {
            for e in network.allEdges where e.roadClass == .local || e.roadClass == .collector { weight[e.id.raw] = 1 }
        }
        // Not the street it is on; not a stub that only leads off the map.
        var keys = weight.keys.sorted().filter { e in
            guard e != cur.raw, let edge = network.edge(EdgeID(e)) else { return false }
            return !(network.node(edge.to)?.isRegionalConnection ?? true)
        }
        if keys.isEmpty { keys = weight.keys.sorted().filter { $0 != cur.raw } }   // only stubs: turn round off-map
        if keys.isEmpty { keys = weight.keys.sorted() }                              // only this street: go round
        guard !keys.isEmpty else { return false }
        let w = keys.map { e -> Double in
            let since = police.lastVisit[e].map { time - $0 } ?? 3600
            let staleness = min(since, 3600) / 600 + 0.2
            return weight[e]! * staleness
        }
        var tries: [EdgeID] = []
        for _ in 0..<3 { if let k = rng.pickWeighted(w) { tries.append(EdgeID(keys[k])) } }
        // Then any street at all (an edited network may leave few reachable).
        tries += keys.prefix(40).map { EdgeID($0) }
        for t in tries {
            guard let target = network.edge(t) else { continue }
            let dest = Destination(kind: .kerb, edge: target.id,
                                   s: (target.length * rng.nextDouble(in: 0.35..<0.7)).clamped(to: kerbRange(target.id, vehicles[i].length)))
            guard let plan = plannedUnitRoute(from: cur, s: vehicles[i].s, to: dest, seed: rng.next()) else { continue }
            vehicles[i].purpose = .patrol
            steer(i, along: plan, to: dest)
            return true
        }
        return false
    }

    /// On the final edge, near the kerb goal, slow enough to stop there.
    func arrivedAtKerbGoal(_ i: Int) -> Bool {
        let v = vehicles[i]
        guard v.mode == .driving, v.isOnFinalEdge, v.destination.kind == .kerb, case .edge(let e) = v.track,
              e == v.destination.edge, v.laneChange == nil,      // pulled over for a siren counts: it parks further over
              let edge = network.edge(e),
              v.lane == edge.lanes.filter({ $0.kind == .travel && $0.exists(at: v.s) }).min(by: { $0.index < $1.index })?.index
        else { return false }
        return v.s >= v.destination.s - 3 && v.s <= v.destination.s + 15 && v.speed < 6
    }

    /// Where a car may stop at the kerb on an edge (front-bumper positions).
    func kerbRange(_ e: EdgeID, _ length: Double) -> ClosedRange<Double> {
        let len = network.edge(e)?.length ?? 0
        let lo = length + 26, hi = len - 25     // room to slow down after the junction
        return lo <= hi ? lo...hi : (len / 2)...(len / 2)
    }

    /// A kerb spot is free: no parked car and no driveway mouth within reach.
    func kerbSpotFree(_ i: Int) -> Bool {
        let v = vehicles[i]
        guard case .edge(let e) = v.track else { return false }
        return kerbSpotFree(edge: e, s: v.s, length: v.length, except: i)
    }

    /// Whether a car of `length` whose front is at `s` may park there: clear of
    /// the junction mouths, other kerbside cars and driveways (it rolls ~8 m
    /// on while easing onto the shoulder).
    func kerbSpotFree(edge e: EdgeID, s: Double, length: Double, except: Int? = nil) -> Bool {
        guard let edge = network.edge(e) else { return false }
        if s - length < 12 || edge.length - s < 25 { return false }
        for j in kerbside where j != except && j < vehicles.count && vehicles[j].track == .edge(e) {
            let w = vehicles[j]
            if (w.mode == .parkedAtKerb || w.mode == .pullingIn || w.mode == .pullingOut || w.mode == .waitingToEnter)
                && w.s > s - length - 6 && w.s - w.length < s + 14 { return false }
        }
        // Clear of every other road's carriageway (near junctions, or where an
        // edit has put another road alongside).
        let lane0 = edge.lanes.first { $0.kind == .travel }
        let kerb = side.kerbSign
        let lat = (lane0?.lateral ?? 0) + kerb * ((lane0?.width ?? 3.5) / 2 + edge.roadClass.shoulderWidth * 0.5 + 0.7)
        // The whole footprint it ends up in (it rolls on up to ~8 m).
        let spots = stride(from: s - length, through: s + 8, by: 2).map { edge.position(s: min(max($0, 0), edge.length), lateral: lat) }
        for other in network.allEdges where other.road != edge.road {
            let b = other.reference.bounds
            let reach = Double(other.lanes.count) * other.laneWidth + 4
            let half = (other.lanes.map { abs($0.lateral) + $0.width / 2 }.max() ?? 3.5) + 1.5
            for spot in spots {
                guard spot.x > b.min.x - reach, spot.x < b.max.x + reach, spot.y > b.min.y - reach, spot.y < b.max.y + reach else { continue }
                if other.reference.project(spot).distance < half { return false }
            }
        }
        // Across an idle driveway is fine; not one in use right now.
        for b in city.buildings {
            if let a = b.access, a.edge == e, a.s > s - length - 5, a.s < s + 13,
               b.drivewayVehicle != nil || !b.departureQueue.isEmpty { return false }
        }
        return true
    }

    /// The free kerb spot nearest to `near` on `e` (front-bumper position).
    func findKerbSpot(edge e: EdgeID, near: Double, length: Double) -> Double? {
        let range = kerbRange(e, length)
        guard range.lowerBound < range.upperBound else { return nil }
        var best: Double?
        var s = range.lowerBound
        while s <= range.upperBound {
            if kerbSpotFree(edge: e, s: s, length: length), best == nil || abs(s - near) < abs(best! - near) { best = s }
            s += 4
        }
        return best
    }

    /// Pull fully onto the shoulder and stop (traffic can pass).
    func startParking(_ i: Int) {
        vehicles[i].mode = .parkedAtKerb
        kerbside.append(i)          // visible to kerb checks for the rest of this step
        vehicles[i].modeTimer = 0
        vehicles[i].laneChange = nil
    }

    /// Kerb parking lateral shift: clear of the lane.
    func parkingShift(_ v: Vehicle) -> Double {
        guard case .edge(let e) = v.track, let edge = network.edge(e), let lane = edge.lane(v.lane) else { return 2.5 }
        return lane.width / 2 + edge.roadClass.shoulderWidth * 0.5 + v.width / 2 - 0.2
    }

    /// Leave the kerb when the lane behind is clear.
    func unparkIfClear(_ i: Int) -> Bool {
        guard vehicles[i].pullOverShift >= parkingShift(vehicles[i]) - 0.05 else { return false }
        guard drivewayGapOK(i) else { return false }
        vehicles[i].mode = .driving
        return true
    }

    // MARK: - Dispatch

    func dispatchIncidents() {
        for k in police.incidents.indices where police.incidents[k].status == .waiting {
            guard let b = city.building(police.incidents[k].building), let access = b.access else {
                police.incidents[k].status = .cleared
                continue
            }
            // Either side of the street will do (the building's own carriageway
            // may only be reachable from beyond the map).
            var goals: [BuildingAccess] = [access]
            if let rev = network.edge(EdgeID(road: access.road, forward: !access.edge.isForward)), rev.id != access.edge {
                var g = access
                g.edge = rev.id
                g.s = rev.length - access.s
                goals.append(g)
            }
            var best: (unit: Int, plan: (route: [EdgeID], via: Bool, cost: Double), dest: Destination)?
            for goal in goals {
                let len = VehicleClass.police.length
                let dest = Destination(kind: .kerb, edge: goal.edge,
                                       s: findKerbSpot(edge: goal.edge, near: goal.s - 8, length: len) ?? (goal.s - 8).clamped(to: kerbRange(goal.edge, len)))
                for (u, unit) in police.units.enumerated() {
                    var from: (EdgeID, Double)?
                    var penalty = 0.0
                    switch unit.status {
                    case .inStation:
                        if let sa = city.building(unit.station)?.access { from = (sa.edge, sa.s); penalty = 30 }
                    case .patrolling, .patrolBreak:
                        if let vid = unit.vehicle, let i = index(of: vid), case .edge(let e) = vehicles[i].track {
                            from = (e, vehicles[i].s)
                            penalty = unit.status == .patrolBreak ? 10 : 0
                        }
                    default:
                        break
                    }
                    guard let (e, s0) = from, let plan = plannedUnitRoute(from: e, s: s0, to: dest, seed: UInt64(u)) else { continue }
                    if best == nil || plan.cost + penalty < best!.plan.cost { best = (u, (plan.route, plan.via, plan.cost + penalty), dest) }
                }
            }
            guard let pick = best else { continue }
            var unit = police.units[pick.unit]
            police.incidents[k].status = .assigned
            police.incidents[k].dispatched = time
            police.incidents[k].unit = pick.unit
            unit.incident = police.incidents[k].id
            switch unit.status {
            case .inStation:
                unit.deployAt = time
                if let id = deployUnit(&unit), let i = index(of: id) {
                    unit.vehicle = id
                    unit.status = .deploying
                    vehicles[i].siren = true
                    vehicles[i].purpose = .emergency
                    steer(i, along: pick.plan, to: pick.dest)
                }
            default:
                guard let vid = unit.vehicle, let i = index(of: vid) else { continue }
                vehicles[i].siren = true
                vehicles[i].hazard = false
                vehicles[i].purpose = .emergency
                steer(i, along: pick.plan, to: pick.dest)
                unit.status = .responding
                if vehicles[i].mode == .parkedAtKerb { _ = unparkIfClear(i) }
            }
            police.units[pick.unit] = unit
            log(.dispatch, "unit \(pick.unit) → \(police.incidents[k].id) at \(police.incidents[k].building) (est. \(Int(pick.plan.cost)) s\(pick.plan.via ? ", via the map edge" : ""))")
        }
    }


}

extension Vehicle {
    /// While changing lanes a vehicle is not shifted for an emergency.
    mutating func vehicleShiftReset() {
        pullOverShift = 0
        yieldingToEmergency = false
    }
}
