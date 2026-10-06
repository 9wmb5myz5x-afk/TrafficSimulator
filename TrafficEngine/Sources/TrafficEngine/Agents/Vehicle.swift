//
//  Vehicle.swift
//  TrafficEngine
//
//  A microscopic agent. Position is (track, s, lateral):
//   • track — an edge (carriageway) or a connector (path through a junction)
//   • s     — arc length of the *front bumper* along the track
//   • lateral — offset from the track's reference line (left-positive);
//               on an edge this is the lane centre, or between two lanes
//               during a lane change
//  The whole struct is Codable: a save file stores it verbatim, so a loaded
//  city continues bit-identically.
//

public enum Track: Codable, Sendable, Equatable, Hashable {
    case edge(EdgeID)
    case connector(ConnectorID)
}

/// A lane change in progress: signal, then a smooth lateral move during
/// which the vehicle occupies both lanes.
public struct LaneChange: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case signalling, moving }
    public var fromLane: Int
    public var toLane: Int
    public var phase: Phase
    /// Seconds spent in the current phase.
    public var elapsed: Double = 0
    /// Lateral progress u ∈ [0, 1] (quintic profile).
    public var progress: Double = 0
    /// Planned lateral-motion duration [s].
    public var duration: Double
    public var mandatory: Bool
    /// True while returning to the original lane after an abort.
    public var aborted: Bool = false
    public var fromLateral: Double
    public var toLateral: Double
}

public enum VehicleMode: String, Codable, Sendable {
    /// Waiting in a driveway / lot for a gap to pull out.
    case waitingToEnter
    /// Pulling out of a driveway into the kerb lane.
    case pullingOut
    case driving
    /// Turning off the carriageway into the destination driveway.
    case pullingIn
    /// Stopped at the kerb (police on scene, patrol break, pulled over).
    case parkedAtKerb
    /// Left the network; removed at the end of the step.
    case finished
}

public enum TripPurpose: String, Codable, Sendable {
    case work, home, shop, school, freight, through, patrol, emergency, other
}

/// Where the trip ends.
public struct Destination: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case exitMap, building, kerb }
    public var kind: Kind
    public var edge: EdgeID
    /// Arc length on `edge` of the driveway / stopping point.
    public var s: Double
    public var building: BuildingID?
    public init(kind: Kind, edge: EdgeID, s: Double, building: BuildingID? = nil) {
        self.kind = kind
        self.edge = edge
        self.s = s
        self.building = building
    }
}

public struct Vehicle: Codable, Sendable, Identifiable {
    public let id: VehicleID
    public var cls: VehicleClass
    public var driver: Driver
    public var colorIndex: Int

    // MARK: Kinematics
    public var track: Track
    public var s: Double
    /// Primary lane index on the current edge (the lane it is "in").
    public var lane: Int
    public var lateral: Double
    /// Lateral velocity [m/s] (for heading and body yaw).
    public var lateralSpeed: Double = 0
    /// Body yaw relative to the track direction [rad], continuous state.
    public var bodyYaw: Double = 0
    /// Lateral offset of the rear bumper on the current edge (continuous state).
    public var rearLateral: Double? = nil
    public var speed: Double
    public var acceleration: Double = 0
    /// Acceleration held between reaction points.
    public var heldAcceleration: Double = 0
    public var reactionTimer: Double = 0
    public var laneChange: LaneChange?
    /// A lane change the route needs is pending: 0 none, 1 preferred lane
    /// (pre-positioning for a later turn), 2 required lane (the next turn).
    /// The driver slows down to find a gap rather than miss the turn.
    public var laneNeed: UInt8 = 0
    /// Lane changes still needed for `laneNeed`.
    public var laneNeedCount: UInt8 = 0

    /// The track the rear of the vehicle is still on after the front crossed
    /// a boundary, and that track's length.
    public var tailTrack: Track?
    public var tailTrackLength: Double = 0

    // MARK: Route
    public var route: [EdgeID]
    public var routeIndex: Int = 0
    public var destination: Destination
    /// Connector chosen for the next junction, and whether the vehicle has
    /// committed to it (holds a reservation).
    public var plannedConnector: ConnectorID?
    public var committed: Bool = false
    /// Sim time at which the vehicle came to a full stop at the current stop line.
    public var stopArrival: Double?
    /// Time spent waiting at the current stop line [s].
    public var lineWait: Double = 0
    public var rerouteTimer: Double = 0
    public var missedTurns: Int = 0
    /// Sim time this driver last let a merging car in (zipper: one at a time).
    public var letInAt: Double = -1e9

    // MARK: State
    public var mode: VehicleMode
    public var modeTimer: Double = 0
    public var purpose: TripPurpose
    public var person: PersonID?
    public var origin: BuildingID?
    /// Leaving the map only to turn round beyond it and drive back in (the
    /// building it is heading for can't be reached from inside the map).
    public var viaRegion: Bool = false
    /// Lane next to the destination driveway (must be in it to turn in).
    public var destinationLane: Int?
    public var siren: Bool = false
    public var hazard: Bool = false
    /// Lateral shift towards the kerb while yielding to an emergency vehicle [m].
    public var pullOverShift: Double = 0
    public var yieldingToEmergency: Bool = false

    // MARK: Metrics
    public var spawnTime: Double
    public var distance: Double = 0
    public var delay: Double = 0
    public var stationaryTime: Double = 0
    /// When / where the vehicle entered its current edge (control delay).
    public var edgeEnterTime: Double = 0
    public var edgeEnterS: Double = 0

    // MARK: Derived pose (recomputed every step)
    public var center: Vector2 = .zero
    public var heading: Double = 0
    public var front: Vector2 = .zero
    public var braking: Bool = false

    public init(id: VehicleID, cls: VehicleClass, driver: Driver, colorIndex: Int, track: Track, s: Double,
                lane: Int, lateral: Double, speed: Double, route: [EdgeID], destination: Destination,
                mode: VehicleMode, purpose: TripPurpose, spawnTime: Double) {
        self.id = id
        self.cls = cls
        self.driver = driver
        self.colorIndex = colorIndex
        self.track = track
        self.s = s
        self.lane = lane
        self.lateral = lateral
        self.speed = speed
        self.route = route
        self.destination = destination
        self.mode = mode
        self.purpose = purpose
        self.spawnTime = spawnTime
    }

    public var length: Double { cls.length }
    public var width: Double { cls.width }

    public var currentEdge: EdgeID? {
        if case .edge(let e) = track { return e }
        return nil
    }

    /// The route edge after the current one.
    public var nextRouteEdge: EdgeID? {
        routeIndex + 1 < route.count ? route[routeIndex + 1] : nil
    }

    public var isOnFinalEdge: Bool { routeIndex >= route.count - 1 }

    /// Blinker: −1 left, +1 right, 0 off.
    public func blinker(side: DrivingSide) -> Int {
        if hazard { return 2 }
        guard let lc = laneChange, !lc.aborted else {
            if mode == .pullingIn || mode == .parkedAtKerb || pullOverShift > 0.3 {
                return side == .right ? 1 : -1
            }
            if mode == .pullingOut || mode == .waitingToEnter { return side == .right ? -1 : 1 }
            return 0
        }
        return lc.toLateral > lc.fromLateral ? -1 : 1
    }

    public var footprint: OrientedBox {
        OrientedBox(center: center, axis: Vector2.unit(angle: heading), halfLength: length / 2, halfWidth: width / 2)
    }
}
