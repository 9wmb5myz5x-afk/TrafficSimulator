//
//  Geometry.swift
//  TrafficEngine
//
//  Geometric predicates: segment distances, oriented boxes (vehicle
//  footprints) and polygons.
//

public enum Geometry {

    /// Squared distance from point p to segment ab.
    public static func pointSegmentDistanceSquared(_ p: Vector2, _ a: Vector2, _ b: Vector2) -> Double {
        let ab = b - a
        let len2 = ab.lengthSquared
        let t = len2 > 1e-12 ? ((p - a).dot(ab) / len2).clamped(to: 0...1) : 0
        return (a + ab * t).distanceSquared(to: p)
    }

    /// Do segments p1–p2 and p3–p4 properly intersect?
    public static func segmentsIntersect(_ p1: Vector2, _ p2: Vector2, _ p3: Vector2, _ p4: Vector2) -> Bool {
        let d1 = (p4 - p3).cross(p1 - p3)
        let d2 = (p4 - p3).cross(p2 - p3)
        let d3 = (p2 - p1).cross(p3 - p1)
        let d4 = (p2 - p1).cross(p4 - p1)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Minimum distance between segments ab and cd.
    public static func segmentDistance(_ a: Vector2, _ b: Vector2, _ c: Vector2, _ d: Vector2) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        let m = min(min(pointSegmentDistanceSquared(a, c, d), pointSegmentDistanceSquared(b, c, d)),
                    min(pointSegmentDistanceSquared(c, a, b), pointSegmentDistanceSquared(d, a, b)))
        return m.squareRoot()
    }

    /// Does any segment of polyline a properly cross any segment of b?
    public static func polylinesCross(_ a: Polyline, _ b: Polyline) -> Bool {
        let pa = a.points, pb = b.points
        for i in 0..<(pa.count - 1) {
            for j in 0..<(pb.count - 1) where segmentsIntersect(pa[i], pa[i + 1], pb[j], pb[j + 1]) {
                return true
            }
        }
        return false
    }

    /// Ray-casting point-in-polygon test.
    public static func pointInPolygon(_ p: Vector2, _ poly: [Vector2]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Convex hull (Andrew's monotone chain), counter-clockwise.
    public static func convexHull(_ input: [Vector2]) -> [Vector2] {
        let pts = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }
        var lower: [Vector2] = []
        for p in pts {
            while lower.count >= 2 && (lower[lower.count - 1] - lower[lower.count - 2]).cross(p - lower[lower.count - 2]) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Vector2] = []
        for p in pts.reversed() {
            while upper.count >= 2 && (upper[upper.count - 1] - upper[upper.count - 2]).cross(p - upper[upper.count - 2]) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Signed area (positive = counter-clockwise).
    public static func signedArea(_ poly: [Vector2]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var a = 0.0
        var j = poly.count - 1
        for i in 0..<poly.count {
            a += poly[j].cross(poly[i])
            j = i
        }
        return a * 0.5
    }
}

/// An oriented bounding box: a vehicle footprint.
public struct OrientedBox: Sendable, Equatable {
    public var center: Vector2
    /// Unit vector along the box's length.
    public var axis: Vector2
    public var halfLength: Double
    public var halfWidth: Double

    public init(center: Vector2, axis: Vector2, halfLength: Double, halfWidth: Double) {
        self.center = center
        self.axis = axis
        self.halfLength = halfLength
        self.halfWidth = halfWidth
    }

    public var corners: [Vector2] {
        let l = axis * halfLength
        let w = axis.perpendicular * halfWidth
        return [center + l + w, center - l + w, center - l - w, center + l - w]
    }

    /// Bounding-circle radius.
    public var radius: Double { (halfLength * halfLength + halfWidth * halfWidth).squareRoot() }

    /// Separating-axis overlap test. `margin` shrinks both boxes (positive) or
    /// grows them (negative) along every axis.
    public func overlaps(_ o: OrientedBox, margin: Double = 0) -> Bool {
        let d = o.center - center
        let rsum = radius + o.radius
        if d.lengthSquared > rsum * rsum { return false }
        let axes = [axis, axis.perpendicular, o.axis, o.axis.perpendicular]
        for n in axes {
            let ra = halfLength * abs(axis.dot(n)) + halfWidth * abs(axis.perpendicular.dot(n))
            let rb = o.halfLength * abs(o.axis.dot(n)) + o.halfWidth * abs(o.axis.perpendicular.dot(n))
            if abs(d.dot(n)) >= ra + rb - 2 * margin { return false }
        }
        return true
    }
}
