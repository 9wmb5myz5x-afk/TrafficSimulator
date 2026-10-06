//
//  Vector2.swift
//  TrafficEngine
//
//  A tiny, dependency-free 2D vector in world metres. The engine avoids
//  CoreGraphics/simd so it compiles and behaves identically on Linux.
//  World axes: +x east, +y north (counter-clockwise angles).
//

public struct Vector2: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    @inlinable
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vector2(0, 0)

    @inlinable public static func + (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Vector2, b: Vector2) -> Vector2 { Vector2(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (a: Vector2, s: Double) -> Vector2 { Vector2(a.x * s, a.y * s) }
    @inlinable public static func * (s: Double, a: Vector2) -> Vector2 { Vector2(a.x * s, a.y * s) }
    @inlinable public static func / (a: Vector2, s: Double) -> Vector2 { Vector2(a.x / s, a.y / s) }
    @inlinable public static prefix func - (a: Vector2) -> Vector2 { Vector2(-a.x, -a.y) }
    @inlinable public static func += (a: inout Vector2, b: Vector2) { a = a + b }
    @inlinable public static func -= (a: inout Vector2, b: Vector2) { a = a - b }

    @inlinable public var length: Double { (x * x + y * y).squareRoot() }
    @inlinable public var lengthSquared: Double { x * x + y * y }

    /// Unit vector in the same direction, or `.zero` for a zero-length vector.
    @inlinable public var normalized: Vector2 {
        let len = length
        return len > 1e-12 ? Vector2(x / len, y / len) : .zero
    }

    /// Perpendicular rotated +90° (to the *left* of the direction of travel).
    @inlinable public var perpendicular: Vector2 { Vector2(-y, x) }

    @inlinable public func dot(_ o: Vector2) -> Double { x * o.x + y * o.y }
    /// z-component of the 3D cross product (positive when `o` is CCW of self).
    @inlinable public func cross(_ o: Vector2) -> Double { x * o.y - y * o.x }
    @inlinable public func distance(to o: Vector2) -> Double { (self - o).length }
    @inlinable public func distanceSquared(to o: Vector2) -> Double { (self - o).lengthSquared }

    @inlinable public func lerp(to o: Vector2, _ t: Double) -> Vector2 {
        Vector2(x + (o.x - x) * t, y + (o.y - y) * t)
    }

    /// Heading angle in radians from +x, in (-π, π].
    public var angle: Double { DMath.atan2(y, x) }

    public static func unit(angle: Double) -> Vector2 { Vector2(DMath.cos(angle), DMath.sin(angle)) }

    public func rotated(by a: Double) -> Vector2 {
        let c = DMath.cos(a), s = DMath.sin(a)
        return Vector2(x * c - y * s, x * s + y * c)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public var description: String { "(\(x), \(y))" }
}
