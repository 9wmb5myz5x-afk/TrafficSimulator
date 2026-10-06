//
//  Terrain.swift
//  TrafficEngine
//
//  Static land cover: water bodies (which roads must bridge), parks, beaches
//  and map labels. Deterministic from a seed; stored in saves.
//

public struct TerrainFeature: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case water, park, beach }
    public var kind: Kind
    /// CCW polygon in world metres.
    public var polygon: [Vector2]
    public init(kind: Kind, polygon: [Vector2]) {
        self.kind = kind
        self.polygon = polygon
    }
}

public struct MapLabel: Codable, Sendable, Equatable {
    public var text: String
    public var position: Vector2
    public var isWater: Bool
    public init(text: String, position: Vector2, isWater: Bool = false) {
        self.text = text
        self.position = position
        self.isWater = isWater
    }
}

public struct Terrain: Codable, Sendable, Equatable {
    public var features: [TerrainFeature] = []
    public var labels: [MapLabel] = []
    /// Playable world bounds.
    public var minCorner = Vector2(-1000, -1000)
    public var maxCorner = Vector2(1000, 1000)
    public init() {}

    public func isWater(_ p: Vector2) -> Bool {
        features.contains { $0.kind == .water && Geometry.pointInPolygon(p, $0.polygon) }
    }

    /// Fraction of samples along a polyline that lie on water.
    public func waterFraction(of line: Polyline) -> Double {
        let n = max(2, Int(line.length / 5))
        var wet = 0
        for k in 0...n where isWater(line.point(at: line.length * Double(k) / Double(n))) { wet += 1 }
        return Double(wet) / Double(n + 1)
    }

    public func contains(_ p: Vector2) -> Bool {
        p.x >= minCorner.x && p.y >= minCorner.y && p.x <= maxCorner.x && p.y <= maxCorner.y
    }

    /// A meandering river band between two points.
    public static func river(from a: Vector2, to b: Vector2, width: Double, wiggle: Double, seed: UInt64) -> TerrainFeature {
        var rng = SeededRandom(seed: seed)
        let dir = (b - a).normalized
        let n = dir.perpendicular
        let len = a.distance(to: b)
        let steps = max(4, Int(len / 40))
        var centre: [Vector2] = []
        var phase = rng.nextUnit() * DMath.twoPi
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            phase += 0.35 + 0.2 * rng.nextUnit()
            centre.append(a + dir * (len * t) + n * (wiggle * DMath.sin(phase)))
        }
        let line = Polyline(Curves.catmullRom(through: centre, maxSpacing: 8))
        var left: [Vector2] = [], right: [Vector2] = []
        for k in 0...Int(line.length / 8) {
            let s = Double(k) * 8
            let w = width / 2 * (1 + 0.15 * DMath.sin(s / 60))
            left.append(line.position(at: s, lateral: w))
            right.append(line.position(at: s, lateral: -w))
        }
        return TerrainFeature(kind: .water, polygon: right + left.reversed())
    }

    /// A soft blob (lake / park) polygon.
    public static func blob(center: Vector2, radius: Double, kind: TerrainFeature.Kind, seed: UInt64) -> TerrainFeature {
        var rng = SeededRandom(seed: seed)
        var pts: [Vector2] = []
        let k1 = rng.nextUnit() * DMath.twoPi, k2 = rng.nextUnit() * DMath.twoPi
        for i in 0..<40 {
            let a = DMath.twoPi * Double(i) / 40
            let r = radius * (1 + 0.12 * DMath.sin(2 * a + k1) + 0.08 * DMath.sin(3 * a + k2))
            pts.append(center + Vector2.unit(angle: a) * r)
        }
        return TerrainFeature(kind: kind, polygon: pts)
    }
}
