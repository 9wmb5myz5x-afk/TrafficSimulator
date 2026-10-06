//
//  IDM.swift
//  TrafficEngine
//
//  Intelligent Driver Model (Treiber, Hennecke & Helbing 2000, "Congested
//  traffic states in empirical observations and microscopic simulations"):
//
//      a = a_max · [ 1 − (v/v0)^δ − (s*(v, Δv) / s)² ]
//      s*(v, Δv) = s0 + max(0, v·T + v·Δv / (2·√(a_max·b)))
//
//  A pure function of the local situation, so it is unit-testable alone.
//  The simulation adds reaction time, bounded jerk and an emergency braking
//  limit on top (see `Driver` and the motion stage).
//

/// IDM parameters of one driver/vehicle.
public struct IDMParameters: Codable, Sendable, Equatable {
    /// Safe time headway T [s].
    public var timeHeadway: Double
    /// Maximum acceleration a_max [m/s²].
    public var maxAcceleration: Double
    /// Comfortable deceleration b [m/s²].
    public var comfortableDeceleration: Double
    /// Minimum standstill gap s0 [m].
    public var minGap: Double
    /// Acceleration exponent δ.
    public var delta: Double

    public init(timeHeadway: Double = 1.4, maxAcceleration: Double = 1.6,
                comfortableDeceleration: Double = 2.2, minGap: Double = 2.0, delta: Double = 4) {
        self.timeHeadway = timeHeadway
        self.maxAcceleration = maxAcceleration
        self.comfortableDeceleration = comfortableDeceleration
        self.minGap = minGap
        self.delta = delta
    }
}

public enum IDM {

    /// Emergency braking limit [m/s²] (≈0.8 g). Used only when necessary.
    public static let emergencyDeceleration = 8.0

    /// Free-road term only.
    @inline(__always)
    public static func freeAcceleration(_ p: IDMParameters, speed v: Double, desiredSpeed v0: Double) -> Double {
        let v0 = max(v0, 0.1)
        let ratio = v / v0
        let free: Double
        if p.delta == 4 { let r2 = ratio * ratio; free = r2 * r2 } else { free = DMath.pow(max(ratio, 0), p.delta) }
        // Above the desired speed, decelerate gently instead of with a^δ blow-up.
        if v > v0 { return max(-p.comfortableDeceleration, p.maxAcceleration * (1 - free)) }
        return p.maxAcceleration * (1 - free)
    }

    /// Desired dynamic gap s*.
    @inline(__always)
    public static func desiredGap(_ p: IDMParameters, speed v: Double, approachRate dv: Double) -> Double {
        p.minGap + max(0, v * p.timeHeadway + v * dv / (2 * (p.maxAcceleration * p.comfortableDeceleration).squareRoot()))
    }

    /// Full IDM acceleration with a leader at bumper-to-bumper `gap` moving at `leaderSpeed`.
    @inline(__always)
    public static func acceleration(_ p: IDMParameters, speed v: Double, desiredSpeed v0: Double,
                                    gap: Double, leaderSpeed: Double) -> Double {
        let free = freeAcceleration(p, speed: v, desiredSpeed: v0)
        let s = max(gap, 0.05)
        let sStar = desiredGap(p, speed: v, approachRate: v - leaderSpeed)
        let interaction = p.maxAcceleration * (sStar / s) * (sStar / s)
        return max(free - interaction, -emergencyDeceleration)
    }

    /// Kinematic braking needed to stop within `distance` from speed v.
    @inline(__always)
    public static func stoppingDeceleration(speed v: Double, distance: Double) -> Double {
        v * v / (2 * max(distance, 0.05))
    }

    /// Highest speed from which the vehicle can still slow to `targetSpeed`
    /// within `distance` at deceleration `b`.
    @inline(__always)
    public static func approachSpeed(target: Double, distance: Double, decel b: Double) -> Double {
        (target * target + 2 * b * max(distance, 0)).squareRoot()
    }
}
