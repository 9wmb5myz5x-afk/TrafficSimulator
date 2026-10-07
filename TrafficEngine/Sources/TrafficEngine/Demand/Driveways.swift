//
//  Driveways.swift
//  TrafficEngine
//
//  Every building has a paved driveway from its front to the kerb. Cars
//  drive along it (`onDriveway`) instead of appearing beside the road:
//   • leaving: from the front of the building down to the mouth, where the
//     driver stops and waits for a gap, then pulls out into the kerb lane
//   • arriving: straight from the kerb lane, turning off along a curve up to
//     the front of the building, where the trip ends
//  The driveway path is pure geometry (also drawn by the renderer); the car
//  rides it with its front bumper on the path and its rear following the
//  same path a car length behind.
//

/// A car on a driveway path.
public struct DrivewayRun: Codable, Sendable, Equatable {
    public var path: Polyline
    /// Arc length of the front bumper along `path`.
    public var s: Double
    /// Turning in (arriving) rather than leaving.
    public var inbound: Bool
    /// Arc length of the garage door: the car is inside the building before
    /// it (leaving) or beyond it (arriving).
    public var door: Double
}

public extension Vehicle {
    /// How much of the car shows (0…1): it fades as it goes into or comes
    /// out of its garage.
    var visibility: Double {
        guard mode == .onDriveway, let r = driveway else { return 1 }
        let span = 0.8 * length
        let out = r.inbound ? 1 - (r.s - r.door) / span : (r.s - r.door) / span
        return out.clamped(to: 0...1)
    }
}

extension Simulation {

    /// Angle at which a car leaving a driveway meets the kerb lane [rad].
    static let drivewayMouthAngle = 0.35
    /// Top speed on a driveway [m/s].
    static let drivewaySpeed = 3.0

    /// The geometry of a building's driveway in the road's frame.
    struct DrivewayFrame {
        /// The mouth (where a car leaving waits for a gap) and the road's direction there.
        var mouth: Vector2
        var along: Vector2
        /// Away from the road.
        var outward: Vector2
        /// Direction of a car leaving, at the mouth.
        var exit: Vector2
        /// The middle of the building's front.
        var door: Vector2
        var facing: Vector2
    }

    func drivewayFrame(for b: Building) -> DrivewayFrame? {
        guard let a = b.access, let edge = network.edge(a.edge), let lane = edge.lane(a.lane) else { return nil }
        let f = Vector2.unit(angle: b.rotation)
        let t = edge.reference.tangent(at: a.s)
        let towardLane: Double = lane.lateral >= a.drivewayLateral ? 1 : -1
        let th = Self.drivewayMouthAngle
        return DrivewayFrame(mouth: edge.position(s: a.s, lateral: a.drivewayLateral), along: t,
                             outward: t.perpendicular * -towardLane,
                             exit: (t * DMath.cos(th) + t.perpendicular * (towardLane * DMath.sin(th))).normalized,
                             door: b.center + f * (b.kind.size.depth / 2), facing: f)
    }

    /// The centre line of a building's driveway, from the building down to
    /// the mouth at the kerb. The last few metres run straight at
    /// `drivewayMouthAngle` to the traffic, so a car waiting there is already
    /// angled to pull out. A building set well back is left from its front
    /// door; one close to the road from inside it (its garage), so the
    /// driveway is always a gentle curve.
    public func drivewayPath(for b: Building) -> Polyline? {
        guard let d = drivewayFrame(for: b) else { return nil }
        let k0 = d.mouth - d.exit * 3.5
        let out = (d.door - k0).dot(d.outward), along = (d.door - k0).dot(d.along)
        func path(_ start: Vector2, _ dir: Vector2, _ k: Double) -> Polyline {
            let c = max(1, start.distance(to: k0) * k)
            return Polyline(Curves.cubic(start, start + dir * c, k0 - d.exit * c, k0, segments: 16) + [d.mouth])
        }
        if out >= 4 && along <= 0.4 * out && along >= -1.5 * out {
            let p = path(d.door, d.facing, 0.45)
            if p.minimumRadius >= 3 { return p }
        }
        // From the garage: a plain turn (radius about 4.5 m) out of it,
        // within the building's own frontage.
        return path(k0 + d.outward * 5 - d.along * 3.2, -d.outward, 0.37)
    }

    /// Where a car turning in ends up (the front door, or inside a building
    /// close to the road), and the direction it faces there.
    func drivewayEnds(for b: Building) -> [(point: Vector2, direction: Vector2)] {
        guard let d = drivewayFrame(for: b) else { return [] }
        let garage = (d.mouth + d.outward * 5, -d.outward)
        if (d.door - d.mouth).dot(d.outward) >= 4 { return [(d.door, -d.facing), garage] }
        return [garage]
    }

    /// Arc length at which a path last (leaving) or first (arriving) is
    /// inside the building's footprint: where the car comes out of / goes into its garage.
    func garageDoor(on path: Polyline, building b: Building, leaving: Bool) -> Double {
        let poly = b.footprint
        let n = max(2, Int(path.length / 0.25))
        var found: Double?
        for k in 0...n {
            let s = path.length * Double(k) / Double(n)
            let inside = Geometry.pointInPolygon(path.point(at: s), poly)
            if leaving, inside { found = s }
            if !leaving, inside { return s }
        }
        return found ?? (leaving ? 0 : path.length)
    }

    /// The paved area of a building's driveway, as simple polygons: a strip
    /// along the way out, one along the way in, and an apron flaring out
    /// where the driveway meets the road.
    public func drivewaySurfaces(for b: Building) -> [[Vector2]] {
        guard let path = drivewayPath(for: b), let a = b.access, let edge = network.edge(a.edge),
              let lane = edge.lane(a.lane), let d = drivewayFrame(for: b) else { return [] }
        func strip(_ p: Polyline, half: Double) -> [Vector2] {
            var left: [Vector2] = [], right: [Vector2] = []
            let n = max(2, Int(p.length / 1.5))
            for k in 0...n {
                let s = p.length * Double(k) / Double(n)
                left.append(p.position(at: s, lateral: half))
                right.append(p.position(at: s, lateral: -half))
            }
            return left + right.reversed()
        }
        var out = [strip(path, half: 1.6)]
        if let end = drivewayEnds(for: b).first {
            out.append(strip(Polyline([d.mouth - d.exit * 3, end.point]), half: 1.6))
        }
        // The apron, in the edge frame: from the edge of the carriageway to a
        // little beyond the mouth, wide at the road and narrowing inwards.
        let o: Double = a.drivewayLateral >= lane.lateral ? 1 : -1
        let roadEdge = lane.lateral + o * (lane.width / 2 + edge.roadClass.shoulderWidth - 0.2)
        let back = a.drivewayLateral + o * 1.6
        let s0 = max(0, a.s - 10), s1 = min(edge.length, a.s + 9)
        out.append([edge.position(s: s0, lateral: roadEdge), edge.position(s: s1, lateral: roadEdge),
                    edge.position(s: min(s1, a.s + 3.5), lateral: back), edge.position(s: max(s0, a.s - 7), lateral: back)])
        return out
    }

    /// The car currently using a building's driveway, if any (clearing a
    /// stale claim left by a car that has gone).
    func drivewayHolder(_ b: BuildingID) -> VehicleID? {
        guard let id = city.buildingSlots[b.raw]?.drivewayVehicle else { return nil }
        if let i = index(of: id) {
            let v = vehicles[i]
            // A car pulling out frees the driveway once it is well on its way.
            let nearMouth = city.building(b)?.access.map { abs(v.s - $0.s) < 12 } ?? false
            let leaving = v.origin == b && (v.mode == .onDriveway || v.mode == .waitingToEnter || (v.mode == .pullingOut && nearMouth))
            let arriving = v.destination.building == b && (v.mode == .onDriveway || v.mode == .pullingIn)
            if leaving || arriving { return id }
        }
        city.buildingSlots[b.raw]?.drivewayVehicle = nil
        return nil
    }

    /// Put vehicle `i` in building `b`'s garage (or at its door), about to drive down the driveway.
    func startLeaving(_ i: Int, from b: Building) {
        guard let path = drivewayPath(for: b), let a = b.access else { return }
        vehicles[i].mode = .onDriveway
        vehicles[i].lateral = a.drivewayLateral
        vehicles[i].speed = 0
        // Nose at the garage door, the rest of the car still inside.
        let door = garageDoor(on: path, building: b, leaving: true)
        vehicles[i].driveway = DrivewayRun(path: path, s: min(door + 0.3, path.length), inbound: false, door: door)
        updatePose(&vehicles[i])
    }

    /// Vehicle `i`, driving in the kerb lane, turns off into building `b`'s driveway.
    func startArriving(_ i: Int, at b: Building) {
        guard let path = arrivalPath(i, at: b) else { return }
        let v = vehicles[i]
        let door = garageDoor(on: path, building: b, leaving: false)
        vehicles[i].mode = .onDriveway
        vehicles[i].driveway = DrivewayRun(path: path, s: v.length, inbound: true, door: door)
        vehicles[i].laneChange = nil
        vehicles[i].modeTimer = 0
        city.buildingSlots[b.id.raw]?.drivewayVehicle = v.id
        kerbside.append(i)
    }

    /// The way from vehicle `i`'s place in the kerb lane up to the building,
    /// if there is a smooth one (the turn must not be too tight).
    func arrivalPath(_ i: Int, at b: Building) -> Polyline? {
        let v = vehicles[i]
        let h = Vector2.unit(angle: v.heading)
        for end in drivewayEnds(for: b) {
            let c = max(1.0, v.front.distance(to: end.point) * 0.45)
            // Off the lane promptly (not carrying on along it).
            let side = abs((end.point - v.front).dot(h.perpendicular))
            let c0 = min(c, max(3, 0.6 * side))
            // A car length of straight behind the front, so the rear follows the
            // path it actually came along; and a car length on into the garage.
            let curve = Curves.cubic(v.front, v.front + h * c0, end.point - end.direction * c, end.point, segments: 14)
            let path = Polyline([v.front - h * v.length] + curve + [end.point + end.direction * (v.length + 0.5)])
            if path.minimumRadius >= 3 { return path }
        }
        return nil
    }

    /// One step along the driveway: roll at walking pace, stopping at the end.
    /// Returns true once the car is stopped at the end of the path.
    func rollAlongDriveway(_ i: Int, dt: Double) -> Bool {
        guard var run = vehicles[i].driveway else { return true }
        let v = vehicles[i]
        let remaining = max(run.path.length - run.s, 0)
        let brake = 1.2
        // Brake to stop exactly at the end (never quite crawling to a halt short of it).
        let target = remaining < 0.02 ? 0 : max(min(Self.drivewaySpeed, (2 * brake * remaining).squareRoot()), 0.25)
        let accMax = min(1.2, v.driver.idm.maxAcceleration)
        var a = ((target - v.speed) / dt).clamped(to: -3.0...accMax)
        // Turning in: until off the lane, keep behind whoever is ahead in it.
        if run.inbound, case .edge(let e) = v.track, let edge = network.edge(e), let lane = edge.lane(v.lane) {
            let p = edge.reference.project(v.front)
            if abs(p.lateral - lane.lateral) < lane.width / 2 + v.width / 2 + 0.3,
               let o = leader(in: laneOcc[laneKey(e, v.lane)], after: p.s, excluding: i) {
                let w = vehicles[Int(o.index)]
                a = min(a, IDM.acceleration(v.driver.idm, speed: v.speed, desiredSpeed: Self.drivewaySpeed,
                                            gap: o.s - w.length - p.s, leaderSpeed: w.speed))
            }
        }
        a = max(a, -IDM.emergencyDeceleration)
        var speed = max(0, v.speed + a * dt)
        if speed * dt > remaining { speed = remaining / dt }
        run.s = min(run.s + speed * dt, run.path.length)
        vehicles[i].acceleration = speed > 0 || a > 0 ? a : 0
        vehicles[i].speed = speed
        vehicles[i].distance += speed * dt
        vehicles[i].driveway = run
        let done = run.path.length - run.s < 0.02
        if done {
            vehicles[i].speed = 0
            vehicles[i].acceleration = 0
            vehicles[i].driveway?.s = run.path.length
        }
        return done
    }

    /// From the mouth of the driveway into the edge frame: the car is now
    /// pulling out, at the angle it came down the driveway.
    func joinKerbFromDriveway(_ i: Int) {
        guard case .edge(let e) = vehicles[i].track, let edge = network.edge(e) else { return }
        let v = vehicles[i]
        let road = edge.reference.tangent(at: v.s).angle
        let phi = DMath.angleDifference(road, v.heading).clamped(to: -1.1...1.1)
        // The rear offset that keeps the body's heading exactly (the road may
        // curve under the car): heading grows monotonically as the rear moves
        // the other way, so bisect.
        let front = edge.position(s: v.s, lateral: v.lateral)
        func heading(_ rl: Double) -> Double {
            DMath.angleDifference(v.heading, (front - edge.position(s: v.s - v.length, lateral: rl)).angle)
        }
        var lo = v.lateral - 3 * v.length, hi = v.lateral + 3 * v.length
        if heading(lo) > heading(hi) { swap(&lo, &hi) }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if heading(mid) < 0 { lo = mid } else { hi = mid }
        }
        vehicles[i].driveway = nil
        vehicles[i].mode = .pullingOut
        vehicles[i].modeTimer = 0
        vehicles[i].rearLateral = (lo + hi) / 2
        vehicles[i].bodyYaw = phi.clamped(to: -0.45...0.45)
        updatePose(&vehicles[i])
    }

    /// Pose on a driveway: front on the path, rear a car length behind on it.
    func drivewayPose(_ v: inout Vehicle, _ run: DrivewayRun) {
        let front = run.path.point(at: run.s)
        let rear = run.path.extendedPoint(at: run.s - v.length)
        var axis = front - rear
        if axis.length < 0.5 { axis = run.path.tangent(at: run.s) }
        let dir = axis.normalized
        v.front = front
        v.heading = axis.angle
        v.center = front - dir * (v.length / 2)
    }
}
