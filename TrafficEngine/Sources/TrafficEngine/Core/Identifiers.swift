//
//  Identifiers.swift
//  TrafficEngine
//
//  Strongly typed, dense integer identifiers. Dense ids let the engine store
//  entities in arrays (fast, and iteration order is deterministic).
//

public protocol DenseID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    var raw: Int { get }
    init(_ raw: Int)
}

public extension DenseID {
    static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
}

public struct NodeID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "N\(raw)" }
}

/// A player-level road between two nodes (both directions).
public struct RoadID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "R\(raw)" }
}

/// A directed carriageway. Derived from a road: `2·road` runs A→B and
/// `2·road + 1` runs B→A, so edge ids are stable across geometry rebuilds.
public struct EdgeID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public init(road: RoadID, forward: Bool) { self.raw = road.raw * 2 + (forward ? 0 : 1) }
    public var road: RoadID { RoadID(raw >> 1) }
    public var isForward: Bool { raw & 1 == 0 }
    /// The opposite carriageway of the same road.
    public var opposite: EdgeID { EdgeID(raw ^ 1) }
    public var description: String { "E\(raw)" }
}

public struct LaneID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let edge: EdgeID
    /// 0 = kerb-most lane, increasing towards the centre of the road.
    public let index: Int
    public init(edge: EdgeID, index: Int) { self.edge = edge; self.index = index }
    public static func < (a: LaneID, b: LaneID) -> Bool {
        a.edge.raw != b.edge.raw ? a.edge.raw < b.edge.raw : a.index < b.index
    }
    public var description: String { "\(edge):\(index)" }
}

public struct ConnectorID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "C\(raw)" }
}

public struct VehicleID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "V\(raw)" }
}

public struct BuildingID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "B\(raw)" }
}

public struct PersonID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "P\(raw)" }
}

public struct IncidentID: DenseID {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "I\(raw)" }
}
