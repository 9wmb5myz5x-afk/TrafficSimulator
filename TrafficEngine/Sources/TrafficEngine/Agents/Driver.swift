//
//  Driver.swift
//  TrafficEngine
//
//  A sampled driver: personal desired-speed factor, IDM and MOBIL
//  parameters, reaction time and gap-acceptance tolerance.
//

public struct Driver: Codable, Sendable, Equatable {
    /// Multiplies the speed limit to give the desired speed (N(1.03, 0.08), clamped).
    public var speedFactor: Double
    public var idm: IDMParameters
    public var mobil: MOBILParameters
    /// Reaction time [s]: gentle changes in the situation are acted on only
    /// every `reactionTime` seconds (emergencies immediately). Allows
    /// stop-and-go waves to form at high density.
    public var reactionTime: Double
    /// Scales HCM critical gaps (≈N(1, 0.1), clamped [0.8, 1.25]).
    public var gapFactor: Double
    /// Time spent signalling before a discretionary lane change [s].
    public var signalTime: Double
    /// 0 = very calm, 1 = very aggressive (inspector display).
    public var aggressiveness: Double

    public init(speedFactor: Double = 1.0, idm: IDMParameters = IDMParameters(), mobil: MOBILParameters = MOBILParameters(),
                reactionTime: Double = 0.4, gapFactor: Double = 1.0, signalTime: Double = 2.0, aggressiveness: Double = 0.5) {
        self.speedFactor = speedFactor
        self.idm = idm
        self.mobil = mobil
        self.reactionTime = reactionTime
        self.gapFactor = gapFactor
        self.signalTime = signalTime
        self.aggressiveness = aggressiveness
    }

    /// Sample a driver for a vehicle class. `meanAggressiveness` ∈ [0, 1] shifts the population.
    public static func sample(for cls: VehicleClass, rng: inout SeededRandom, meanAggressiveness: Double = 0.5) -> Driver {
        let aggr = rng.nextGaussian(mean: meanAggressiveness, stdDev: 0.18, clampedTo: 0...1)
        var d = Driver()
        d.aggressiveness = aggr
        d.speedFactor = rng.nextGaussian(mean: 1.03 + 0.06 * (aggr - 0.5), stdDev: 0.08, clampedTo: 0.85...1.22)
        d.idm = IDMParameters(
            timeHeadway: (1.6 - 0.8 * (aggr - 0.5)).clamped(to: 0.9...2.2),
            maxAcceleration: cls.maxAcceleration * (0.9 + 0.3 * aggr),
            comfortableDeceleration: cls.comfortableDeceleration * (0.9 + 0.3 * aggr),
            minGap: (2.4 - 0.8 * aggr).clamped(to: 1.5...3.0),
            delta: 4)
        d.mobil = MOBILParameters(
            politeness: (0.55 - 0.5 * aggr).clamped(to: 0.05...0.7),
            threshold: (0.25 - 0.2 * aggr).clamped(to: 0.05...0.35),
            safeDeceleration: 3.0 + 1.5 * aggr,
            keepKerbBias: 0.3)
        d.reactionTime = rng.nextGaussian(mean: 0.45, stdDev: 0.12, clampedTo: 0.25...0.8)
        d.gapFactor = rng.nextGaussian(mean: 1.0 - 0.15 * (aggr - 0.5), stdDev: 0.1, clampedTo: 0.8...1.25)
        d.signalTime = rng.nextDouble(in: 1.6..<2.8)
        return d
    }
}
