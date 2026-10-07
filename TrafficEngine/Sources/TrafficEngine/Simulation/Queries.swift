//
//  Queries.swift
//  TrafficEngine
//
//  Read-only queries for the UI: hit-testing and inspector cards. They live
//  in the engine so they are unit-tested on every platform; the app only
//  renders the results.
//

public enum EntityRef: Hashable, Sendable {
    case vehicle(VehicleID)
    case building(BuildingID)
    case junction(NodeID)
    case road(RoadID)
}

public struct InspectorInfo: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    /// (label, value) rows.
    public var rows: [Row]
    /// World polyline to highlight (a vehicle's route, a road's centreline).
    public var highlight: [Vector2]
    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: String
    }
}

extension Simulation {

    /// The entity under a world point: vehicles first, then buildings,
    /// junctions and roads (`radius` in metres, e.g. a fingertip at the zoom).
    public func hitTest(_ p: Vector2, radius: Double) -> EntityRef? {
        var best: (EntityRef, Double)?
        func offer(_ r: EntityRef, _ d: Double) { if d <= radius && (best == nil || d < best!.1) { best = (r, d) } }
        for v in vehicles where v.mode != .finished && v.mode != .waitingToEnter {
            offer(.vehicle(v.id), max(0, v.center.distance(to: p) - v.length / 2))
        }
        if let b = best { return b.0 }
        for b in city.buildings where Geometry.pointInPolygon(p, b.footprint) {
            return .building(b.id)
        }
        for n in network.allNodes where !n.isRegionalConnection && network.degree(of: n.id) >= 3 {
            offer(.junction(n.id), max(0, n.position.distance(to: p) - 8))
        }
        if let b = best { return b.0 }
        for e in network.allEdges {
            let pr = e.reference.project(p)
            let half = Double(e.lanes.count) * e.roadClass.laneWidth / 2 + e.roadClass.medianWidth / 2
            offer(.road(e.road), max(0, pr.distance - half))
        }
        return best?.0
    }

    /// A short, plain-language description of what a vehicle is doing.
    public func vehicleStatus(_ v: Vehicle) -> String {
        if v.siren { return "Responding with lights and siren" }
        switch v.mode {
        case .waitingToEnter: return "Waiting to pull out"
        case .onDriveway: return (v.driveway?.inbound ?? false) ? "Turning into the driveway" : (v.speed > 0.1 ? "Driving down the driveway" : "Waiting to pull out")
        case .pullingOut: return "Pulling out of the driveway"
        case .pullingIn: return "Turning into the driveway"
        case .parkedAtKerb: return v.hazard ? "On scene" : "Parked at the kerb"
        case .finished: return "Arrived"
        case .driving: break
        }
        if v.yieldingToEmergency { return "Pulling over for an emergency vehicle" }
        if let lc = v.laneChange {
            let left = (lc.toLateral - lc.fromLateral) > 0
            let dir = left ? "left" : "right"
            return lc.phase == .signalling ? "Signalling to change lanes \(dir)" : "Changing lanes \(dir)"
        }
        if isInGridlock(v.id) { return "Stuck in a gridlock" }
        if case .edge(let e) = v.track, let edge = network.edge(e) {
            let dEnd = edge.length - v.s
            if v.speed < 0.3 && dEnd < 8, let pc = v.plannedConnector, let conn = network.connector(pc) {
                if !exitHasRoom(index(of: v.id) ?? 0, conn) { return "Waiting: no room ahead" }
                switch network.node(conn.node)?.effectiveControl {
                case .signal?: return signals.indication(for: pc, at: conn.node) == .red ? "Waiting at a red light" : "Waiting for a gap"
                case .allWayStop?: return "Stopped at the stop sign"
                case .twoWayStop?, .yield?, .roundabout?: return "Waiting for a gap"
                default: return "Giving way"
                }
            }
            if v.speed < 0.3 { return "Queuing" }
            if v.braking { return "Slowing down" }
        }
        if case .connector = v.track { return "Crossing the junction" }
        return "Driving"
    }

    public func inspect(_ ref: EntityRef) -> InspectorInfo? {
        func kmh(_ v: Double) -> String { "\(Int((v * 3.6).rounded())) km/h" }
        func mins(_ s: Double) -> String { s < 90 ? "\(Int(s)) s" : "\(Int((s / 60).rounded())) min" }
        switch ref {
        case .vehicle(let id):
            guard let v = vehicle(id) else { return nil }
            var rows: [InspectorInfo.Row] = [
                .init(label: "Doing", value: vehicleStatus(v)),
                .init(label: "Speed", value: kmh(v.speed)),
                .init(label: "Trip", value: v.purpose.rawValue.firstCapitalized),
                .init(label: "Driver", value: v.driver.aggressiveness > 0.66 ? "Assertive" : v.driver.aggressiveness < 0.33 ? "Relaxed" : "Typical"),
                .init(label: "On the road", value: mins(time - v.spawnTime)),
            ]
            if let o = v.origin.flatMap({ city.building($0) }) { rows.insert(.init(label: "From", value: o.kind.displayName), at: 2) }
            switch v.destination.kind {
            case .building: rows.insert(.init(label: "To", value: v.destination.building.flatMap { city.building($0)?.kind.displayName } ?? "Building"), at: 2)
            case .exitMap: rows.insert(.init(label: "To", value: v.viaRegion ? "Round the block (via the map edge)" : "Out of town"), at: 2)
            case .kerb: rows.insert(.init(label: "To", value: v.siren ? "Incident" : "Patrol"), at: 2)
            }
            var route: [Vector2] = [v.front]
            for e in v.route.dropFirst(v.routeIndex) {
                guard let edge = network.edge(e) else { continue }
                route.append(contentsOf: edge.reference.points)
            }
            return InspectorInfo(title: v.cls.displayName, subtitle: "\(v.id)", rows: rows, highlight: route)
        case .building(let id):
            guard let b = city.building(id) else { return nil }
            var rows: [InspectorInfo.Row] = []
            if b.kind.isResidential { rows.append(.init(label: "Residents", value: "\(b.residents.count) of \(b.capacity)")) }
            if b.jobs > 0 { rows.append(.init(label: "Jobs filled", value: "\(b.workers) of \(b.jobs)")) }
            if b.kind == .policeStation {
                let units = police.units.filter { $0.station == id }
                rows.append(.init(label: "Units", value: units.map { $0.status.rawValue }.joined(separator: ", ")))
                if let m = police.meanResponseTime { rows.append(.init(label: "Mean response", value: mins(m))) }
            }
            let open = police.incidents.filter { $0.building == id && $0.status != .cleared }
            if !open.isEmpty { rows.append(.init(label: "Incident", value: open[0].status.rawValue.firstCapitalized)) }
            return InspectorInfo(title: b.kind.displayName, subtitle: "\(b.id)", rows: rows, highlight: b.footprint + [b.footprint[0]])
        case .junction(let n):
            guard let node = network.node(n) else { return nil }
            let m = metrics.junction(n)
            var rows: [InspectorInfo.Row] = [
                .init(label: "Control", value: node.effectiveControl.displayName + (node.control.requested == .auto ? " (automatic)" : "") + (node.control.locked ? ", locked" : "")),
                .init(label: "Level of service", value: m?.los.rawValue ?? "A"),
                .init(label: "Average delay", value: mins(m?.averageDelay ?? 0)),
                .init(label: "Queue", value: "\(Int(m?.queue ?? 0)) m"),
            ]
            if let plan = signals.plan(for: n) {
                rows.append(.init(label: "Signal", value: "\(plan.mode.rawValue.firstCapitalized), cycle \(Int(plan.cycle)) s"))
            }
            return InspectorInfo(title: "Junction", subtitle: "\(n)", rows: rows, highlight: network.geometry(of: n)?.surface ?? [])
        case .road(let r):
            guard let road = network.road(r) else { return nil }
            var rows: [InspectorInfo.Row] = [
                .init(label: "Class", value: road.roadClass.rawValue.firstCapitalized),
                .init(label: "Lanes", value: road.isOneWay ? "\(road.lanesForward) one-way" : "\(road.lanesForward) + \(road.lanesBackward)"),
            ]
            var pts: [Vector2] = []
            for fwd in [true, false] {
                guard let e = network.edge(EdgeID(road: r, forward: fwd)), let m = metrics.edge(e.id) else { continue }
                if pts.isEmpty { pts = e.reference.points }
                rows.append(.init(label: fwd ? "Flow →" : "Flow ←", value: "\(Int(m.flow)) veh/h, \(kmh(m.meanSpeed))"))
                rows.append(.init(label: "Limit", value: kmh(e.speedLimit)))
            }
            return InspectorInfo(title: road.roadClass.rawValue.firstCapitalized + " road", subtitle: "\(r)", rows: rows, highlight: pts)
        }
    }
}

extension String {
    /// First letter upper-cased (Foundation-free).
    var firstCapitalized: String { prefix(1).uppercased() + dropFirst() }
}
