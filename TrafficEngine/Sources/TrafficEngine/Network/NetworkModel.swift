//
//  NetworkModel.swift
//  TrafficEngine
//
//  The *authored* road network: what the player builds and what a save file
//  stores. Nodes (junctions) and roads are plain Codable values. All geometry
//  (carriageways, lanes, turn paths, junction surfaces) is *derived* from
//  them by `NetworkBuilder`, so one source of truth drives both simulation
//  and rendering.
//

/// How a junction is controlled.
public enum ControlType: String, Codable, Sendable, CaseIterable {
    /// Chosen automatically from road classes and measured volumes.
    case auto
    /// No signs: yield to traffic from the kerb side ("yield to the right" for `.right`).
    case uncontrolled
    /// Minor approaches yield to the major road.
    case yield
    /// Minor approaches stop, then yield to the major road.
    case twoWayStop
    /// Every approach stops; first come, first served.
    case allWayStop
    /// NEMA dual-ring traffic signal.
    case signal
    /// Circulating carriageway; entering traffic yields to circulating traffic.
    case roundabout

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .uncontrolled: return "Uncontrolled"
        case .yield: return "Yield"
        case .twoWayStop: return "Two-way stop"
        case .allWayStop: return "All-way stop"
        case .signal: return "Signal"
        case .roundabout: return "Roundabout"
        }
    }
}

/// Treatment of across-traffic (left for `.right`) turns at a signal.
public enum AcrossTurnMode: String, Codable, Sendable, CaseIterable {
    case auto
    /// Turn on the through green after yielding (flashing yellow arrow).
    case permitted
    /// Protected arrow phase, then permitted during the through green.
    case protectedPermitted
    /// Turn only on the protected arrow.
    case protectedOnly
}

public enum SignalMode: String, Codable, Sendable, CaseIterable {
    /// Vehicle-actuated: detectors extend greens, phases without demand are skipped.
    case actuated
    /// Fixed-time plan.
    case fixedTime
    /// Webster-optimal cycle and splits recomputed from measured flows.
    case adaptive
}

/// Player-editable signal settings for one junction.
public struct SignalSettings: Codable, Sendable, Equatable {
    public var mode: SignalMode = .actuated
    public var acrossTurnMode: AcrossTurnMode = .auto
    /// Coordination: junctions sharing a group run a common cycle with
    /// offsets that create a green wave. nil = free running.
    public var coordinationGroup: Int?
    /// Manual offset [s] (used when coordinated without auto offsets).
    public var offset: Double = 0
    /// Fixed-time cycle length [s] (fixed-time mode, and coordinated cycles).
    public var cycleLength: Double = 90
    public init() {}
}

public struct NodeControl: Codable, Sendable, Equatable {
    /// The control the player asked for (`.auto` = let warrants decide).
    public var requested: ControlType = .auto
    /// When locked, automatic re-evaluation never changes this junction.
    public var locked: Bool = false
    public var signal = SignalSettings()
    /// Roads forming the major (priority) street for yield / two-way-stop
    /// control. nil = chosen automatically (highest class, straightest pair).
    public var majorRoads: [RoadID]?
    /// Right-on-red (left-on-red for `.left`) permitted here; nil = city default.
    public var turnOnRed: Bool?
    public init(requested: ControlType = .auto, locked: Bool = false) {
        self.requested = requested
        self.locked = locked
    }
}

/// A junction, dead end or map-edge connection.
public struct Node: Codable, Sendable, Equatable, Identifiable {
    public let id: NodeID
    public var position: Vector2
    public var control: NodeControl
    /// Upgrade chosen by the volume-warrant evaluator for `.auto` junctions.
    public var warrantControl: ControlType?
    /// Effective control after `.auto` resolution and warrant upgrades
    /// (derived by `NetworkBuilder`).
    public internal(set) var effectiveControl: ControlType = .uncontrolled
    /// A regional connection: traffic enters/leaves the map here.
    public var isRegionalConnection: Bool = false
    /// Grade level: 0 ground, +1 elevated (bridge/overpass), −1 tunnel.
    public var level: Int = 0

    public init(id: NodeID, position: Vector2, control: NodeControl = NodeControl()) {
        self.id = id
        self.position = position
        self.control = control
    }
}

/// A road between two nodes, possibly curved, possibly one-way.
public struct Road: Codable, Sendable, Equatable, Identifiable {
    public let id: RoadID
    public var a: NodeID
    public var b: NodeID
    /// Interior shape points (world metres) between `a` and `b`; empty = straight.
    public var shape: [Vector2]
    public var roadClass: RoadClass
    /// Lanes running a → b.
    public var lanesForward: Int
    /// Lanes running b → a (0 = one-way a → b).
    public var lanesBackward: Int
    /// Speed limit override [m/s]; nil = class default.
    public var speedLimitOverride: Double?
    /// Grade level of the road body (bridges over roads/water, tunnels).
    public var level: Int = 0
    /// Crosses water (drawn as a bridge deck).
    public var isBridge: Bool = false
    /// Auto-add across-traffic turn pockets at junctions (arterials).
    public var turnPockets: Bool
    /// Auto-add kerb-side turn lanes at junctions.
    public var kerbTurnLanes: Bool = false

    public init(id: RoadID, a: NodeID, b: NodeID, shape: [Vector2] = [], roadClass: RoadClass,
                lanesForward: Int? = nil, lanesBackward: Int? = nil, oneWay: Bool? = nil) {
        self.id = id
        self.a = a
        self.b = b
        self.shape = shape
        self.roadClass = roadClass
        let n = lanesForward ?? roadClass.defaultLanes
        self.lanesForward = max(1, n)
        let isOneWay = oneWay ?? !roadClass.isTwoWayByDefault
        self.lanesBackward = isOneWay ? 0 : max(1, lanesBackward ?? n)
        self.turnPockets = roadClass == .arterial
    }

    public var isOneWay: Bool { lanesBackward == 0 }
    public var speedLimit: Double { speedLimitOverride ?? roadClass.defaultSpeedLimit }

    public func otherEnd(_ n: NodeID) -> NodeID { n == a ? b : a }
    public func touches(_ n: NodeID) -> Bool { a == n || b == n }
}
