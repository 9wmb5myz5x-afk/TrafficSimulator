//
//  RoadClass.swift
//  TrafficEngine
//
//  Functional road classification (local → collector → arterial → highway,
//  plus ramps), with the geometric and operational defaults of each class.
//

public enum RoadClass: String, Codable, Sendable, CaseIterable {
    case local
    case collector
    case arterial
    case highway
    case ramp

    /// Default lanes per direction.
    public var defaultLanes: Int {
        switch self {
        case .local, .collector, .ramp: return 1
        case .arterial: return 2
        case .highway: return 3
        }
    }

    public var maxLanes: Int {
        switch self {
        case .local: return 1
        case .collector: return 2
        case .arterial: return 3
        case .highway: return 4
        case .ramp: return 2
        }
    }

    /// Default speed limit [m/s].
    public var defaultSpeedLimit: Double {
        switch self {
        case .local: return 30 / 3.6
        case .collector: return 40 / 3.6
        case .arterial: return 60 / 3.6
        case .highway: return 100 / 3.6
        case .ramp: return 60 / 3.6
        }
    }

    /// Lane width [m].
    public var laneWidth: Double {
        switch self {
        case .local: return 3.0
        case .collector: return 3.25
        case .arterial: return 3.5
        case .highway, .ramp: return 3.65
        }
    }

    /// Width of the central median on two-way roads [m]. Arterials and
    /// highways have a median wide enough to hold a left-turn pocket.
    public var medianWidth: Double {
        switch self {
        case .local, .collector, .ramp: return 0.3
        case .arterial: return 3.5
        case .highway: return 4.0
        }
    }

    /// Paved shoulder / parking strip outside the kerb lane [m]. Vehicles pull
    /// onto it for emergency vehicles.
    public var shoulderWidth: Double {
        switch self {
        case .local: return 2.2
        case .collector: return 2.0
        case .arterial: return 1.5
        case .highway: return 2.5
        case .ramp: return 1.5
        }
    }

    /// Kerb radius at junction corners [m].
    public var cornerRadius: Double {
        switch self {
        case .local: return 5
        case .collector: return 7
        case .arterial: return 9
        case .highway, .ramp: return 12
        }
    }

    /// Hierarchy rank used for priority and control warrants.
    public var rank: Int {
        switch self {
        case .local: return 0
        case .collector: return 1
        case .arterial: return 2
        case .ramp: return 3
        case .highway: return 4
        }
    }

    /// Highways are built as two one-way carriageways (so interchanges attach
    /// ramps to the correct side); ramps are one-way.
    public var isTwoWayByDefault: Bool { self != .ramp && self != .highway }

    /// Highways are grade-separated: they may only meet highways and ramps.
    public var isGradeSeparated: Bool { self == .highway }

    /// Distance before a stop line inside which lane changes are prohibited [m].
    public var noLaneChangeZone: Double {
        switch self {
        case .local: return 8
        case .collector: return 12
        case .arterial: return 15
        case .highway, .ramp: return 20
        }
    }

    /// Distance before a junction at which drivers start positioning for a
    /// turn (per lane that must be crossed) [m].
    public var prepositionDistance: Double {
        switch self {
        case .local: return 80
        case .collector: return 120
        case .arterial: return 160
        case .highway: return 400
        case .ramp: return 150
        }
    }

    public var displayName: String {
        switch self {
        case .local: return "Local street"
        case .collector: return "Collector"
        case .arterial: return "Arterial"
        case .highway: return "Highway"
        case .ramp: return "Ramp"
        }
    }
}
