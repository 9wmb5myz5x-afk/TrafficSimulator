//
//  RoundaboutBuilder.swift
//  TrafficEngine
//
//  Turns a junction into a modern roundabout: a ring of one-way circulating
//  roads (counter-clockwise for `.right`, clockwise for `.left`) with a ring
//  node where each approach meets the circle. Ring nodes use yield control
//  with the ring roads as the major street, so entering traffic yields to
//  circulating traffic through ordinary gap acceptance, and exits are
//  ordinary kerb-side turns. Exit-lane choice falls out of normal route-driven
//  lane positioning.
//

public extension RoadNetwork {

    /// Default inscribed radius of the circulating lane centre [m].
    static let defaultRoundaboutRadius = 18.0

    /// Convert `node` into a roundabout. Returns the roundabout id, or nil if
    /// the node has fewer than 3 roads or the roads are too short.
    @discardableResult
    func makeRoundabout(at nodeID: NodeID, radius: Double = RoadNetwork.defaultRoundaboutRadius,
                        ringClass: RoadClass = .collector) -> Int? {
        guard let node = node(nodeID) else { return nil }
        let attached = allRoads.filter { $0.touches(nodeID) }
        guard attached.count >= 3 else { return nil }
        let c = node.position

        // Where each approach crosses a circle of radius `rad`.
        struct Arm { var road: Road; var angle: Double; var point: Vector2 }
        func armsFor(_ rad: Double) -> [Arm]? {
            var arms: [Arm] = []
            for r in attached {
                guard let line = centreline(of: r.id) else { return nil }
                // Walk from the node end until the centreline leaves the circle.
                let fromA = r.a == nodeID
                let len = line.length
                guard len > rad + 15 else { return nil }
                var s = rad
                var p = fromA ? line.point(at: s) : line.point(at: len - s)
                for _ in 0..<20 {
                    let d = p.distance(to: c)
                    if abs(d - rad) < 0.05 { break }
                    s += rad - d
                    p = fromA ? line.point(at: s) : line.point(at: len - s)
                }
                let dir = (p - c).normalized
                arms.append(Arm(road: r, angle: dir.angle, point: c + dir * rad))
            }
            return arms.sorted { $0.angle < $1.angle }
        }
        // The smallest radius (from the requested one up) whose ring segments
        // between consecutive legs are long enough to drive once both
        // junction mouths are trimmed off (≈ 24 m of arc).
        var chosen: (radius: Double, arms: [Arm])?
        for rad in stride(from: radius, through: radius + 16, by: 4) {
            guard let arms = armsFor(rad) else { break }
            var minGap = Double.infinity
            for i in 0..<arms.count {
                var gap = arms[(i + 1) % arms.count].angle - arms[i].angle
                if gap <= 0 { gap += DMath.twoPi }
                minGap = min(minGap, gap * rad)
            }
            if minGap >= 24 { chosen = (rad, arms); break }
        }
        guard let (radius, arms) = chosen else { return nil }

        var ringNodes: [NodeID] = []
        var ringRoads: [RoadID] = []
        batch {
            var control = NodeControl(requested: .yield, locked: true)
            control.turnOnRed = false
            for arm in arms {
                let n = addNode(at: arm.point, control: control)
                ringNodes.append(n)
                // Re-attach the approach road to its ring node, dropping shape
                // points that fall inside the circle.
                updateRoad(arm.road.id) { r in
                    if r.a == nodeID { r.a = n } else { r.b = n }
                    r.shape = r.shape.filter { $0.distance(to: c) > radius + 2 }
                }
            }
            // Ring roads between consecutive ring nodes, in circulating direction.
            let ccw = side == .right
            let count = arms.count
            for k in 0..<count {
                let i = ccw ? k : (count - k) % count
                let j = ccw ? (k + 1) % count : (count - k - 1 + count) % count
                let a0 = arms[i].angle
                var a1 = arms[j].angle
                if ccw { if a1 <= a0 { a1 += DMath.twoPi } } else { if a1 >= a0 { a1 -= DMath.twoPi } }
                let steps = max(2, Int((abs(a1 - a0) * radius / 4).rounded(.up)))
                var shape: [Vector2] = []
                for t in 1..<steps {
                    let a = a0 + (a1 - a0) * Double(t) / Double(steps)
                    shape.append(c + Vector2.unit(angle: a) * radius)
                }
                if let rid = addRoad(from: ringNodes[i], to: ringNodes[j], roadClass: ringClass, shape: shape,
                                     lanes: 1, oneWay: true) {
                    updateRoad(rid) { $0.speedLimitOverride = 25 / 3.6; $0.turnPockets = false }
                    ringRoads.append(rid)
                }
            }
            for n in ringNodes {
                updateNode(n) { $0.control.majorRoads = ringRoads }
            }
            // The original centre node is no longer part of the network.
            removeNode(nodeID)
        }
        return addRoundabout(Roundabout(id: 0, center: c, radius: radius, ringNodes: ringNodes, ringRoads: ringRoads))
    }
}
