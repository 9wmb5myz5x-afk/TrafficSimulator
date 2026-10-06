//
//  DerivedGeometry.swift
//  TrafficEngine
//
//  Geometry derived from the authored network by `NetworkBuilder`:
//  directed carriageways (edges), lanes, junction surfaces and turn
//  connectors. None of this is saved; it is rebuilt deterministically.
//
//  Coordinate convention: every vehicle on an edge is positioned by the
//  edge's *reference* arc length `s` (the road centreline, trimmed at both
//  junctions and oriented in the direction of travel) plus a lateral offset
//  (left-positive). All lanes of an edge share the same `s`, so a lane change
//  only moves the lateral coordinate.
//

public enum LaneKind: String, Codable, Sendable {
    /// A through lane for the full length of the edge.
    case travel
    /// Across-traffic turn pocket (left pocket for `.right`), opens near the end.
    case acrossPocket
    /// Kerb-side turn lane (right-turn lane for `.right`), opens near the end.
    case kerbTurn
    /// Highway acceleration lane after an on-ramp merge; ends after a taper.
    case acceleration
    /// Highway deceleration lane before an off-ramp diverge.
    case deceleration
}

public struct Lane: Sendable, Identifiable {
    public let id: LaneID
    public let kind: LaneKind
    /// Lateral offset of the lane centre from the reference line (left-positive) [m].
    public let lateral: Double
    public let width: Double
    /// The lane is usable (full width) for s in `sStart...sEnd`.
    public let sStart: Double
    public let sEnd: Double
    /// Rendering tapers: the lane widens from `taperStart` to `sStart`, and
    /// narrows from `sEnd` to `taperEnd`.
    public let taperStart: Double
    public let taperEnd: Double
    /// Movements permitted from this lane at the downstream junction (lane-use arrows).
    public internal(set) var movements: Set<TurnDirection> = []

    public var index: Int { id.index }
    public var edge: EdgeID { id.edge }
    public func exists(at s: Double) -> Bool { s >= sStart - 1e-9 && s <= sEnd + 1e-9 }
}

/// A directed carriageway between two nodes.
///
/// A class: the step loop looks edges up millions of times a second, and a
/// struct holding arrays is retained / released field by field on every copy.
/// Edges are immutable once the network is built (only the builder sets lane
/// movements), so sharing them is safe.
public final class Edge: @unchecked Sendable, Identifiable {
    public let id: EdgeID
    public let road: RoadID
    public let from: NodeID
    public let to: NodeID
    public let roadClass: RoadClass
    public let speedLimit: Double
    public let level: Int
    public let isBridge: Bool
    /// Trimmed centreline in the direction of travel. Lateral 0 = road centre.
    public let reference: Polyline
    /// Ordered kerb-most (index 0) to centre-most.
    public internal(set) var lanes: [Lane]
    /// Number of `.travel` lanes.
    public let travelLanes: Int
    public let isOneWay: Bool
    /// Cached `reference.length`.
    public let length: Double

    init(id: EdgeID, road: RoadID, from: NodeID, to: NodeID, roadClass: RoadClass, speedLimit: Double, level: Int,
         isBridge: Bool, reference: Polyline, lanes: [Lane], travelLanes: Int, isOneWay: Bool) {
        self.id = id; self.road = road; self.from = from; self.to = to; self.roadClass = roadClass
        self.speedLimit = speedLimit; self.level = level; self.isBridge = isBridge; self.reference = reference
        self.lanes = lanes; self.travelLanes = travelLanes; self.isOneWay = isOneWay
        self.length = reference.length
    }
    public var laneWidth: Double { roadClass.laneWidth }

    public func lane(_ index: Int) -> Lane? {
        index >= 0 && index < lanes.count ? lanes[index] : nil
    }

    /// World position of a point on the carriageway.
    public func position(s: Double, lateral: Double) -> Vector2 {
        reference.position(at: s, lateral: lateral)
    }

    /// Lanes that reach the stop line.
    public var lanesAtEnd: [Lane] { lanes.filter { $0.sEnd >= length - 1e-6 } }
    /// Lanes that exist at s = 0.
    public var lanesAtStart: [Lane] { lanes.filter { $0.sStart <= 1e-6 } }
}

/// One permitted movement from an approach lane to an exit lane through a node
/// (a class for the same reason as `Edge`).
public final class Connector: @unchecked Sendable, Identifiable {
    public let id: ConnectorID
    public let node: NodeID
    public let from: LaneID
    public let to: LaneID
    public let turn: TurnDirection
    public let path: Polyline
    /// Comfortable speed through the curve: √(a_lat · R_min), capped by the limits [m/s].
    public let speedLimit: Double
    /// Cached `path.length`.
    public let length: Double

    init(id: ConnectorID, node: NodeID, from: LaneID, to: LaneID, turn: TurnDirection, path: Polyline, speedLimit: Double) {
        self.id = id; self.node = node; self.from = from; self.to = to; self.turn = turn
        self.path = path; self.speedLimit = speedLimit; self.length = path.length
    }
    public var fromEdge: EdgeID { from.edge }
    public var toEdge: EdgeID { to.edge }
}

/// Junction geometry: where each road stops, and the paved surface.
public struct NodeGeometry: Sendable {
    public struct RoadEnd: Sendable {
        public let road: RoadID
        /// Unit direction pointing away from the node along the road.
        public let direction: Vector2
        public let angle: Double
        /// Half the paved width at this end (incl. shoulders and flares) [m].
        public let halfWidth: Double
        /// Distance from node centre to the stop line [m].
        public let setback: Double
        /// Edge arriving at the node from this road (nil if one-way away).
        public let incoming: EdgeID?
        /// Edge leaving the node along this road.
        public let outgoing: EdgeID?
    }
    public let node: NodeID
    public let center: Vector2
    /// Road ends in counter-clockwise angle order.
    public let ends: [RoadEnd]
    /// Paved junction surface (CCW polygon). Empty for simple continuations.
    public let surface: [Vector2]
    public var degree: Int { ends.count }
    public var isDeadEnd: Bool { ends.count == 1 }
}
