//
//  Outskirts.swift
//  TrafficEngine
//
//  The countryside around the map, so the town doesn't stop at a hard edge:
//  the regional roads carry on out to the horizon, between fields, woods and
//  the odd farmstead. Scenery only — nothing here is simulated — but it is
//  generated here (deterministically, from the map) so it is testable and the
//  same every time.
//

public struct Outskirts: Sendable, Equatable {
    public enum FieldKind: Int, Sendable, CaseIterable { case pasture, crop, stubble, wood }

    public struct Field: Sendable, Equatable {
        public var kind: FieldKind
        /// CCW quad in world metres.
        public var polygon: [Vector2]
    }

    /// A road continuing off the map from a regional connection.
    public struct Road: Sendable, Equatable {
        /// From the map edge outwards.
        public var line: Polyline
        public var halfWidth: Double
        public var lanesEachWay: Int
        public var isHighway: Bool
    }

    public struct Farm: Sendable, Equatable {
        public var center: Vector2
        public var rotation: Double
        public var width: Double
        public var depth: Double
    }

    public var fields: [Field] = []
    public var roads: [Road] = []
    public var farms: [Farm] = []
    /// The map's own extent (the countryside lies outside it).
    public var inner: (min: Vector2, max: Vector2) = (.zero, .zero)

    public static func == (a: Outskirts, b: Outskirts) -> Bool {
        a.fields == b.fields && a.roads == b.roads && a.farms == b.farms && a.inner.min == b.inner.min && a.inner.max == b.inner.max
    }
}

extension Simulation {

    /// The countryside within `margin` metres around the map.
    public func outskirts(margin: Double) -> Outskirts {
        var out = Outskirts()
        // The map: the terrain's bounds, grown to take in every road.
        var lo = terrain.minCorner, hi = terrain.maxCorner
        for n in network.allNodes {
            lo = Vector2(min(lo.x, n.position.x), min(lo.y, n.position.y))
            hi = Vector2(max(hi.x, n.position.x), max(hi.y, n.position.y))
        }
        out.inner = (lo, hi)
        let outerLo = lo - Vector2(margin, margin), outerHi = hi + Vector2(margin, margin)
        var rng = SeededRandom(seed: SeededRandom.mix(UInt64(bitPattern: Int64((hi.x - lo.x) * 7 + (hi.y - lo.y) * 13))))

        // Roads: each regional connection carries on outwards, straight at
        // first, then wandering gently, until well past the margin.
        for node in network.allNodes where node.isRegionalConnection {
            guard let e = (network.incoming(node.id).first ?? network.outgoing(node.id).first).flatMap({ network.edge($0) }),
                  let road = network.road(e.road) else { continue }
            let inward = e.to == node.id ? -e.reference.endTangent : e.reference.startTangent
            var dir = -inward
            var p = node.position
            var pts = [p]
            var travelled = 0.0
            while travelled < margin * 1.6 {
                let step = 40.0
                if travelled > 160 {
                    let wander = rng.nextDouble(in: -0.06..<0.06)
                    dir = Vector2.unit(angle: dir.angle + wander)
                    // Never turn back towards the map.
                    if dir.dot(-inward) < 0.6 { dir = Vector2.unit(angle: (-inward).angle + (wander > 0 ? 0.9 : -0.9)) }
                }
                p = p + dir * step
                pts.append(p)
                travelled += step
            }
            let lanes = max(road.lanesForward, road.lanesBackward)
            let half = Double(road.lanesForward + road.lanesBackward) * road.roadClass.laneWidth / 2
                + road.roadClass.medianWidth / 2 + road.roadClass.shoulderWidth
            out.roads.append(Outskirts.Road(line: Polyline(pts), halfWidth: half, lanesEachWay: lanes,
                                            isHighway: road.roadClass == .highway))
        }

        // Fields: a jittered patchwork filling the band around the map, with
        // hedgerow gaps between them, clear of the roads.
        let cw = 190.0, ch = 140.0
        func nearRoad(_ c: Vector2, _ reach: Double) -> Bool {
            out.roads.contains { r in r.line.project(c).distance < reach + r.halfWidth }
        }
        var y = outerLo.y
        while y < outerHi.y {
            var x = outerLo.x
            let rowH = ch * rng.nextDouble(in: 0.8..<1.2)
            while x < outerHi.x {
                let colW = cw * rng.nextDouble(in: 0.7..<1.3)
                let c = Vector2(x + colW / 2, y + rowH / 2)
                defer { x += colW }
                // Outside the map (with a little room at its edge).
                if c.x > lo.x - 20 && c.x < hi.x + 20 && c.y > lo.y - 20 && c.y < hi.y + 20 { continue }
                let r = rng.nextUnit()
                let kind: Outskirts.FieldKind = r < 0.38 ? .pasture : r < 0.68 ? .crop : r < 0.84 ? .stubble : .wood
                var quad = [Vector2(x + 3, y + 3), Vector2(x + colW - 3, y + 3), Vector2(x + colW - 3, y + rowH - 3), Vector2(x + 3, y + rowH - 3)]
                // Not inside the map.
                quad = quad.map { q in
                    var q = q
                    if q.x > lo.x && q.x < hi.x && q.y > lo.y && q.y < hi.y {
                        // Push the corner out to the nearest map edge.
                        let dx = min(q.x - lo.x, hi.x - q.x), dy = min(q.y - lo.y, hi.y - q.y)
                        if dx < dy { q.x = q.x - lo.x < hi.x - q.x ? lo.x - 3 : hi.x + 3 } else { q.y = q.y - lo.y < hi.y - q.y ? lo.y - 3 : hi.y + 3 }
                    }
                    return q
                }
                // Fields stop at the roads: split nothing, just leave the
                // patch beside a road as verge.
                if nearRoad(c, max(colW, rowH) / 2 + 6) { continue }
                out.fields.append(Outskirts.Field(kind: kind, polygon: quad))
            }
            y += rowH
        }

        // Farmsteads: a house and a barn beside the roads now and then.
        for r in out.roads {
            var s = 260.0 + rng.nextDouble(in: 0..<200)
            while s < r.line.length - 100 {
                let side: Double = rng.chance(0.5) ? 1 : -1
                let t = r.line.tangent(at: s)
                let base = r.line.position(at: s, lateral: side * (r.halfWidth + 22))
                let face = (t.perpendicular * -side).angle
                out.farms.append(Outskirts.Farm(center: base, rotation: face, width: 12, depth: 9))
                out.farms.append(Outskirts.Farm(center: base + t * 20 + t.perpendicular * side * 10,
                                                rotation: face, width: 16, depth: 12))
                s += 380 + rng.nextDouble(in: 0..<420)
            }
        }
        return out
    }
}
