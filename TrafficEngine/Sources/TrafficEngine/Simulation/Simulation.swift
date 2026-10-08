//
//  Simulation.swift
//  TrafficEngine
//
//  The headless world and its fixed-timestep loop. One `step()` runs these
//  stages, in this order (each in its own file):
//
//   1. Signals      — advance signal controllers from detector calls      (Signals.swift)
//   2. Demand       — departures, external traffic, police dispatch       (StageDemand.swift)
//   3. Index        — per-lane / per-connector occupancy, sorted by s     (StageIndex.swift)
//   4. Junctions    — plan connectors, gap acceptance, commit reservations(StageJunctions.swift)
//   5. Lane changes — MOBIL decisions, signalling, lateral manoeuvres     (StageLaneChange.swift)
//   6. Motion       — IDM accelerations, reaction time, jerk, integrate   (StageMotion.swift)
//   7. Tracks       — cross stop lines / junction exits, arrivals         (StageTracks.swift)
//   8. Pose, metrics, invariants, compaction                             (StagePose.swift, Metrics)
//
//  Determinism: vehicles live in an array ordered by id; every stage
//  iterates in index order or in an explicitly sorted order; the RNG is a
//  single seeded stream stored in the save file.
//

struct LaneChoiceKey: Hashable {
    var edge: Int32
    var next: Int32
    var after: Int32
}

public struct SimEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case gridlockDetected, gridlockResolved, missedTurn, forcedStop, controlUpgraded, controlSuggested,
             incident, dispatch, arrivedOnScene, incidentCleared, tripUnroutable
    }
    public var time: Double
    public var kind: Kind
    public var text: String
}

struct MovementKey: Hashable {
    let from: LaneID
    let to: LaneID
}

public final class Simulation {

    // MARK: World
    public let network: RoadNetwork
    public var terrain: Terrain
    public var config: SimulationConfig
    public internal(set) var time: Double = 0
    public internal(set) var stepCount: Int = 0
    var rng: SeededRandom
    public internal(set) var vehicles: [Vehicle] = []
    var nextVehicleID = 0

    // MARK: Subsystems
    public internal(set) var signals = SignalSystem()
    public let router: Router
    public let metrics = MetricsCollector()
    public internal(set) var city = CityState()
    public internal(set) var police = PoliceState()
    public internal(set) var events: [SimEvent] = []
    public internal(set) var warrants = WarrantState()
    public internal(set) var gridlock = GridlockState()
    /// Optional per-step invariant checking (tests / CLI soak).
    public var invariantChecker: InvariantChecker?

    // MARK: Derived (rebuilt on network change)
    var laneBase: [Int] = []
    var laneOcc: [[Occupant]] = []
    var connOcc: [[Occupant]] = []
    var connCommits: [[Int32]] = []
    var builtNetworkVersion = -1
    /// Edge geometry as of the last rebuild (to re-anchor vehicles after an edit).
    var builtEdgeRefs: [Polyline?] = []
    var builtLaneLats: [[Double]] = []
    /// Sim time of the last network edit (vehicles get a moment to adapt).
    public internal(set) var lastNetworkEdit = -Double.infinity
    var sirenSources: [Int] = []
    /// Vehicles parked, waiting in, or turning into / out of a driveway (rebuilt with the index).
    var kerbside: [Int] = []
    private var populationCache: (step: Int, value: Int) = (-1, 0)
    /// Lane choices that depend only on the network (cleared on every rebuild).
    var laneChoiceCache: [LaneChoiceKey: Set<Int>] = [:]

    /// Residents, recounted once per simulated second (the count walks every person).
    func currentPopulation() -> Int {
        let bucket = stepCount / 20
        if populationCache.step != bucket { populationCache = (bucket, city.population) }
        return populationCache.value
    }
    /// Per-step scratch (recomputed every step, never saved).
    var stopTargets: [Double?] = []
    var courtesyLeader: [Int] = []
    var movementKeys: [MovementKey] = []
    public internal(set) var gridlockVehicles: Set<VehicleID> = []
    public var debugForcedStops = false
    /// Profiling: called after each stage of a step with the stage number.
    public var stageHook: ((Int) -> Void)?
    public static let stageNames = ["index", "signals", "demand", "index2", "junctions", "laneChanges", "services",
                                    "motion", "tracks", "poses", "metrics", "warrants", "gridlock", "servicesPost"]
    /// Test/diagnostic hooks: a vehicle committed to a connector, and a vehicle
    /// crossed a stop line (with the signal indication at that instant).
    public var onCommit: ((Vehicle, Connector) -> Void)?
    public var onJunctionEntry: ((Vehicle, Connector, SignalIndication) -> Void)?
    /// Optional trace hook for one vehicle (debugging).
    public var debugVehicle: VehicleID?
    public var debugLog: ((String) -> Void)?
    func trace(_ i: Int, _ msg: @autoclosure () -> String) {
        if let d = debugVehicle, vehicles[i].id == d { debugLog?("t=\(time) \(d): \(msg())") }
    }

    struct Occupant {
        var s: Double
        var index: Int32
    }

    public init(network: RoadNetwork, terrain: Terrain = Terrain(), config: SimulationConfig = SimulationConfig()) {
        self.network = network
        self.terrain = terrain
        self.config = config
        self.rng = SeededRandom(seed: config.seed)
        self.router = Router(network: network)
        networkDidChange()
    }

    public var side: DrivingSide { network.side }

    /// Clock seconds since Monday 00:00.
    public var clock: Double { config.startClock + time * config.clockScale }
    public var clockHour: Double { (clock / 3600).truncatingRemainder(dividingBy: 24) }
    public var dayIndex: Int { Int(clock / 86400) }
    public var dayOfWeek: Int { dayIndex % 7 }   // 0 = Monday
    public var isWeekend: Bool { dayOfWeek >= 5 }

    public var clockString: String {
        let h = Int(clockHour), m = Int((clockHour - Double(h)) * 60)
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }

    public static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    // MARK: - Network changes

    /// Rebuild derived state after the network was edited. Vehicles on
    /// removed roads leave gracefully; others are re-anchored.
    /// Set when vehicles were removed after the last index rebuild.
    var indexStale = false

    /// The network shape the city's driveways were last anchored to.
    var builtGeometryVersion = -1

    public func networkDidChange() {
        if builtNetworkVersion == network.version && !laneBase.isEmpty { return }
        builtNetworkVersion = network.version
        laneChoiceCache.removeAll()
        laneBase = []
        var total = 0
        for i in 0..<network.edgeSlotCount {
            laneBase.append(total)
            total += network.edges[i]?.lanes.count ?? 0
        }
        laneOcc = Array(repeating: [], count: total)
        connOcc = Array(repeating: [], count: network.connectors.count)
        connCommits = Array(repeating: [], count: network.connectors.count)
        router.refresh()
        signals.rebuild(network: network, config: config, time: time)
        // Driveways depend on the shape of the roads only (not on control).
        if builtGeometryVersion != network.geometryVersion {
            builtGeometryVersion = network.geometryVersion
            city.networkDidChange(self)
        }
        if !builtEdgeRefs.isEmpty { lastNetworkEdit = time }
        reconcileVehiclesAfterEdit(oldRefs: builtEdgeRefs, oldLanes: builtLaneLats)
        builtEdgeRefs = network.edges.map { $0?.reference }
        builtLaneLats = network.edges.map { $0?.lanes.map { $0.lateral } ?? [] }
    }

    // MARK: - Vehicles

    @discardableResult
    public func addVehicle(cls: VehicleClass = .car, driver: Driver? = nil, edge: EdgeID, lane: Int, s: Double,
                           speed: Double = 0, route: [EdgeID]? = nil, destination: Destination? = nil,
                           purpose: TripPurpose = .other, mode: VehicleMode = .driving) -> VehicleID? {
        guard let e = network.edge(edge), let l = e.lane(lane) else { return nil }
        let r = route ?? [edge]
        guard r.first == edge else { return nil }
        let last = network.edge(r.last!)!
        let dest = destination ?? Destination(kind: .exitMap, edge: r.last!, s: last.length)
        let id = VehicleID(nextVehicleID)
        nextVehicleID += 1
        let d = driver ?? Driver.sample(for: cls, rng: &rng, meanAggressiveness: config.meanAggressiveness)
        var v = Vehicle(id: id, cls: cls, driver: d, colorIndex: rng.nextInt(64), track: .edge(edge), s: s,
                        lane: lane, lateral: l.lateral, speed: speed, route: r, destination: dest,
                        mode: mode, purpose: purpose, spawnTime: time)
        v.edgeEnterTime = time
        v.edgeEnterS = s
        updatePose(&v)
        vehicles.append(v)
        metrics.recordSpawn()
        return id
    }

    public func index(of id: VehicleID) -> Int? {
        // Vehicles are sorted by id: binary search.
        var lo = 0, hi = vehicles.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = vehicles[mid].id.raw
            if r == id.raw { return mid }
            if r < id.raw { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public func vehicle(_ id: VehicleID) -> Vehicle? { index(of: id).map { vehicles[$0] } }

    func log(_ kind: SimEvent.Kind, _ text: String) {
        events.append(SimEvent(time: time, kind: kind, text: text))
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    // MARK: - Step

    public func step() {
        let dt = config.dt
        if builtNetworkVersion != network.version { networkDidChange() }
        time += dt
        stepCount += 1

        let hook = stageHook
        rebuildIndex(); hook?(0)
        signals.advance(sim: self, dt: dt); hook?(1)
        updateDemand(dt: dt); hook?(2)
        rebuildIndex(); hook?(3)
        updateJunctions(dt: dt); hook?(4)
        updateLaneChanges(dt: dt); hook?(5)
        updateServices(dt: dt); hook?(6)
        updateMotion(dt: dt); hook?(7)
        advanceTracks(); hook?(8)
        for i in vehicles.indices where vehicles[i].mode != .finished { updatePose(&vehicles[i]) }
        hook?(9)
        updateMetrics(dt: dt); hook?(10)
        updateWarrants(); hook?(11)
        updateGridlock(dt: dt); hook?(12)
        updateServicesPostStep(dt: dt); hook?(13)
        invariantChecker?.check(self)
        compact()
    }

    /// Run for `seconds` of simulated time.
    public func run(seconds: Double) {
        let n = Int((seconds / config.dt).rounded())
        for _ in 0..<n { step() }
    }

    func compact() {
        guard vehicles.contains(where: { $0.mode == .finished }) else { return }
        vehicles.removeAll { $0.mode == .finished }
        indexStale = true
    }

    /// The occupancy index holds vehicle indices; after `compact()` they are
    /// stale until the next step rebuilds them. Entry points used between
    /// steps (spawning, diagnostics) call this first.
    func ensureIndex() {
        if builtNetworkVersion != network.version { networkDidChange() }
        if indexStale { rebuildIndex() }
    }

    // MARK: - Geometry helpers

    func laneKey(_ edge: EdgeID, _ lane: Int) -> Int { laneBase[edge.raw] + lane }

    func trackLength(_ t: Track) -> Double {
        switch t {
        case .edge(let e): return network.edge(e)?.length ?? 0
        case .connector(let c): return network.connector(c)?.length ?? 0
        }
    }

    func speedLimit(of t: Track) -> Double {
        switch t {
        case .edge(let e): return network.edge(e)?.speedLimit ?? 13.9
        case .connector(let c): return network.connector(c)?.speedLimit ?? 8
        }
    }

    /// World position on a track (lateral only applies to edges).
    func position(on t: Track, s: Double, lateral: Double) -> Vector2 {
        switch t {
        case .edge(let e):
            guard let edge = network.edge(e) else { return .zero }
            return edge.reference.extendedPoint(at: s, lateral: lateral)
        case .connector(let c):
            guard let conn = network.connector(c) else { return .zero }
            return conn.path.extendedPoint(at: s)
        }
    }

    func tangent(on t: Track, s: Double) -> Vector2 {
        switch t {
        case .edge(let e): return network.edge(e)?.reference.tangent(at: s) ?? Vector2(1, 0)
        case .connector(let c): return network.connector(c)?.path.tangent(at: s) ?? Vector2(1, 0)
        }
    }
}
