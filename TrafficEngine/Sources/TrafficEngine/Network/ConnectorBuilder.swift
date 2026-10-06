//
//  ConnectorBuilder.swift
//  TrafficEngine
//
//  Builds the lane-to-lane movements through every junction.
//
//  Lane-use assignment ("turn into the corresponding lane"):
//   • Through: approach lanes map to exit lanes aligned from the *centre*
//     side, so lanes added after a junction appear at the kerb. Surplus kerb
//     lanes become kerb-turn-only if a kerb turn exists, else they merge.
//   • Across-traffic turns leave from the pockets if any, else the centre-most
//     lane, and enter the exit's centre-most lanes (k-th → k-th).
//   • Kerb turns leave from the kerb turn lane / deceleration lane if any,
//     else the kerb lane, and enter the exit's kerb-most lanes.
//   • An approach that is not the mainline feeder of an exit with an
//     acceleration lane (an on-ramp) enters that acceleration lane.
//   • U-turns exist only at dead ends, around a cul-de-sac bulb.
//

struct ConnectorBuilder {
    static let bulbRadius = 11.0
    static let bulbOffset = 6.0   // bulb centre lies 6 m beyond the dead-end node

    let builder: NetworkBuilder
    var edges: [Edge?]
    let ends: [[NetworkBuilder.End]]
    let turnTables: [TurnTable]
    let effectiveControls: [ControlType]

    var connectors: [Connector] = []
    var connectorsFrom: [[[ConnectorID]]] = []
    var connectorsInto: [[ConnectorID]] = []
    var connectorsAtNode: [[ConnectorID]] = []
    var successors: [[EdgeID]] = []
    var majorApproaches: [Set<EdgeID>] = []

    var side: DrivingSide { builder.side }

    init(builder: NetworkBuilder, edges: [Edge?], ends: [[NetworkBuilder.End]], turnTables: [TurnTable],
         effectiveControls: [ControlType]) {
        self.builder = builder
        self.edges = edges
        self.ends = ends
        self.turnTables = turnTables
        self.effectiveControls = effectiveControls
    }

    mutating func build() {
        let nodeCount = ends.count
        connectorsFrom = edges.map { e in Array(repeating: [], count: e?.lanes.count ?? 0) }
        connectorsInto = Array(repeating: [], count: edges.count)
        connectorsAtNode = Array(repeating: [], count: nodeCount)
        successors = Array(repeating: [], count: edges.count)
        majorApproaches = Array(repeating: [], count: nodeCount)

        for n in 0..<nodeCount {
            guard let node = builder.node(NodeID(n)) else { continue }
            // Traffic leaves the map at regional connections: no turnaround.
            if !node.isRegionalConnection { buildNode(node) }
            majorApproaches[n] = majors(at: node)
        }
    }

    // MARK: - Per node

    private mutating func buildNode(_ node: Node) {
        let nodeEnds = ends[node.id.raw]
        let table = turnTables[node.id.raw]

        // Mainline feeder for each exit that has an acceleration lane.
        var feeder: [Int: Int] = [:]   // exit end index → approach end index
        for (j, e) in nodeEnds.enumerated() {
            guard let out = e.outgoing, let outEdge = edges[out.raw],
                  outEdge.lanes.contains(where: { Self.isMergeLane($0) }) else { continue }
            var best: (Int, Int, Double)?   // (approach index, rank, |θ|)
            for (i, a) in nodeEnds.enumerated() where i != j && a.incoming != nil {
                guard let x = table.exits(from: i).first(where: { $0.index == j }), x.turn == .straight else { continue }
                let cand = (i, a.road.roadClass.rank, abs(x.angle))
                if best == nil || cand.1 > best!.1 || (cand.1 == best!.1 && cand.2 < best!.2) { best = cand }
            }
            if let b = best { feeder[j] = b.0 }
        }

        for (i, approach) in nodeEnds.enumerated() {
            guard let inID = approach.incoming, let inEdge = edges[inID.raw] else { continue }
            let atEnd = inEdge.lanesAtEnd
            let travel = atEnd.filter { $0.kind == .travel }.sorted { $0.index < $1.index }       // kerb → centre
            let pockets = atEnd.filter { $0.kind == .acrossPocket }.sorted { $0.index > $1.index } // centre-most first
            let kerbAux = atEnd.filter { $0.kind == .kerbTurn || $0.kind == .deceleration }.sorted { $0.index < $1.index }
            guard !travel.isEmpty else { continue }

            let exits = table.exits(from: i)
            let hasKerbTurn = exits.contains { $0.turn == side.kerbTurn && nodeEnds[$0.index].outgoing != nil }
            var straightExits = 0
            for x in exits where x.turn == .straight && nodeEnds[x.index].outgoing != nil { straightExits += 1 }

            // A hairpin into an adjacent leg (roads meeting at a sharp angle)
            // has no drivable path; leave it out if the approach has another exit.
            let drivable = exits.filter { x in
                guard let outID = nodeEnds[x.index].outgoing, let outEdge = edges[outID.raw] else { return false }
                return x.turn == .uTurn || abs(x.angle) < 120 * DMath.pi / 180
                    || Self.probeRadius(inEdge: inEdge, outEdge: outEdge, kerbSide: x.turn == side.kerbTurn) >= Self.minimumTurnRadius
            }
            var planned: [(turn: TurnDirection, outEdge: Edge, pairs: [(Lane, Lane)])] = []
            for x in exits {
                guard let outID = nodeEnds[x.index].outgoing, let outEdge = edges[outID.raw] else { continue }
                if !drivable.isEmpty && !drivable.contains(where: { $0.index == x.index }) { continue }
                let atStart = outEdge.lanesAtStart
                let outTravel = atStart.filter { $0.kind == .travel }.sorted { $0.index < $1.index }  // kerb → centre
                let outAccel = atStart.filter { Self.isMergeLane($0) }.sorted { $0.index < $1.index }
                guard !outTravel.isEmpty else { continue }
                var pairs: [(Lane, Lane)] = []

                if !outAccel.isEmpty, let f = feeder[x.index], f != i {
                    // On-ramp → acceleration lane, kerb-aligned.
                    for (k, l) in travel.enumerated() where k < outAccel.count { pairs.append((l, outAccel[k])) }
                } else {
                    switch x.turn {
                    case .straight:
                        var inLanes = travel
                        let outN = outTravel.count
                        if inLanes.count > outN {
                            // Lane drop through the junction.
                            let surplus = inLanes.count - outN
                            let dropped = Array(inLanes.prefix(surplus))
                            inLanes.removeFirst(surplus)
                            if !hasKerbTurn {
                                for l in dropped { pairs.append((l, outTravel[0])) }
                            }
                        }
                        // Centre-aligned mapping.
                        let m = inLanes.count
                        for k in 0..<m {
                            let inLane = inLanes[m - 1 - k]
                            let outLane = outTravel[outN - 1 - k]
                            pairs.append((inLane, outLane))
                        }
                    case side.acrossTurn:
                        let from: [Lane] = pockets.isEmpty ? [travel[travel.count - 1]] : pockets
                        let outCentreFirst = Array(outTravel.reversed())
                        for (k, l) in from.enumerated() where k < outCentreFirst.count {
                            pairs.append((l, outCentreFirst[k]))
                        }
                    case side.kerbTurn:
                        var from: [Lane] = kerbAux.isEmpty ? [travel[0]] : kerbAux
                        // Surplus kerb lanes of a lane drop turn here.
                        if kerbAux.isEmpty, straightExits > 0,
                           let sx = exits.first(where: { $0.turn == .straight }),
                           let so = nodeEnds[sx.index].outgoing, let soEdge = edges[so.raw] {
                            let outN = soEdge.lanesAtStart.filter { $0.kind == .travel }.count
                            let surplus = travel.count - outN
                            if surplus > 1 { from = Array(travel.prefix(surplus)) }
                        }
                        for (k, l) in from.enumerated() where k < outTravel.count { pairs.append((l, outTravel[k])) }
                    case .uTurn:
                        pairs.append((travel[travel.count - 1], outTravel[outTravel.count - 1]))
                    default:
                        break
                    }
                }

                planned.append((x.turn, outEdge, pairs))
            }

            // Every travel lane must lead somewhere: a lane left without a
            // movement (e.g. the middle lane at a T-junction with no straight
            // on) shares the movement of its nearest neighbour, into the
            // adjacent exit lane (a double turn).
            for lane in travel where !planned.contains(where: { $0.pairs.contains { $0.0.index == lane.index } }) {
                var best: (k: Int, neighbour: Lane, out: Lane, d: Int, pref: Int)?
                for (k, p) in planned.enumerated() {
                    let preference = p.turn == .straight ? 0 : (p.turn == side.acrossTurn) == (2 * lane.index >= travel.count) ? 1 : 2
                    for (a, b) in p.pairs {
                        let d = abs(a.index - lane.index)
                        if best == nil || d < best!.d || (d == best!.d && preference < best!.pref) {
                            best = (k, a, b, d, preference)
                        }
                    }
                }
                guard let b = best else { continue }
                let outTravel = planned[b.k].outEdge.lanesAtStart.filter { $0.kind == .travel }.sorted { $0.index < $1.index }
                guard let at = outTravel.firstIndex(where: { $0.index == b.out.index }) else { continue }
                let step = lane.index < b.neighbour.index ? -1 : 1
                let target = outTravel[max(0, min(outTravel.count - 1, at + step))]
                planned[b.k].pairs.append((lane, target))
            }

            for p in planned {
                for (inLane, outLane) in p.pairs {
                    addConnector(node: node, inEdge: inEdge, inLane: inLane, outEdge: p.outEdge, outLane: outLane,
                                 turn: p.turn, deadEnd: nodeEnds.count == 1)
                }
                if !p.pairs.isEmpty && !successors[inID.raw].contains(p.outEdge.id) { successors[inID.raw].append(p.outEdge.id) }
            }
        }
    }

    /// Tightest turn path radius a car can follow [m].
    static let minimumTurnRadius = 4.0

    /// Minimum radius of the turn path between the kerb (or centre) travel
    /// lanes of two edges.
    static func probeRadius(inEdge: Edge, outEdge: Edge, kerbSide: Bool) -> Double {
        let a = inEdge.lanesAtEnd.filter { $0.kind == .travel }.sorted { $0.index < $1.index }
        let b = outEdge.lanesAtStart.filter { $0.kind == .travel }.sorted { $0.index < $1.index }
        guard let la = kerbSide ? a.first : a.last, let lb = kerbSide ? b.first : b.last else { return .infinity }
        let path = Curves.turnPath(from: inEdge.position(s: inEdge.length, lateral: la.lateral), heading: inEdge.reference.endTangent,
                                   to: outEdge.position(s: 0, lateral: lb.lateral), heading: outEdge.reference.startTangent)
        return path.minimumRadius
    }

    /// A kerb-side auxiliary lane beginning at the junction that a ramp merges
    /// into: an acceleration lane, or a weaving lane (acceleration and
    /// deceleration lanes joined between close ramps) typed `.deceleration`.
    static func isMergeLane(_ l: Lane) -> Bool {
        l.kind == .acceleration || (l.kind == .deceleration && l.sStart <= 1e-6)
    }

    private mutating func addConnector(node: Node, inEdge: Edge, inLane: Lane, outEdge: Edge, outLane: Lane,
                                       turn: TurnDirection, deadEnd: Bool) {
        let p0 = inEdge.position(s: inEdge.length, lateral: inLane.lateral)
        let d0 = inEdge.reference.endTangent
        let p1 = outEdge.position(s: 0, lateral: outLane.lateral)
        let d1 = outEdge.reference.startTangent
        let path: Polyline
        if turn == .uTurn && deadEnd {
            path = bulbUTurn(p0: p0, d0: d0, p1: p1, center: node.position)
        } else {
            path = Curves.turnPath(from: p0, heading: d0, to: p1, heading: d1)
        }
        let radius = path.minimumRadius
        let curveSpeed = (builder.config.turnLateralAcceleration * radius).squareRoot()
        let limit = max(3.0, min(curveSpeed, min(inEdge.speedLimit, outEdge.speedLimit)))
        let id = ConnectorID(connectors.count)
        connectors.append(Connector(id: id, node: node.id, from: inLane.id, to: outLane.id, turn: turn,
                                    path: path, speedLimit: limit))
        connectorsFrom[inEdge.id.raw][inLane.index].append(id)
        connectorsInto[outEdge.id.raw].append(id)
        connectorsAtNode[node.id.raw].append(id)
        edges[inEdge.id.raw]?.lanes[inLane.index].movements.insert(turn)
    }

    /// A U-turn around a cul-de-sac bulb: swing towards the kerb, circle the
    /// bulb centre, and return into the opposite lane — a drivable radius
    /// rather than a pivot on the spot.
    private func bulbUTurn(p0: Vector2, d0: Vector2, p1: Vector2, center: Vector2) -> Polyline {
        let across = (p1 - p0)
        let acrossDir = (across - d0 * across.dot(d0)).normalized
        let rho = Self.bulbRadius - 4.0
        let c = center + d0 * Self.bulbOffset
        let kerbDir = -acrossDir
        let entry = c + kerbDir * rho              // heading d0 on the circle
        let exit = c + acrossDir * rho             // heading -d0
        var pts: [Vector2] = []
        pts.append(contentsOf: Curves.cubic(p0, p0 + d0 * 3, entry - d0 * 3, entry, segments: 8))
        // Semicircle from entry to exit, turning towards acrossDir.
        let a0 = (entry - c).angle
        let turnSign = d0.cross(acrossDir) > 0 ? 1.0 : -1.0
        for k in 1..<24 {
            let a = a0 + turnSign * DMath.pi * Double(k) / 24
            pts.append(c + Vector2.unit(angle: a) * rho)
        }
        pts.append(contentsOf: Curves.cubic(exit, exit - d0 * 3, p1 + d0 * 3, p1, segments: 8))
        return Polyline(pts)
    }

    // MARK: - Major approaches

    private func majors(at node: Node) -> Set<EdgeID> {
        let nodeEnds = ends[node.id.raw]
        guard nodeEnds.count >= 3 else { return [] }
        if let roads = node.control.majorRoads {
            return Set(nodeEnds.filter { roads.contains($0.road.id) }.compactMap { $0.incoming })
        }
        // Best pair: highest combined class, preferring a straight-through pair.
        var best: (Int, Int, Double)?
        for i in 0..<nodeEnds.count {
            for j in (i + 1)..<nodeEnds.count {
                let a = nodeEnds[i], b = nodeEnds[j]
                let straight = -a.direction.dot(b.direction)   // 1 when opposite
                let score = Double(a.road.roadClass.rank + b.road.roadClass.rank) * 10 + straight * 5
                if best == nil || score > best!.2 + 1e-9 { best = (i, j, score) }
            }
        }
        guard let (i, j, _) = best else { return [] }
        return Set([nodeEnds[i].incoming, nodeEnds[j].incoming].compactMap { $0 })
    }
}
