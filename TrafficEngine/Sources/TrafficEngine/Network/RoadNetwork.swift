//
//  RoadNetwork.swift
//  TrafficEngine
//
//  Storage for the authored network plus its derived geometry. Entities live
//  in arrays indexed by their dense id (`nil` = deleted), so iteration is in
//  id order — deterministic and cache-friendly.
//
//  Every mutating call rebuilds derived geometry unless it runs inside
//  `batch { }`, which rebuilds once at the end.
//

/// The Codable, authored part of the network (what a save file stores).
public struct NetworkData: Codable, Sendable, Equatable {
    public var side: DrivingSide
    public var nodes: [Node?]
    public var roads: [Road?]
    public var roundabouts: [Roundabout?]
    public init(side: DrivingSide, nodes: [Node?] = [], roads: [Road?] = [], roundabouts: [Roundabout?] = []) {
        self.side = side
        self.nodes = nodes
        self.roads = roads
        self.roundabouts = roundabouts
    }
}

/// A roundabout built from one-way ring roads around a centre.
public struct Roundabout: Codable, Sendable, Equatable {
    public let id: Int
    public var center: Vector2
    public var radius: Double
    public var ringNodes: [NodeID]
    public var ringRoads: [RoadID]
}

public final class RoadNetwork {

    // MARK: Authored state
    public private(set) var data: NetworkData
    public var side: DrivingSide { data.side }

    // MARK: Derived state (rebuilt)
    public private(set) var edges: [Edge?] = []
    public private(set) var connectors: [Connector] = []
    public private(set) var nodeGeometry: [NodeGeometry?] = []
    /// `connectorsFrom[edge.raw][laneIndex]` → connector ids leaving that lane.
    public private(set) var connectorsFrom: [[[ConnectorID]]] = []
    /// Connectors entering an edge (by edge raw).
    public private(set) var connectorsInto: [[ConnectorID]] = []
    public private(set) var connectorsAtNode: [[ConnectorID]] = []
    public private(set) var incomingEdges: [[EdgeID]] = []
    public private(set) var outgoingEdges: [[EdgeID]] = []
    /// Edges reachable from an edge through its downstream node.
    public private(set) var successors: [[EdgeID]] = []
    public private(set) var conflicts = ConflictMap()
    /// Major (priority) incoming edges for yield / two-way-stop nodes.
    public private(set) var majorApproaches: [Set<EdgeID>] = []
    /// Increments on every rebuild; renderers use it to invalidate caches.
    public private(set) var version: Int = 0
    /// Changes only when the shape of the network changes (roads, lanes,
    /// junction surfaces) — not when a junction's control does. Lets the
    /// city and the renderer skip rebuilding what a control change can't affect.
    public private(set) var geometryVersion: Int = 0
    private var geometrySignature: Int?
    /// Nodes whose geometry changed in the last rebuild (for incremental redraw).
    public private(set) var lastChangedNodes: Set<NodeID> = []

    public var config = NetworkBuildConfig()
    private var batchDepth = 0
    private var dirty = false
    private var pendingChanged: Set<NodeID> = []

    public init(side: DrivingSide = .right) {
        data = NetworkData(side: side)
    }

    public init(data: NetworkData) {
        self.data = data
        rebuild()
    }

    // MARK: - Lookups

    public func node(_ id: NodeID) -> Node? {
        id.raw >= 0 && id.raw < data.nodes.count ? data.nodes[id.raw] : nil
    }
    public func road(_ id: RoadID) -> Road? {
        id.raw >= 0 && id.raw < data.roads.count ? data.roads[id.raw] : nil
    }
    public func edge(_ id: EdgeID) -> Edge? {
        id.raw >= 0 && id.raw < edges.count ? edges[id.raw] : nil
    }
    public func lane(_ id: LaneID) -> Lane? { edge(id.edge)?.lane(id.index) }
    public func connector(_ id: ConnectorID) -> Connector? {
        id.raw >= 0 && id.raw < connectors.count ? connectors[id.raw] : nil
    }
    public func geometry(of node: NodeID) -> NodeGeometry? {
        node.raw >= 0 && node.raw < nodeGeometry.count ? nodeGeometry[node.raw] : nil
    }

    public var allNodes: [Node] { data.nodes.compactMap { $0 } }
    public var allRoads: [Road] { data.roads.compactMap { $0 } }
    public var allEdges: [Edge] { edges.compactMap { $0 } }
    public var nodeCount: Int { data.nodes.count }
    public var edgeSlotCount: Int { edges.count }

    public func incoming(_ node: NodeID) -> [EdgeID] {
        node.raw < incomingEdges.count ? incomingEdges[node.raw] : []
    }
    public func outgoing(_ node: NodeID) -> [EdgeID] {
        node.raw < outgoingEdges.count ? outgoingEdges[node.raw] : []
    }
    public func successors(of edge: EdgeID) -> [EdgeID] {
        edge.raw < successors.count ? successors[edge.raw] : []
    }
    public func connectors(from lane: LaneID) -> [ConnectorID] {
        guard lane.edge.raw < connectorsFrom.count else { return [] }
        let lanes = connectorsFrom[lane.edge.raw]
        return lane.index < lanes.count ? lanes[lane.index] : []
    }
    public func connectors(at node: NodeID) -> [ConnectorID] {
        node.raw < connectorsAtNode.count ? connectorsAtNode[node.raw] : []
    }
    public func connectors(into edge: EdgeID) -> [ConnectorID] {
        edge.raw < connectorsInto.count ? connectorsInto[edge.raw] : []
    }

    /// The connector from `lane` into any lane of `next`, if the lane serves that movement.
    public func connector(from lane: LaneID, toEdge next: EdgeID) -> ConnectorID? {
        connectors(from: lane).first { connectors[$0.raw].toEdge == next }
    }

    /// Lane indices of `edge` that have a connector into `next`.
    public func lanesServing(edge: EdgeID, next: EdgeID) -> [Int] {
        guard let e = self.edge(edge) else { return [] }
        return e.lanes.indices.filter { connector(from: LaneID(edge: edge, index: $0), toEdge: next) != nil }
    }

    /// Turn classification of the movement edge → next, if one exists.
    public func turn(from edge: EdgeID, to next: EdgeID) -> TurnDirection? {
        guard let e = self.edge(edge) else { return nil }
        for l in e.lanes {
            if let c = connector(from: l.id, toEdge: next) { return connectors[c.raw].turn }
        }
        return nil
    }

    public func isMajorApproach(_ edge: EdgeID, at node: NodeID) -> Bool {
        node.raw < majorApproaches.count && majorApproaches[node.raw].contains(edge)
    }

    public func roads(at node: NodeID) -> [Road] {
        allRoads.filter { $0.touches(node) }
    }

    public func degree(of node: NodeID) -> Int { geometry(of: node)?.degree ?? 0 }

    // MARK: - Editing

    /// Run several edits and rebuild derived geometry once.
    public func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 && dirty { rebuild() }
    }

    private func touched(_ nodes: [NodeID]) {
        dirty = true
        pendingChanged.formUnion(nodes)
        if batchDepth == 0 { rebuild() }
    }

    public func setDrivingSide(_ side: DrivingSide) {
        data.side = side
        touched(allNodes.map { $0.id })
    }

    @discardableResult
    public func addNode(at position: Vector2, control: NodeControl = NodeControl()) -> NodeID {
        let id = NodeID(data.nodes.count)
        data.nodes.append(Node(id: id, position: position, control: control))
        touched([id])
        return id
    }

    /// Add a road. Returns nil if the endpoints are invalid or identical.
    @discardableResult
    public func addRoad(from a: NodeID, to b: NodeID, roadClass: RoadClass, shape: [Vector2] = [],
                        lanes: Int? = nil, backwardLanes: Int? = nil, oneWay: Bool? = nil) -> RoadID? {
        guard a != b, node(a) != nil, node(b) != nil else { return nil }
        let id = RoadID(data.roads.count)
        let road = Road(id: id, a: a, b: b, shape: shape, roadClass: roadClass,
                        lanesForward: lanes.map { min($0, roadClass.maxLanes) },
                        lanesBackward: backwardLanes.map { min($0, roadClass.maxLanes) }, oneWay: oneWay)
        data.roads.append(road)
        touched([a, b])
        return id
    }

    public func updateRoad(_ id: RoadID, _ change: (inout Road) -> Void) {
        guard var r = road(id) else { return }
        let before = [r.a, r.b]
        change(&r)
        r.lanesForward = max(1, min(r.lanesForward, r.roadClass.maxLanes))
        r.lanesBackward = max(0, min(r.lanesBackward, r.roadClass.maxLanes))
        data.roads[id.raw] = r
        touched(before + [r.a, r.b])
    }

    public func removeRoad(_ id: RoadID) {
        guard let r = road(id) else { return }
        data.roads[id.raw] = nil
        touched([r.a, r.b])
    }

    /// Remove a node and every road attached to it.
    public func removeNode(_ id: NodeID) {
        guard node(id) != nil else { return }
        var affected: [NodeID] = [id]
        for r in allRoads where r.touches(id) {
            affected.append(r.otherEnd(id))
            data.roads[r.id.raw] = nil
        }
        data.nodes[id.raw] = nil
        touched(affected)
    }

    public func moveNode(_ id: NodeID, to position: Vector2) {
        guard node(id) != nil else { return }
        data.nodes[id.raw]?.position = position
        touched([id] + allRoads.filter { $0.touches(id) }.map { $0.otherEnd(id) })
    }

    public func updateNode(_ id: NodeID, _ change: (inout Node) -> Void) {
        guard var n = node(id) else { return }
        change(&n)
        data.nodes[id.raw] = n
        touched([id])
    }

    public func setControl(_ control: NodeControl, at id: NodeID) {
        updateNode(id) { $0.control = control }
    }

    /// Split a road at the point nearest `p`, inserting a new node. Returns
    /// the new node, or nil if the point is too close to an end.
    @discardableResult
    public func splitRoad(_ id: RoadID, near p: Vector2, minEndDistance: Double = 12) -> NodeID? {
        guard let r = road(id), let na = node(r.a), let nb = node(r.b) else { return nil }
        let line = centreline(of: r, a: na.position, b: nb.position)
        let proj = line.project(p)
        guard proj.s > minEndDistance && proj.s < line.length - minEndDistance else { return nil }
        let at = line.point(at: proj.s)
        var newNode: NodeID?
        batch {
            let n = addNode(at: at)
            newNode = n
            // Each half keeps the exact curve: a curved road's halves take the
            // smoothed centreline itself as their shape (a spline through
            // densely spaced points of a curve reproduces it), so nothing
            // driving on it moves.
            let dense = !r.shape.isEmpty
            let shapeA = dense ? line.points.filter { line.project($0).s > 0.5 && line.project($0).s < proj.s - 1.5 }
                               : []
            let shapeB = dense ? line.points.filter { line.project($0).s > proj.s + 1.5 && line.project($0).s < line.length - 0.5 }
                               : []
            data.roads[id.raw]?.b = n
            data.roads[id.raw]?.shape = shapeA
            var second = Road(id: RoadID(data.roads.count), a: n, b: r.b, shape: shapeB, roadClass: r.roadClass,
                          lanesForward: r.lanesForward, lanesBackward: r.lanesBackward, oneWay: r.isOneWay)
            second.speedLimitOverride = r.speedLimitOverride
            second.level = r.level
            second.isBridge = r.isBridge
            second.turnPockets = r.turnPockets
            second.kerbTurnLanes = r.kerbTurnLanes
            data.roads.append(second)
            touched([r.a, r.b, n])
        }
        return newNode
    }

    public func addRoundabout(_ r: Roundabout) -> Int {
        var r = r
        let id = data.roundabouts.count
        r = Roundabout(id: id, center: r.center, radius: r.radius, ringNodes: r.ringNodes, ringRoads: r.ringRoads)
        data.roundabouts.append(r)
        touched(r.ringNodes)
        return id
    }

    public func removeRoundabout(_ id: Int) {
        guard id < data.roundabouts.count, let r = data.roundabouts[id] else { return }
        data.roundabouts[id] = nil
        touched(r.ringNodes)
    }

    public var allRoundabouts: [Roundabout] { data.roundabouts.compactMap { $0 } }

    /// Replace the whole authored state (load / undo).
    public func replace(with newData: NetworkData) {
        data = newData
        dirty = true
        pendingChanged = Set(allNodes.map { $0.id })
        if batchDepth == 0 { rebuild() }
    }

    // MARK: - Geometry helpers

    /// The full (untrimmed) centreline of a road from `a` to `b`.
    public func centreline(of road: Road, a: Vector2, b: Vector2) -> Polyline {
        let pts = [a] + road.shape + [b]
        if pts.count == 2 { return Polyline(pts) }
        return Polyline(Curves.catmullRom(through: pts, maxSpacing: 3.0))
    }

    public func centreline(of id: RoadID) -> Polyline? {
        guard let r = road(id), let a = node(r.a), let b = node(r.b) else { return nil }
        return centreline(of: r, a: a.position, b: b.position)
    }

    // MARK: - Rebuild

    /// A hash of the derived shape: every carriageway's reference line and
    /// lanes, every junction surface, the node levels and regional flags, and
    /// the movements through each junction.
    private func shapeSignature() -> Int {
        var h = Hasher()
        func add(_ v: Vector2) { h.combine(v.x); h.combine(v.y) }
        for e in edges {
            guard let e else { h.combine(-1); continue }
            h.combine(e.road.raw); h.combine(e.level); h.combine(e.isBridge); h.combine(e.roadClass.rawValue)
            for p in e.reference.points { add(p) }
            for l in e.lanes { h.combine(l.lateral); h.combine(l.width); h.combine(l.sStart); h.combine(l.sEnd); h.combine(l.kind.rawValue) }
        }
        for g in nodeGeometry {
            guard let g else { h.combine(-2); continue }
            add(g.center)
            for p in g.surface { add(p) }
        }
        for n in data.nodes {
            guard let n else { continue }
            h.combine(n.level); h.combine(n.isRegionalConnection)
        }
        // The movements (they give the lane arrows).
        for c in connectors { h.combine(c.from); h.combine(c.to); h.combine(c.turn.rawValue) }
        return h.finalize()
    }

    public func rebuild() {
        var builder = NetworkBuilder(data: data, config: config)
        let result = builder.build()
        for (i, eff) in result.effectiveControls.enumerated() where data.nodes[i] != nil {
            data.nodes[i]?.effectiveControl = eff
        }
        edges = result.edges
        connectors = result.connectors
        nodeGeometry = result.nodeGeometry
        connectorsFrom = result.connectorsFrom
        connectorsInto = result.connectorsInto
        connectorsAtNode = result.connectorsAtNode
        incomingEdges = result.incoming
        outgoingEdges = result.outgoing
        successors = result.successors
        majorApproaches = result.majorApproaches
        conflicts = ConflictMap.build(network: self)
        version += 1
        let sig = shapeSignature()
        if sig != geometrySignature { geometrySignature = sig; geometryVersion += 1 }
        lastChangedNodes = pendingChanged
        pendingChanged = []
        dirty = false
    }
}
