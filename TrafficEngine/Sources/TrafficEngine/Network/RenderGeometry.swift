//
//  RenderGeometry.swift
//  TrafficEngine
//
//  Renderer-agnostic drawing data for the static network: paved surfaces,
//  medians, lane markings, stop bars and lane-use arrows. Both the app's
//  SpriteKit renderer and the CLI's SVG dump draw exactly this, so what the
//  CLI shows on Linux is what the app shows on device.
//
//  Built per road and per junction so editors can rebuild incrementally.
//

public enum MarkingKind: String, Codable, Sendable {
    /// Dashed line between lanes travelling the same way.
    case laneDash
    /// Solid line between lanes where changing is prohibited (approach to stop line).
    case laneSolid
    /// Centre line of a two-way road without a median (drawn doubled).
    case centreDouble
    /// Solid line along the edge of the carriageway (kerb lane / shoulder boundary).
    case edgeLine
    /// Stop bar across an approach (stop sign, signal).
    case stopBar
    /// Dashed give-way line (yield, roundabout entry).
    case yieldLine
}

public struct Marking: Sendable {
    public var kind: MarkingKind
    public var points: [Vector2]
    public var width: Double
}

public struct LaneArrow: Sendable {
    public var position: Vector2
    public var heading: Double
    public var movements: [TurnDirection]
}

public struct RoadSurface: Sendable {
    public var road: RoadID
    public var roadClass: RoadClass
    public var polygon: [Vector2]
    /// Centre line of the paved road (for rounded-stroke renderers).
    public var centreline: [Vector2]
    public var isBridge: Bool
    public var level: Int
}

public struct RoadRenderData: Sendable {
    public var surface: RoadSurface
    public var medians: [[Vector2]]
    public var markings: [Marking]
    public var arrows: [LaneArrow]
}

public struct JunctionRenderData: Sendable {
    public var node: NodeID
    public var polygon: [Vector2]
    public var markings: [Marking]
    public var control: ControlType
    public var level: Int
}

public struct RoundaboutRenderData: Sendable {
    public var center: Vector2
    /// Paved circulating carriageway (outer ring, CCW) and the central island.
    public var outer: [Vector2]
    public var island: [Vector2]
}

public enum RenderGeometryBuilder {

    public static func roundabouts(_ net: RoadNetwork) -> [RoundaboutRenderData] {
        net.allRoundabouts.map { r in
            let hw = (net.road(r.ringRoads.first ?? RoadID(-1))?.roadClass ?? .collector)
            let laneHalf = hw.laneWidth / 2 + hw.shoulderWidth * 0.6
            func circle(_ radius: Double) -> [Vector2] {
                (0..<48).map { r.center + Vector2.unit(angle: DMath.twoPi * Double($0) / 48) * radius }
            }
            return RoundaboutRenderData(center: r.center, outer: circle(r.radius + laneHalf),
                                        island: circle(max(2, r.radius - laneHalf)))
        }
    }

    public static func road(_ id: RoadID, in net: RoadNetwork) -> RoadRenderData? {
        guard let road = net.road(id) else { return nil }
        let fwd = net.edge(EdgeID(road: id, forward: true))
        let bwd = net.edge(EdgeID(road: id, forward: false))
        guard let base = fwd ?? bwd else { return nil }
        // Work in the A→B frame using the forward reference (or the reversed backward one).
        let ref = fwd?.reference ?? base.reference.reversed()
        let len = ref.length
        let cls = road.roadClass
        let shoulder = cls.shoulderWidth

        // Lateral extent of each edge's lanes at s (A→B frame), with tapers.
        func extent(of e: Edge?, forwardFrame: Bool, at sAB: Double) -> (lo: Double, hi: Double)? {
            guard let e else { return nil }
            let s = forwardFrame ? sAB : e.length - sAB
            let travel = e.lanes.filter { $0.kind == .travel }
            let centre = travel.isEmpty ? 0 : travel.reduce(0) { $0 + $1.lateral } / Double(travel.count)
            var lo = Double.infinity, hi = -Double.infinity
            for l in e.lanes {
                let f = taperFactor(l, s)
                guard f > 0 else { continue }
                // An auxiliary lane opens outward from its travel-lane neighbour.
                let dir: Double = l.kind == .travel ? 0 : (l.lateral >= centre ? 1 : -1)
                let inner = l.lateral - dir * l.width / 2
                let a = dir == 0 ? l.lateral - l.width / 2 : inner
                let b = dir == 0 ? l.lateral + l.width / 2 : inner + dir * l.width * f
                let (x0, x1) = forwardFrame ? (min(a, b), max(a, b)) : (-max(a, b), -min(a, b))
                lo = min(lo, x0)
                hi = max(hi, x1)
            }
            return lo.isFinite ? (lo, hi) : nil
        }

        let samples = sampleStations(len: len, edges: [fwd, bwd].compactMap { $0 })
        var left: [Vector2] = []
        var right: [Vector2] = []
        for s in samples {
            var lo = Double.infinity, hi = -Double.infinity
            if let x = extent(of: fwd, forwardFrame: true, at: s) { lo = min(lo, x.lo); hi = max(hi, x.hi) }
            if let x = extent(of: bwd, forwardFrame: false, at: s) { lo = min(lo, x.lo); hi = max(hi, x.hi) }
            if !lo.isFinite { lo = -1; hi = 1 }
            left.append(ref.position(at: s, lateral: hi + shoulder))
            right.append(ref.position(at: s, lateral: lo - shoulder))
        }
        let polygon = right + left.reversed()
        let surface = RoadSurface(road: id, roadClass: cls, polygon: polygon,
                                  centreline: samples.map { ref.point(at: $0) },
                                  isBridge: road.isBridge, level: road.level)

        var markings: [Marking] = []
        var arrows: [LaneArrow] = []
        for e in [fwd, bwd].compactMap({ $0 }) {
            markings.append(contentsOf: laneMarkings(e))
            arrows.append(contentsOf: laneArrows(e, net: net))
        }
        // Centre line or median.
        var medians: [[Vector2]] = []
        if !road.isOneWay, let f = fwd {
            if cls.medianWidth >= 1.0 {
                medians = medianIslands(road: road, fwd: f, bwd: bwd, ref: ref)
            } else {
                let pts = samples.map { ref.point(at: $0) }
                markings.append(Marking(kind: .centreDouble, points: pts, width: 0.12))
            }
        }
        return RoadRenderData(surface: surface, medians: medians, markings: markings, arrows: arrows)
    }

    public static func junction(_ id: NodeID, in net: RoadNetwork) -> JunctionRenderData? {
        guard let g = net.geometry(of: id), let node = net.node(id) else { return nil }
        var markings: [Marking] = []
        let control = node.effectiveControl
        for e in net.incoming(id) {
            guard let edge = net.edge(e) else { continue }
            let kind: MarkingKind?
            switch control {
            case .signal, .allWayStop: kind = .stopBar
            case .twoWayStop: kind = net.isMajorApproach(e, at: id) ? nil : .stopBar
            case .yield, .roundabout: kind = net.isMajorApproach(e, at: id) ? nil : .yieldLine
            default: kind = nil
            }
            guard let k = kind else { continue }
            let lanes = edge.lanesAtEnd
            guard let lo = lanes.map({ $0.lateral - $0.width / 2 }).min(),
                  let hi = lanes.map({ $0.lateral + $0.width / 2 }).max() else { continue }
            let s = edge.length - 0.4
            markings.append(Marking(kind: k, points: [edge.position(s: s, lateral: lo + 0.1),
                                                      edge.position(s: s, lateral: hi - 0.1)],
                                    width: k == .stopBar ? 0.5 : 0.35))
        }
        return JunctionRenderData(node: id, polygon: g.surface, markings: markings, control: control, level: node.level)
    }

    public static func all(_ net: RoadNetwork) -> (roads: [RoadRenderData], junctions: [JunctionRenderData]) {
        let roads = net.allRoads.compactMap { road($0.id, in: net) }
        let junctions = net.allNodes.compactMap { junction($0.id, in: net) }
        return (roads, junctions)
    }

    // MARK: - Helpers

    static func taperFactor(_ l: Lane, _ s: Double) -> Double {
        if s < l.taperStart || s > l.taperEnd { return 0 }
        if s < l.sStart { return l.sStart - l.taperStart > 1e-6 ? (s - l.taperStart) / (l.sStart - l.taperStart) : 1 }
        if s > l.sEnd { return l.taperEnd - l.sEnd > 1e-6 ? 1 - (s - l.sEnd) / (l.taperEnd - l.sEnd) : 1 }
        return 1
    }

    static func sampleStations(len: Double, edges: [Edge]) -> [Double] {
        var st: Set<Double> = [0, len]
        let n = max(1, Int((len / 3).rounded(.up)))
        for k in 0...n { st.insert(len * Double(k) / Double(n)) }
        for e in edges {
            for l in e.lanes where l.kind != .travel {
                for v in [l.taperStart, l.sStart, l.sEnd, l.taperEnd] {
                    let sAB = e.id.isForward ? v : e.length - v
                    if sAB > 0 && sAB < len { st.insert(sAB) }
                }
            }
        }
        return st.sorted()
    }

    static func laneMarkings(_ e: Edge) -> [Marking] {
        var out: [Marking] = []
        let lanes = e.lanes
        // Boundaries between laterally adjacent lanes.
        for i in 0..<lanes.count {
            for j in (i + 1)..<lanes.count {
                let a = lanes[i], b = lanes[j]
                guard abs(abs(a.lateral - b.lateral) - a.width) < 0.05 else { continue }
                let s0 = max(a.sStart, b.sStart), s1 = min(a.sEnd, b.sEnd)
                guard s1 - s0 > 2 else { continue }
                let lat = (a.lateral + b.lateral) / 2
                let solidFrom = max(s0, e.length - e.roadClass.noLaneChangeZone)
                if solidFrom - s0 > 2 {
                    out.append(Marking(kind: .laneDash, points: sampleLine(e, lat, s0, solidFrom), width: 0.12))
                }
                if s1 - solidFrom > 0.5 && a.kind == .travel && b.kind == .travel && s1 >= e.length - 0.1 {
                    out.append(Marking(kind: .laneSolid, points: sampleLine(e, lat, solidFrom, s1), width: 0.12))
                } else if s1 - solidFrom > 0.5 {
                    out.append(Marking(kind: .laneDash, points: sampleLine(e, lat, solidFrom, s1), width: 0.12))
                }
            }
        }
        // Kerb edge line along the kerb-most travel lane.
        if let kerb = lanes.first(where: { $0.kind == .travel }) {
            let lat = kerb.lateral + (kerb.lateral < 0 ? -kerb.width / 2 : kerb.width / 2)
            out.append(Marking(kind: .edgeLine, points: sampleLine(e, lat, 0, e.length), width: 0.12))
        }
        return out
    }

    static func sampleLine(_ e: Edge, _ lat: Double, _ s0: Double, _ s1: Double) -> [Vector2] {
        let n = max(1, Int(((s1 - s0) / 3).rounded(.up)))
        return (0...n).map { e.position(s: s0 + (s1 - s0) * Double($0) / Double(n), lateral: lat) }
    }

    static func laneArrows(_ e: Edge, net: RoadNetwork) -> [LaneArrow] {
        guard let node = net.geometry(of: e.to), node.degree >= 3, e.length > 25 else { return [] }
        let s = e.length - 9
        let heading = e.reference.tangent(at: s).angle
        return e.lanesAtEnd.compactMap { l in
            guard !l.movements.isEmpty, l.exists(at: s) else { return nil }
            let order: [TurnDirection] = [.left, .straight, .right, .uTurn]
            return LaneArrow(position: e.position(s: s, lateral: l.lateral), heading: heading,
                             movements: order.filter { l.movements.contains($0) })
        }
    }

    /// Raised median islands between the carriageways, cut back where turn
    /// pockets occupy the median.
    static func medianIslands(road: Road, fwd: Edge, bwd: Edge?, ref: Polyline) -> [[Vector2]] {
        let len = ref.length
        let half = road.roadClass.medianWidth / 2 - 0.25
        guard half > 0.2 else { return [] }
        var lo = 2.0, hi = len - 2.0
        if let p = fwd.lanes.first(where: { $0.kind == .acrossPocket }) { hi = min(hi, p.taperStart) }
        if let b = bwd, let p = b.lanes.first(where: { $0.kind == .acrossPocket }) { lo = max(lo, b.length - p.taperStart) }
        guard hi - lo > 4 else { return [] }
        let n = max(2, Int(((hi - lo) / 3).rounded(.up)))
        var l: [Vector2] = [], r: [Vector2] = []
        for k in 0...n {
            let s = lo + (hi - lo) * Double(k) / Double(n)
            // Taper the nose of the island.
            let taper = min(1, min(s - lo, hi - s) / 6)
            let w = max(0.15, half * taper)
            l.append(ref.position(at: s, lateral: w))
            r.append(ref.position(at: s, lateral: -w))
        }
        return [r + l.reversed()]
    }
}
