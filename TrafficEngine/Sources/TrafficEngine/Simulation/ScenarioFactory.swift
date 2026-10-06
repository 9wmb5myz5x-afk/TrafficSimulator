//
//  ScenarioFactory.swift
//  TrafficEngine
//
//  Builds a complete, populated city for each scenario. Tests, the CLI and
//  the app's starter maps all use this one code path.
//

public enum ScenarioFactory {

    public static func make(_ kind: ScenarioKind, side: DrivingSide = .right, seed: UInt64 = 1,
                            config base: SimulationConfig = SimulationConfig()) -> Simulation {
        let map = ScenarioNetworks.make(kind, side: side, seed: seed)
        var cfg = base
        cfg.seed = seed
        // The stress scenario runs at high demand (≥ 1,500 vehicles at the peak).
        if kind == .stressCity { cfg.demandMultiplier *= 3 }
        let sim = Simulation(network: map.network, terrain: map.terrain, config: cfg)
        populate(sim, map: map, kind: kind)
        return sim
    }

    /// Place buildings in the map's land-use areas.
    static func populate(_ sim: Simulation, map: CityMap, kind: ScenarioKind) {
        var r = SeededRandom(seed: sim.config.seed &* 0x5DEECE66D &+ 11)
        func fill(_ area: [Vector2], kinds: [(BuildingKind, Double)], spacing: Double) {
            let lo = Vector2(area.map { $0.x }.min()!, area.map { $0.y }.min()!)
            let hi = Vector2(area.map { $0.x }.max()!, area.map { $0.y }.max()!)
            var y = lo.y + spacing / 2
            while y < hi.y {
                var x = lo.x + spacing / 2
                while x < hi.x {
                    let jitter = Vector2(r.nextDouble(in: -3..<3), r.nextDouble(in: -3..<3))
                    let p = Vector2(x, y) + jitter
                    if Geometry.pointInPolygon(p, area) || area.count == 4 {
                        let k = kinds[r.pickWeighted(kinds.map { $0.1 }) ?? 0].0
                        _ = sim.placeBuilding(k, at: p, fillImmediately: true)
                    }
                    x += spacing
                }
                y += spacing
            }
        }
        // Police stations first (civic sites), searching outwards for a free plot.
        for site in map.policeSites {
            search: for radius in stride(from: 0.0, through: 90, by: 15) {
                let n = radius == 0 ? 1 : 8
                for k in 0..<n {
                    let a = Double(k) / Double(n) * 2 * 3.141592653589793
                    let p = site + Vector2(DMath.cos(a), DMath.sin(a)) * radius
                    if case .success = sim.placeBuilding(.policeStation, at: p, fillImmediately: true) { break search }
                }
            }
        }
        let dense = kind == .downtown || kind == .stressCity
        for a in map.residentialAreas {
            fill(a, kinds: dense ? [(.house, 3), (.townhouse, 3), (.apartment, 2)] : [(.house, 8), (.townhouse, 1.5), (.apartment, 0.3)],
                 spacing: dense ? 30 : 24)
        }
        for a in map.commercialAreas {
            fill(a, kinds: [(.shop, 3), (.office, dense ? 2 : 1)], spacing: 32)
        }
        for a in map.industrialAreas {
            fill(a, kinds: [(.factory, 1)], spacing: 46)
        }
        // A school near the middle of the residential areas.
        if let first = map.residentialAreas.first {
            let c = first.reduce(Vector2.zero, +) / Double(first.count)
            for dx in stride(from: 0.0, through: 120, by: 30) {
                if case .success = sim.placeBuilding(.school, at: c + Vector2(dx, 10), fillImmediately: true) { break }
            }
        }
    }
}
