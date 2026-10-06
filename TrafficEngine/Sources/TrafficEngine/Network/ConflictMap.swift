//
//  ConflictMap.swift
//  TrafficEngine
//
//  Footprint-level conflicts between movements through the same junction.
//
//  Two connectors conflict when vehicles on them could touch. Centre lines
//  alone are not enough (two near-parallel turns can pass within a car width
//  without crossing), so each path is swept by the widest vehicle plus a
//  margin. For every conflicting pair we store the *conflict zone* on each
//  path: the arc-length interval where the swept areas overlap. A vehicle
//  has *cleared* a conflict once its rear is past its zone.
//
//  Kinds:
//   • diverge — same approach lane. Not a reservation conflict: the follower
//     simply car-follows its predecessor until their paths separate.
//   • merge   — same exit lane. The zone runs to the end of both paths.
//   • cross   — paths cross or come within a footprint of each other.
//

public struct ConflictMap: Sendable {
    public enum Kind: Sendable { case diverge, merge, cross }

    public struct Entry: Sendable {
        public let other: ConnectorID
        public let kind: Kind
        /// Zone on this connector [s0, s1].
        public let zoneStart: Double
        public let zoneEnd: Double
        /// Zone on the other connector.
        public let otherZoneStart: Double
        public let otherZoneEnd: Double
    }

    /// Widest vehicle (bus) plus clearance, used to sweep paths [m].
    public static let sweepWidth = 2.6
    public static let clearance = 0.5

    public private(set) var entries: [[Entry]] = []

    public init() {}

    public func conflicts(of c: ConnectorID) -> [Entry] {
        c.raw < entries.count ? entries[c.raw] : []
    }

    static func build(network: RoadNetwork) -> ConflictMap {
        var map = ConflictMap()
        map.entries = Array(repeating: [], count: network.connectors.count)
        let threshold = sweepWidth + clearance
        for n in 0..<network.nodeCount {
            let ids = network.connectors(at: NodeID(n))
            guard ids.count > 1 else { continue }
            let samples = ids.map { sample(network.connectors[$0.raw].path) }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = network.connectors[ids[i].raw], b = network.connectors[ids[j].raw]
                    if a.from == b.from {
                        // Diverge: zone from the start until the paths separate.
                        let split = separation(samples[i], samples[j], threshold: threshold)
                        map.entries[a.id.raw].append(Entry(other: b.id, kind: .diverge, zoneStart: 0, zoneEnd: split.0,
                                                           otherZoneStart: 0, otherZoneEnd: split.1))
                        map.entries[b.id.raw].append(Entry(other: a.id, kind: .diverge, zoneStart: 0, zoneEnd: split.1,
                                                           otherZoneStart: 0, otherZoneEnd: split.0))
                        continue
                    }
                    guard let (za, zb) = overlapZones(samples[i], samples[j], threshold: threshold) else {
                        if a.to == b.to {
                            // Same exit lane but footprints never touch inside: still a merge at the exit.
                            let ea = a.length, eb = b.length
                            map.entries[a.id.raw].append(Entry(other: b.id, kind: .merge, zoneStart: ea - 1, zoneEnd: ea,
                                                               otherZoneStart: eb - 1, otherZoneEnd: eb))
                            map.entries[b.id.raw].append(Entry(other: a.id, kind: .merge, zoneStart: eb - 1, zoneEnd: eb,
                                                               otherZoneStart: ea - 1, otherZoneEnd: ea))
                        }
                        continue
                    }
                    let kind: Kind = a.to == b.to ? .merge : .cross
                    let zaEnd = kind == .merge ? a.length : za.1
                    let zbEnd = kind == .merge ? b.length : zb.1
                    map.entries[a.id.raw].append(Entry(other: b.id, kind: kind, zoneStart: za.0, zoneEnd: zaEnd,
                                                       otherZoneStart: zb.0, otherZoneEnd: zbEnd))
                    map.entries[b.id.raw].append(Entry(other: a.id, kind: kind, zoneStart: zb.0, zoneEnd: zbEnd,
                                                       otherZoneStart: za.0, otherZoneEnd: zaEnd))
                }
            }
        }
        return map
    }

    struct Samples {
        var s: [Double]
        var p: [Vector2]
        var minP: Vector2
        var maxP: Vector2
    }

    static func sample(_ path: Polyline) -> Samples {
        let n = max(2, Int((path.length / 0.75).rounded(.up)))
        var s: [Double] = []
        var p: [Vector2] = []
        s.reserveCapacity(n + 1)
        p.reserveCapacity(n + 1)
        var lo = Vector2(.infinity, .infinity), hi = Vector2(-.infinity, -.infinity)
        for k in 0...n {
            let sk = path.length * Double(k) / Double(n)
            let pk = path.point(at: sk)
            s.append(sk)
            p.append(pk)
            lo = Vector2(min(lo.x, pk.x), min(lo.y, pk.y))
            hi = Vector2(max(hi.x, pk.x), max(hi.y, pk.y))
        }
        return Samples(s: s, p: p, minP: lo, maxP: hi)
    }

    /// Arc-length intervals on each path where the other path is within `threshold`.
    static func overlapZones(_ a: Samples, _ b: Samples, threshold: Double) -> ((Double, Double), (Double, Double))? {
        if a.minP.x - threshold > b.maxP.x || b.minP.x - threshold > a.maxP.x ||
           a.minP.y - threshold > b.maxP.y || b.minP.y - threshold > a.maxP.y { return nil }
        let t2 = threshold * threshold
        var a0 = Double.infinity, a1 = -Double.infinity
        var b0 = Double.infinity, b1 = -Double.infinity
        for i in 0..<a.p.count {
            for j in 0..<b.p.count where a.p[i].distanceSquared(to: b.p[j]) < t2 {
                a0 = min(a0, a.s[i]); a1 = max(a1, a.s[i])
                b0 = min(b0, b.s[j]); b1 = max(b1, b.s[j])
            }
        }
        guard a0.isFinite else { return nil }
        let pad = 0.75
        return ((max(0, a0 - pad), min(a.s.last!, a1 + pad)), (max(0, b0 - pad), min(b.s.last!, b1 + pad)))
    }

    /// Arc lengths at which two paths from the same start have separated.
    static func separation(_ a: Samples, _ b: Samples, threshold: Double) -> (Double, Double) {
        let t2 = threshold * threshold
        var lastA = 0.0, lastB = 0.0
        for i in 0..<a.p.count {
            var close = false
            for j in 0..<b.p.count where a.p[i].distanceSquared(to: b.p[j]) < t2 {
                close = true
                lastB = max(lastB, b.s[j])
            }
            if close { lastA = a.s[i] }
        }
        return (lastA, lastB)
    }
}
