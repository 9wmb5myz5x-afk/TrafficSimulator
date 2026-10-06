//
//  ExternalTraffic.swift
//  TrafficEngine
//
//  Regional connections at the map edge inject and absorb through traffic.
//  Vehicles enter from beyond the map boundary at the speed of the stream
//  (never appearing on top of anyone: the entry needs a safe gap), and leave
//  by driving off the map at another connection.
//

public struct ExternalTrafficState: Codable, Sendable, Equatable {
    /// Fractional spawn accumulators per regional entry edge.
    var accumulators: [Int: Double] = [:]
    /// Explicit rate override [veh/h per entry] (tests / CLI). nil = population-driven.
    public var fixedRatePerEntry: Double?
    public var spawnedTotal = 0
    public init() {}
}

extension Simulation {

    func updateDemand(dt: Double) {
        updateExternalTraffic(dt: dt)
        updateCityDemand(dt: dt)
    }

    func tripDidFinish(_ v: Vehicle) {
        metrics.recordCompletion(clockHourOfWeek: clockHourOfWeek)
        personArrived(v)
    }

    /// Entry edges (leaving a regional connection into the map) and exit edges.
    func regionalEntries() -> (entries: [EdgeID], exits: [EdgeID]) {
        var entries: [EdgeID] = [], exits: [EdgeID] = []
        for n in network.allNodes where n.isRegionalConnection {
            entries += network.outgoing(n.id)
            exits += network.incoming(n.id)
        }
        return (entries.sorted(), exits.sorted())
    }

    /// Hourly through-traffic rate per entry at the current time of day.
    func externalRatePerEntry() -> Double {
        if let fixed = city.external.fixedRatePerEntry { return fixed }
        // The city-wide through-traffic total scales with population and is
        // shared between the regional entries.
        let residents = Double(currentPopulation())
        let entries = Double(max(regionalEntries().entries.count, 1))
        let base = residents / 1000 * config.externalTripsPerThousand / entries
        return base * DemandProfile.externalFactor(hour: clockHour, weekend: isWeekend) * config.demandMultiplier
    }

    func updateExternalTraffic(dt: Double) {
        let (entries, exits) = regionalEntries()
        guard !entries.isEmpty, !exits.isEmpty else { return }
        // Flow rates are physical: vehicles per hour of simulated time, as an
        // observer at the roadside would count them (independent of clockScale).
        let perSecond = externalRatePerEntry() / 3600
        for e in entries {
            // A random initial phase spreads the first arrivals (a fresh map
            // has traffic arriving at once, not after a whole interval).
            var acc = city.external.accumulators[e.raw] ?? rng.nextUnit()
            acc += perSecond * dt
            if acc >= 1 {
                if vehicles.count < config.maxVehicles, spawnExternal(entry: e, exits: exits) {
                    acc -= 1
                } else {
                    acc = min(acc, 3)   // keep demand waiting at the boundary, bounded
                }
            }
            city.external.accumulators[e.raw] = acc
        }
    }

    /// Spawn one through vehicle entering on `entry` if there is a safe gap.
    @discardableResult
    func spawnExternal(entry: EdgeID, exits: [EdgeID]) -> Bool {
        guard let edge = network.edge(entry) else { return false }
        let fromNode = edge.from
        let candidates = exits.filter { network.edge($0)?.to != fromNode }
        guard !candidates.isEmpty else { return false }
        // Prefer far-away exits (through traffic), weighted by distance.
        let weights = candidates.map { c -> Double in
            let d = (network.edge(c)?.reference.end ?? .zero).distance(to: edge.reference.start)
            return d * d
        }
        guard let pick = rng.pickWeighted(weights) else { return false }
        let exit = candidates[pick]
        let cls: VehicleClass = {
            let r = rng.nextUnit()
            if r < 0.07 { return .truck }
            if r < 0.12 { return .van }
            if r < 0.40 { return .suv }
            return .car
        }()
        guard let route = router.route(from: entry, to: exit, seed: rng.next()) else { return false }
        let id = spawnEntering(entry: entry, cls: cls, route: route,
                               destination: Destination(kind: .exitMap, edge: exit, s: network.edge(exit)!.length),
                               purpose: .through)
        if id != nil {
            city.external.spawnedTotal += 1
            metrics.recordDeparture(time: time, clockHourOfWeek: clockHourOfWeek)
        }
        return id != nil
    }

    /// A vehicle arriving from beyond the map boundary on `entry`, at a speed
    /// the gap ahead supports — only if there is a safe gap.
    func spawnEntering(entry: EdgeID, cls: VehicleClass, route: [EdgeID], destination: Destination,
                       purpose: TripPurpose) -> VehicleID? {
        ensureIndex()
        guard let edge = network.edge(entry), vehicles.count < config.maxVehicles else { return nil }
        let travel = edge.lanes.filter { $0.kind == .travel && $0.sStart <= 0 }
        var best: (lane: Lane, gap: Double, speed: Double)?
        for l in travel {
            // Not in front of traffic arriving through a junction into this lane.
            let feeding = network.connectors(into: entry).contains { cid in
                guard let c = network.connector(cid), c.to.index == l.index else { return false }
                return !connOcc[cid.raw].isEmpty || !connCommits[cid.raw].isEmpty
            }
            if feeding { continue }
            let list = laneOcc[laneKey(entry, l.index)]
            var gap = edge.length
            var leaderSpeed = edge.speedLimit
            if let first = list.first {
                let j = Int(first.index)
                gap = first.s - vehicles[j].length
                leaderSpeed = vehicles[j].speed
            }
            if best == nil || gap > best!.gap { best = (l, gap, leaderSpeed) }
        }
        guard let b = best else { return nil }
        let v0 = min(edge.speedLimit, b.speed + 3)
        let safeSpeed = max(0, min(v0, (b.gap - cls.length - 4) / 1.6))
        guard b.gap > cls.length + 8, safeSpeed >= min(3, v0) else { return nil }
        let id = addVehicle(cls: cls, edge: entry, lane: b.lane.index, s: cls.length, speed: safeSpeed,
                            route: route, destination: destination, purpose: purpose)
        if id != nil { rebuildLaneAfterSpawn(entry, lane: b.lane.index) }
        return id
    }

    /// Keep the occupancy index consistent after spawning inside a step.
    func rebuildLaneAfterSpawn(_ e: EdgeID, lane: Int) {
        let key = laneKey(e, lane)
        let i = vehicles.count - 1
        laneOcc[key].append(Occupant(s: vehicles[i].s, index: Int32(i)))
        sortOccupants(&laneOcc[key])
    }
}

public extension Simulation {
    /// Fix the through-traffic rate (veh per simulated hour per entry), overriding the population-based rate.
    func setExternalRate(perEntryPerHour rate: Double?) {
        city.external.fixedRatePerEntry = rate
    }
}
