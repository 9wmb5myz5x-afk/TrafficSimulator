//
//  TrafficLevel.swift
//  TrafficEngine
//
//  The player's traffic dial. 1 = the city's own demand; up to 5 the roads
//  fill until they jam. A change takes effect at once:
//   • through traffic follows immediately, with a floor that does not depend
//     on the population, so even a small town can be made to congest;
//   • when the level rises, residents who were not going to drive today get
//     the rest of a day's plan (trips already in the past are skipped).
//

public extension Simulation {

    static let trafficLevelRange: ClosedRange<Double> = 0.25...5

    /// Through traffic per regional entry for each level above normal [veh/h].
    static let throughTrafficPerLevel = 140.0

    /// How busy the roads are (1 = normal).
    var trafficLevel: Double { config.demandMultiplier }

    func setTrafficLevel(_ level: Double) {
        let old = config.demandMultiplier
        let new = level.clamped(to: Self.trafficLevelRange)
        config.demandMultiplier = new
        guard new > old + 1e-9 else { return }
        let oldShare = min(1, config.dailyDriverShare * old)
        let newShare = min(1, config.dailyDriverShare * new)
        // Of those not yet driving today, the fraction that now will.
        let extra = oldShare >= 1 ? 0 : (newShare - oldShare) / (1 - oldShare)
        guard extra > 0 else { return }
        let day = Int(clock / 86400)
        var r = rng.derived(0x7EAF_F1C0 &+ UInt64(day) &* 7919 &+ UInt64(max(0, time)))
        for k in city.people.indices {
            let p = city.people[k]
            guard p.movedIn, p.planDay == day, p.plan.isEmpty, p.vehicle == nil, p.inRegion == nil,
                  p.at == p.home, city.building(p.home) != nil else { continue }
            guard r.chance(extra) else { continue }
            let full = Schedules.plan(for: p, day: day, weekend: (day % 7) >= 5, city: city, rng: &r)
            // Only what is still ahead today, starting from home.
            guard let start = full.firstIndex(where: { $0.depart >= clock }) else { continue }
            let plan = Array(full[start...])
            guard let first = plan.first, first.to != p.home || first.toRegion != nil else { continue }
            city.people[k].plan = plan
            city.schedule(p.id, at: first.depart)
        }
    }
}
