//
//  SeededRandom.swift
//  TrafficEngine
//
//  A deterministic, seedable, *serialisable* PRNG (SplitMix64). Its state is
//  part of the save file so a loaded city continues bit-identically.
//

public struct SeededRandom: RandomNumberGenerator, Codable, Sendable, Equatable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        return SeededRandom.mix(state)
    }

    /// SplitMix64 finaliser, also usable as a stateless hash.
    @inline(__always)
    public static func mix(_ v: UInt64) -> UInt64 {
        var z = v
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1) using the top 53 bits.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    public mutating func nextDouble(in range: Range<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }

    public mutating func nextInt(_ upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    public mutating func chance(_ p: Double) -> Bool { nextUnit() < p }

    /// Normal sample (Box–Muller) using deterministic maths.
    public mutating func nextGaussian(mean: Double = 0, stdDev: Double = 1) -> Double {
        let u1 = Swift.max(nextUnit(), 1e-300)
        let u2 = nextUnit()
        return mean + stdDev * (-2.0 * DMath.log(u1)).squareRoot() * DMath.cos(DMath.twoPi * u2)
    }

    /// Normal sample clamped to [lo, hi].
    public mutating func nextGaussian(mean: Double, stdDev: Double, clampedTo r: ClosedRange<Double>) -> Double {
        nextGaussian(mean: mean, stdDev: stdDev).clamped(to: r)
    }

    /// Exponential inter-arrival time with the given rate (events per unit).
    public mutating func nextExponential(rate: Double) -> Double {
        guard rate > 0 else { return .infinity }
        return -DMath.log(Swift.max(1 - nextUnit(), 1e-300)) / rate
    }

    /// Gumbel(0,1) sample, used for logit-style route perturbations.
    public mutating func nextGumbel() -> Double {
        -DMath.log(-DMath.log(Swift.max(nextUnit(), 1e-300)))
    }

    /// Pick an index with probability proportional to `weights` (non-negative).
    public mutating func pickWeighted(_ weights: [Double]) -> Int? {
        var total = 0.0
        for w in weights where w > 0 { total += w }
        guard total > 0 else { return nil }
        var r = nextUnit() * total
        for (i, w) in weights.enumerated() where w > 0 {
            r -= w
            if r < 0 { return i }
        }
        return weights.lastIndex(where: { $0 > 0 })
    }

    /// Derive an independent child generator (e.g. per vehicle) from a key.
    public func derived(_ key: UInt64) -> SeededRandom {
        SeededRandom(seed: SeededRandom.mix(state ^ SeededRandom.mix(key &+ 0x632BE59BD9B4E019)))
    }
}

/// Stateless hash → uniform [0,1). Used where a value must be a pure function
/// of identifiers (e.g. a driver's per-edge route perturbation).
@inline(__always)
public func hashUnit(_ a: UInt64, _ b: UInt64) -> Double {
    let h = SeededRandom.mix(a &* 0x9E3779B97F4A7C15 ^ SeededRandom.mix(b))
    return Double(h >> 11) * (1.0 / 9007199254740992.0)
}

/// FNV-1a 64-bit running hash, used for determinism trace hashes.
public struct TraceHasher: Sendable, Equatable, Codable {
    public private(set) var value: UInt64 = 0xcbf29ce484222325
    public init() {}
    @inline(__always)
    public mutating func combine(_ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            value ^= x & 0xff
            value = value &* 0x100000001b3
            x >>= 8
        }
    }
    public mutating func combine(_ v: Int) { combine(UInt64(bitPattern: Int64(v))) }
    public mutating func combine(_ v: Double) { combine(v.bitPattern) }
}
