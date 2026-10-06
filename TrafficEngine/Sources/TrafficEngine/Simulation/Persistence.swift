//
//  Persistence.swift
//  TrafficEngine
//
//  Save files. A `SaveFile` is the authored network, the terrain, the
//  configuration and the complete dynamic state, so that
//
//      save → load → continue  ≡  an uninterrupted run   (same trace hash)
//
//  Everything else (geometry, connectors, conflict map, occupancy indices,
//  per-step scratch) is derived deterministically on load.
//
//  The engine is Foundation-free: it only defines the Codable model. The app
//  and the tests encode it as JSON (non-finite numbers as strings).
//

public struct SaveFile: Codable, Sendable {
    /// Schema version; bump on incompatible changes and migrate in `migrate`.
    public static let currentSchema = 1

    public var schema: Int
    public var name: String
    /// Wall-clock save time supplied by the app (seconds since 1970), for listings.
    public var savedAt: Double
    public var network: NetworkData
    public var terrain: Terrain
    public var config: SimulationConfig
    public var state: SimulationState

    /// Summary for a city picker without decoding vehicles.
    public var summary: String {
        "Day \(Int(state.clockSeconds / 86400) + 1), \(state.population) residents"
    }
}

/// The dynamic state of a simulation.
public struct SimulationState: Codable, Sendable {
    var time: Double
    var stepCount: Int
    var rng: SeededRandom
    var vehicles: [Vehicle]
    var nextVehicleID: Int
    var signals: SignalSystem
    var edgeTime: [Double]
    var metrics: MetricsState
    var city: CityState
    var police: PoliceState
    var events: [SimEvent]
    var warrants: WarrantState
    var gridlock: GridlockState
    var gridlockVehicles: [VehicleID]
    /// For listings.
    public var clockSeconds: Double
    public var population: Int
}

public enum LoadError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
    case corrupt(String)
}

extension Simulation {

    /// Snapshot everything needed to resume bit-identically.
    public func makeSave(name: String, savedAt: Double = 0) -> SaveFile {
        let state = SimulationState(
            time: time, stepCount: stepCount, rng: rng, vehicles: vehicles, nextVehicleID: nextVehicleID,
            signals: signals, edgeTime: router.edgeTime, metrics: metrics.state, city: city, police: police,
            events: events, warrants: warrants, gridlock: gridlock,
            gridlockVehicles: gridlockVehicles.sorted { $0.raw < $1.raw },
            clockSeconds: clock, population: city.population)
        return SaveFile(schema: SaveFile.currentSchema, name: name, savedAt: savedAt,
                        network: network.data, terrain: terrain, config: config, state: state)
    }

    /// Rebuild a simulation from a save file.
    public static func restore(_ input: SaveFile) throws -> Simulation {
        let save = try migrate(input)
        // Sanity checks on data that came from disk.
        guard save.config.dt > 0, save.config.dt <= 1, save.config.clockScale > 0 else {
            throw LoadError.corrupt("invalid configuration")
        }
        let net = RoadNetwork(side: save.network.side)
        net.replace(with: save.network)
        let sim = Simulation(network: net, terrain: save.terrain, config: save.config)
        let s = save.state
        for v in s.vehicles {
            switch v.track {
            case .edge(let e): guard net.edge(e) != nil else { throw LoadError.corrupt("vehicle \(v.id) on a missing road") }
            case .connector(let c): guard net.connector(c) != nil else { throw LoadError.corrupt("vehicle \(v.id) in a missing junction path") }
            }
        }
        guard s.edgeTime.count == sim.router.edgeTime.count else { throw LoadError.corrupt("routing table size") }
        sim.time = s.time
        sim.stepCount = s.stepCount
        sim.rng = s.rng
        sim.vehicles = s.vehicles
        sim.nextVehicleID = s.nextVehicleID
        sim.signals = s.signals
        sim.router.edgeTime = s.edgeTime
        sim.metrics.state = s.metrics
        sim.city = s.city
        sim.police = s.police
        sim.events = s.events
        sim.warrants = s.warrants
        sim.gridlock = s.gridlock
        sim.gridlockVehicles = Set(s.gridlockVehicles)
        sim.rebuildIndex()
        return sim
    }

    /// Bring an older save up to the current schema.
    static func migrate(_ save: SaveFile) throws -> SaveFile {
        switch save.schema {
        case SaveFile.currentSchema: return save
        default: throw LoadError.unsupportedSchema(save.schema)
        }
    }
}
