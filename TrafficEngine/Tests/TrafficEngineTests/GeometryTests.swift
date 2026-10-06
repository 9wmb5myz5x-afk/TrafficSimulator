import XCTest
import Foundation
@testable import TrafficEngine

final class MathTests: XCTestCase {

    func testDMathMatchesLibm() {
        var rng = SeededRandom(seed: 1)
        for _ in 0..<20000 {
            let x = rng.nextDouble(in: -50..<50)
            XCTAssertEqual(DMath.sin(x), Foundation.sin(x), accuracy: 2e-15 * max(1, abs(x)))
            XCTAssertEqual(DMath.cos(x), Foundation.cos(x), accuracy: 2e-15 * max(1, abs(x)))
            let y = rng.nextDouble(in: -50..<50)
            XCTAssertEqual(DMath.atan2(y, x), Foundation.atan2(y, x), accuracy: 1e-15 * 4)
            let e = rng.nextDouble(in: -30..<30)
            XCTAssertEqual(DMath.exp(e), Foundation.exp(e), accuracy: 3e-15 * Foundation.exp(e))
            let l = rng.nextDouble(in: 1e-6..<1e6)
            XCTAssertEqual(DMath.log(l), Foundation.log(l), accuracy: 1e-15 * max(1, abs(Foundation.log(l))))
        }
        XCTAssertEqual(DMath.pow(2, 10), 1024, accuracy: 1e-9)
        XCTAssertEqual(DMath.pow(1.7, 4), Foundation.pow(1.7, 4), accuracy: 1e-14)
    }

    func testGaussianMoments() {
        var rng = SeededRandom(seed: 42)
        var sum = 0.0, sq = 0.0
        let n = 50000
        for _ in 0..<n { let g = rng.nextGaussian(); sum += g; sq += g * g }
        XCTAssertEqual(sum / Double(n), 0, accuracy: 0.02)
        XCTAssertEqual(sq / Double(n), 1, accuracy: 0.03)
    }

    func testPolylineOffsetPositionIsContinuousAcrossVertices() {
        // A polyline with a 30° kink: offset positions must not jump at the vertex.
        let line = Polyline([Vector2(0, 0), Vector2(50, 0), Vector2(50 + 50 * Foundation.cos(0.5), 50 * Foundation.sin(0.5))])
        var prev = line.position(at: 0, lateral: -5)
        var s = 0.05
        while s < line.length {
            let p = line.position(at: s, lateral: -5)
            XCTAssertLessThan(p.distance(to: prev), 0.2, "jump at s=\(s)")
            prev = p
            s += 0.05
        }
    }

    func testProjectFindsClosestPoint() {
        let line = Polyline([Vector2(0, 0), Vector2(100, 0)])
        let pr = line.project(Vector2(40, 3))
        XCTAssertEqual(pr.s, 40, accuracy: 1e-9)
        XCTAssertEqual(pr.distance, 3, accuracy: 1e-9)
        XCTAssertGreaterThan(pr.lateral, 0)
    }

    func testOrientedBoxOverlap() {
        let a = OrientedBox(center: .zero, axis: Vector2(1, 0), halfLength: 2.25, halfWidth: 1)
        let b = OrientedBox(center: Vector2(4.4, 0), axis: Vector2(1, 0), halfLength: 2.25, halfWidth: 1)
        XCTAssertTrue(a.overlaps(b))
        let c = OrientedBox(center: Vector2(4.6, 0), axis: Vector2(1, 0), halfLength: 2.25, halfWidth: 1)
        XCTAssertFalse(a.overlaps(c))
        let d = OrientedBox(center: Vector2(0, 2.5), axis: Vector2(0, 1), halfLength: 2.25, halfWidth: 1)
        XCTAssertTrue(a.overlaps(d))
    }
}

final class NetworkGeometryTests: XCTestCase {

    /// A plus-shaped junction of two arterials.
    func crossroads(_ side: DrivingSide, cls: RoadClass = .arterial) -> (RoadNetwork, NodeID) {
        let net = RoadNetwork(side: side)
        var c = NodeID(0)
        net.batch {
            c = net.addNode(at: .zero)
            for d in [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)] {
                let n = net.addNode(at: d * 250)
                net.addRoad(from: n, to: c, roadClass: cls)
            }
        }
        return (net, c)
    }

    func testLaneOffsetsFollowDrivingSide() {
        for side in DrivingSide.allCases {
            let net = RoadNetwork(side: side)
            let a = net.addNode(at: .zero), b = net.addNode(at: Vector2(200, 0))
            net.addRoad(from: a, to: b, roadClass: .arterial)
            let fwd = net.allEdges.first { $0.from == a }!
            let lanes = fwd.lanes.filter { $0.kind == .travel }
            XCTAssertEqual(lanes.count, 2)
            if side == .right {
                XCTAssertTrue(lanes.allSatisfy { $0.lateral < 0 }, "eastbound lanes on the south side")
                XCTAssertLessThan(lanes[0].lateral, lanes[1].lateral, "lane 0 is the kerb lane")
            } else {
                XCTAssertTrue(lanes.allSatisfy { $0.lateral > 0 })
                XCTAssertGreaterThan(lanes[0].lateral, lanes[1].lateral)
            }
            // Opposite carriageway never overlaps.
            let bwd = net.allEdges.first { $0.from == b }!
            let pF = fwd.position(s: 100, lateral: lanes[1].lateral)
            let bl = bwd.lanes.filter { $0.kind == .travel }.last!
            let pB = bwd.position(s: bwd.length - 100, lateral: bl.lateral)
            XCTAssertGreaterThanOrEqual(pF.distance(to: pB), RoadClass.arterial.laneWidth - 1e-6)
        }
    }

    func testTurnClassificationAndPockets() {
        for side in DrivingSide.allCases {
            let (net, c) = crossroads(side)
            let conns = net.connectors(at: c).map { net.connectors[$0.raw] }
            XCTAssertEqual(conns.filter { $0.turn == .uTurn }.count, 0)
            for e in net.incoming(c) {
                let edge = net.edge(e)!
                // Across-traffic pocket on every arterial approach to a signal.
                let pocket = edge.lanes.first { $0.kind == .acrossPocket }
                XCTAssertNotNil(pocket, "pocket on \(e) (\(side))")
                XCTAssertEqual(pocket?.movements, [side.acrossTurn])
                // Kerb lane serves through + kerb turn.
                let kerb = edge.lanes.first { $0.kind == .travel }!
                XCTAssertEqual(kerb.movements, [.straight, side.kerbTurn])
                XCTAssertEqual(net.node(c)?.effectiveControl, .signal)
            }
        }
    }

    func testPocketStorageScalesWithSpeed() {
        let (slow, cs) = crossroads(.right)
        let (fast, cf) = crossroads(.right)
        for r in fast.allRoads { fast.updateRoad(r.id) { $0.speedLimitOverride = 80 / 3.6 } }
        func pocketLen(_ net: RoadNetwork, _ c: NodeID) -> Double {
            let e = net.edge(net.incoming(c)[0])!
            let p = e.lanes.first { $0.kind == .acrossPocket }!
            return p.sEnd - p.sStart
        }
        XCTAssertGreaterThan(pocketLen(fast, cf), pocketLen(slow, cs) + 10)
    }

    func testOpposingAcrossTurnsDoNotOverlap() {
        for side in DrivingSide.allCases {
            let (net, c) = crossroads(side)
            let lefts = net.connectors(at: c).map { net.connectors[$0.raw] }.filter { $0.turn == side.acrossTurn }
            XCTAssertEqual(lefts.count, 4)
            for a in lefts {
                guard let edgeA = net.edge(a.fromEdge) else { continue }
                // The opposing approach is the one whose direction is reversed.
                for b in lefts where b.id != a.id {
                    guard let edgeB = net.edge(b.fromEdge) else { continue }
                    if edgeA.reference.endTangent.dot(edgeB.reference.endTangent) < -0.9 {
                        XCTAssertFalse(Geometry.polylinesCross(a.path, b.path), "opposing across turns cross (\(side))")
                        // Footprints keep clear too (two 2 m wide cars).
                        var minD = Double.infinity
                        for p in a.path.points { for q in b.path.points { minD = min(minD, p.distance(to: q)) } }
                        XCTAssertGreaterThan(minD, 2.2, "opposing across turns too close (\(side)): \(minD)")
                    }
                }
            }
        }
    }

    func testKerbTurnsAreTighterThanAcrossTurns() {
        for side in DrivingSide.allCases {
            let (net, c) = crossroads(side)
            let conns = net.connectors(at: c).map { net.connectors[$0.raw] }
            let kerb = conns.filter { $0.turn == side.kerbTurn }.map { $0.length }
            let across = conns.filter { $0.turn == side.acrossTurn }.map { $0.length }
            XCTAssertLessThan(kerb.max()!, across.min()!)
            // Turn paths hug the kerb: a kerb turn never passes near the node centre.
            for k in conns.filter({ $0.turn == side.kerbTurn }) {
                let closest = k.path.points.map { $0.length }.min()!
                XCTAssertGreaterThan(closest, 8)
            }
        }
    }

    func testTurnIntoCorrespondingLane() {
        let (net, c) = crossroads(.right)
        for conn in net.connectors(at: c).map({ net.connectors[$0.raw] }) {
            let out = net.edge(conn.toEdge)!
            let travel = out.lanes.filter { $0.kind == .travel }
            switch conn.turn {
            case .right: XCTAssertEqual(conn.to.index, travel.first!.index, "right turn into the kerb lane")
            case .left: XCTAssertEqual(conn.to.index, travel.last!.index, "left turn into the centre lane")
            default: break
            }
        }
    }

    func testOneWayGeometrySurvivesNodeMove() {
        // Defect 5: moving a node rebuilt one-way roads as two-way.
        let net = RoadNetwork(side: .right)
        let a = net.addNode(at: .zero), b = net.addNode(at: Vector2(200, 0))
        let r = net.addRoad(from: a, to: b, roadClass: .arterial, lanes: 3, oneWay: true)!
        let before = net.edge(EdgeID(road: r, forward: true))!.lanes.map { $0.lateral }
        net.moveNode(b, to: Vector2(220, 30))
        XCTAssertNil(net.edge(EdgeID(road: r, forward: false)))
        let after = net.edge(EdgeID(road: r, forward: true))!.lanes.map { $0.lateral }
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, [-3.5, 0, 3.5].map { $0 }, "one-way lanes are centred on the road")
    }

    func testCurvedRoadIsSmooth() {
        let net = RoadNetwork(side: .right)
        let a = net.addNode(at: .zero), b = net.addNode(at: Vector2(400, 0))
        net.addRoad(from: a, to: b, roadClass: .collector, shape: [Vector2(150, 80), Vector2(280, -60)])
        let e = net.allEdges[0]
        XCTAssertGreaterThan(e.reference.points.count, 50)
        XCTAssertGreaterThan(e.reference.minimumRadius, 25, "drawn curves keep a drivable radius")
    }

    func testControlWarrantsFromRoadClasses() {
        XCTAssertEqual(crossroads(.right, cls: .local).0.node(NodeID(0))?.effectiveControl, .uncontrolled)
        XCTAssertEqual(crossroads(.right, cls: .collector).0.node(NodeID(0))?.effectiveControl, .allWayStop)
        XCTAssertEqual(crossroads(.right, cls: .arterial).0.node(NodeID(0))?.effectiveControl, .signal)
        // Local meeting an arterial: two-way stop with the arterial as major road.
        let net = RoadNetwork(side: .right)
        let c = net.addNode(at: .zero)
        net.batch {
            let e = net.addNode(at: Vector2(200, 0)), w = net.addNode(at: Vector2(-200, 0)), n = net.addNode(at: Vector2(0, 200))
            net.addRoad(from: w, to: c, roadClass: .arterial)
            net.addRoad(from: c, to: e, roadClass: .arterial)
            net.addRoad(from: n, to: c, roadClass: .local)
        }
        XCTAssertEqual(net.node(c)?.effectiveControl, .twoWayStop)
        let majors = net.majorApproaches[c.raw]
        XCTAssertEqual(majors.count, 2)
        XCTAssertTrue(majors.allSatisfy { net.edge($0)?.roadClass == .arterial })
    }

    func testConflictMapClassification() {
        let (net, c) = crossroads(.right)
        let conns = net.connectors(at: c).map { net.connectors[$0.raw] }
        func find(_ approachDir: Vector2, _ turn: TurnDirection) -> Connector {
            conns.first { $0.turn == turn && net.edge($0.fromEdge)!.reference.endTangent.dot(approachDir) > 0.9 }!
        }
        let nbThrough = find(Vector2(0, 1), .straight)
        let sbThrough = find(Vector2(0, -1), .straight)
        let sbLeft = find(Vector2(0, -1), .left)
        let nbRight = find(Vector2(0, 1), .right)
        let sbRight = find(Vector2(0, -1), .right)
        func kind(_ a: Connector, _ b: Connector) -> ConflictMap.Kind? {
            net.conflicts.conflicts(of: a.id).first { $0.other == b.id }?.kind
        }
        XCTAssertNil(kind(nbThrough, sbThrough), "opposing throughs are compatible")
        XCTAssertEqual(kind(nbThrough, sbLeft), .cross, "permissive left crosses the opposing through")
        XCTAssertNil(kind(nbRight, sbRight), "opposite right turns are compatible")
        // Both enter the eastbound road, but into different lanes ("turn into the
        // corresponding lane"), so they may turn simultaneously.
        XCTAssertNil(kind(nbRight, sbLeft), "right turn and opposing left use separate exit lanes")
        let nbLeft = find(Vector2(0, 1), .left)
        XCTAssertEqual(kind(nbLeft, sbThrough), .cross)
    }

    func testHighwayRampsUseAuxiliaryLanes() {
        for side in DrivingSide.allCases {
            let map = ScenarioNetworks.make(.highwayTown, side: side)
            let net = map.network
            var accel = 0, decel = 0
            for e in net.allEdges where e.roadClass == .highway {
                for l in e.lanes {
                    if l.kind == .acceleration { accel += 1 }
                    if l.kind == .deceleration {
                        decel += 1
                        XCTAssertEqual(l.movements, [side.kerbTurn], "decel lane only exits")
                    }
                    // Aux lanes are on the kerb side.
                    if l.kind != .travel { XCTAssertGreaterThan(l.lateral * side.kerbSign, 0) }
                }
            }
            XCTAssertEqual(accel, 2)
            XCTAssertEqual(decel, 2)
            // On-ramps feed the acceleration lane; no highway movement crosses into the opposite carriageway.
            for c in net.connectors {
                let from = net.edge(c.fromEdge)!, to = net.edge(c.toEdge)!
                if from.roadClass == .ramp && to.roadClass == .highway {
                    XCTAssertEqual(to.lane(c.to.index)?.kind, .acceleration)
                }
                if from.roadClass == .highway && to.roadClass == .ramp {
                    XCTAssertEqual(from.lane(c.from.index)?.kind, .deceleration)
                }
                if from.roadClass == .highway || from.roadClass == .ramp { XCTAssertNotEqual(c.turn, .uTurn) }
            }
            // Map-edge connections let traffic leave; they have no turnaround.
            for n in net.allNodes where n.isRegionalConnection {
                XCTAssertTrue(net.connectors(at: n.id).isEmpty)
            }
        }
    }

    func testRoundaboutCirculatesWithDrivingSide() {
        for side in DrivingSide.allCases {
            let map = ScenarioNetworks.make(.roundaboutVillage, side: side)
            let net = map.network
            XCTAssertEqual(net.allRoundabouts.count, 3)
            for rb in net.allRoundabouts {
                for rid in rb.ringRoads {
                    let e = net.edge(EdgeID(road: rid, forward: true))!
                    XCTAssertTrue(e.isOneWay)
                    // Sign of the angular velocity around the centre.
                    let p = e.reference.point(at: e.length / 2) - rb.center
                    let t = e.reference.tangent(at: e.length / 2)
                    let ccw = p.cross(t) > 0
                    XCTAssertEqual(ccw, side == .right, "ring direction for \(side)")
                }
                for n in rb.ringNodes {
                    XCTAssertEqual(net.node(n)?.effectiveControl, .yield)
                    let majors = net.majorApproaches[n.raw]
                    XCTAssertEqual(majors.count, 1)
                    XCTAssertTrue(rb.ringRoads.contains(majors.first!.road), "circulating traffic has priority")
                }
            }
        }
    }

    func testAllScenariosBuildForBothSides() {
        for kind in ScenarioKind.allCases {
            for side in DrivingSide.allCases {
                let net = ScenarioNetworks.make(kind, side: side).network
                XCTAssertFalse(net.allEdges.isEmpty, "\(kind) \(side)")
                for e in net.allEdges {
                    XCTAssertGreaterThan(e.length, 1.5, "\(kind) \(side) \(e.id) too short")
                    XCTAssertTrue(e.reference.points.allSatisfy { $0.isFinite })
                }
                for c in net.connectors {
                    XCTAssertTrue(c.path.points.allSatisfy { $0.isFinite })
                    XCTAssertGreaterThan(c.speedLimit, 2.9)
                }
                // Every non-dead-end approach has somewhere to go.
                for e in net.allEdges {
                    guard let n = net.node(e.to), !n.isRegionalConnection else { continue }
                    XCTAssertFalse(net.successors(of: e.id).isEmpty, "\(kind) \(side): \(e.id) is a trap")
                }
            }
        }
    }

    /// Regression: the middle lane of a T-junction approach with no straight
    /// exit had no movement, so cars in it could never leave the edge.
    func testEveryLaneReachingAJunctionLeadsSomewhere() {
        for kind in ScenarioKind.allCases {
            for side in DrivingSide.allCases {
                let net = ScenarioNetworks.make(kind, side: side).network
                for e in net.allEdges where !net.successors(of: e.id).isEmpty {
                    for l in e.lanesAtEnd where l.kind != .acceleration {
                        XCTAssertFalse(net.connectors(from: l.id).isEmpty, "\(kind) \(side): \(e.id) lane \(l.index) (\(l.kind)) has no exit")
                    }
                }
            }
        }
    }

    /// Regression: between close on- and off-ramps the acceleration and
    /// deceleration lanes join into one weaving lane; the on-ramp was mapped
    /// into the median-side lane, crossing every highway lane.
    func testRampsMergeIntoTheKerbSideLane() {
        for kind in ScenarioKind.allCases {
            for side in DrivingSide.allCases {
                let net = ScenarioNetworks.make(kind, side: side).network
                for c in net.connectors {
                    guard let from = net.edge(c.fromEdge), let to = net.edge(c.toEdge),
                          from.roadClass == .ramp, to.roadClass == .highway else { continue }
                    let kerbMost = to.lanesAtStart.map { $0.index }.min()
                    XCTAssertEqual(c.to.index, kerbMost, "\(kind) \(side): \(c.id) ramp \(c.fromEdge) → \(c.toEdge) lane \(c.to.index)")
                }
            }
        }
    }

    func testRebuildIsDeterministic() {
        let a = ScenarioNetworks.make(.stressCity, side: .right).network
        let b = ScenarioNetworks.make(.stressCity, side: .right).network
        XCTAssertEqual(a.connectors.count, b.connectors.count)
        for (x, y) in zip(a.connectors, b.connectors) {
            XCTAssertEqual(x.from, y.from)
            XCTAssertEqual(x.to, y.to)
            XCTAssertEqual(x.path.points, y.path.points)
        }
    }
}
