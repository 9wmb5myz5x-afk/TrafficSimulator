//
//  Population.swift
//  TrafficEngine
//
//  Synthetic population and activity schedules.
//
//  Each resident has an employment status, a workplace chosen by a gravity
//  model (P(j) ∝ jobs_j · e^(−β·d_ij)), a car, and — every day — an activity
//  plan sampled from realistic departure-time distributions:
//
//    workers (weekday)   home → [school drop-off] → work → [shop] → home
//                        departure ~ N(07:45, 45 min), work ~ N(8.5 h, 45 min)
//    others / weekends   midday shopping ~ N(12:30, 2 h), light evening trips
//    freight             factory → shop → factory, mostly midday
//    night               a few shift workers
//
//  Plans are generated from an RNG derived from (seed, person, day), so the
//  whole demand is deterministic and needs no stored randomness.
//

public enum PersonRole: String, Codable, Sendable {
    case worker, nonWorker, trucker
}

public struct Person: Codable, Sendable, Identifiable, Equatable {
    public let id: PersonID
    public var home: BuildingID
    public var work: BuildingID?
    public var role: PersonRole
    public var car: VehicleClass
    /// Takes children to school on the way to work.
    public var schoolRun: Bool
    /// Where the person currently is (nil while driving).
    public var at: BuildingID?
    public var vehicle: VehicleID?
    /// Remaining stops of today's plan.
    public var plan: [PlannedTrip] = []
    public var planDay: Int = -1
    /// Moved in yet (occupancy fills in after a building is placed).
    public var movedIn: Bool = true
    /// Works beyond the map, reached through this regional connection.
    public var regionalWork: NodeID?
    /// Currently away beyond the map (entered/left via this connection).
    public var inRegion: NodeID?
}

public struct PlannedTrip: Codable, Sendable, Equatable {
    /// Clock time (seconds since Monday 00:00) of departure.
    public var depart: Double
    public var to: BuildingID
    /// When set, the trip leaves the map through this regional connection
    /// (`to` is then ignored).
    public var toRegion: NodeID? = nil
    public var purpose: TripPurpose
    /// Stay at the destination before the next trip may start [clock s].
    public var dwell: Double
}

/// A scheduled departure in the city's event queue.
public struct DemandEvent: Codable, Sendable, Equatable {
    public var time: Double         // clock seconds
    public var seq: Int
    public var person: PersonID
}

enum Schedules {
    static let minute = 60.0
    static let hour = 3600.0

    /// Build one person's plan for `day` (0 = Monday of week 0).
    static func plan(for p: Person, day: Int, weekend: Bool, city: CityState, rng: inout SeededRandom) -> [PlannedTrip] {
        let dayStart = Double(day) * 86400
        var trips: [PlannedTrip] = []
        func at(_ meanHour: Double, _ sdMin: Double, _ lo: Double, _ hi: Double) -> Double {
            dayStart + rng.nextGaussian(mean: meanHour * hour, stdDev: sdMin * minute, clampedTo: (lo * hour)...(hi * hour))
        }
        switch p.role {
        case .trucker:
            guard !weekend || rng.chance(0.25) else { return [] }
            var t = at(8.5, 120, 6, 17)
            for _ in 0..<2 {
                guard let shop = city.pickShop(near: p.home, rng: &rng) else { break }
                trips.append(PlannedTrip(depart: t, to: shop, purpose: .freight, dwell: rng.nextDouble(in: 300..<900)))
                t += rng.nextDouble(in: 1.2..<2.2) * hour
                trips.append(PlannedTrip(depart: t, to: p.home, purpose: .freight, dwell: 0))
                t += rng.nextDouble(in: 1.0..<2.5) * hour
                if t > dayStart + 18 * hour { break }
            }
        case .worker:
            if let region = p.regionalWork, !weekend || rng.chance(0.12) {
                let leave = at(7.6, 45, 5.75, 10.5)
                trips.append(PlannedTrip(depart: leave, to: p.home, toRegion: region, purpose: .work,
                                         dwell: rng.nextGaussian(mean: 9 * hour, stdDev: 50 * minute, clampedTo: (6 * hour)...(11 * hour))))
                trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
            } else if let work = p.work, !weekend || rng.chance(0.12) {
                let shift = rng.chance(0.06)
                var leave = shift ? at(21.5, 40, 20, 23) : at(7.75, 45, 5.75, 10.5)
                if p.schoolRun, !shift, let school = city.nearestOf(.school, to: p.home) {
                    trips.append(PlannedTrip(depart: leave, to: school, purpose: .school, dwell: 4 * minute))
                    leave += 0   // continues to work from school
                }
                trips.append(PlannedTrip(depart: leave, to: work, purpose: .work,
                                         dwell: rng.nextGaussian(mean: 8.5 * hour, stdDev: 45 * minute, clampedTo: (6 * hour)...(10.5 * hour))))
                // From work: maybe shop, then home.
                if rng.chance(0.3), let shop = city.pickShop(near: work, rng: &rng) {
                    trips.append(PlannedTrip(depart: 0, to: shop, purpose: .shop, dwell: rng.nextDouble(in: 15..<45) * minute))
                }
                trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
                if rng.chance(0.12), let shop = city.pickShop(near: p.home, rng: &rng) {
                    trips.append(PlannedTrip(depart: at(19.75, 50, 18.5, 22), to: shop, purpose: .shop, dwell: rng.nextDouble(in: 30..<90) * minute))
                    trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
                }
            } else {
                fallthrough
            }
        case .nonWorker:
            let shopChance = weekend ? 0.65 : 0.45
            if rng.chance(shopChance), rng.chance(city.regionalShare * 0.5), let region = city.pickRegion(near: p.home, rng: &rng) {
                trips.append(PlannedTrip(depart: at(weekend ? 13 : 11.5, 120, 8, 19), to: p.home, toRegion: region, purpose: .shop,
                                         dwell: rng.nextDouble(in: 60..<150) * minute))
                trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
            } else if rng.chance(shopChance), let shop = city.pickShop(near: p.home, rng: &rng) {
                trips.append(PlannedTrip(depart: at(weekend ? 13 : 11.5, 120, 8, 19), to: shop, purpose: .shop,
                                         dwell: rng.nextDouble(in: 25..<100) * minute))
                trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
            }
            if rng.chance(0.06), let shop = city.pickShop(near: p.home, rng: &rng) {
                trips.append(PlannedTrip(depart: at(20.5, 45, 19, 23), to: shop, purpose: .other, dwell: rng.nextDouble(in: 40..<120) * minute))
                trips.append(PlannedTrip(depart: 0, to: p.home, purpose: .home, dwell: 0))
            }
        }
        // Trips with depart = 0 follow the previous stop's dwell.
        return trips
    }
}

extension CityState {

    public func building(_ id: BuildingID) -> Building? {
        id.raw >= 0 && id.raw < buildingSlots.count ? buildingSlots[id.raw] : nil
    }

    func nearestOf(_ kind: BuildingKind, to b: BuildingID) -> BuildingID? {
        guard let origin = building(b) else { return nil }
        var best: (BuildingID, Double)?
        for x in buildings where x.kind == kind && x.access != nil {
            let d = x.center.distance(to: origin.center)
            if best == nil || d < best!.1 { best = (x.id, d) }
        }
        return best?.0
    }

    /// Gravity choice of a shop: size × e^(−β d).
    func pickShop(near b: BuildingID, rng: inout SeededRandom) -> BuildingID? {
        guard let origin = building(b) else { return nil }
        let shops = shopIDs.compactMap { building($0) }.filter { $0.id != b }
        guard !shops.isEmpty else { return nil }
        let w = shops.map { $0.kind.shopAttraction * DMath.exp(-0.9 * $0.center.distance(to: origin.center) / 1000) }
        return rng.pickWeighted(w).map { shops[$0].id }
    }

    /// Choose a regional connection, nearer ones more likely.
    func pickRegion(near b: BuildingID, rng: inout SeededRandom) -> NodeID? {
        guard let origin = building(b), !regions.isEmpty else { return nil }
        let w = regions.map { DMath.exp(-$0.1.distance(to: origin.center) / 1500) }
        return rng.pickWeighted(w).map { regions[$0].0 }
    }

    /// Gravity choice of a workplace: free jobs × e^(−β d).
    mutating func assignWork(for home: BuildingID, rng: inout SeededRandom) -> BuildingID? {
        guard let origin = building(home) else { return nil }
        let employers = employerIDs.compactMap { building($0) }.filter { $0.workers < $0.jobs }
        guard !employers.isEmpty else { return nil }
        let w = employers.map { Double($0.jobs - $0.workers) * DMath.exp(-0.5 * $0.center.distance(to: origin.center) / 1000) }
        guard let k = rng.pickWeighted(w) else { return nil }
        let id = employers[k].id
        buildingSlots[id.raw]?.workers += 1
        return id
    }
}
