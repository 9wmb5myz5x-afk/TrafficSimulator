import XCTest
@testable import TrafficEngine

/// §10.3 intersection behaviour: signals, gap acceptance, stop signs.
final class IntersectionTests: XCTestCase {

    func mainAndSide(_ sim: Simulation, _ c: NodeID) -> (main: [EdgeID], side: [EdgeID]) {
        let plan = sim.signals.plan(for: c)!
        return (plan.approaches[2] + plan.approaches[6], plan.approaches[4] + plan.approaches[8])
    }

    func isGreen(_ sim: Simulation, _ c: NodeID, phase: Int) -> Bool {
        let st = sim.signals.state(for: c)!
        return (0..<2).contains { st.phase[$0] == phase && st.interval[$0] == .green }
    }

    // MARK: Timing

    func testITEYellowAndAllRed() {
        let (sim, c, _) = Micro.crossroads(.right)
        let plan = sim.signals.plan(for: c)!
        let t = plan.timing[2]!
        let v = RoadClass.arterial.defaultSpeedLimit
        XCTAssertEqual(t.yellow, 1.0 + v / (2 * 3.05), accuracy: 1e-9, "Y = t + v / (2a + 2Gg)")
        XCTAssertGreaterThanOrEqual(t.allRed, 1.0)
        XCTAssertLessThanOrEqual(t.allRed, 3.0)
    }

    func testRestsInMainStreetAndSkipsPhasesWithoutDemand() {
        let (sim, c, _) = Micro.crossroads(.right)
        var sideEverGreen = false
        var mainAlwaysGreen = true
        for _ in 0..<1200 {
            sim.step()
            for p in [1, 3, 4, 5, 7, 8] where isGreen(sim, c, phase: p) { sideEverGreen = true }
            if !(isGreen(sim, c, phase: 2) && isGreen(sim, c, phase: 6)) { mainAlwaysGreen = false }
        }
        XCTAssertFalse(sideEverGreen, "phases without calls are skipped")
        XCTAssertTrue(mainAlwaysGreen, "controller rests in the main-street green")
    }

    func testActuatedServesSideCallAndGapsOut() {
        let (sim, c, _) = Micro.crossroads(.right)
        let (_, side) = mainAndSide(sim, c)
        let sideEdge = sim.network.edge(side[0])!
        let through = sim.network.successors(of: side[0]).first { sim.network.turn(from: side[0], to: $0) == .straight }!
        let kerb = sideEdge.lanes.first { $0.kind == .travel }!.index
        sim.addVehicle(edge: side[0], lane: kerb, s: sideEdge.length - 60, speed: 10, route: [side[0], through])
        var greenAt: Double?
        var backToMainAt: Double?
        let plan = sim.signals.plan(for: c)!
        let sidePhase = plan.approaches[4].contains(side[0]) ? 4 : 8
        for _ in 0..<1600 {
            sim.step()
            if greenAt == nil && isGreen(sim, c, phase: sidePhase) { greenAt = sim.time }
            if greenAt != nil && backToMainAt == nil && isGreen(sim, c, phase: 2) { backToMainAt = sim.time }
        }
        let t2 = plan.timing[2]!
        XCTAssertNotNil(greenAt, "side street was served")
        // Main gaps out right after its minimum green (no main traffic), then yellow + all-red.
        XCTAssertLessThanOrEqual(greenAt ?? 99, t2.minGreen + t2.yellow + t2.allRed + 3)
        XCTAssertNotNil(backToMainAt, "side phase gapped out and the controller returned to the main street")
    }

    func testMainStreetMaxesOutForWaitingSideStreet() {
        let (sim, c, arms) = Micro.crossroads(.right)
        let (main, side) = mainAndSide(sim, c)
        let plan = sim.signals.plan(for: c)!
        // Saturate the main street; one side vehicle waits.
        let sideEdge = sim.network.edge(side[0])!
        let sideThrough = sim.network.successors(of: side[0]).first { sim.network.turn(from: side[0], to: $0) == .straight }!
        sim.addVehicle(edge: side[0], lane: sideEdge.lanes.first { $0.kind == .travel }!.index, s: sideEdge.length - 30, speed: 0,
                       route: [side[0], sideThrough])
        _ = arms
        var greenAt: Double?
        let sidePhase = plan.approaches[4].contains(side[0]) ? 4 : 8
        for k in 0..<2400 {
            if k % 30 == 0 {
                for m in main {
                    let e = sim.network.edge(m)!
                    let out = sim.network.successors(of: m).first { sim.network.turn(from: m, to: $0) == .straight }!
                    for l in e.lanes where l.kind == .travel {
                        sim.addVehicle(edge: m, lane: l.index, s: 5, speed: 14, route: [m, out])
                    }
                }
            }
            sim.step()
            if greenAt == nil && isGreen(sim, c, phase: sidePhase) { greenAt = sim.time }
        }
        let t2 = plan.timing[2]!
        XCTAssertNotNil(greenAt, "side street served despite continuous main traffic")
        XCTAssertLessThanOrEqual(greenAt ?? 999, t2.maxGreen + t2.yellow + t2.allRed + 5, "main street maxed out")
    }

    func testFixedTimeRunsAFixedCycle() {
        let (sim, c, _) = Micro.crossroads(.right)
        sim.network.updateNode(c) { $0.control.signal.mode = .fixedTime; $0.control.signal.cycleLength = 80 }
        sim.networkDidChange()
        var starts: [Double] = []
        var wasGreen = isGreen(sim, c, phase: 2)
        for _ in 0..<(4000) {
            sim.step()
            let g = isGreen(sim, c, phase: 2)
            if g && !wasGreen { starts.append(sim.time) }
            wasGreen = g
        }
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertEqual(b - a, 80, accuracy: 0.11) }
    }

    // MARK: Red-light compliance

    func testNoVehicleEntersOnRedAndTurnOnRedOnlyAfterFullStop() {
        for side in DrivingSide.allCases {
            let map = ScenarioNetworks.make(.signalGrid, side: side)
            var cfg = SimulationConfig(); cfg.seed = 3
            let sim = Simulation(network: map.network, terrain: map.terrain, config: cfg)
            sim.setExternalRate(perEntryPerHour: 200)
            var redEntries = 0, turnOnRed = 0, turnOnRedWithoutStop = 0
            sim.onJunctionEntry = { v, conn, ind in
                guard ind == .red else { return }
                if conn.turn.isKerbSide(side) {
                    turnOnRed += 1
                    if v.stopArrival == nil { turnOnRedWithoutStop += 1 }
                } else {
                    redEntries += 1
                }
            }
            sim.runChecked(seconds: 600)
            XCTAssertEqual(redEntries, 0, "\(side): entered on red")
            XCTAssertEqual(turnOnRedWithoutStop, 0, "\(side): turn on red without a full stop")
            XCTAssertGreaterThan(turnOnRed, 0, "\(side): turn on red happens")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }

    // MARK: Gap acceptance

    /// A permissive across-traffic turn never commits when an opposing vehicle
    /// would reach the conflict zone sooner than the driver's critical gap.
    func testPermissiveTurnRespectsCriticalGap() {
        for side in DrivingSide.allCases {
            let (sim, c, _) = Micro.crossroads(side, seed: 9)
            sim.network.updateNode(c) { $0.control.signal.acrossTurnMode = .permitted }
            sim.networkDidChange()
            let plan = sim.signals.plan(for: c)!
            let a = plan.approaches[2][0], b = plan.approaches[6][0]
            var violations = 0, permissiveCommits = 0
            sim.onCommit = { v, conn in
                guard conn.turn.isAcross(side), sim.signals.indication(for: conn.id, at: c) == .permissive else { return }
                permissiveCommits += 1
                let myEdge = sim.network.edge(conn.fromEdge)!
                let myLine = sim.timeToCover(v, distance: myEdge.length - v.s)
                for e in sim.network.conflicts.conflicts(of: conn.id) where e.kind != .diverge {
                    guard let other = sim.network.connector(e.other), !other.turn.isAcross(side),
                          let j = sim.frontVehicle(onLane: other.from) else { continue }
                    let w = sim.vehicles[j]
                    if w.committed || w.plannedConnector != other.id { continue }
                    let d = sim.network.edge(other.fromEdge)!.length - w.s
                    if d > 150 { continue }
                    let t = sim.timeToCover(w, distance: d + e.otherZoneStart)
                    if t < CriticalGap.majorAcross * v.driver.gapFactor + myLine - 1e-6 { violations += 1 }
                }
            }
            // Opposing streams, some turning across.
            var rng = SeededRandom(seed: 4)
            for k in 0..<3600 {
                if k % 60 == 0 {
                    for appr in [a, b] {
                        let e = sim.network.edge(appr)!
                        let succ = sim.network.successors(of: appr)
                        let acrossOut = succ.first { sim.network.turn(from: appr, to: $0)?.isAcross(side) == true }!
                        let straight = succ.first { sim.network.turn(from: appr, to: $0) == .straight }!
                        let turn = rng.chance(0.35)
                        let lanes = e.lanes.filter { $0.kind == .travel }
                        let lane = turn ? lanes.last! : lanes[rng.nextInt(lanes.count)]
                        sim.addVehicle(edge: appr, lane: lane.index, s: 5, speed: 12, route: [appr, turn ? acrossOut : straight])
                    }
                }
                sim.step()
            }
            XCTAssertGreaterThan(permissiveCommits, 5, "\(side): permissive turns happened")
            XCTAssertEqual(violations, 0, "\(side): permissive turn accepted a gap below the critical gap")
            XCTAssertEqual(sim.invariantChecker?.total ?? 0, 0)
        }
    }

    // MARK: Stop signs

    func testAllWayStopServesInArrivalOrder() {
        let (sim, c, arms) = Micro.crossroads(.right, cls: .collector)
        XCTAssertEqual(sim.network.node(c)?.effectiveControl, .allWayStop)
        // One through vehicle per approach, staggered so arrival order is known.
        var ids: [VehicleID] = []
        for (k, arm) in arms.enumerated() {
            let (inb, _) = Micro.edges(sim, arm: arm, centre: c)
            let e = sim.network.edge(inb)!
            let out = sim.network.successors(of: inb).first { sim.network.turn(from: inb, to: $0) == .straight }!
            ids.append(sim.addVehicle(driver: Micro.driver(speedFactor: 1.0), edge: inb, lane: 0,
                                      s: e.length - 40 - Double(k) * 12, speed: 8, route: [inb, out])!)
        }
        var arrival: [VehicleID: Double] = [:]
        var entryOrder: [VehicleID] = []
        sim.onJunctionEntry = { v, _, _ in entryOrder.append(v.id) }
        sim.runChecked(seconds: 60) {
            for id in ids { if let v = sim.vehicle(id), let a = v.stopArrival, arrival[id] == nil { arrival[id] = a } }
        }
        XCTAssertEqual(entryOrder.count, 4, "all served")
        XCTAssertEqual(arrival.count, 4, "all came to a full stop")
        // Crossing movements are served in arrival order (opposite throughs may share).
        for (x, y) in zip(entryOrder, entryOrder.dropFirst()) {
            guard let ax = arrival[x], let ay = arrival[y] else { continue }
            let ix = ids.firstIndex(of: x)!, iy = ids.firstIndex(of: y)!
            let opposite = (ix + 2) % 4 == iy
            if !opposite { XCTAssertLessThanOrEqual(ax, ay + 1e-9, "\(x) entered before \(y) but arrived later") }
        }
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
    }

    func testTwoWayStopMinorYieldsToMajor() {
        let net = RoadNetwork(side: .right)
        var c = NodeID(0), w = NodeID(0), e = NodeID(0), n = NodeID(0)
        net.batch {
            c = net.addNode(at: .zero)
            w = net.addNode(at: Vector2(-400, 0)); e = net.addNode(at: Vector2(400, 0)); n = net.addNode(at: Vector2(0, 300))
            for x in [w, e, n] { net.updateNode(x) { $0.isRegionalConnection = true } }
            net.addRoad(from: w, to: c, roadClass: .arterial)
            net.addRoad(from: c, to: e, roadClass: .arterial)
            net.addRoad(from: n, to: c, roadClass: .local)
        }
        let sim = Simulation(network: net)
        XCTAssertEqual(net.node(c)?.effectiveControl, .twoWayStop)
        let minorIn = net.incoming(c).first { net.edge($0)?.from == n }!
        let majorIn = net.incoming(c).first { net.edge($0)?.from == w }!
        let east = net.outgoing(c).first { net.edge($0)?.to == e }!
        let minorEdge = net.edge(minorIn)!, majorEdge = net.edge(majorIn)!
        // Minor vehicle turning towards the east (crosses the westbound... uses the eastbound lanes).
        let minor = sim.addVehicle(edge: minorIn, lane: 0, s: minorEdge.length - 25, speed: 6, route: [minorIn, east])!
        // A major vehicle arriving 3 s later (well inside the critical gap).
        let major = sim.addVehicle(edge: majorIn, lane: 0, s: majorEdge.length - 50, speed: 16, route: [majorIn, east])!
        var order: [VehicleID] = []
        var minorStopped = false
        sim.onJunctionEntry = { v, _, _ in order.append(v.id) }
        sim.runChecked(seconds: 30) { if let v = sim.vehicle(minor), v.stopArrival != nil { minorStopped = true } }
        XCTAssertTrue(minorStopped, "minor approach stops")
        XCTAssertEqual(order.first, major, "major-road vehicle has priority")
        XCTAssertTrue(order.contains(minor))
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
    }

    // MARK: Roundabouts

    func testRoundaboutEntryYieldsToCirculatingTraffic() {
        for side in DrivingSide.allCases {
            let map = ScenarioNetworks.make(.roundaboutVillage, side: side)
            var cfg = SimulationConfig(); cfg.seed = 2
            let sim = Simulation(network: map.network, terrain: map.terrain, config: cfg)
            sim.setExternalRate(perEntryPerHour: 320)
            let ring = Set(sim.network.allRoundabouts.flatMap { $0.ringNodes })
            var entries = 0, violations = 0
            sim.onCommit = { v, conn in
                guard ring.contains(conn.node), !sim.network.isMajorApproach(conn.fromEdge, at: conn.node) else { return }
                entries += 1
                let myEdge = sim.network.edge(conn.fromEdge)!
                let myLine = sim.timeToCover(v, distance: myEdge.length - v.s)
                for e in sim.network.conflicts.conflicts(of: conn.id) where e.kind != .diverge {
                    guard let other = sim.network.connector(e.other), sim.network.isMajorApproach(other.fromEdge, at: conn.node),
                          let j = sim.frontVehicle(onLane: other.from) else { continue }
                    let w = sim.vehicles[j]
                    if w.committed || w.plannedConnector != other.id { continue }
                    // Courtesy rule: a circulating car queued at its own line that arrived later doesn't count.
                    if let arr = w.stopArrival, let mine = v.stopArrival, mine <= arr, w.lineWait > 1.5 { continue }
                    let d = sim.network.edge(other.fromEdge)!.length - w.s
                    // Zipper courtesy in a queued ring: a crawling circulating car lets in
                    // an entering driver who has waited ≥ 15 s (see gapAccepted).
                    if v.lineWait >= 15 && w.speed < 3 && d > 0.5 { continue }
                    let t = sim.timeToCover(w, distance: d + e.otherZoneStart)
                    let impatience = 1 - 0.3 * ((v.lineWait - 20) / 60).clamped(to: 0...1)
                    if t < CriticalGap.roundaboutEntry * v.driver.gapFactor * impatience + myLine - 1e-6 { violations += 1 }
                }
            }
            sim.runChecked(seconds: 600)
            XCTAssertGreaterThan(entries, 50, "\(side)")
            XCTAssertEqual(violations, 0, "\(side): entered in front of circulating traffic")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
            XCTAssertGreaterThan(sim.metrics.aggregate.completedTrips, 20)
        }
    }

    // MARK: Gridlock

    /// A one-way ring round a block, packed so that every queue head waits for
    /// the full segment ahead: a wait-for cycle. It must be detected, reported
    /// and released slowly by priority (a head car takes another exit) —
    /// nobody teleports, and everyone eventually leaves.
    func testRingGridlockIsDetectedAndReleased() {
        for side in DrivingSide.allCases {
            let net = RoadNetwork(side: side)
            var ring: [NodeID] = []
            var ringEdges: [EdgeID] = []
            var stubs: [EdgeID] = []   // outbound stub from each ring node
            net.batch {
                let corners = [Vector2(0, 0), Vector2(70, 0), Vector2(70, 70), Vector2(0, 70)]
                ring = corners.map { net.addNode(at: $0) }
                for k in 0..<4 {
                    let r = net.addRoad(from: ring[k], to: ring[(k + 1) % 4], roadClass: .local, lanes: 1, oneWay: true)!
                    ringEdges.append(EdgeID(road: r, forward: true))
                }
                let centre = Vector2(35, 35)
                for k in 0..<4 {
                    let p = corners[k] + (corners[k] - centre).normalized * 200
                    let out = net.addNode(at: p)
                    net.updateNode(out) { $0.isRegionalConnection = true }
                    let r = net.addRoad(from: ring[k], to: out, roadClass: .local)!
                    stubs.append(EdgeID(road: r, forward: true))
                }
            }
            var cfg = SimulationConfig(); cfg.seed = 9
            let sim = Simulation(network: net, config: cfg)
            sim.setExternalRate(perEntryPerHour: 0)
            var placed = 0
            for k in 0..<4 {
                let e = sim.network.edge(ringEdges[k])!
                let next = ringEdges[(k + 1) % 4], after = ringEdges[(k + 2) % 4]
                let exit = stubs[(k + 3) % 4]
                var s = e.length - 1
                while s > 4.6 {
                    let route = [ringEdges[k], next, after, exit]
                    let dest = Destination(kind: .exitMap, edge: exit, s: sim.network.edge(exit)!.length)
                    if sim.addVehicle(cls: .car, edge: ringEdges[k], lane: 0, s: s, route: route, destination: dest) != nil { placed += 1 }
                    s -= 6.6   // 4.5 m cars at a 2.1 m standstill gap
                }
            }
            XCTAssertGreaterThan(placed, 12)
            let checker = sim.runChecked(seconds: 900)
            XCTAssertGreaterThanOrEqual(sim.gridlock.detected, 1, "\(side): gridlock detected")
            XCTAssertGreaterThanOrEqual(sim.gridlock.resolved, 1, "\(side): gridlock released")
            XCTAssertTrue(sim.events.contains { $0.kind == .gridlockDetected }, "\(side): reported")
            XCTAssertEqual(sim.vehicles.count, 0, "\(side): everyone left (\(sim.vehicles.count) remain)")
            XCTAssertEqual(checker.total, 0, "\(side): \(checker.summary())\n" + checker.samples.prefix(5).map { "\($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: Coordination and adaptive timing

    /// Eastbound stops per vehicle along a 5-signal arterial, fixed-time 90 s,
    /// with or without a coordination group (green wave).
    private func corridorStops(coordinated: Bool, side: DrivingSide) -> (stops: Double, trips: Int) {
        let net = RoadNetwork(side: side)
        var nodes: [NodeID] = []
        var west = NodeID(0), east = NodeID(0)
        net.batch {
            west = net.addNode(at: Vector2(-400, 0))
            net.updateNode(west) { $0.isRegionalConnection = true }
            nodes = (0..<5).map { net.addNode(at: Vector2(Double($0) * 300, 0)) }
            east = net.addNode(at: Vector2(1600, 0))
            net.updateNode(east) { $0.isRegionalConnection = true }
            let chain = [west] + nodes + [east]
            for k in 0..<(chain.count - 1) { net.addRoad(from: chain[k], to: chain[k + 1], roadClass: .arterial, lanes: 2) }
            for (k, n) in nodes.enumerated() {
                for dir in [1.0, -1.0] {
                    let x = net.addNode(at: Vector2(Double(k) * 300, dir * 200))
                    net.updateNode(x) { $0.isRegionalConnection = true }
                    net.addRoad(from: x, to: n, roadClass: .collector)
                }
                net.updateNode(n) {
                    $0.control.requested = .signal
                    $0.control.signal.mode = .fixedTime
                    $0.control.signal.cycleLength = 90
                    $0.control.signal.coordinationGroup = coordinated ? 1 : nil
                }
            }
        }
        var cfg = SimulationConfig(); cfg.seed = 21
        let sim = Simulation(network: net, config: cfg)
        sim.setExternalRate(perEntryPerHour: 0)
        let entry = sim.network.outgoing(west).first!
        let exit = sim.network.incoming(east).first!
        let route = sim.router.route(from: entry, to: exit)!
        var stops: [VehicleID: Int] = [:], moving: [VehicleID: Bool] = [:]
        var finished = 0, finishedStops = 0
        var next = 0.0
        _ = sim.runChecked(seconds: 900) {
            if sim.time >= next && sim.time < 600 {
                if let id = sim.spawnEntering(entry: entry, cls: .car, route: route,
                                              destination: Destination(kind: .exitMap, edge: exit, s: sim.network.edge(exit)!.length),
                                              purpose: .through) {
                    stops[id] = 0; moving[id] = true
                }
                next = sim.time + 20
            }
            var seen = Set<VehicleID>()
            for v in sim.vehicles where stops[v.id] != nil {
                seen.insert(v.id)
                if v.speed < 0.5 && moving[v.id] == true { stops[v.id]! += 1; moving[v.id] = false }
                if v.speed > 3 { moving[v.id] = true }
            }
            for (id, n) in stops where !seen.contains(id) {
                finished += 1; finishedStops += n
                stops[id] = nil
            }
        }
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        return (Double(finishedStops) / Double(max(finished, 1)), finished)
    }

    func testCoordinationCreatesAGreenWave() {
        for side in DrivingSide.allCases {
            let free = corridorStops(coordinated: false, side: side)
            let wave = corridorStops(coordinated: true, side: side)
            XCTAssertGreaterThan(free.trips, 15)
            XCTAssertGreaterThan(wave.trips, 15)
            XCTAssertLessThanOrEqual(wave.stops, 0.5 * free.stops, "\(side): stops/vehicle coordinated \(wave.stops) vs \(free.stops)")
            XCTAssertLessThan(wave.stops, 1.0, "\(side): most of the platoon rides the green wave")
        }
    }

    /// Webster: heavy east–west and light north–south demand ⇒ the main phases
    /// get the longer split, and the cycle stays within its bounds.
    func testAdaptiveSignalFavoursTheBusyStreet() {
        for side in DrivingSide.allCases {
            let (sim, c, arms) = Micro.crossroads(side, cls: .arterial, control: .signal, seed: 4)
            sim.network.updateNode(c) { $0.control.signal.mode = .adaptive }
            let east = Micro.edges(sim, arm: arms[0], centre: c), north = Micro.edges(sim, arm: arms[1], centre: c)
            let west = Micro.edges(sim, arm: arms[2], centre: c), south = Micro.edges(sim, arm: arms[3], centre: c)
            func send(_ from: EdgeID, _ to: EdgeID) {
                guard let r = sim.router.route(from: from, to: to) else { return }
                _ = sim.spawnEntering(entry: from, cls: .car, route: r,
                                      destination: Destination(kind: .exitMap, edge: to, s: sim.network.edge(to)!.length), purpose: .through)
            }
            var tick = 0
            _ = sim.runChecked(seconds: 1500) {
                tick += 1
                if tick % 50 == 0 { send(east.inbound, west.outbound); send(west.inbound, east.outbound) }   // 1,440 veh/h each way
                if tick % 400 == 0 { send(north.inbound, south.outbound); send(south.inbound, north.outbound) } // 180 veh/h each way
            }
            let plan = sim.signals.plan(for: c)!
            XCTAssertEqual(plan.mode, .adaptive)
            func split(serving e: EdgeID) -> Double {
                let p = [2, 6, 4, 8].first { plan.approaches[$0].contains(e) }!
                return plan.timing[p]!.split
            }
            let main = split(serving: east.inbound), minor = split(serving: north.inbound)
            XCTAssertGreaterThan(main, 1.5 * minor, "\(side): main \(main) s vs side \(minor) s")
            XCTAssertTrue((40...150).contains(plan.cycle), "\(side): cycle \(plan.cycle)")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }
}
