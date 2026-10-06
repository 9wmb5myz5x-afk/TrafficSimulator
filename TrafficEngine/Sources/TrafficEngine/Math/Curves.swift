//
//  Curves.swift
//  TrafficEngine
//
//  Curve construction: centripetal Catmull–Rom splines for freehand roads and
//  cubic Béziers for turn paths through junctions. Both are sampled into
//  `Polyline`s, which are then arc-length parameterised.
//

public enum Curves {

    /// Sample a cubic Bézier into points (inclusive of both ends).
    public static func cubic(_ p0: Vector2, _ p1: Vector2, _ p2: Vector2, _ p3: Vector2, segments: Int) -> [Vector2] {
        let n = max(2, segments)
        var pts: [Vector2] = []
        pts.reserveCapacity(n + 1)
        for k in 0...n {
            let t = Double(k) / Double(n)
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            pts.append(Vector2(a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                               a * p0.y + b * p1.y + c * p2.y + d * p3.y))
        }
        return pts
    }

    /// Centripetal Catmull–Rom spline (α = 0.5) through `points`, sampled so
    /// that consecutive samples are at most `maxSpacing` apart. Centripetal
    /// parameterisation never forms cusps or self-intersections within a
    /// segment, which matters for player-drawn roads.
    public static func catmullRom(through points: [Vector2], maxSpacing: Double = 4.0) -> [Vector2] {
        guard points.count >= 3 else { return points }
        // Phantom end points by reflection so the curve passes through the ends.
        let first = points[0] * 2 - points[1]
        let last = points[points.count - 1] * 2 - points[points.count - 2]
        let ctrl = [first] + points + [last]
        var out: [Vector2] = [points[0]]
        for i in 1..<(ctrl.count - 2) {
            let p0 = ctrl[i - 1], p1 = ctrl[i], p2 = ctrl[i + 1], p3 = ctrl[i + 2]
            let t0 = 0.0
            let t1 = t0 + max(p0.distance(to: p1), 1e-6).squareRoot()
            let t2 = t1 + max(p1.distance(to: p2), 1e-6).squareRoot()
            let t3 = t2 + max(p2.distance(to: p3), 1e-6).squareRoot()
            let segLen = p1.distance(to: p2)
            let n = max(2, Int((segLen / maxSpacing).rounded(.up)))
            for k in 1...n {
                let t = t1 + (t2 - t1) * Double(k) / Double(n)
                let a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
                let a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
                let a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
                let b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
                let b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
                out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
            }
        }
        return out
    }

    /// Intersection of two rays p + d·a and q + e·b. Returns (a, b) or nil if parallel.
    public static func rayIntersection(_ p: Vector2, _ d: Vector2, _ q: Vector2, _ e: Vector2) -> (Double, Double)? {
        let denom = d.cross(e)
        if abs(denom) < 1e-9 { return nil }
        let w = q - p
        let a = w.cross(e) / denom
        let b = w.cross(d) / denom
        return (a, b)
    }

    /// A smooth turn path from `p0` heading `d0` to `p1` heading `d1`.
    ///
    /// When the two rays meet ahead of both ends at X, the curve uses X as its
    /// control polygon corner (degree-elevated quadratic Bézier). That makes the
    /// path hug the *correct corner*: a near-side (right, for RHT) turn stays
    /// tight to the kerb, and a far-side (left) turn sweeps on its own side of
    /// the junction centre, so opposing far turns do not overlap. Parallel or
    /// diverging rays (through movements, lane shifts, U-turns) use a cubic with
    /// tangent handles proportional to the gap.
    public static func turnPath(from p0: Vector2, heading d0: Vector2, to p1: Vector2, heading d1: Vector2) -> Polyline {
        let chord = p0.distance(to: p1)
        let segments = max(8, Int((chord / 1.5).rounded(.up)))
        let cosAngle = d0.dot(d1)
        if cosAngle < -0.85 {
            // U-turn: semicircle-like cubic.
            let h = 0.75 * chord + 2.0
            return Polyline(cubic(p0, p0 + d0 * h, p1 - d1 * h, p1, segments: segments + 8))
        }
        if let (a, b) = rayIntersection(p0, d0, p1, -d1), a > 0.5, b > 0.5, cosAngle < 0.985 {
            let x = p0 + d0 * a
            let c1 = p0 + (x - p0) * (2.0 / 3.0)
            let c2 = p1 + (x - p1) * (2.0 / 3.0)
            return Polyline(cubic(p0, c1, c2, p1, segments: segments))
        }
        let h = max(chord / 3.0, 0.5)
        return Polyline(cubic(p0, p0 + d0 * h, p1 - d1 * h, p1, segments: segments))
    }
}
