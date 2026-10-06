//
//  SimulationConfig.swift
//  TrafficEngine
//
//  Every tunable of the simulation, with units and defaults. Codable so it
//  is part of the save file.
//

public struct SimulationConfig: Codable, Sendable, Equatable {
    /// RNG seed. Same seed + same inputs ⇒ identical run.
    public var seed: UInt64 = 0xC0FFEE
    /// Fixed physics timestep [s].
    public var dt: Double = 0.05

    // MARK: Time of day
    /// Clock seconds per simulated second. Vehicles always move in real
    /// physical time; the day clock runs faster so a whole day passes in a
    /// playable time (8 ⇒ one day = 3 simulated hours).
    public var clockScale: Double = 8
    /// Clock time at t = 0, in seconds since Monday 00:00.
    public var startClock: Double = 5 * 3600

    // MARK: Demand
    /// Global demand multiplier (the "traffic volume" slider).
    public var demandMultiplier: Double = 1.0
    /// Hard cap on simultaneous vehicles (performance guard).
    public var maxVehicles: Int = 4000
    /// Mean driver aggressiveness ∈ [0, 1].
    public var meanAggressiveness: Double = 0.5
    /// External through-traffic (all entries together) per 1000 residents,
    /// per simulated hour at the daily peak.
    public var externalTripsPerThousand: Double = 80
    /// Fraction of residents who drive on a given day. The clock runs
    /// `clockScale`× faster than the vehicles, so if everybody drove, flow
    /// rates would be `clockScale`× those of a real town of the same size;
    /// sampling 1/clockScale of the residents each day keeps peak-hour flows
    /// realistic (≈0.3 veh/h per resident at the AM peak). Scaled by
    /// `demandMultiplier`.
    public var dailyDriverShare: Double = 0.125

    // MARK: Behaviour
    /// Look-ahead for leaders across junctions [m] (at least).
    public var lookAhead: Double = 120
    /// Comfortable lateral acceleration in curves [m/s²].
    public var curveLateralAcceleration: Double = 2.8
    /// Comfortable jerk limit [m/s³]; emergencies may exceed it.
    public var comfortJerk: Double = 4.0
    /// Right-on-red (left-on-red for `.left`) allowed city-wide.
    public var turnOnRed: Bool = true
    /// Undertaking (passing on the kerb side) discouraged on highways.
    public var noUndertakingOnHighways: Bool = true

    // MARK: Routing
    public var rerouteInterval: Double = 30
    /// Switch routes only when the alternative saves this fraction…
    public var rerouteRelativeGain: Double = 0.15
    /// …and at least this many seconds.
    public var rerouteAbsoluteGain: Double = 20

    // MARK: Junctions
    /// Automatically select/upgrade junction control from warrants.
    public var autoTrafficControl: Bool = true
    /// Wait after which a stuck vehicle is considered part of a gridlock check [s].
    public var gridlockWait: Double = 60

    // MARK: Services
    public var incidentsPerThousandPerDay: Double = 4
    public var minorCollisions: Bool = false

    public init() {}
}
