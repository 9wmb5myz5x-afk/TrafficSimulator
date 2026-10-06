//
//  Polyline.swift
//  TrafficEngine
//
//  An arc-length-parameterised polyline with *smoothly interpolated* tangents.
//
//  Vehicles are positioned at `point(s) + normal(s) · lateral`. If the normal
//  were piecewise constant (one per segment), a vehicle with a lateral offset
//  would jump by `lateral · Δθ` at every vertex. Instead we store a unit
//  tangent per vertex (the bisector of the adjacent segments) and interpolate
//  it along each segment, so offset positions and headings are continuous.
//

public struct Polyline: Codable, Sendable, Equatable {
    public private(set) var points: [Vector2]
    /// Cumulative arc length at each point (`cumulative[0] == 0`).
    public private(set) var cumulative: [Double]
    /// Unit tangent at each vertex.
    public private(set) var tangents: [Vector2]

    public init(_ pts: [Vector2]) {
        // Drop consecutive duplicates; a polyline needs two distinct points.
        var clean: [Vector2] = []
        clean.reserveCapacity(pts.count)
        for p in pts where clean.last.map({ $0.distanceSquared(to: p) > 1e-12 }) ?? true {
            clean.append(p)
        }
        if clean.count < 2 {
            let p = clean.first ?? .zero
            clean = [p, p + Vector2(1e-3, 0)]
        }
        points = clean
        var cum: [Double] = [0]
        cum.reserveCapacity(clean.count)
        for i in 1..<clean.count {
            cum.append(cum[i - 1] + clean[i].distance(to: clean[i - 1]))
        }
        cumulative = cum
        var tans: [Vector2] = []
        tans.reserveCapacity(clean.count)
        for i in 0..<clean.count {
            if i == 0 {
                tans.append((clean[1] - clean[0]).normalized)
            } else if i == clean.count - 1 {
                tans.append((clean[i] - clean[i - 1]).normalized)
            } else {
                let a = (clean[i] - clean[i - 1]).normalized
                let b = (clean[i + 1] - clean[i]).normalized
                let m = (a + b).normalized
                tans.append(m == .zero ? b : m)
            }
        }
        tangents = tans
    }

    public init(from a: Vector2, to b: Vector2) { self.init([a, b]) }

    public var length: Double { cumulative[cumulative.count - 1] }
    public var start: Vector2 { points[0] }
    public var end: Vector2 { points[points.count - 1] }
    public var startTangent: Vector2 { tangents[0] }
    public var endTangent: Vector2 { tangents[tangents.count - 1] }

    /// Segment index `i` and fraction `t` such that `s` lies between point i and i+1.
    @inline(__always)
    public func locate(_ s: Double) -> (index: Int, t: Double) {
        let n = cumulative.count
        if s <= 0 { return (0, 0) }
        if s >= cumulative[n - 1] { return (n - 2, 1) }
        var lo = 0
        var hi = n - 1
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        return (lo, segLen > 1e-12 ? (s - cumulative[lo]) / segLen : 0)
    }

    public func point(at s: Double) -> Vector2 {
        let (i, t) = locate(s)
        return points[i].lerp(to: points[i + 1], t)
    }

    /// Smoothly interpolated unit tangent at `s`.
    public func tangent(at s: Double) -> Vector2 {
        let (i, t) = locate(s)
        let v = tangents[i].lerp(to: tangents[i + 1], t).normalized
        return v == .zero ? (points[i + 1] - points[i]).normalized : v
    }

    /// Unit normal pointing to the left of travel.
    public func leftNormal(at s: Double) -> Vector2 { tangent(at: s).perpendicular }

    /// Position offset laterally by `lateral` metres (positive = left of travel).
    public func position(at s: Double, lateral: Double) -> Vector2 {
        let (i, t) = locate(s)
        let p = points[i].lerp(to: points[i + 1], t)
        if lateral == 0 { return p }
        var tan = tangents[i].lerp(to: tangents[i + 1], t).normalized
        if tan == .zero { tan = (points[i + 1] - points[i]).normalized }
        return p + tan.perpendicular * lateral
    }

    /// Extrapolating position: beyond the ends, continues along the end tangent.
    public func extendedPoint(at s: Double, lateral: Double = 0) -> Vector2 {
        if s < 0 { return position(at: 0, lateral: lateral) + startTangent * s }
        if s > length { return position(at: length, lateral: lateral) + endTangent * (s - length) }
        return position(at: s, lateral: lateral)
    }

    /// A polyline offset laterally (positive = left). Uses the smooth normals.
    public func offset(by lateral: Double) -> Polyline {
        guard lateral != 0 else { return self }
        var out: [Vector2] = []
        out.reserveCapacity(points.count)
        for i in 0..<points.count {
            // Scale the bisector normal so straight edges stay parallel at joins.
            let n = tangents[i].perpendicular
            var scale = 1.0
            if i > 0 && i < points.count - 1 {
                let segN = (points[i + 1] - points[i]).normalized.perpendicular
                let c = n.dot(segN)
                if c > 0.5 { scale = 1.0 / c }
            }
            out.append(points[i] + n * (lateral * scale))
        }
        return Polyline(out)
    }

    /// Variable offset: lateral(s) sampled at every vertex.
    public func offset(_ lateral: (Double) -> Double) -> Polyline {
        var out: [Vector2] = []
        out.reserveCapacity(points.count)
        for i in 0..<points.count {
            out.append(points[i] + tangents[i].perpendicular * lateral(cumulative[i]))
        }
        return Polyline(out)
    }

    public func reversed() -> Polyline { Polyline(points.reversed()) }

    /// Sub-polyline between arc lengths s0 < s1.
    public func slice(from s0: Double, to s1: Double) -> Polyline {
        let a = s0.clamped(to: 0...length)
        let b = s1.clamped(to: a...length)
        var pts: [Vector2] = [point(at: a)]
        for i in 0..<points.count where cumulative[i] > a + 1e-9 && cumulative[i] < b - 1e-9 {
            pts.append(points[i])
        }
        pts.append(point(at: b))
        return Polyline(pts)
    }

    /// Re-sample at approximately uniform spacing (keeps both ends).
    public func resampled(spacing: Double) -> Polyline {
        let n = max(1, Int((length / max(spacing, 0.05)).rounded(.up)))
        var pts: [Vector2] = []
        pts.reserveCapacity(n + 1)
        for k in 0...n { pts.append(point(at: length * Double(k) / Double(n))) }
        return Polyline(pts)
    }

    /// Closest point on the polyline to `p`.
    public func project(_ p: Vector2) -> (s: Double, distance: Double, lateral: Double) {
        var bestS = 0.0
        var bestD2 = Double.greatestFiniteMagnitude
        var bestLat = 0.0
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let ab = b - a
            let len2 = ab.lengthSquared
            let t = len2 > 1e-12 ? ((p - a).dot(ab) / len2).clamped(to: 0...1) : 0
            let q = a + ab * t
            let d2 = q.distanceSquared(to: p)
            if d2 < bestD2 {
                bestD2 = d2
                bestS = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t
                bestLat = ab.cross(p - a) >= 0 ? d2.squareRoot() : -d2.squareRoot()
            }
        }
        return (bestS, bestD2.squareRoot(), bestLat)
    }

    /// Smallest radius of curvature along the line (∞ for a straight line),
    /// estimated from turning angle per unit length at each interior vertex.
    public var minimumRadius: Double {
        var minR = Double.infinity
        guard points.count > 2 else { return minR }
        for i in 1..<(points.count - 1) {
            let a = (points[i] - points[i - 1]).normalized
            let b = (points[i + 1] - points[i]).normalized
            let turn = abs(DMath.atan2(a.cross(b), a.dot(b)))
            if turn < 1e-6 { continue }
            let span = 0.5 * (cumulative[i + 1] - cumulative[i - 1])
            minR = min(minR, span / turn)
        }
        return minR
    }

    /// Total signed heading change from start to end (positive = left/CCW).
    public var totalTurn: Double {
        DMath.angleDifference(startTangent.angle, endTangent.angle)
    }

    public var bounds: (min: Vector2, max: Vector2) {
        var lo = points[0], hi = points[0]
        for p in points {
            lo = Vector2(min(lo.x, p.x), min(lo.y, p.y))
            hi = Vector2(max(hi.x, p.x), max(hi.y, p.y))
        }
        return (lo, hi)
    }
}
