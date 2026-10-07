//
//  CityState.swift
//  TrafficEngine
//
//  The demand engine: buildings, residents, the departure event queue and the
//  physical life cycle of a trip:
//
//   departure event → person joins the building's driveway queue → the first
//   in line becomes a parked car in the driveway (`waitingToEnter`) → it
//   pulls out when the kerb lane has a safe gap (`pullingOut`) → drives →
//   turns into the destination driveway (`pullingIn`) → parks (removed) →
//   the person's next activity is scheduled.
//

public enum CityMode: String, Codable, Sendable { case sandbox, growth }

public struct CityState: Codable, Sendable {
    public var mode: CityMode = .sandbox
    public var external = ExternalTrafficState()
    public internal(set) var buildingSlots: [Building?] = []
    public internal(set) var people: [Person] = []
    var events: [DemandEvent] = []          // binary min-heap on (time, seq)
    var eventSeq = 0
    var shopIDs: [BuildingID] = []
    var employerIDs: [BuildingID] = []
    /// Regional connections (node, position) and people waiting to drive in from them.
    var regionNodes: [NodeID] = []
    var regionPositions: [Vector2] = []
    var regions: [(NodeID, Vector2)] { Array(zip(regionNodes, regionPositions)) }
    var regionQueue: [PersonID] = []
    /// Share of workers whose job is beyond the map (from local job supply).
    var regionalShare: Double = 0.4
    public var growth = GrowthState()
    /// Minutes (clock) over which a newly placed building fills up.
    public var fillInMinutes: Double = 45

    public init() {}

    public var buildings: [Building] { buildingSlots.compactMap { $0 } }
    /// Bumped whenever a building is placed or removed (renderer cache key).
    public internal(set) var version = 0
    public var population: Int { people.reduce(0) { $0 + ($1.movedIn && $1.role != .trucker ? 1 : 0) } }

    // MARK: Event heap

    mutating func schedule(_ person: PersonID, at time: Double) {
        eventSeq += 1
        events.append(DemandEvent(time: time, seq: eventSeq, person: person))
        var c = events.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if less(events[c], events[p]) { events.swapAt(c, p); c = p } else { break }
        }
    }

    private func less(_ a: DemandEvent, _ b: DemandEvent) -> Bool {
        a.time != b.time ? a.time < b.time : a.seq < b.seq
    }

    mutating func popDue(before t: Double) -> DemandEvent? {
        guard let top = events.first, top.time <= t else { return nil }
        let last = events.removeLast()
        if !events.isEmpty {
            events[0] = last
            var p = 0
            while true {
                let l = 2 * p + 1, r = l + 1
                var m = p
                if l < events.count && less(events[l], events[m]) { m = l }
                if r < events.count && less(events[r], events[m]) { m = r }
                if m == p { break }
                events.swapAt(p, m); p = m
            }
        }
        return top
    }

    var pendingEvents: Int { events.count }

    mutating func refreshIndexes() {
        shopIDs = buildings.filter { $0.kind.shopAttraction > 0 && $0.access != nil }.map { $0.id }
        employerIDs = buildings.filter { $0.jobs > 0 && $0.access != nil }.map { $0.id }
        let jobs = Double(buildings.reduce(0) { $0 + $1.jobs })
        let residents = Double(buildings.reduce(0) { $0 + $1.capacity })
        regionalShare = regions.isEmpty ? 0 : (0.15 + 0.7 * max(0, 1 - jobs / max(residents * 0.62, 1))).clamped(to: 0.15...0.85)
    }

    mutating func networkDidChange(_ sim: Simulation) {
        let rn = sim.network.allNodes.filter { $0.isRegionalConnection }
        regionNodes = rn.map { $0.id }
        regionPositions = rn.map { $0.position }
        // Re-anchor driveways to the (possibly rebuilt) roads.
        for k in buildingSlots.indices {
            guard var b = buildingSlots[k] else { continue }
            if let a = sim.accessPoint(for: b.center)?.0 { b.access = a } else { b.access = nil }
            buildingSlots[k] = b
        }
        refreshIndexes()
    }
}

public struct GrowthState: Codable, Sendable, Equatable {
    public var lastGrowthDay = -1
    public var housesPerDay = 6
    public var businessesPerDay = 2
}

// MARK: - Simulation API

extension Simulation {

    /// Place a building. Residents and jobs fill in over the next clock hour.
    @discardableResult
    public func placeBuilding(_ kind: BuildingKind, at p: Vector2, fillImmediately: Bool = false) -> Result<BuildingID, PlacementError> {
        defer { city.version += 1 }
        switch validatePlacement(kind: kind, at: p) {
        case .failure(let e): return .failure(e)
        case .success(let (access, rotation)):
            let id = BuildingID(city.buildingSlots.count)
            var b = Building(id: id, kind: kind, center: p, rotation: rotation,
                             capacity: kind.residents.isEmpty ? 0 : kind.residents.lowerBound + rng.nextInt(kind.residents.count),
                             placedAt: time)
            b.access = access
            city.buildingSlots.append(b)
            city.refreshIndexes()
            populate(id, immediately: fillImmediately)
            if kind == .policeStation { registerPoliceStation(id) }
            return .success(id)
        }
    }

    public func removeBuilding(_ id: BuildingID) {
        defer { city.version += 1 }
        guard let b = city.building(id) else { return }
        // Residents leave; workers lose this job; vehicles heading here go home.
        for pid in b.residents where pid.raw < city.people.count { city.people[pid.raw].movedIn = false; city.people[pid.raw].plan = [] }
        for k in city.people.indices where city.people[k].work == id { city.people[k].work = nil; city.people[k].role = .nonWorker }
        if let v = b.drivewayVehicle, let i = index(of: v) { vehicles[i].mode = .finished }
        city.buildingSlots[id.raw] = nil
        city.refreshIndexes()
        if b.kind == .policeStation { removePoliceStation(id) }
        // Vehicles heading here: home if they have one, otherwise off the map;
        // with no way to either, they simply go.
        for i in vehicles.indices where vehicles[i].destination.building == id && vehicles[i].mode != .finished {
            let seed = UInt64(vehicles[i].id.raw)
            guard case .edge(let e) = vehicles[i].track, vehicles[i].mode == .driving else {
                if vehicles[i].mode == .pullingIn || vehicles[i].mode == .waitingToEnter || vehicles[i].mode == .onDriveway { vehicles[i].mode = .finished }
                else { vehicles[i].destination.building = nil; vehicles[i].destination.kind = .exitMap }
                continue
            }
            if let pid = vehicles[i].person, pid.raw < city.people.count, city.people[pid.raw].home != id,
               let home = city.building(city.people[pid.raw].home), let acc = home.access,
               let r = router.route(from: e, to: acc.edge, seed: seed) {
                vehicles[i].destination = Destination(kind: .building, edge: acc.edge, s: acc.s, building: home.id)
                vehicles[i].destinationLane = acc.lane
                setRoute(i, r)
            } else if let r = cheapestRouteToRegion(from: e, seed: seed), let exit = r.last {
                vehicles[i].destination = Destination(kind: .exitMap, edge: exit, s: network.edge(exit)?.length ?? 0)
                vehicles[i].destinationLane = nil
                setRoute(i, r)
            } else {
                vehicles[i].mode = .finished
                continue
            }
        }
        releaseOccupantsOfFinishedVehicles()
    }

    /// People in vehicles that were removed (not arrived) are back home.
    func releaseOccupantsOfFinishedVehicles() {
        var gone: [Int: VehicleID] = [:]
        for v in vehicles where v.mode == .finished { if let p = v.person { gone[p.raw] = v.id } }
        for (k, vid) in gone where k < city.people.count && city.people[k].vehicle == vid {
            city.people[k].vehicle = nil
            city.people[k].inRegion = nil
            city.people[k].at = city.building(city.people[k].home) != nil ? city.people[k].home : nil
            city.people[k].plan = []
        }
    }

    /// Create residents (and their cars), or a factory's truck fleet.
    func populate(_ id: BuildingID, immediately: Bool) {
        guard let b = city.building(id) else { return }
        var r = rng.derived(UInt64(id.raw) &* 7919)
        var newPeople: [PersonID] = []
        let fill = city.fillInMinutes * 60
        func addPerson(role: PersonRole, car: VehicleClass) {
            let pid = PersonID(city.people.count)
            var p = Person(id: pid, home: id, work: nil, role: role, car: car, schoolRun: false, at: id)
            p.movedIn = immediately
            city.people.append(p)
            newPeople.append(pid)
            // Moving in happens progressively over the fill-in period.
            city.schedule(pid, at: immediately ? clock + r.nextDouble(in: 0..<60) : clock + r.nextDouble(in: 60..<max(fill, 61)))
        }
        if b.kind.isResidential {
            for _ in 0..<b.capacity {
                let u = r.nextUnit()
                let role: PersonRole = u < 0.62 ? .worker : .nonWorker
                let carRoll = r.nextUnit()
                let car: VehicleClass = carRoll < 0.58 ? .car : (carRoll < 0.9 ? .suv : .van)
                addPerson(role: role, car: car)
            }
        }
        for _ in 0..<b.kind.trucks { addPerson(role: .trucker, car: .truck) }
        city.buildingSlots[id.raw]?.residents += newPeople
    }

    // MARK: - Stage

    func updateCityDemand(dt: Double) {
        let now = clock
        var budget = 200
        while budget > 0, let ev = city.popDue(before: now) {
            budget -= 1
            handleEvent(ev)
        }
        updateDriveways()
        if !city.regionQueue.isEmpty { updateRegionalArrivals() }
        updatePullManoeuvres(dt: dt)
        if city.mode == .growth { updateGrowth() }
    }

    func handleEvent(_ ev: DemandEvent) {
        let k = ev.person.raw
        guard k < city.people.count else { return }
        var p = city.people[k]
        guard city.building(p.home) != nil else { return }
        if !p.movedIn || p.planDay < 0 && p.role == .worker && p.work == nil && p.regionalWork == nil {
            p.movedIn = true
            if p.role == .worker && p.work == nil && p.regionalWork == nil {
                if rng.chance(city.regionalShare), let region = city.pickRegion(near: p.home, rng: &rng) {
                    p.regionalWork = region
                } else {
                    p.work = city.assignWork(for: p.home, rng: &rng)
                }
            }
            if p.role == .worker && p.work == nil && p.regionalWork == nil { p.role = .nonWorker }
            p.schoolRun = p.role == .worker && rng.chance(0.2)
            city.people[k] = p
        }
        guard p.vehicle == nil, p.at != nil || p.inRegion != nil else { return }
        // A new day: plan it.
        let day = Int(clock / 86400)
        if p.planDay != day {
            let atHome = p.at == p.home && p.inRegion == nil
            if !atHome && !p.plan.isEmpty {
                // Still out after midnight: finish yesterday's plan first.
                p.planDay = day
            } else {
                var r = rng.derived(UInt64(k) &* 104729 &+ UInt64(day))
                // Only a sample of residents drive each day (see `dailyDriverShare`).
                let share = min(1, config.dailyDriverShare * config.demandMultiplier)
                p.plan = !atHome || r.chance(share)
                    ? Schedules.plan(for: p, day: day, weekend: (day % 7) >= 5, city: city, rng: &r) : []
                p.planDay = day
                // Only the parts of the plan still ahead.
                if let first = p.plan.first, first.depart > 0, first.depart < clock - 1800 { p.plan.removeAll() }
                // Anyone away from home goes home first.
                if !atHome { p.plan.insert(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0), at: 0) }
            }
            city.people[k] = p
        }
        guard let trip = p.plan.first else {
            // Nothing more today: wake up tomorrow at 03:00.
            city.schedule(p.id, at: Double(day + 1) * 86400 + 3 * 3600 + rng.nextDouble(in: 0..<600))
            return
        }
        if trip.depart > clock + 1 {
            city.schedule(p.id, at: trip.depart)
            return
        }
        if (trip.toRegion == nil && (trip.to == p.at || city.building(trip.to)?.access == nil)) ||
           (trip.toRegion != nil && p.inRegion != nil) {
            p.plan.removeFirst()
            city.people[k] = p
            city.schedule(p.id, at: clock + 1)
            return
        }
        // Depart: join the driveway queue, or (from beyond the map) the regional entry queue.
        if let at = p.at {
            city.buildingSlots[at.raw]?.departureQueue.append(p.id)
        } else {
            city.regionQueue.append(p.id)
        }
    }

    /// The first person in each driveway queue becomes a parked car, ready to pull out.
    func updateDriveways() {
        var spawnedHere: [(EdgeID, Double)] = []
        for k in city.buildingSlots.indices {
            // Cheap checks first, without copying the building.
            if city.buildingSlots[k]?.departureQueue.isEmpty ?? true { continue }
            if city.buildingSlots[k]?.drivewayVehicle != nil, drivewayHolder(BuildingID(k)) != nil { continue }
            guard let b = city.buildingSlots[k], b.drivewayVehicle == nil, let pid = b.departureQueue.first,
                  let access = b.access else { continue }
            // Neighbouring driveways (a second row of houses shares the frontage):
            // one car at a time in the same few metres of kerb.
            let busyNearby = kerbside.contains { j in
                j < vehicles.count && vehicles[j].track == .edge(access.edge) && abs(vehicles[j].s - access.s) < 7
            } || spawnedHere.contains { $0.0 == access.edge && abs($0.1 - access.s) < 7 }
            if busyNearby { continue }
            city.buildingSlots[k]?.departureQueue.removeFirst()
            guard pid.raw < city.people.count, let trip = city.people[pid.raw].plan.first,
                  let (route, destination, destLane, viaRegion) = planTrip(from: access, trip: trip, seed: UInt64(pid.raw) &* 31 &+ UInt64(dayIndex)) else {
                if pid.raw < city.people.count, let t = city.people[pid.raw].plan.first {
                    log(.tripUnroutable, "\(pid) can't drive from \(b.id) (\(access.edge)) to \(t.toRegion.map { "\($0)" } ?? "\(t.to) (\(city.building(t.to)?.access.map { "\($0.edge) s=\(Int($0.s))" } ?? "no access"))")")
                    city.people[pid.raw].plan.removeFirst()
                }
                city.schedule(pid, at: clock + 300)
                continue
            }
            let p = city.people[pid.raw]
            guard let id = addVehicle(cls: p.car, edge: access.edge, lane: access.lane, s: access.s, speed: 0,
                                      route: route, destination: destination, purpose: trip.purpose, mode: .onDriveway) else { continue }
            if let i = index(of: id) {
                // At the front of the building, about to drive down the driveway.
                vehicles[i].person = pid
                vehicles[i].origin = b.id
                vehicles[i].destinationLane = destLane
                vehicles[i].viaRegion = viaRegion
                startLeaving(i, from: b)
                kerbside.append(i)
            }
            city.people[pid.raw].vehicle = id
            city.people[pid.raw].at = nil
            city.buildingSlots[k]?.drivewayVehicle = id
            spawnedHere.append((access.edge, access.s))
            metrics.recordDeparture(time: time, clockHourOfWeek: clockHourOfWeek)
        }
    }

    /// Route and destination for a planned trip from a driveway. `viaRegion`:
    /// the destination can only be reached by leaving the map and coming
    /// back in (e.g. a driveway on a road stub that runs off the map edge).
    func planTrip(from access: BuildingAccess, trip: PlannedTrip, seed: UInt64)
        -> (route: [EdgeID], destination: Destination, lane: Int?, viaRegion: Bool)? {
        if let region = trip.toRegion {
            // Beyond the map every connection leads everywhere: use the
            // intended one if it can be reached, else the cheapest that can.
            let preferred = network.incoming(region).first.flatMap { router.route(from: access.edge, to: $0, seed: seed) }
            guard let route = preferred ?? cheapestRouteToRegion(from: access.edge, seed: seed),
                  let exit = route.last, let e = network.edge(exit) else { return nil }
            return (route, Destination(kind: .exitMap, edge: exit, s: e.length), nil, false)
        }
        guard let dest = city.building(trip.to), let destAccess = dest.access else { return nil }
        if let route = tripRoute(from: access, to: destAccess, seed: seed) {
            return (route, Destination(kind: .building, edge: destAccess.edge, s: destAccess.s, building: dest.id), destAccess.lane, false)
        }
        // Turn round beyond the map edge.
        guard let route = cheapestRouteToRegion(from: access.edge, seed: seed, thenTo: destAccess.edge),
              let exit = route.last, let e = network.edge(exit) else { return nil }
        return (route, Destination(kind: .exitMap, edge: exit, s: e.length), nil, true)
    }

    /// The cheapest route from `edge` off the map. With `thenTo`, only if
    /// `thenTo` can be reached again by driving back in at some connection
    /// (beyond the map edge every connection leads to every other).
    func cheapestRouteToRegion(from edge: EdgeID, seed: UInt64, thenTo: EdgeID? = nil) -> [EdgeID]? {
        if let goal = thenTo, cheapestRouteFromRegion(to: goal, seed: seed) == nil { return nil }
        var best: (route: [EdgeID], cost: Double)?
        for node in city.regionNodes {
            guard let exit = network.incoming(node).first, let r = router.route(from: edge, to: exit, seed: seed) else { continue }
            let c = router.cost(of: r[...])
            if best == nil || c < best!.cost { best = (r, c) }
        }
        return best?.route
    }

    /// The cheapest way into the map to reach `goal`, from any connection.
    func cheapestRouteFromRegion(to goal: EdgeID, seed: UInt64) -> [EdgeID]? {
        var best: (route: [EdgeID], cost: Double)?
        for node in city.regionNodes {
            guard let entry = network.outgoing(node).first, let r = router.route(from: entry, to: goal, seed: seed) else { continue }
            let c = router.cost(of: r[...])
            if best == nil || c < best!.cost { best = (r, c) }
        }
        return best?.route
    }

    /// People returning from beyond the map drive in at their regional connection.
    func updateRegionalArrivals() {
        var remaining: [PersonID] = []
        for pid in city.regionQueue {
            guard pid.raw < city.people.count else { continue }
            let p = city.people[pid.raw]
            let seed = UInt64(pid.raw) &+ UInt64(dayIndex)
            guard let region = p.inRegion, let trip = p.plan.first,
                  let dest = city.building(trip.to), let destAccess = dest.access,
                  let route = network.outgoing(region).first.flatMap({ router.route(from: $0, to: destAccess.edge, seed: seed) })
                    ?? cheapestRouteFromRegion(to: destAccess.edge, seed: seed),
                  let entry = route.first else {
                if pid.raw < city.people.count && city.people[pid.raw].inRegion != nil {
                    // Can't get back right now (edited network?): try again later.
                    city.schedule(pid, at: clock + 600)
                }
                continue
            }
            let destination = Destination(kind: .building, edge: destAccess.edge, s: destAccess.s, building: dest.id)
            if let id = spawnEntering(entry: entry, cls: p.car, route: route, destination: destination, purpose: trip.purpose) {
                if let i = index(of: id) { vehicles[i].person = pid; vehicles[i].destinationLane = destAccess.lane }
                city.people[pid.raw].vehicle = id
                city.people[pid.raw].inRegion = nil
                metrics.recordDeparture(time: time, clockHourOfWeek: clockHourOfWeek)
            } else {
                remaining.append(pid)
            }
        }
        city.regionQueue = remaining
    }

    /// Route between two driveways (handles a destination behind on the same edge).
    func tripRoute(from a: BuildingAccess, to b: BuildingAccess, seed: UInt64) -> [EdgeID]? {
        if a.edge == b.edge && b.s > a.s + 15 { return [a.edge] }
        if a.edge == b.edge {
            var best: [EdgeID]?
            for next in network.successors(of: a.edge) {
                if let r = router.route(from: next, to: b.edge, seed: seed), best == nil || r.count < best!.count { best = [a.edge] + r }
            }
            return best
        }
        return router.route(from: a.edge, to: b.edge, seed: seed)
    }

    /// Pull out of the driveway when the kerb lane has a safe gap; pull in at the destination.
    func updatePullManoeuvres(dt: Double) {
        for i in vehicles.indices {
            switch vehicles[i].mode {
            case .waitingToEnter:
                vehicles[i].modeTimer += dt
                if drivewayGapOK(i) { vehicles[i].mode = .pullingOut; vehicles[i].modeTimer = 0 }
            case .onDriveway:
                let stopped = rollAlongDriveway(i, dt: dt)
                guard stopped, let run = vehicles[i].driveway else { continue }
                if run.inbound {
                    // Up at the building: parked.
                    if let b = vehicles[i].destination.building, city.buildingSlots[b.raw]?.drivewayVehicle == vehicles[i].id {
                        city.buildingSlots[b.raw]?.drivewayVehicle = nil
                    }
                    finishTrip(i)
                } else {
                    // At the mouth: wait for a gap in the kerb lane.
                    vehicles[i].modeTimer += dt
                    if drivewayGapOK(i) { joinKerbFromDriveway(i) }
                }
            case .pullingOut:
                guard case .edge(let e) = vehicles[i].track, let lane = network.edge(e)?.lane(vehicles[i].lane) else { continue }
                // Sideways only as the car rolls forward (it steers, it doesn't slide).
                let rate = max(0.45 * vehicles[i].speed, 0.6 * min(vehicles[i].speed, 1)) * dt
                let d = lane.lateral - vehicles[i].lateral
                vehicles[i].lateral += d.clamped(to: -rate...rate)
                vehicles[i].lateralSpeed = d.clamped(to: -rate...rate) / dt
                if abs(lane.lateral - vehicles[i].lateral) < 0.02 {
                    vehicles[i].lateral = lane.lateral
                    vehicles[i].lateralSpeed = 0
                    vehicles[i].mode = .driving
                    if let o = vehicles[i].origin { city.buildingSlots[o.raw]?.drivewayVehicle = nil }
                }
            case .driving:
                let v = vehicles[i]
                guard v.isOnFinalEdge, v.destination.kind == .building, case .edge(let e) = v.track, e == v.destination.edge,
                      v.laneChange == nil, v.lane == (v.destinationLane ?? v.lane),
                      v.s >= v.destination.s - 10, v.s <= v.destination.s + 6, v.speed < 7 else { continue }
                // Wait for a car pulling out of / into a driveway right here.
                if drivewayBusy(i) || drivewayBlockedByParkedCar(i) { continue }
                // Turn off along the driveway (the building's own, when it has one free).
                // Turn off along the driveway a few metres short of it, curving
                // up to the building; too late for that, the old way (a short
                // sidestep onto the verge).
                if v.s <= v.destination.s - 1.5 {
                    guard let b = v.destination.building.flatMap({ city.building($0) }), b.access != nil,
                          v.speed <= 5.5, drivewayHolder(b.id) == nil, arrivalPath(i, at: b) != nil else { continue }
                    startArriving(i, at: b)
                    continue
                }
                if v.s < v.destination.s - 5 { continue }
                vehicles[i].mode = .pullingIn
                kerbside.append(i)
                vehicles[i].modeTimer = 0
            case .pullingIn:
                guard let b = vehicles[i].destination.building, let access = city.building(b)?.access else {
                    finishTrip(i); continue
                }
                vehicles[i].modeTimer += dt
                let rate = max(0.45 * vehicles[i].speed, 0.6) * dt
                let d = access.drivewayLateral - vehicles[i].lateral
                vehicles[i].lateral += d.clamped(to: -rate...rate)
                vehicles[i].lateralSpeed = d.clamped(to: -rate...rate) / dt
                if abs(d) < 0.05 || vehicles[i].modeTimer > 12 { finishTrip(i) }
            default:
                break
            }
        }
    }

    /// Another car is turning out of or into a driveway close to this
    /// vehicle's destination driveway.
    func drivewayBusy(_ i: Int) -> Bool {
        let v = vehicles[i]
        return kerbside.contains { j in
            j != i && j < vehicles.count && vehicles[j].track == v.track && abs(vehicles[j].s - v.destination.s) < 14
                && (vehicles[j].mode == .pullingOut || vehicles[j].mode == .pullingIn
                    // On a driveway: one turning in, one leaving the very
                    // driveway we want, or one still coming down the driveway
                    // next door (once it waits at its mouth, it waits for us).
                    || (vehicles[j].mode == .onDriveway
                        && (vehicles[j].driveway?.inbound == true || vehicles[j].origin == v.destination.building
                            || vehicles[j].driveway.map { $0.path.length - $0.s > 0.05 } == true)))
        }
    }

    /// A car parked across this vehicle's destination driveway (it will drive
    /// on and come round again rather than wait in the lane).
    func drivewayBlockedByParkedCar(_ i: Int) -> Bool {
        let v = vehicles[i]
        return kerbside.contains { j in
            j != i && j < vehicles.count && vehicles[j].mode == .parkedAtKerb && vehicles[j].track == v.track
                // The pull-in sweeps the body across the shoulder from about a
                // car length before the mouth.
                && vehicles[j].s > v.destination.s - v.length - 6 && vehicles[j].s - vehicles[j].length < v.destination.s + 9
        }
    }

    /// Safe to pull out: approaching traffic in the kerb lane is far enough
    /// away (time gap) and nobody is alongside or just ahead.
    func drivewayGapOK(_ i: Int) -> Bool {
        let v = vehicles[i]
        guard case .edge(let e) = v.track, let edge = network.edge(e) else { return false }
        for l in edge.lanes where abs(l.lateral - (edge.lane(v.lane)?.lateral ?? 0)) < 0.1 || l.index == v.lane {
            for o in laneOcc[laneKey(e, l.index)] {
                let w = vehicles[Int(o.index)]
                // A car stopped behind, waiting to turn into this driveway, waits for us.
                if w.mode == .driving, w.speed < 0.5, w.isOnFinalEdge, w.destination.kind == .building,
                   w.destination.edge == e, abs(w.destination.s - v.s) < 14, o.s < v.s - v.length - 1 { continue }
                let ahead = o.s - w.length - v.s           // gap to a vehicle ahead
                let behind = v.s - v.length - o.s          // gap from a vehicle behind
                if ahead > -v.length - 1 && ahead < 8 { return false }
                // A stationary queue behind lets a car out in front of it.
                if behind > -2 && behind < (w.speed < 0.5 ? 2.5 : 10 + w.speed * 5) { return false }
                if o.s > v.s - v.length - 2 && o.s - w.length < v.s + 2 { return false }
            }
        }
        // Traffic still coming through the junction behind: on the connectors
        // into this lane, and near the end of the lanes feeding them.
        for c in network.connectors(into: e) {
            guard let conn = network.connector(c), conn.to.index == v.lane else { continue }
            for o in connOcc[c.raw] {
                let w = vehicles[Int(o.index)]
                let behind = conn.length - o.s + v.s - v.length
                if behind < 10 + w.speed * 5 { return false }
            }
            if let feed = network.edge(conn.fromEdge) {
                // Near the start of the edge, yield to junction traffic waiting
                // to enter this lane (it needs the same space).
                if v.s < 30 + v.length, let front = laneOcc[laneKey(conn.fromEdge, conn.from.index)].last {
                    let w = vehicles[Int(front.index)]
                    if w.plannedConnector == c && feed.length - front.s < 6 && w.speed < 1 { return false }
                }
                for o in laneOcc[laneKey(conn.fromEdge, conn.from.index)].reversed() {
                    let w = vehicles[Int(o.index)]
                    let behind = feed.length - o.s + conn.length + v.s - v.length
                    if behind > 120 { break }
                    if w.plannedConnector == c || w.plannedConnector == nil, behind < 10 + w.speed * 5 { return false }
                }
            }
        }
        // Cars parked at the kerb across the swept path (a pull-out runs
        // ~15 m forward while crossing the shoulder).
        for j in kerbside where j != i && j < vehicles.count && vehicles[j].mode == .parkedAtKerb && vehicles[j].track == v.track {
            if vehicles[j].s > v.s - v.length - 3 && vehicles[j].s - vehicles[j].length < v.s + 18 { return false }
        }
        // Other cars pulling out of or into driveways next door.
        for j in kerbside where j != i && j < vehicles.count && (vehicles[j].mode == .pullingOut || vehicles[j].mode == .pullingIn
                                                                 || (vehicles[j].mode == .onDriveway && vehicles[j].driveway?.inbound == true)) {
            if case .edge(let ej) = vehicles[j].track, ej == e, abs(vehicles[j].s - v.s) < 14 { return false }
        }
        return true
    }

    /// A trip ended at a building: the person is there and plans their next move.
    func personArrived(_ v: Vehicle) {
        guard let pid = v.person, pid.raw < city.people.count else { return }
        var p = city.people[pid.raw]
        p.vehicle = nil
        if v.destination.kind == .exitMap, let node = network.edge(v.destination.edge)?.to {
            p.at = nil
            p.inRegion = node
            if v.viaRegion {
                // Turning round beyond the map: the trip continues after a
                // couple of minutes (physical time) off-screen.
                city.people[pid.raw] = p
                city.schedule(pid, at: clock + 90 * config.clockScale)
                return
            }
        } else {
            p.at = v.destination.building ?? p.home
            if city.building(p.at!) == nil { p.at = p.home }
        }
        var dwell = 60.0
        if let first = p.plan.first {
            dwell = first.dwell
            p.plan.removeFirst()
        }
        city.people[pid.raw] = p
        if let next = p.plan.first, next.depart > clock {
            city.schedule(pid, at: next.depart)
        } else {
            city.schedule(pid, at: clock + max(dwell, 30))
        }
        if let b = v.destination.building { city.buildingSlots[b.raw]?.parked += 1 }
    }
}
