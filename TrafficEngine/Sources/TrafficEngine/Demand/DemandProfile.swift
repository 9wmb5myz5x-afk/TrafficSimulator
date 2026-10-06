//
//  DemandProfile.swift
//  TrafficEngine
//
//  Time-of-day shapes. Departure times of activities are *sampled* from
//  these distributions per resident (see Population), so peaks emerge from
//  people's schedules rather than from a scripted curve. The profile below
//  is only used for external (through) traffic, whose origins are off-map.
//

public enum DemandProfile {

    @inline(__always)
    static func bump(_ h: Double, _ centre: Double, _ width: Double) -> Double {
        let d = (h - centre) / width
        return DMath.exp(-0.5 * d * d)
    }

    /// Relative intensity of through traffic at clock hour `hour` (peak = 1).
    public static func externalFactor(hour h: Double, weekend: Bool) -> Double {
        if weekend {
            return 0.08 + 0.55 * bump(h, 13, 3.0) + 0.2 * bump(h, 18, 2)
        }
        return 0.05 + 0.95 * bump(h, 8, 0.9) + 0.9 * bump(h, 17.3, 1.1) + 0.35 * bump(h, 12.5, 2.5) + 0.12 * bump(h, 20.5, 1.5)
    }
}
