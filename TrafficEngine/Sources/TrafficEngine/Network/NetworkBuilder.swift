//
//  NetworkBuilder.swift
//  TrafficEngine
//
//  Derives all geometry from the authored network, deterministically:
//
//   1. centrelines of every road (Catmull–Rom through its shape points)
//   2. per node: attached road ends sorted by angle, and the turn each
//      approach→exit pair represents
//   3. lane plans per directed edge: travel lanes, across-traffic turn pockets
//      (storage scaled with approach speed), kerb turn lanes, and highway
//      acceleration/deceleration lanes at ramp merges/diverges
//   4. junction setbacks from the approach widths and kerb radii, and the
//      junction surface polygon
//   5. trimmed carriageways (edges) with their lanes
//   6. turn connectors (see ConnectorBuilder.swift)
//

public struct NetworkBuildConfig: Sendable, Equatable {
    /// Taper over which a turn pocket opens [m].
    public var pocketTaper: Double = 15
    /// Storage length of an across-traffic pocket = base + factor · v_limit [m, s].
    public var pocketBase: Double = 25
    public var pocketSpeedFactor: Double = 2.0
    public var pocketMax: Double = 90
    public var pocketMin: Double = 15
    /// Highway acceleration lane length (excluding taper) [m].
    public var accelerationLaneLength: Double = 220
    /// Highway deceleration lane length (excluding taper) [m].
    public var decelerationLaneLength: Double = 180
    public var auxTaper: Double = 60
    /// Comfortable lateral acceleration used for turn speeds [m/s²].
    public var turnLateralAcceleration: Double = 2.8
    /// Minimum stop-line setback at junctions of degree ≥ 3 [m].
    public var minimumSetback: Double = 3.0
    public init() {}
}

struct NetworkBuilder {
    let data: NetworkData
    let config: NetworkBuildConfig
    /// Nodes where only highways and ramps meet (merges / diverges).
    var isFreewayJunction: [Bool] = []
    var side: DrivingSide { data.side }

    struct Result {
        var edges: [Edge?] = []
        var connectors: [Connector] = []
        var nodeGeometry: [NodeGeometry?] = []
        var connectorsFrom: [[[ConnectorID]]] = []
        var connectorsInto: [[ConnectorID]] = []
        var connectorsAtNode: [[ConnectorID]] = []
        var incoming: [[EdgeID]] = []
        var outgoing: [[EdgeID]] = []
        var successors: [[EdgeID]] = []
        var majorApproaches: [Set<EdgeID>] = []
        var effectiveControls: [ControlType] = []
    }

    /// One road attached to a node.
    struct End {
        let road: Road
        let atA: Bool                 // node is the road's `a` end
        let direction: Vector2        // away from the node
        let angle: Double
        /// Edge arriving at the node along this road (nil if none).
        var incoming: EdgeID? {
            if atA { return road.isOneWay ? nil : EdgeID(road: road.id, forward: false) }
            return EdgeID(road: road.id, forward: true)
        }
        /// Edge leaving the node along this road.
        var outgoing: EdgeID? {
            if atA { return EdgeID(road: road.id, forward: true) }
            return road.isOneWay ? nil : EdgeID(road: road.id, forward: false)
        }
    }

    struct LanePlan {
        var travel: Int
        var acrossPocket = false
        var kerbTurn = false
        var accel = false
        var decel = false
    }

    // MARK: - Build

    mutating func build() -> Result {
        var result = Result()
        let nodeCount = data.nodes.count
        let edgeCount = data.roads.count * 2

        // 0. Highway merge/diverge nodes: ramps attach at the kerb-side
        //    auxiliary lane, not at the highway centreline.
        var rampAnchor: [Vector2?] = Array(repeating: nil, count: nodeCount)
        isFreewayJunction = Array(repeating: false, count: nodeCount)
        for case let n? in data.nodes {
            let attached = data.roads.compactMap { $0 }.filter { $0.touches(n.id) }
            guard attached.count >= 3,
                  attached.allSatisfy({ $0.roadClass == .highway || $0.roadClass == .ramp }),
                  let hw = attached.first(where: { $0.roadClass == .highway }),
                  attached.contains(where: { $0.roadClass == .ramp }),
                  let other = node(hw.otherEnd(n.id)) else { continue }
            isFreewayJunction[n.id.raw] = true
            // Direction of travel on the highway at this node.
            var dir = (n.position - other.position).normalized
            if hw.a == n.id { dir = -dir }
            let w = RoadClass.highway.laneWidth
            let lanes = attached.filter { $0.roadClass == .highway }.map { $0.lanesForward }.max() ?? 3
            let shift = w * (Double(lanes - 1) / 2 + 1)
            rampAnchor[n.id.raw] = n.position + dir.perpendicular * (side.kerbSign * shift)
        }

        // 1. Centrelines.
        var centrelines: [Polyline?] = Array(repeating: nil, count: data.roads.count)
        for case let road? in data.roads {
            guard let a = node(road.a), let b = node(road.b) else { continue }
            var pa = a.position, pb = b.position
            if road.roadClass == .ramp {
                if let anchor = rampAnchor[road.a.raw] { pa = anchor }
                if let anchor = rampAnchor[road.b.raw] { pb = anchor }
            }
            let pts = [pa] + road.shape + [pb]
            centrelines[road.id.raw] = pts.count == 2 ? Polyline(pts)
                : Polyline(Curves.catmullRom(through: pts, maxSpacing: 3.0))
        }

        // 2. Ends per node, CCW order.
        var ends: [[End]] = Array(repeating: [], count: nodeCount)
        for case let road? in data.roads {
            guard let line = centrelines[road.id.raw] else { continue }
            let dA = line.startTangent
            let dB = -line.endTangent
            ends[road.a.raw].append(End(road: road, atA: true, direction: dA, angle: dA.angle))
            ends[road.b.raw].append(End(road: road, atA: false, direction: dB, angle: dB.angle))
        }
        for i in 0..<nodeCount {
            ends[i].sort { $0.angle != $1.angle ? $0.angle < $1.angle : $0.road.id.raw < $1.road.id.raw }
        }

        // 3. Effective control.
        result.effectiveControls = Array(repeating: .uncontrolled, count: nodeCount)
        for case let n? in data.nodes {
            result.effectiveControls[n.id.raw] = resolveControl(n, ends: ends[n.id.raw])
        }

        // 4. Turn classification per node: turns[node][(inRoadIndex, outRoadIndex)].
        var turnTables: [TurnTable] = []
        turnTables.reserveCapacity(nodeCount)
        for i in 0..<nodeCount { turnTables.append(TurnTable(ends: ends[i], side: side)) }

        // 5. Lane plans per directed edge.
        var plans: [LanePlan?] = Array(repeating: nil, count: edgeCount)
        for case let road? in data.roads {
            for forward in [true, false] {
                let count = forward ? road.lanesForward : road.lanesBackward
                guard count > 0 else { continue }
                let eid = EdgeID(road: road.id, forward: forward)
                let fromNode = forward ? road.a : road.b
                let toNode = forward ? road.b : road.a
                var plan = LanePlan(travel: count)
                let endTable = turnTables[toNode.raw]
                let degreeTo = ends[toNode.raw].count
                let effTo = result.effectiveControls[toNode.raw]
                if let inIdx = ends[toNode.raw].firstIndex(where: { $0.road.id == road.id && $0.atA == !forward }) {
                    let exits = endTable.exits(from: inIdx).filter { ends[toNode.raw][$0.index].outgoing != nil }
                    let hasAcross = exits.contains { $0.turn == side.acrossTurn }
                    let hasKerb = exits.contains { $0.turn == side.kerbTurn }
                    if road.turnPockets && !road.isOneWay && degreeTo >= 3 && hasAcross
                        && road.roadClass.medianWidth >= 0.9 * road.roadClass.laneWidth
                        && effTo != .roundabout {
                        plan.acrossPocket = true
                    }
                    if road.kerbTurnLanes && degreeTo >= 3 && hasKerb { plan.kerbTurn = true }
                    // Highway diverge: an exit to a ramp alongside a highway continuation.
                    if road.roadClass == .highway {
                        let exitsRoads = exits.map { ends[toNode.raw][$0.index].road.roadClass }
                        if exitsRoads.contains(.ramp) && exitsRoads.contains(.highway) { plan.decel = true }
                    }
                }
                // Highway merge at the start node: a ramp entering alongside the highway.
                if road.roadClass == .highway {
                    let arriving = ends[fromNode.raw].filter { $0.road.id != road.id && $0.incoming != nil }
                    let classes = arriving.map { $0.road.roadClass }
                    if classes.contains(.ramp) && classes.contains(.highway) { plan.accel = true }
                }
                plans[eid.raw] = plan
            }
        }

        // 6. Half widths and setbacks.
        var ringNodes: Set<Int> = []
        var ringRoads: Set<Int> = []
        for case let r? in data.roundabouts {
            for n in r.ringNodes { ringNodes.insert(n.raw) }
            for rd in r.ringRoads { ringRoads.insert(rd.raw) }
        }
        var setbacks: [[Double]] = ends.map { Array(repeating: 0, count: $0.count) }
        var halfWidths: [[Double]] = ends.map { Array(repeating: 0, count: $0.count) }
        for n in 0..<nodeCount {
            for (k, e) in ends[n].enumerated() {
                halfWidths[n][k] = halfWidth(of: e.road, plans: plans)
            }
            if isFreewayJunction[n] {
                setbacks[n] = Array(repeating: 1.0, count: ends[n].count)
            } else if ringNodes.contains(n) {
                // Ring roads stay continuous; only the approach mouth is set back.
                let approachHW = zip(ends[n], halfWidths[n]).filter { !ringRoads.contains($0.0.road.id.raw) }.map { $0.1 }.max() ?? 4
                let ringHW = zip(ends[n], halfWidths[n]).filter { ringRoads.contains($0.0.road.id.raw) }.map { $0.1 }.max() ?? 4
                setbacks[n] = ends[n].map { ringRoads.contains($0.road.id.raw) ? approachHW + 1.0 : ringHW + 3.0 }
            } else {
                setbacks[n] = computeSetbacks(ends: ends[n], halfWidths: halfWidths[n], centrelines: centrelines)
            }
        }

        // 7. Edges.
        result.edges = Array(repeating: nil, count: edgeCount)
        for case let road? in data.roads {
            guard let line = centrelines[road.id.raw] else { continue }
            let ia = ends[road.a.raw].firstIndex { $0.road.id == road.id && $0.atA } ?? 0
            let ib = ends[road.b.raw].firstIndex { $0.road.id == road.id && !$0.atA } ?? 0
            let sa = setbacks[road.a.raw].isEmpty ? 0 : setbacks[road.a.raw][ia]
            let sb = setbacks[road.b.raw].isEmpty ? 0 : setbacks[road.b.raw][ib]
            let total = line.length
            // Keep at least a short drivable stub even if setbacks collide.
            var s0 = min(sa, total * 0.45)
            var s1 = max(total - sb, total * 0.55)
            if s1 - s0 < 2 { s0 = total * 0.5 - 1; s1 = total * 0.5 + 1 }
            let trimmed = line.slice(from: s0, to: s1)
            for forward in [true, false] {
                let eid = EdgeID(road: road.id, forward: forward)
                guard let plan = plans[eid.raw] else { continue }
                let ref = forward ? trimmed : trimmed.reversed()
                result.edges[eid.raw] = makeEdge(id: eid, road: road, reference: ref, plan: plan)
            }
        }

        // 8. Node geometry (surfaces).
        result.nodeGeometry = Array(repeating: nil, count: nodeCount)
        for case let n? in data.nodes {
            let i = n.id.raw
            var geomEnds: [NodeGeometry.RoadEnd] = []
            for (k, e) in ends[i].enumerated() {
                geomEnds.append(NodeGeometry.RoadEnd(
                    road: e.road.id, direction: e.direction, angle: e.angle,
                    halfWidth: halfWidths[i][k], setback: setbacks[i][k],
                    incoming: e.incoming, outgoing: e.outgoing))
            }
            let surface = (isFreewayJunction[i] || ringNodes.contains(i))
                ? hullSurface(center: n.position, ends: geomEnds)
                : junctionSurface(center: n.position, ends: geomEnds, roads: ends[i].map { $0.road })
            result.nodeGeometry[i] = NodeGeometry(node: n.id, center: n.position, ends: geomEnds, surface: surface)
        }

        // 9. Adjacency.
        result.incoming = Array(repeating: [], count: nodeCount)
        result.outgoing = Array(repeating: [], count: nodeCount)
        for case let e? in result.edges {
            result.incoming[e.to.raw].append(e.id)
            result.outgoing[e.from.raw].append(e.id)
        }

        // 10. Connectors, successors, majors.
        var cb = ConnectorBuilder(builder: self, edges: result.edges, ends: ends, turnTables: turnTables,
                                  effectiveControls: result.effectiveControls)
        cb.build()
        result.edges = cb.edges
        result.connectors = cb.connectors
        result.connectorsFrom = cb.connectorsFrom
        result.connectorsInto = cb.connectorsInto
        result.connectorsAtNode = cb.connectorsAtNode
        result.successors = cb.successors
        result.majorApproaches = cb.majorApproaches
        return result
    }

    func node(_ id: NodeID) -> Node? {
        id.raw >= 0 && id.raw < data.nodes.count ? data.nodes[id.raw] : nil
    }

    // MARK: - Control resolution

    func resolveControl(_ n: Node, ends: [End]) -> ControlType {
        if ends.count <= 2 && n.control.requested != .yield && n.control.requested != .twoWayStop {
            return n.control.requested == .signal && ends.count == 2 ? .signal : .uncontrolled
        }
        if n.control.requested != .auto {
            // A roundabout is realised by the editor as a ring of yield nodes;
            // the original node keeps priority control until then.
            return n.control.requested == .roundabout ? .uncontrolled : n.control.requested
        }
        if let w = n.warrantControl { return w }
        return Self.classWarrant(ranks: ends.map { $0.road.roadClass })
    }

    /// Simplified MUTCD-style control from the classes of the meeting roads.
    static func classWarrant(ranks classes: [RoadClass]) -> ControlType {
        if classes.allSatisfy({ $0 == .highway || $0 == .ramp }) { return .uncontrolled }
        let ranks = classes.map { $0 == .ramp ? 2 : $0.rank }.sorted(by: >)
        guard ranks.count >= 3 else { return .uncontrolled }
        let r1 = ranks[0]
        // The second-highest *distinct road* rank (a straight road counts twice).
        let r2 = ranks.count > 2 ? ranks[2] : ranks[1]
        switch (r1, r2) {
        case (0, _): return .uncontrolled
        case (1, 1): return .allWayStop
        case (1, _): return .twoWayStop
        case (_, 2...): return .signal
        default: return .twoWayStop
        }
    }

    // MARK: - Widths & setbacks

    func halfWidth(of road: Road, plans: [LanePlan?]) -> Double {
        let w = road.roadClass.laneWidth
        let shoulder = road.roadClass.shoulderWidth
        func auxCount(_ p: LanePlan?) -> Int {
            guard let p else { return 0 }
            return (p.kerbTurn || p.accel || p.decel) ? 1 : 0
        }
        let pf = plans[EdgeID(road: road.id, forward: true).raw]
        let pb = plans[EdgeID(road: road.id, forward: false).raw]
        if road.isOneWay {
            return Double(road.lanesForward) * w / 2 + Double(auxCount(pf)) * w + shoulder
        }
        let m = road.roadClass.medianWidth / 2
        let fw = Double(road.lanesForward + auxCount(pf)) * w
        let bw = Double(road.lanesBackward + auxCount(pb)) * w
        return m + max(fw, bw) + shoulder
    }

    /// Distance from the node centre to each road's stop line so that kerb
    /// fillets of radius r fit between adjacent roads.
    func computeSetbacks(ends: [End], halfWidths: [Double], centrelines: [Polyline?]) -> [Double] {
        let n = ends.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var result = Array(repeating: n == 2 ? 0.5 : config.minimumSetback, count: n)
        for i in 0..<n {
            let j = (i + 1) % n
            let ei = ends[i], ej = ends[j]
            var alpha = ej.angle - ei.angle
            if alpha <= 0 { alpha += DMath.twoPi }
            if n == 2 && j == i { continue }
            // Reflex or straight corner: kerbs don't collide.
            if alpha >= DMath.pi * 0.97 { continue }
            let hi = halfWidths[i], hj = halfWidths[j]
            let ni = ei.direction.perpendicular, nj = ej.direction.perpendicular
            // Left kerb of i (looking away) meets right kerb of j.
            guard let (ti, tj) = Curves.rayIntersection(ni * hi, ei.direction, -nj * hj, ej.direction) else { continue }
            let r = min(ei.road.roadClass.cornerRadius, ej.road.roadClass.cornerRadius)
            let tangent = r / max(DMath.tan(alpha / 2), 0.15)
            result[i] = max(result[i], ti + tangent)
            result[j] = max(result[j], tj + tangent)
        }
        // Two roads of different widths meeting end to end: the lanes shift
        // sideways across the join, so give it a taper (≈ 1:8) rather than a
        // kink.
        if n == 2 {
            let d = abs(halfWidths[0] - halfWidths[1])
            if d > 0.25 {
                let half = min(32, 8 * d) / 2
                result[0] = max(result[0], half)
                result[1] = max(result[1], half)
            }
        }
        // Clamp to a fraction of each road so short roads still have lanes.
        for i in 0..<n {
            if let line = centrelines[ends[i].road.id.raw] {
                result[i] = min(result[i], line.length * 0.4)
            }
        }
        return result
    }

    // MARK: - Junction surface

    func junctionSurface(center: Vector2, ends: [NodeGeometry.RoadEnd], roads: [Road]) -> [Vector2] {
        let n = ends.count
        if n == 0 { return [] }
        if n == 1, let node = data.nodes.first(where: { $0?.position == center }) ?? nil, node.isRegionalConnection {
            return []
        }
        if n == 1 {
            // Cul-de-sac bulb, centred ahead of the dead end so U-turns fit.
            let e = ends[0]
            let c = center - e.direction * ConnectorBuilder.bulbOffset
            let radius = max(e.halfWidth + 1.5, ConnectorBuilder.bulbRadius)
            var pts: [Vector2] = []
            for k in 0..<32 {
                let a = DMath.twoPi * Double(k) / 32
                pts.append(c + Vector2.unit(angle: a) * radius)
            }
            return pts
        }
        if n == 2 {
            let alpha = abs(DMath.angleDifference(ends[0].angle, ends[1].angle))
            if alpha > DMath.pi * 0.9 {
                // Gentle continuation: the roads meet directly, unless they are
                // set back for a width taper — then the patch joins their ends.
                if ends.allSatisfy({ $0.setback < 0.05 }) { return [] }
                return hullSurface(center: center, ends: ends)
            }
        }
        var pts: [Vector2] = []
        for i in 0..<n {
            let e = ends[i]
            let nrm = e.direction.perpendicular
            let base = center + e.direction * e.setback
            let right = base - nrm * e.halfWidth
            let left = base + nrm * e.halfWidth
            pts.append(right)
            pts.append(left)
            // Fillet from this road's left kerb to the next road's right kerb.
            let f = ends[(i + 1) % n]
            let fn = f.direction.perpendicular
            let nextRight = center + f.direction * f.setback - fn * f.halfWidth
            var alpha = f.angle - e.angle
            if alpha <= 0 { alpha += DMath.twoPi }
            if alpha < DMath.pi * 0.97,
               let (t, _) = Curves.rayIntersection(left, -e.direction, nextRight, -f.direction), t > 0 {
                let corner = left - e.direction * t
                let curve = Curves.cubic(left, left + (corner - left) * 0.55, nextRight + (corner - nextRight) * 0.55,
                                         nextRight, segments: 8)
                pts.append(contentsOf: curve.dropFirst().dropLast())
            }
        }
        return pts
    }

    /// Convex hull of the road-end corners: a seamless patch for merges,
    /// diverges and roundabout entries.
    func hullSurface(center: Vector2, ends: [NodeGeometry.RoadEnd]) -> [Vector2] {
        var pts: [Vector2] = []
        for e in ends {
            let n = e.direction.perpendicular
            let base = center + e.direction * (e.setback + 0.5)
            pts.append(base + n * e.halfWidth)
            pts.append(base - n * e.halfWidth)
        }
        return Geometry.convexHull(pts)
    }

    // MARK: - Edge construction

    func laneOffsets(road: Road, travel: Int) -> (kerbOffset: (Int) -> Double, w: Double) {
        let w = road.roadClass.laneWidth
        if road.isOneWay {
            return ({ i in w * (Double(travel - 1) / 2 - Double(i)) }, w)
        }
        let m = road.roadClass.medianWidth / 2
        return ({ i in m + w * Double(travel - 1 - i) + w / 2 }, w)
    }

    func makeEdge(id: EdgeID, road: Road, reference: Polyline, plan: LanePlan) -> Edge {
        let (kerbOffset, w) = laneOffsets(road: road, travel: plan.travel)
        let len = reference.length
        let k = side.kerbSign
        var specs: [(kind: LaneKind, kerb: Double, s0: Double, s1: Double, t0: Double, t1: Double)] = []

        // Kerb-side auxiliary lanes.
        let auxKerb = kerbOffset(0) + w
        if plan.accel && plan.decel {
            specs.append((.deceleration, auxKerb, 0, len, 0, len))
        } else if plan.accel {
            let l = min(config.accelerationLaneLength, len * 0.8 - config.auxTaper * 0.5)
            if l > 30 { specs.append((.acceleration, auxKerb, 0, l, 0, min(l + config.auxTaper, len))) }
        } else if plan.decel {
            let l = min(config.decelerationLaneLength, len * 0.8 - config.auxTaper * 0.5)
            if l > 30 { specs.append((.deceleration, auxKerb, len - l, len, max(len - l - config.auxTaper, 0), len)) }
        }
        if plan.kerbTurn && !plan.decel {
            let l = pocketLength(road: road, edgeLength: len)
            if l > 0 { specs.append((.kerbTurn, auxKerb, len - l, len, max(len - l - config.pocketTaper, 0), len)) }
        }
        for i in 0..<plan.travel {
            specs.append((.travel, kerbOffset(i), 0, len, 0, len))
        }
        if plan.acrossPocket {
            let l = pocketLength(road: road, edgeLength: len)
            if l > 0 {
                specs.append((.acrossPocket, kerbOffset(plan.travel - 1) - w, len - l, len,
                              max(len - l - config.pocketTaper, 0), len))
            }
        }
        // Kerb-most first.
        specs.sort { $0.kerb > $1.kerb }
        var lanes: [Lane] = []
        for (i, sp) in specs.enumerated() {
            lanes.append(Lane(id: LaneID(edge: id, index: i), kind: sp.kind, lateral: k * sp.kerb, width: w,
                              sStart: sp.s0, sEnd: sp.s1, taperStart: sp.t0, taperEnd: sp.t1))
        }
        return Edge(id: id, road: road.id,
                    from: id.isForward ? road.a : road.b, to: id.isForward ? road.b : road.a,
                    roadClass: road.roadClass, speedLimit: road.speedLimit, level: road.level,
                    isBridge: road.isBridge, reference: reference, lanes: lanes,
                    travelLanes: plan.travel, isOneWay: road.isOneWay)
    }

    func pocketLength(road: Road, edgeLength: Double) -> Double {
        var l = (config.pocketBase + config.pocketSpeedFactor * road.speedLimit).clamped(to: config.pocketMin...config.pocketMax)
        // Back-to-back pockets on a two-way road share the median: leave room.
        let available = edgeLength * 0.45 - config.pocketTaper
        l = min(l, available)
        return l >= config.pocketMin ? l : 0
    }
}

/// Turn classification of every approach → exit pair at one node.
struct TurnTable {
    struct Exit { let index: Int; let turn: TurnDirection; let angle: Double }
    private var table: [[Exit]] = []

    init(ends: [NetworkBuilder.End], side: DrivingSide) {
        let n = ends.count
        table = Array(repeating: [], count: n)
        for i in 0..<n {
            let inDir = -ends[i].direction            // direction of travel arriving
            var candidates: [(Int, Double)] = []
            for j in 0..<n {
                let theta = DMath.atan2(inDir.cross(ends[j].direction), inDir.dot(ends[j].direction))
                if j == i {
                    if n == 1 { candidates.append((j, DMath.pi)) }
                    continue
                }
                candidates.append((j, theta))
            }
            // Through = smallest |θ| below 50°; other movements by sign.
            let through = candidates.filter { $0.0 != i && abs($0.1) < 50 * DMath.pi / 180 }
                .min { abs($0.1) != abs($1.1) ? abs($0.1) < abs($1.1) : $0.0 < $1.0 }
            for (j, theta) in candidates {
                let turn: TurnDirection
                if j == i || abs(theta) > 165 * DMath.pi / 180 { turn = .uTurn }
                else if let t = through, t.0 == j { turn = .straight }
                else { turn = theta > 0 ? .left : .right }
                table[i].append(Exit(index: j, turn: turn, angle: theta))
            }
        }
    }

    func exits(from i: Int) -> [Exit] { i < table.count ? table[i] : [] }
}
