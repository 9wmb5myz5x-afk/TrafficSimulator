//
//  Building.swift
//  TrafficEngine
//
//  Buildings hold people and jobs. Every building has a driveway onto a
//  specific road: the carriageway whose kerb faces it (or, on a one-way road,
//  the outer lane on its side). Cars leave by pulling out of the driveway and
//  arrive by turning into it — they never appear or vanish on a live lane.
//

public enum BuildingKind: String, Codable, Sendable, CaseIterable {
    case house, townhouse, apartment, shop, office, factory, school, policeStation, fireStation, hospital

    /// Range of residents when fully occupied.
    public var residents: ClosedRange<Int> {
        switch self {
        case .house: return 2...4
        case .townhouse: return 6...12
        case .apartment: return 20...80
        default: return 0...0
        }
    }

    /// Jobs offered.
    public var jobs: Int {
        switch self {
        case .shop: return 12
        case .office: return 60
        case .factory: return 45
        case .school: return 25
        case .policeStation: return 15
        case .fireStation: return 10
        case .hospital: return 80
        default: return 0
        }
    }

    /// Relative attraction for shopping / errands.
    public var shopAttraction: Double {
        switch self {
        case .shop: return 1.0
        case .hospital: return 0.3
        case .office: return 0.05
        default: return 0
        }
    }

    public var parking: Int {
        switch self {
        case .house: return 3
        case .townhouse: return 10
        case .apartment: return 50
        case .shop: return 25
        case .office: return 60
        case .factory: return 40
        case .school: return 30
        case .policeStation, .fireStation: return 20
        case .hospital: return 80
        }
    }

    /// Footprint (frontage width × depth) [m] and height [storeys].
    public var size: (width: Double, depth: Double, height: Double) {
        switch self {
        case .house: return (12, 10, 1)
        case .townhouse: return (24, 11, 2)
        case .apartment: return (30, 22, 6)
        case .shop: return (22, 16, 1)
        case .office: return (28, 24, 8)
        case .factory: return (40, 30, 2)
        case .school: return (40, 26, 2)
        case .policeStation: return (26, 20, 2)
        case .fireStation: return (24, 20, 2)
        case .hospital: return (44, 34, 5)
        }
    }

    public var isResidential: Bool { self == .house || self == .townhouse || self == .apartment }
    /// Trucks are based here and make deliveries.
    public var generatesFreight: Bool { self == .factory }
    /// Daily truck deliveries made from this building.
    public var trucks: Int { self == .factory ? 6 : 0 }

    public var displayName: String {
        switch self {
        case .house: return "House"
        case .townhouse: return "Townhouses"
        case .apartment: return "Apartments"
        case .shop: return "Shop"
        case .office: return "Office"
        case .factory: return "Factory"
        case .school: return "School"
        case .policeStation: return "Police station"
        case .fireStation: return "Fire station"
        case .hospital: return "Hospital"
        }
    }
}

/// Where a building meets the road.
public struct BuildingAccess: Codable, Sendable, Equatable {
    public var road: RoadID
    /// The carriageway (directed edge) the driveway opens onto.
    public var edge: EdgeID
    /// Arc length of the driveway along `edge`.
    public var s: Double
    /// Lane index of the lane next to the driveway.
    public var lane: Int
    /// Lateral offset of the driveway mouth (left-positive, edge frame).
    public var drivewayLateral: Double
}

public struct Building: Codable, Sendable, Identifiable, Equatable {
    public let id: BuildingID
    public var kind: BuildingKind
    public var center: Vector2
    /// Facing angle (the front faces the road) [rad].
    public var rotation: Double
    public var access: BuildingAccess?
    /// Residents when full (fixed at placement).
    public var capacity: Int
    public var jobs: Int
    /// Sim time the building was placed (occupancy fills in afterwards).
    public var placedAt: Double
    public var residents: [PersonID] = []
    public var workers: Int = 0
    /// People waiting inside to drive off (only the first is a vehicle in the driveway).
    public var departureQueue: [PersonID] = []
    /// Vehicle currently waiting in / pulling out of the driveway.
    public var drivewayVehicle: VehicleID?
    public var parked: Int = 0

    public init(id: BuildingID, kind: BuildingKind, center: Vector2, rotation: Double, capacity: Int, placedAt: Double) {
        self.id = id
        self.kind = kind
        self.center = center
        self.rotation = rotation
        self.capacity = capacity
        self.jobs = kind.jobs
        self.placedAt = placedAt
    }

    /// Footprint polygon (CCW).
    public var footprint: [Vector2] {
        let s = kind.size
        let f = Vector2.unit(angle: rotation), r = f.perpendicular
        let hw = s.width / 2, hd = s.depth / 2
        return [center + r * hw - f * hd, center - r * hw - f * hd, center - r * hw + f * hd, center + r * hw + f * hd]
            .map { $0 }
    }
}

public enum PlacementError: String, Error, Sendable {
    case noRoadNearby = "No road within reach — build a road first."
    case overlapsRoad = "Too close to a road."
    case overlapsBuilding = "Overlaps another building."
    case onWater = "Can't build on water."
    case outOfBounds = "Outside the map."
    case highwayAccess = "Buildings can't connect to a highway or ramp."
}

extension Simulation {

    /// Find the driveway for a building centred at `p`: the nearest road
    /// (not a highway/ramp) within reach, on the carriageway whose kerb faces it.
    public func accessPoint(for p: Vector2, maxDistance: Double = 70) -> (BuildingAccess, distance: Double)? {
        var best: (BuildingAccess, Double)?
        for road in network.allRoads where road.roadClass != .highway && road.roadClass != .ramp {
            guard let fwd = network.edge(EdgeID(road: road.id, forward: true)) ?? network.edge(EdgeID(road: road.id, forward: false)) else { continue }
            let proj = fwd.reference.project(p)
            // Driveways need a street long enough to turn in and out clear of
            // both junctions (a car's whole body off the junction path first).
            guard fwd.length >= 30, proj.distance < maxDistance, proj.s > 6, proj.s < fwd.length - 6 else { continue }
            if let b = best, b.1 <= proj.distance { continue }
            // proj.lateral > 0: building is to the left of the forward carriageway.
            let leftOfForward = proj.lateral > 0
            var edge = fwd
            var s = proj.s
            if !road.isOneWay {
                // The carriageway whose kerb is on the building's side.
                let kerbIsLeft = side == .left
                if leftOfForward != kerbIsLeft, let back = network.edge(EdgeID(road: road.id, forward: false)) {
                    edge = back
                    s = back.length - proj.s
                }
            }
            let travel = edge.lanes.filter { $0.kind == .travel && $0.sStart <= 0 && $0.sEnd >= edge.length - 1e-6 }
            let buildingLat = edge.reference.project(p).lateral
            // The driveway opens on the building's side of the carriageway: the
            // kerb side of a two-way road's carriageway, or whichever side of a
            // one-way road the building stands (never across the centre line).
            let outward: Double
            if road.isOneWay {
                outward = buildingLat >= 0 ? 1 : -1
            } else {
                outward = side == .left ? 1 : -1
            }
            guard let lane = (outward > 0 ? travel.max(by: { $0.lateral < $1.lateral }) : travel.min(by: { $0.lateral < $1.lateral }))
            else { continue }
            let drive = lane.lateral + outward * (lane.width / 2 + edge.roadClass.shoulderWidth + 1.4)
            // Keep driveways clear of the junctions (room to pull out before a stop line).
            let lo = 12.0, hi = max(edge.length - 35, edge.length * 0.5)
            let access = BuildingAccess(road: road.id, edge: edge.id, s: s.clamped(to: lo...max(lo, hi)),
                                        lane: lane.index, drivewayLateral: drive)
            best = (access, proj.distance)
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Validate a building placement and compute its orientation.
    public func validatePlacement(kind: BuildingKind, at p: Vector2, ignoring: BuildingID? = nil)
        -> Result<(BuildingAccess, Double), PlacementError> {
        guard terrain.contains(p) else { return .failure(.outOfBounds) }
        if terrain.isWater(p) { return .failure(.onWater) }
        guard let (access, _) = accessPoint(for: p) else { return .failure(.noRoadNearby) }
        guard let edge = network.edge(access.edge) else { return .failure(.noRoadNearby) }
        // Face the road.
        let roadPoint = edge.position(s: access.s, lateral: access.drivewayLateral)
        let rotation = (roadPoint - p).angle
        let size = kind.size
        // Clear of every road surface: the building's half-depth plus a verge.
        for road in network.allRoads {
            guard let e = network.edge(EdgeID(road: road.id, forward: true)) ?? network.edge(EdgeID(road: road.id, forward: false)) else { continue }
            let pr = e.reference.project(p)
            let halfRoad = Double(road.lanesForward + road.lanesBackward) * road.roadClass.laneWidth / 2
                + road.roadClass.medianWidth / 2 + road.roadClass.shoulderWidth
            if pr.distance < halfRoad + min(size.width, size.depth) / 2 + 1.0 { return .failure(.overlapsRoad) }
        }
        for n in network.allNodes {
            if n.position.distance(to: p) < max(size.width, size.depth) / 2 + 12 { return .failure(.overlapsRoad) }
        }
        let r = max(size.width, size.depth) / 2
        for b in city.buildings where b.id != ignoring {
            let rb = max(b.kind.size.width, b.kind.size.depth) / 2
            if b.center.distance(to: p) < (r + rb) * 0.8 { return .failure(.overlapsBuilding) }
        }
        return .success((access, rotation))
    }
}
