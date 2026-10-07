//
//  Editing.swift
//  TrafficEngine
//
//  Player edits with validation and undo/redo.
//
//  Every edit goes through `Editor`, which snapshots the authored network
//  (a small Codable value) before applying it; undo restores the snapshot and
//  the simulation reconciles vehicles (those on removed roads leave
//  gracefully). Building edits are undone by the inverse edit.
//
//  Road drawing: the drawn polyline is simplified to a smooth shape; its ends
//  snap to a nearby junction or split a nearby road; wherever it crosses an
//  existing road at the same level a junction is created; stretches over
//  water become bridges.
//

public enum EditError: String, Error, Sendable {
    case tooShort = "Too short — drag a little further."
    case tooCloseToJunction = "Too close to another junction."
    case nothingThere = "Nothing to edit there."
    case outOfBounds = "Outside the map."
    case invalidLanes = "Unsupported number of lanes."
    case placement = "Can't place that here."
    case tooSharp = "Too sharp a bend or angle for traffic."
}

/// The outcome of drawing a road, worked out before it is built.
public struct RoadPreview: Sendable, Equatable {
    public struct End: Sendable, Equatable {
        public var position: Vector2
        /// Joins an existing road or junction (rather than ending in a dead end).
        public var attached: Bool
    }
    public var ok = false
    public var error: EditError?
    /// Centrelines of the roads that would be built.
    public var centrelines: [[Vector2]] = []
    public var ends: [End] = []
    public var junctions = 0
    public var bridges = 0
    /// Roads crossed at another level (passing over or under them).
    public var overpasses = 0
    public init() {}
}

public enum EditKind: String, Codable, Sendable {
    case drawRoad, removeRoad, changeRoad, setControl, moveJunction, roundabout, placeBuilding, removeBuilding, togglePockets
}

/// What undo restores.
struct EditRecord {
    var kind: EditKind
    var networkBefore: NetworkData?
    var networkAfter: NetworkData?
    var placed: (BuildingKind, Vector2)?          // undo: remove whatever is there
    var removed: (BuildingKind, Vector2)?         // undo: place it again
    var placedID: BuildingID?
}

public final class Editor {
    public let sim: Simulation
    private var undoStack: [EditRecord] = []
    private var redoStack: [EditRecord] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var maxHistory = 100

    public init(sim: Simulation) { self.sim = sim }

    /// A scratch copy of the network being edited in a dry run (`previewRoad`).
    private var scratch: RoadNetwork?
    private var net: RoadNetwork { scratch ?? sim.network }
    /// `problems()` of the live network, by network version (previews reuse it).
    private var problemCache: (version: Int, problems: Set<String>, short: [Int: Double])?

    /// Apply a network edit; reject it (leaving the network untouched) if it
    /// would create a road stub too short to drive or a junction whose roads
    /// meet at too sharp an angle.
    private func networkEdit(_ kind: EditKind, _ body: () throws -> Void) throws {
        let before = net.data
        let (problemsBefore, shortBefore) = liveProblems()
        do {
            try body()
        } catch {
            if net.data != before { net.replace(with: before); sim.networkDidChange() }
            throw error
        }
        var added = problems().subtracting(problemsBefore)
        // A stub that was already short must not get any shorter.
        for (road, len) in shortLengths() {
            if let before = shortBefore[road], len < before - 0.25 { added.insert("short:\(road)") }
        }
        if !added.isEmpty {
            net.replace(with: before)
            sim.networkDidChange()
            throw added.contains { $0.hasPrefix("angle") || $0.hasPrefix("kink") } ? EditError.tooSharp : EditError.tooCloseToJunction
        }
        push(EditRecord(kind: kind, networkBefore: before, networkAfter: net.data))
        sim.networkDidChange()
    }

    private func liveProblems() -> (Set<String>, [Int: Double]) {
        let v = sim.network.version
        if let c = problemCache, c.version == v { return (c.problems, c.short) }
        let p = problems(), s = shortLengths()
        problemCache = (v, p, s)
        return (p, s)
    }

    /// Minimum drivable length of a carriageway between junctions [m].
    public static let minimumEdgeLength = 18.0
    /// Shortest roundabout ring segment between two legs [m].
    public static let minimumRingSegment = 8.0
    /// Tightest bend allowed along a road [m].
    public static let minimumCurveRadius = 8.0
    /// Minimum angle between roads meeting at a junction [rad] (≈ 20°).
    public static let minimumJunctionAngle = 0.35

    /// Lengths of the carriageways currently below the minimum, by road.
    private func shortLengths() -> [Int: Double] {
        var out: [Int: Double] = [:]
        for e in net.allEdges where e.length < Self.minimumEdgeLength { out[e.road.raw] = min(out[e.road.raw] ?? .infinity, e.length) }
        return out
    }

    /// Geometry the simulation cannot drive sensibly, as stable keys.
    private func problems() -> Set<String> {
        var out: Set<String> = []
        let ring = Set(net.data.roundabouts.compactMap { $0 }.flatMap { $0.ringRoads.map { $0.raw } })
        for e in net.allEdges where e.length < (ring.contains(e.road.raw) ? Self.minimumRingSegment : Self.minimumEdgeLength) {
            out.insert("short:\(e.road.raw)")
        }
        for e in net.allEdges where e.reference.minimumRadius < Self.minimumCurveRadius && !ring.contains(e.road.raw) {
            out.insert("kink:\(e.road.raw)")
        }
        // A dead end needs room for its turning bulb, clear of the junction behind.
        for n in net.allNodes where !n.isRegionalConnection && net.degree(of: n.id) == 1 {
            if let r = net.roads(at: n.id).first, let l = net.centreline(of: r.id), l.length < 40 {
                out.insert("short:deadend:\(n.id.raw)")
            }
        }
        for n in net.allNodes where !n.isRegionalConnection {
            guard let g = net.geometry(of: n.id), g.ends.count >= 2 else { continue }
            let angles = g.ends.map { $0.angle }.sorted()
            for k in angles.indices {
                let next = k + 1 < angles.count ? angles[k + 1] : angles[0] + 2 * 3.141592653589793
                if next - angles[k] < Self.minimumJunctionAngle {
                    let roads = g.ends.map { $0.road.raw }.sorted().map(String.init).joined(separator: ",")
                    out.insert("angle:\(n.id.raw):\(roads)")
                }
            }
        }
        out.formUnion(Self.encroachments(net))
        return out
    }

    /// Pairs of roads on the same level whose carriageways overlap away from
    /// any junction they share (e.g. a dead end stopping inside another road).
    static func encroachments(_ net: RoadNetwork) -> Set<String> {
        var out: Set<String> = []
        let edges = net.allEdges
        func half(_ e: Edge) -> Double { e.lanes.map { abs($0.lateral) + $0.width / 2 }.max() ?? 3.5 }
        let boxes = edges.map { e -> (min: Vector2, max: Vector2) in
            let b = e.reference.bounds, h = half(e) + 0.5
            return (Vector2(b.min.x - h, b.min.y - h), Vector2(b.max.x + h, b.max.y + h))
        }
        for a in edges.indices {
            let ea = edges[a]
            for b in edges.indices where b > a {
                let eb = edges[b]
                // Interchange ramps run side by side by design (checked by the invariants).
                guard ea.road != eb.road, ea.level == eb.level, !(ea.roadClass == .ramp && eb.roadClass == .ramp),
                      boxes[a].min.x < boxes[b].max.x, boxes[b].min.x < boxes[a].max.x,
                      boxes[a].min.y < boxes[b].max.y, boxes[b].min.y < boxes[a].max.y else { continue }
                let shared: Set<NodeID> = [ea.from, ea.to]
                if shared.contains(eb.from) || shared.contains(eb.to) { continue }
                let limit = half(ea) + half(eb)
                var s = 0.0
                while s <= ea.length {
                    if eb.reference.project(ea.reference.point(at: s)).distance < limit {
                        let pair = [ea.road.raw, eb.road.raw].sorted()
                        out.insert("overlap:\(pair[0]),\(pair[1])")
                        break
                    }
                    s += 2
                }
            }
        }
        // A dead end's turning bulb must stay clear of every other road.
        for e in edges where net.node(e.to).map({ !$0.isRegionalConnection }) == true && net.degree(of: e.to) == 1 {
            let tangent = e.reference.endTangent
            guard let node = net.node(e.to) else { continue }
            let centre = node.position + tangent * ConnectorBuilder.bulbOffset
            let reach = max(half(e) + 1.5, ConnectorBuilder.bulbRadius)
            for o in edges where o.road != e.road && o.level == e.level && o.from != e.to && o.to != e.to {
                let b = o.reference.bounds, r = reach + half(o)
                guard centre.x > b.min.x - r, centre.x < b.max.x + r, centre.y > b.min.y - r, centre.y < b.max.y + r else { continue }
                if o.reference.project(centre).distance < r { out.insert("bulb:\(e.road.raw)"); break }
            }
        }
        return out
    }

    private func push(_ r: EditRecord) {
        undoStack.append(r)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: Roads

    /// Draw a road along `points` (world metres). Returns the new road ids.
    @discardableResult
    public func drawRoad(_ points: [Vector2], roadClass: RoadClass, lanes: Int? = nil, oneWay: Bool = false) throws -> [RoadID] {
        let line = Self.simplify(points, tolerance: 1.5)
        guard line.count >= 2 else { throw EditError.tooShort }
        let poly = Polyline(line)
        guard poly.length >= 20 else { throw EditError.tooShort }
        if let l = lanes, !(1...4).contains(l) { throw EditError.invalidLanes }
        guard sim.terrain.contains(line.first!), sim.terrain.contains(line.last!) else { throw EditError.outOfBounds }
        var made: [RoadID] = []
        try networkEdit(.drawRoad) {
            var thrown: Error?
            net.batch {
                do { made = try buildChain(poly, roadClass: roadClass, lanes: lanes, oneWay: oneWay) } catch { thrown = error }
            }
            if let e = thrown { throw e }
        }
        return made
    }

    /// What drawing a road along `points` would do, without doing it: the
    /// smoothed shape that would be built, where its ends attach, how many
    /// junctions, bridges and overpasses it makes — or why it can't be built.
    /// Runs on a scratch copy of the network.
    public func previewRoad(_ points: [Vector2], roadClass: RoadClass, lanes: Int? = nil, oneWay: Bool = false) -> RoadPreview {
        var out = RoadPreview()
        let line = Self.simplify(points, tolerance: 1.5)
        guard line.count >= 2, Polyline(line).length >= 20 else { out.error = .tooShort; return out }
        if let l = lanes, !(1...4).contains(l) { out.error = .invalidLanes; return out }
        guard sim.terrain.contains(line.first!), sim.terrain.contains(line.last!) else { out.error = .outOfBounds; return out }
        let (problemsBefore, shortBefore) = liveProblems()
        let live = sim.network
        let copy = RoadNetwork(data: live.data)
        copy.config = live.config
        scratch = copy
        defer { scratch = nil }
        let nodesBefore = live.data.nodes.count
        do {
            var thrown: Error?
            var made: [RoadID] = []
            copy.batch {
                do { made = try buildChain(Polyline(line), roadClass: roadClass, lanes: lanes, oneWay: oneWay) } catch { thrown = error }
            }
            if let e = thrown { throw e }
            var added = problems().subtracting(problemsBefore)
            for (road, len) in shortLengths() {
                if let before = shortBefore[road], len < before - 0.25 { added.insert("short:\(road)") }
            }
            if !added.isEmpty {
                out.error = added.contains { $0.hasPrefix("angle") || $0.hasPrefix("kink") } ? .tooSharp : .tooCloseToJunction
            }
            for id in made {
                guard let r = copy.road(id), let c = copy.centreline(of: id) else { continue }
                out.centrelines.append(c.points)
                if r.isBridge { out.bridges += 1 }
            }
            // Ends: attached to something that was already there, or new.
            if let first = made.first.flatMap({ copy.road($0) }), let last = made.last.flatMap({ copy.road($0) }) {
                for n in [first.a, last.b] {
                    guard let node = copy.node(n) else { continue }
                    out.ends.append(RoadPreview.End(position: node.position, attached: n.raw < nodesBefore || copy.degree(of: n) > 1))
                }
            }
            // New junctions: nodes of the new roads where three or more roads meet.
            var nodes = Set<NodeID>()
            for id in made { if let r = copy.road(id) { nodes.insert(r.a); nodes.insert(r.b) } }
            out.junctions = nodes.filter { copy.degree(of: $0) >= 3 }.count
            // Roads it passes over or under (other levels).
            let level = roadClass == .highway ? 1 : 0
            let poly = Polyline(line)
            for r in live.allRoads where r.level != level {
                guard let other = live.centreline(of: r.id) else { continue }
                var crosses = false
                for i in 0..<(poly.points.count - 1) where !crosses {
                    for j in 0..<(other.points.count - 1) where Self.intersection(poly.points[i], poly.points[i + 1], other.points[j], other.points[j + 1]) != nil {
                        crosses = true; break
                    }
                }
                if crosses { out.overpasses += 1 }
            }
        } catch {
            out.error = (error as? EditError) ?? .placement
        }
        out.ok = out.error == nil
        return out
    }

    /// Snap a point to a junction / split a road / make a node.
    private func anchor(_ p: Vector2, level: Int) -> NodeID {
        if let n = net.allNodes.filter({ !$0.isRegionalConnection || $0.position.distance(to: p) < 6 })
            .min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }), n.position.distance(to: p) < 14 {
            return n.id
        }
        for r in net.allRoads where r.level == level {
            guard let line = net.centreline(of: r.id) else { continue }
            let pr = line.project(p)
            if pr.distance < 8, let n = net.splitRoad(r.id, near: p) { return n }
        }
        return net.addNode(at: p)
    }

    private func buildChain(_ poly: Polyline, roadClass: RoadClass, lanes: Int?, oneWay: Bool) throws -> [RoadID] {
        let level = roadClass == .highway ? 1 : 0
        let firstNewNode = net.data.nodes.count
        // Crossings with existing roads at the same level (by arc length along the new road).
        var cuts: [(s: Double, p: Vector2, road: RoadID)] = []
        for r in net.allRoads where r.level == level {
            guard let other = net.centreline(of: r.id) else { continue }
            for i in 0..<(poly.points.count - 1) {
                for j in 0..<(other.points.count - 1) {
                    if let x = Self.intersection(poly.points[i], poly.points[i + 1], other.points[j], other.points[j + 1]) {
                        let s = poly.project(x).s
                        if s > 15 && s < poly.length - 15 { cuts.append((s, x, r.id)) }
                    }
                }
            }
        }
        cuts.sort { $0.s < $1.s }
        // Drop crossings too close to each other.
        var kept: [(s: Double, p: Vector2, road: RoadID)] = []
        for c in cuts where kept.last.map({ c.s - $0.s > 15 }) ?? true { kept.append(c) }
        let start = anchor(poly.points.first!, level: level)
        var stops: [(s: Double, node: NodeID)] = [(0, start)]
        for c in kept {
            // Split the crossed road where the new road meets it.
            let n = net.splitRoad(c.road, near: c.p, minEndDistance: 10) ?? anchor(c.p, level: level)
            stops.append((c.s, n))
        }
        stops.append((poly.length, anchor(poly.points.last!, level: level)))
        var made: [RoadID] = []
        for k in 0..<(stops.count - 1) {
            let a = stops[k], b = stops[k + 1]
            guard a.node != b.node, let pa = net.node(a.node)?.position, let pb = net.node(b.node)?.position,
                  pa.distance(to: pb) >= 8 else { continue }
            // Interior shape points of the drawn line between the two stops.
            let interior = poly.points.filter { p in let s = poly.project(p).s; return s > a.s + 4 && s < b.s - 4 }
            guard let id = net.addRoad(from: a.node, to: b.node, roadClass: roadClass, shape: interior,
                                       lanes: lanes, oneWay: oneWay) else { continue }
            let segment = Polyline([pa] + interior + [pb])
            let wet = sim.terrain.waterFraction(of: segment) > 0
            net.updateRoad(id) {
                $0.level = level
                $0.isBridge = wet
            }
            made.append(id)
        }
        guard !made.isEmpty else { throw EditError.tooCloseToJunction }
        // New junctions on an elevated road are elevated too.
        if level != 0 {
            for stop in stops where stop.node.raw >= firstNewNode { net.updateNode(stop.node) { $0.level = level } }
        }
        return made
    }

    public func removeRoad(_ id: RoadID) throws {
        guard net.road(id) != nil else { throw EditError.nothingThere }
        try networkEdit(.removeRoad) {
            net.batch {
                let r = net.road(id)!
                net.removeRoad(id)
                // Remove nodes left with no roads (except map-edge connections).
                for n in [r.a, r.b] where net.roads(at: n).isEmpty && !(net.node(n)?.isRegionalConnection ?? true) {
                    net.removeNode(n)
                }
            }
        }
    }

    /// Upgrade / downgrade: class, lanes (per direction) and one-way.
    public func changeRoad(_ id: RoadID, roadClass: RoadClass, lanes: Int? = nil, oneWay: Bool? = nil) throws {
        guard net.road(id) != nil else { throw EditError.nothingThere }
        if let l = lanes, !(1...4).contains(l) { throw EditError.invalidLanes }
        try networkEdit(.changeRoad) {
            net.updateRoad(id) { r in
                r.roadClass = roadClass
                let n = lanes ?? r.lanesForward
                let oneWay = oneWay ?? r.isOneWay
                r.lanesForward = n
                r.lanesBackward = oneWay ? 0 : n
                r.turnPockets = roadClass == .arterial
            }
        }
    }

    public func toggleTurnPockets(_ id: RoadID) throws {
        guard net.road(id) != nil else { throw EditError.nothingThere }
        try networkEdit(.togglePockets) { net.updateRoad(id) { $0.turnPockets.toggle() } }
    }

    // MARK: Junctions

    /// Override a junction's control (`.auto` hands it back to the warrants).
    public func setControl(_ node: NodeID, to control: ControlType, locked: Bool) throws {
        guard let n = net.node(node), net.degree(of: node) >= 2 else { throw EditError.nothingThere }
        var c = n.control
        c.requested = control
        c.locked = locked
        try networkEdit(.setControl) { net.setControl(c, at: node) }
    }

    public func moveJunction(_ node: NodeID, to p: Vector2) throws {
        guard let n = net.node(node), !n.isRegionalConnection else { throw EditError.nothingThere }
        guard sim.terrain.contains(p) else { throw EditError.outOfBounds }
        try networkEdit(.moveJunction) {
            net.batch {
                // Drag the roads' shapes along with a smooth falloff so the
                // curves stay curves (no kink next to the moved junction).
                let delta = p - n.position
                for r in net.roads(at: node) {
                    guard !r.shape.isEmpty, let line = net.centreline(of: r.id) else { continue }
                    let atA = r.a == node
                    let reach = min(60, line.length * 0.6)
                    let moved = r.shape.map { q -> Vector2 in
                        let s = line.project(q).s
                        let d = atA ? s : line.length - s
                        let w = max(0, 1 - d / reach)
                        return q + delta * (w * w * (3 - 2 * w))
                    }
                    net.updateRoad(r.id) { $0.shape = moved }
                }
                net.moveNode(node, to: p)
            }
        }
    }

    public func makeRoundabout(at node: NodeID) throws {
        guard net.node(node) != nil, net.degree(of: node) >= 3 else { throw EditError.nothingThere }
        try networkEdit(.roundabout) { _ = net.makeRoundabout(at: node) }
    }

    // MARK: Buildings

    @discardableResult
    public func placeBuilding(_ kind: BuildingKind, at p: Vector2) -> Result<BuildingID, PlacementError> {
        let r = sim.placeBuilding(kind, at: p)
        if case .success(let id) = r {
            push(EditRecord(kind: .placeBuilding, placed: (kind, p), placedID: id))
        }
        return r
    }

    /// Place at `p`, or at the nearest valid spot within `search` metres
    /// (buildings snap to the closest plot that reaches a road). On failure,
    /// the reason for the spot the player chose.
    @discardableResult
    public func placeBuilding(_ kind: BuildingKind, near p: Vector2, search: Double) -> Result<BuildingID, PlacementError> {
        let first = placeBuilding(kind, at: p)
        if case .success = first { return first }
        for radius in stride(from: 4.0, through: max(search, 4), by: 4) {
            let n = max(8, Int(2 * 3.141592653589793 * radius / 4))
            for k in 0..<n {
                let a = Double(k) / Double(n) * 2 * 3.141592653589793
                let q = p + Vector2(DMath.cos(a), DMath.sin(a)) * radius
                if case .success(let id) = placeBuilding(kind, at: q) { return .success(id) }
            }
        }
        return first
    }

    public func removeBuilding(_ id: BuildingID) throws {
        guard let b = sim.city.building(id) else { throw EditError.nothingThere }
        sim.removeBuilding(id)
        push(EditRecord(kind: .removeBuilding, removed: (b.kind, b.center)))
    }

    /// Bulldoze whatever is at a point: a building first, then a road.
    public func bulldoze(at p: Vector2, radius: Double) throws {
        switch sim.hitTest(p, radius: radius) {
        case .building(let id)?: try removeBuilding(id)
        case .road(let r)?: try removeRoad(r)
        case .vehicle?, .junction?:
            if let r = roadNear(p, radius: radius) { try removeRoad(r) } else { throw EditError.nothingThere }
        case nil: throw EditError.nothingThere
        }
    }

    private func roadNear(_ p: Vector2, radius: Double) -> RoadID? {
        net.allRoads.compactMap { r -> (RoadID, Double)? in
            guard let l = net.centreline(of: r.id) else { return nil }
            return (r.id, l.project(p).distance)
        }.filter { $0.1 < radius + 4 }.min { $0.1 < $1.1 }?.0
    }

    // MARK: Undo / redo

    public func undo() {
        guard let r = undoStack.popLast() else { return }
        apply(r, forward: false)
        redoStack.append(r)
    }

    public func redo() {
        guard let r = redoStack.popLast() else { return }
        apply(r, forward: true)
        undoStack.append(r)
    }

    private func apply(_ r: EditRecord, forward: Bool) {
        if let data = forward ? r.networkAfter : r.networkBefore {
            net.replace(with: data)
            sim.networkDidChange()
            return
        }
        switch (r.kind, forward) {
        case (.placeBuilding, false):
            if let (kind, p) = r.placed, let b = sim.city.buildings.first(where: { $0.kind == kind && $0.center.distance(to: p) < 1 }) {
                sim.removeBuilding(b.id)
            }
        case (.placeBuilding, true):
            if let (kind, p) = r.placed { _ = sim.placeBuilding(kind, at: p) }
        case (.removeBuilding, false):
            if let (kind, p) = r.removed { _ = sim.placeBuilding(kind, at: p) }
        case (.removeBuilding, true):
            if let (kind, p) = r.removed, let b = sim.city.buildings.first(where: { $0.kind == kind && $0.center.distance(to: p) < 1 }) {
                sim.removeBuilding(b.id)
            }
        default:
            break
        }
    }

    // MARK: Geometry helpers

    /// Douglas–Peucker simplification.
    static func simplify(_ pts: [Vector2], tolerance: Double) -> [Vector2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            var best = 0.0, idx = -1
            for i in (a + 1)..<b {
                let d = Geometry.pointSegmentDistanceSquared(pts[i], pts[a], pts[b])
                if d > best { best = d; idx = i }
            }
            if idx >= 0 && best > tolerance * tolerance {
                keep[idx] = true
                stack.append((a, idx)); stack.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Intersection point of segments p1p2 and p3p4, if they cross.
    static func intersection(_ p1: Vector2, _ p2: Vector2, _ p3: Vector2, _ p4: Vector2) -> Vector2? {
        let d1 = p2 - p1, d2 = p4 - p3
        let den = d1.x * d2.y - d1.y * d2.x
        guard abs(den) > 1e-9 else { return nil }
        let w = p3 - p1
        let t = (w.x * d2.y - w.y * d2.x) / den
        let u = (w.x * d1.y - w.y * d1.x) / den
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return p1 + d1 * t
    }
}
