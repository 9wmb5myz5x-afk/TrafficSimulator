//
//  MOBIL.swift
//  TrafficEngine
//
//  MOBIL lane-change decision (Kesting, Treiber & Helbing 2007, "General
//  lane-changing model MOBIL for car-following models"):
//
//   safety:    ã_n ≥ −b_safe           (new follower must not brake too hard)
//   incentive: ã_c − a_c + p·[(ã_n − a_n) + (ã_o − a_o)] > Δa_th + Δa_bias
//
//  where c = changer, n = new follower, o = old follower, ~ = after the
//  change. The asymmetric "keep to the kerb except to pass" rule enters as
//  a bias: a move towards the passing side needs more incentive, a move back
//  towards the kerb needs less.
//

public struct MOBILParameters: Codable, Sendable, Equatable {
    /// Politeness p ∈ [0, 1].
    public var politeness: Double
    /// Changing threshold Δa_th [m/s²].
    public var threshold: Double
    /// Maximum safe deceleration imposed on the new follower b_safe [m/s²].
    public var safeDeceleration: Double
    /// Keep-kerb bias Δa_bias [m/s²].
    public var keepKerbBias: Double

    public init(politeness: Double = 0.35, threshold: Double = 0.15, safeDeceleration: Double = 3.5,
                keepKerbBias: Double = 0.3) {
        self.politeness = politeness
        self.threshold = threshold
        self.safeDeceleration = safeDeceleration
        self.keepKerbBias = keepKerbBias
    }
}

public enum MOBIL {

    public struct Situation: Sendable {
        public var selfCurrent: Double
        public var selfTarget: Double
        public var newFollowerBefore: Double
        public var newFollowerAfter: Double
        public var oldFollowerBefore: Double
        public var oldFollowerAfter: Double
        public init(selfCurrent: Double, selfTarget: Double, newFollowerBefore: Double, newFollowerAfter: Double,
                    oldFollowerBefore: Double, oldFollowerAfter: Double) {
            self.selfCurrent = selfCurrent
            self.selfTarget = selfTarget
            self.newFollowerBefore = newFollowerBefore
            self.newFollowerAfter = newFollowerAfter
            self.oldFollowerBefore = oldFollowerBefore
            self.oldFollowerAfter = oldFollowerAfter
        }
    }

    /// Is the change safe for the new follower?
    public static func isSafe(_ p: MOBILParameters, _ s: Situation) -> Bool {
        s.newFollowerAfter >= -p.safeDeceleration
    }

    /// Net incentive (positive = worth changing). `bias` > 0 makes the change
    /// harder (moving towards the passing side), < 0 easier.
    public static func incentive(_ p: MOBILParameters, _ s: Situation, bias: Double) -> Double {
        let own = s.selfTarget - s.selfCurrent
        let others = (s.newFollowerAfter - s.newFollowerBefore) + (s.oldFollowerAfter - s.oldFollowerBefore)
        return own + p.politeness * others - p.threshold - bias
    }

    public static func shouldChange(_ p: MOBILParameters, _ s: Situation, bias: Double) -> Bool {
        isSafe(p, s) && incentive(p, s, bias: bias) > 0
    }
}
