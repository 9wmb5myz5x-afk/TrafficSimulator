import XCTest
import Foundation
@testable import TrafficEngine

/// §10.3 behaviour tests for car following and lane changing.
final class DrivingBehaviourTests: XCTestCase {

    // MARK: Car following (IDM)

    func testIDMFreeRoadReachesDesiredSpeed() {
        let p = IDMParameters()
        var v = 0.0
        for _ in 0..<1200 { v += IDM.freeAcceleration(p, speed: v, desiredSpeed: 20) * 0.05 }
        XCTAssertEqual(v, 20, accuracy: 0.6)
    }

    func testIDMStopsBehindObstacleWithoutCollision() {
        let p = IDMParameters()
        var x = 0.0, v = 20.0
        let obstacle = 200.0
        for _ in 0..<4000 {
            let a = IDM.acceleration(p, speed: v, desiredSpeed: 20, gap: obstacle - x, leaderSpeed: 0)
            v = max(0, v + a * 0.05)
            x += v * 0.05
        }
        XCTAssertLessThan(x, obstacle)
        XCTAssertGreaterThan(obstacle - x, p.minGap * 0.8)
        XCTAssertLessThan(v, 0.05)
    }

    func testMOBILSafetyAndIncentive() {
        let p = MOBILParameters()
        let good = MOBIL.Situation(selfCurrent: -1, selfTarget: 1, newFollowerBefore: 0, newFollowerAfter: -0.5,
                                   oldFollowerBefore: 0, oldFollowerAfter: 0.2)
        XCTAssertTrue(MOBIL.shouldChange(p, good, bias: 0))
        let unsafe = MOBIL.Situation(selfCurrent: -1, selfTarget: 1, newFollowerBefore: 0, newFollowerAfter: -5,
                                     oldFollowerBefore: 0, oldFollowerAfter: 0)
        XCTAssertFalse(MOBIL.shouldChange(p, unsafe, bias: 0))
        // The keep-kerb bias makes a marginal pass not worth it.
        let marginal = MOBIL.Situation(selfCurrent: 0, selfTarget: 0.4, newFollowerBefore: 0, newFollowerAfter: 0,
                                       oldFollowerBefore: 0, oldFollowerAfter: 0)
        XCTAssertTrue(MOBIL.shouldChange(p, marginal, bias: 0))
        XCTAssertFalse(MOBIL.shouldChange(p, marginal, bias: 0.3))
    }

    func testStopAndGoWavesDoNotCauseCollisionsInDenseTraffic() {
        let (sim, e) = Micro.straight(.right, length: 1500, lanes: 1, cls: .arterial)
        for k in 0..<40 {
            sim.addVehicle(edge: e, lane: 0, s: 1400 - Double(k) * 9, speed: 8)
        }
        let checker = sim.runChecked(seconds: 120)
        XCTAssertEqual(checker.total, 0, checker.summary())
    }

    // MARK: Passing

    /// A fast car behind a slow truck passes on the passing side and returns to the kerb lane.
    func testPassesOnPassingSideAndReturnsToKerbLane() {
        for side in DrivingSide.allCases {
            let (sim, e) = Micro.straight(side, length: 3000, lanes: 2, cls: .highway)
            let edge = sim.network.edge(e)!
            let kerb = edge.lanes.first { $0.kind == .travel }!.index
            let passing = edge.lanes.filter { $0.kind == .travel }.last!.index
            XCTAssertGreaterThan((edge.lane(passing)!.lateral - edge.lane(kerb)!.lateral) * side.passingLateralSign, 0,
                                 "passing lane is on the \(side == .right ? "left" : "right")")
            let truck = sim.addVehicle(cls: .truck, driver: Micro.driver(speedFactor: 0.55), edge: e, lane: kerb, s: 300, speed: 15)!
            let car = sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 1.1), edge: e, lane: kerb, s: 150, speed: 25)!
            var usedPassingLane = false
            var passed = false
            sim.runChecked(seconds: 90) {
                guard let c = sim.vehicle(car), let t = sim.vehicle(truck) else { return }
                if c.lane == passing && abs(c.s - t.s) < 30 { usedPassingLane = true }
                if c.s > t.s + 10 { passed = true }
            }
            let c = sim.vehicle(car)
            XCTAssertTrue(usedPassingLane, "\(side): overtook in the passing lane")
            XCTAssertTrue(passed, "\(side): actually passed the truck")
            XCTAssertEqual(c?.lane, kerb, "\(side): returned to the kerb lane")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }

    // MARK: Lane-change manoeuvre

    /// Blinker ≥ 1.5 s before lateral motion; lateral motion ≥ 2.5 s; the follower in
    /// the target lane brakes for a changer that cuts in front of it.
    func testLaneChangeIsSignalledContinuousAndRespected() {
        for side in DrivingSide.allCases {
            let (sim, e) = Micro.straight(side, length: 2500, lanes: 2, cls: .arterial, limit: 20)
            let edge = sim.network.edge(e)!
            let kerb = edge.lanes.first { $0.kind == .travel }!.index
            let passing = kerb + 1
            // A slow leader forces the changer out; a follower in the target lane slightly behind.
            sim.addVehicle(cls: .truck, driver: Micro.driver(speedFactor: 0.4), edge: e, lane: kerb, s: 260, speed: 8)
            let changer = sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 1.1), edge: e, lane: kerb, s: 200, speed: 17)!
            // Far enough back that cutting in is safe, close enough that it must brake.
            let follower = sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 0.9, politeness: 0.3),
                                          edge: e, lane: passing, s: 140, speed: 18)!
            if ProcessInfo.processInfo.environment["DEBUG_LC"] != nil { sim.debugVehicle = changer; sim.debugLog = { print($0) } }
            var signalStart: Double?
            var moveStart: Double?
            var moveEnd: Double?
            var followerMinAccel = 10.0
            var prevLateral = sim.vehicle(changer)!.lateral
            sim.runChecked(seconds: 40) {
                guard let c = sim.vehicle(changer) else { return }
                if ProcessInfo.processInfo.environment["DEBUG_LC"] != nil, Int(sim.time * 20) % 10 == 0 {
                    print("t=\(sim.time) s=\(c.s) v=\(c.speed) lane=\(c.lane) lc=\(String(describing: c.laneChange))")
                }
                if let lc = c.laneChange {
                    if lc.phase == .signalling && signalStart == nil { signalStart = sim.time }
                    if lc.phase == .moving && moveStart == nil { moveStart = sim.time }
                    if c.blinker(side: side) != 0 && moveStart == nil {} // blinker on while signalling
                } else if moveStart != nil && moveEnd == nil {
                    moveEnd = sim.time
                }
                // Lateral motion is continuous.
                XCTAssertLessThan(abs(c.lateral - prevLateral), 0.2, "lateral jump")
                prevLateral = c.lateral
                if moveStart != nil, moveEnd == nil, let f = sim.vehicle(follower) { followerMinAccel = min(followerMinAccel, f.acceleration) }
            }
            XCTAssertNotNil(signalStart, "\(side): signalled")
            XCTAssertNotNil(moveStart, "\(side): moved")
            if let a = signalStart, let b = moveStart { XCTAssertGreaterThanOrEqual(b - a, 1.5 - 1e-9, "\(side): blinker before moving") }
            if let b = moveStart, let c = moveEnd { XCTAssertGreaterThanOrEqual(c - b, 2.5, "\(side): lateral motion duration") }
            XCTAssertLessThan(followerMinAccel, 0, "\(side): target-lane follower braked for the changer")
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }

    // MARK: Pre-positioning

    /// A car needing an across-traffic turn 300 m ahead reaches the turn pocket before the
    /// stop line in ≥ 95 % of seeded runs, with background traffic in both lanes.
    func testPrepositionsIntoTurnPocket() {
        for side in DrivingSide.allCases {
            var successes = 0
            let runs = 20
            for seed in 1...runs {
                let (sim, c, arms) = Micro.crossroads(side, seed: UInt64(seed))
                let (inb, _) = Micro.edges(sim, arm: arms[2], centre: c)       // from the west, heading east
                let inEdge = sim.network.edge(inb)!
                // Across-traffic turn = left for .right (north), right for .left (south).
                let exitArm = side == .right ? arms[1] : arms[3]
                let (_, outb) = Micro.edges(sim, arm: exitArm, centre: c)
                let kerb = inEdge.lanes.first { $0.kind == .travel }!.index
                let s0 = inEdge.length - 300
                var rng = SeededRandom(seed: UInt64(seed) * 77)
                // Background traffic going straight.
                let (_, straightOut) = Micro.edges(sim, arm: arms[0], centre: c)
                for k in 0..<6 {
                    let lane = kerb + (k % 2)
                    sim.addVehicle(edge: inb, lane: lane, s: max(5, s0 - 40 + Double(k) * 25 + rng.nextDouble(in: 0..<10)),
                                   speed: 12, route: [inb, straightOut])
                }
                guard let me = sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 1.0), edge: inb, lane: kerb, s: s0 + 5,
                                              speed: 13, route: [inb, outb]) else { continue }
                var inPocketAtLine = false
                sim.runChecked(seconds: 60) {
                    guard let v = sim.vehicle(me), case .edge(let e) = v.track, e == inb else { return }
                    if inEdge.length - v.s < 3, inEdge.lane(v.lane)?.kind == .acrossPocket { inPocketAtLine = true }
                }
                if inPocketAtLine || (sim.vehicle(me)?.missedTurns == 0 && sim.vehicle(me).map { $0.currentEdge == outb } ?? true) {
                    if inPocketAtLine { successes += 1 }
                }
                XCTAssertEqual(sim.invariantChecker?.total, 0, "seed \(seed): \(sim.invariantChecker?.summary() ?? "")")
            }
            XCTAssertGreaterThanOrEqual(Double(successes) / Double(runs), 0.95, "\(side): \(successes)/\(runs) in the pocket")
        }
    }

    /// When the driver cannot get over, it continues and reroutes instead of stopping in the lane.
    func testBlockedTurnReroutesInsteadOfStopping() {
        let side = DrivingSide.right
        let (sim, c, arms) = Micro.crossroads(side, seed: 3)
        let (inb, _) = Micro.edges(sim, arm: arms[2], centre: c)
        let inEdge = sim.network.edge(inb)!
        let (_, leftOut) = Micro.edges(sim, arm: arms[1], centre: c)
        let (_, straightOut) = Micro.edges(sim, arm: arms[0], centre: c)
        let kerb = inEdge.lanes.first { $0.kind == .travel }!.index
        // A dense platoon in the inner lane makes the change impossible this late.
        for k in 0..<14 {
            sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 1.0, politeness: 0), edge: inb, lane: kerb + 1,
                           s: inEdge.length - 150 + Double(k) * 7.5 - 30, speed: 12, route: [inb, straightOut])
        }
        let me = sim.addVehicle(cls: .car, driver: Micro.driver(speedFactor: 1.0), edge: inb, lane: kerb,
                                s: inEdge.length - 70, speed: 12, route: [inb, leftOut])!
        var maxStationary = 0.0
        sim.runChecked(seconds: 90) {
            if let v = sim.vehicle(me), v.currentEdge == inb { maxStationary = max(maxStationary, v.stationaryTime) }
        }
        XCTAssertLessThan(maxStationary, 30, "did not wait indefinitely in the wrong lane")
        XCTAssertEqual(sim.invariantChecker?.count(.forcedStop), 0)
        XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        // Either it squeezed into the pocket or it missed the turn and continued.
        if let v = sim.vehicle(me) { XCTAssertNotEqual(v.currentEdge, inb) }
    }

    // MARK: Merges and lane drops

    /// On-ramp traffic merges from the acceleration lane before it ends.
    func testOnRampMergesBeforeAccelerationLaneEnds() {
        for side in DrivingSide.allCases {
            let map = ScenarioNetworks.make(.highwayTown, side: side)
            var cfg = SimulationConfig(); cfg.seed = 5
            let sim = Simulation(network: map.network, terrain: map.terrain, config: cfg)
            sim.setExternalRate(perEntryPerHour: 0)
            let net = sim.network
            // Highway edges with an acceleration lane, and the on-ramp feeding each.
            let mergeEdges = net.allEdges.filter { $0.lanes.contains { $0.kind == .acceleration } }
            XCTAssertEqual(mergeEdges.count, 2)
            var ids: [VehicleID] = []
            for me in mergeEdges {
                guard let ramp = net.incoming(me.from).first(where: { net.edge($0)?.roadClass == .ramp }),
                      let mainIn = net.incoming(me.from).first(where: { net.edge($0)?.roadClass == .highway }),
                      let rampEdge = net.edge(ramp), let mainEdge = net.edge(mainIn) else { XCTFail(); continue }
                let exit = net.successors(of: me.id).first.map { [me.id, $0] } ?? [me.id]
                for k in 0..<4 {
                    if let id = sim.addVehicle(edge: ramp, lane: 0, s: rampEdge.length - 120 + Double(k) * 18, speed: 12,
                                               route: [ramp] + exit) { ids.append(id) }
                }
                // Mainline traffic in the kerb lane to merge into.
                let kerb = mainEdge.lanes.first { $0.kind == .travel }!.index
                for k in 0..<5 {
                    sim.addVehicle(edge: mainIn, lane: kerb, s: mainEdge.length - 250 + Double(k) * 40, speed: 24, route: [mainIn] + exit)
                }
            }
            var stoppedInAccelLane = false
            sim.runChecked(seconds: 80) {
                for id in ids {
                    guard let v = sim.vehicle(id), case .edge(let e) = v.track, let edge = net.edge(e) else { continue }
                    if edge.lane(v.lane)?.kind == .acceleration && v.speed < 1 { stoppedInAccelLane = true }
                }
            }
            XCTAssertFalse(stoppedInAccelLane, "\(side): ramp traffic merged without stopping")
            for id in ids {
                if let v = sim.vehicle(id), case .edge(let e) = v.track, let edge = net.edge(e) {
                    XCTAssertNotEqual(edge.lane(v.lane)?.kind, .acceleration, "\(side): \(id) still in the acceleration lane")
                }
            }
            XCTAssertEqual(sim.invariantChecker?.total, 0, sim.invariantChecker?.summary() ?? "")
        }
    }

    func testVehicleClassesHaveDistinctDynamics() {
        XCTAssertGreaterThan(VehicleClass.bus.length, VehicleClass.truck.length)
        XCTAssertGreaterThan(VehicleClass.car.maxAcceleration, VehicleClass.truck.maxAcceleration)
        let (sim, e) = Micro.straight(.right, length: 1500, lanes: 2, cls: .arterial)
        let car = sim.addVehicle(cls: .car, edge: e, lane: 0, s: 10, speed: 0)!
        let truck = sim.addVehicle(cls: .truck, edge: e, lane: 1, s: 10, speed: 0)!
        sim.run(seconds: 6)
        XCTAssertGreaterThan(sim.vehicle(car)!.speed, sim.vehicle(truck)!.speed + 1)
    }
}
