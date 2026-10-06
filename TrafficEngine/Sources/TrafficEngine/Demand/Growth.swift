//
//  Growth.swift
//  TrafficEngine
//
//  Growth mode: the city grows by itself. Each new simulated day, houses
//  and businesses appear beside well-connected roads (weighted by the
//  number of roads meeting at either end), and their occupancy fills in
//  over the following hour, so demand ramps up smoothly.
//

extension Simulation {

    func updateGrowth() {
        let day = dayIndex
        guard day != city.growth.lastGrowthDay else { return }
        let first = city.growth.lastGrowthDay < 0
        city.growth.lastGrowthDay = day
        if first { return }
        grow(houses: city.growth.housesPerDay, businesses: city.growth.businessesPerDay)
    }

    /// Place up to `houses` homes and `businesses` workplaces along existing roads.
    @discardableResult
    public func grow(houses: Int, businesses: Int) -> Int {
        let roads = network.allRoads.filter { $0.roadClass != .highway && $0.roadClass != .ramp }
        guard !roads.isEmpty else { return 0 }
        let weights = roads.map { Double(network.degree(of: $0.a) + network.degree(of: $0.b)) }
        var placed = 0
        var r = rng.derived(UInt64(dayIndex) &* 6151)
        func tryPlace(_ kind: BuildingKind) -> Bool {
            for _ in 0..<25 {
                guard let k = r.pickWeighted(weights), let line = network.centreline(of: roads[k].id), line.length > 40 else { continue }
                let s = r.nextDouble(in: 20..<(line.length - 20))
                let sideSign: Double = r.chance(0.5) ? 1 : -1
                let depth = kind.size.depth / 2 + 12 + r.nextDouble(in: 0..<6)
                let p = line.position(at: s, lateral: sideSign * depth)
                if case .success = placeBuilding(kind, at: p) { return true }
            }
            return false
        }
        for _ in 0..<houses where tryPlace(r.chance(0.8) ? .house : .townhouse) { placed += 1 }
        for _ in 0..<businesses where tryPlace(r.chance(0.6) ? .shop : .office) { placed += 1 }
        return placed
    }
}
