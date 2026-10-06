//
//  Invariants.swift
//  TrafficEngine
//
//  Physical invariants asserted on every step by tests, soak runs and the
//  CLI. A violation is a bug, never "noise":
//
//   overlap     — two vehicle footprints (oriented boxes) intersect
//   teleport    — per-step displacement exceeds what the speed allows
//   heading     — heading jumps more than the path curvature allows
//   offRoad     — a vehicle is outside its carriageway / connector corridor
//   sanity      — NaN/∞, negative speed, speed > 1.3 × limit (non-emergency)
//   accel       — acceleration outside physical bounds
//   stuck       — stationary > 5 min outside a detected gridlock
//   forcedStop  — a vehicle reached a stop line it was not allowed to cross
//                 (the engine had to stop it instantly)
//

public struct InvariantViolation: Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable, CaseIterable { case overlap, teleport, heading, offRoad, sanity, accel, stuck, forcedStop }
    public var kind: Kind
    public var time: Double
    public var detail: String
    public var description: String { "[\(kind.rawValue) t=\(String(format1(time)))] \(detail)" }
}

func format1(_ x: Double) -> String {
    let r = (x * 10).rounded() / 10
    return "\(r)"
}

public final class InvariantChecker {
    public private(set) var counts: [InvariantViolation.Kind: Int] = [:]
    public private(set) var samples: [InvariantViolation] = []
    public var maxSamples = 40
    /// Footprint shrink applied before the overlap test [m] (rounded bumpers).
    public var overlapTolerance = 0.05
    public var stuckLimit = 300.0
    public var checkEvery = 1
    private var previous: [Int: (front: Vector2, heading: Double, speed: Double)] = [:]
    public private(set) var checkedSteps = 0
    public private(set) var maxVehicles = 0

    public init() {}

    public var total: Int { counts.values.reduce(0, +) }
    public func count(_ k: InvariantViolation.Kind) -> Int { counts[k] ?? 0 }

    func record(_ kind: InvariantViolation.Kind, _ time: Double, _ detail: @autoclosure () -> String) {
        counts[kind, default: 0] += 1
        // Keep the first few of every kind, so rare kinds aren't crowded out.
        if samples.count < maxSamples * 4 && (counts[kind] ?? 0) <= maxSamples / 2 {
            samples.append(InvariantViolation(kind: kind, time: time, detail: detail()))
        }
    }

    func recordForcedStop(_ v: Vehicle, time: Double) {
        record(.forcedStop, time, "\(v.id) forced to stop at the end of \(v.track)")
    }

    public func summary() -> String {
        if total == 0 { return "0 violations in \(checkedSteps) steps (max \(maxVehicles) vehicles)" }
        let parts = InvariantViolation.Kind.allCases.compactMap { k in counts[k].map { "\(k.rawValue)=\($0)" } }
        return "\(total) violations [\(parts.joined(separator: ", "))] in \(checkedSteps) steps"
    }

    func check(_ sim: Simulation) {
        checkedSteps += 1
        guard checkedSteps % checkEvery == 0 else { return }
        let dt = sim.config.dt * Double(checkEvery)
        let t = sim.time
        var live: [Int] = []
        maxVehicles = max(maxVehicles, sim.vehicles.count)
        var next: [Int: (front: Vector2, heading: Double, speed: Double)] = [:]
        next.reserveCapacity(sim.vehicles.count)

        for (i, v) in sim.vehicles.enumerated() {
            guard v.mode != .finished, v.mode != .waitingToEnter else { continue }
            live.append(i)
            // Sanity.
            if !v.s.isFinite || !v.speed.isFinite || !v.center.isFinite || !v.heading.isFinite || !v.lateral.isFinite {
                record(.sanity, t, "\(v.id) non-finite state"); continue
            }
            if v.speed < 0 { record(.sanity, t, "\(v.id) negative speed \(v.speed)") }
            let limit = maxLimit(sim, v)
            // A road downgraded under a moving car: it needs a few seconds to brake.
            if !v.siren && v.speed > 1.3 * limit + 0.5 && sim.time - sim.lastNetworkEdit > 15 {
                record(.sanity, t, "\(v.id) speed \(v.speed) > 1.3 × \(limit) on \(v.track)")
            }
            if v.acceleration < -IDM.emergencyDeceleration - 1e-6 || v.acceleration > v.driver.idm.maxAcceleration + 0.05 {
                if !(v.acceleration < 0 && v.speed == 0) {
                    record(.accel, t, "\(v.id) acceleration \(v.acceleration)")
                }
            }
            // Teleport / heading (the front bumper moves along the path at the vehicle's speed).
            if let p = previous[v.id.raw] {
                let disp = p.front.distance(to: v.front)
                let vmax = max(p.speed, v.speed)
                let allowed = vmax * dt * 1.35 + 0.15
                if disp > allowed { record(.teleport, t, "\(v.id) moved \(disp) m in \(dt) s at \(vmax) m/s on \(v.track)") }
                let dh = abs(DMath.angleDifference(p.heading, v.heading))
                if dh > disp * 0.6 + 0.1 { record(.heading, t, "\(v.id) heading jumped \(dh) rad over \(disp) m on \(v.track)") }
            }
            next[v.id.raw] = (v.front, v.heading, v.speed)
            // Off-road.
            if case .edge(let e) = v.track, let edge = sim.network.edge(e) {
                let lats = edge.lanes.map { $0.lateral }
                let lo = (lats.min() ?? 0) - edge.laneWidth / 2 - edge.roadClass.shoulderWidth - 0.6
                let hi = (lats.max() ?? 0) + edge.laneWidth / 2 + edge.roadClass.shoulderWidth + 0.6
                let driveway = v.mode == .pullingIn || v.mode == .pullingOut || v.mode == .parkedAtKerb
                if !driveway && (v.lateral < lo || v.lateral > hi) {
                    record(.offRoad, t, "\(v.id) lateral \(v.lateral) outside [\(lo), \(hi)] on \(e)")
                }
                let exiting = v.isOnFinalEdge && v.destination.kind == .exitMap
                if v.s < -0.01 || (v.s > edge.length + 0.01 && !exiting) {
                    record(.offRoad, t, "\(v.id) s=\(v.s) outside edge \(e) (len \(edge.length))")
                }
            } else if case .connector(let c) = v.track, let conn = sim.network.connector(c) {
                if v.s < -0.01 || v.s > conn.length + 0.01 { record(.offRoad, t, "\(v.id) s=\(v.s) outside connector \(c)") }
            }
            // Liveness.
            if v.stationaryTime > stuckLimit && v.mode == .driving && !sim.isInGridlock(v.id) {
                if v.stationaryTime - dt <= stuckLimit {
                    record(.stuck, t, "\(v.id) stationary \(Int(v.stationaryTime)) s on \(v.track) s=\(Int(v.s))")
                }
            }
        }
        previous = next

        // Overlaps via a uniform grid.
        let cell = 12.0
        var grid: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        for i in live {
            let c = sim.vehicles[i].center
            grid[key(Int((c.x / cell).rounded(.down)), Int((c.y / cell).rounded(.down))), default: []].append(i)
        }
        for i in live {
            let a = sim.vehicles[i]
            let cx = Int((a.center.x / cell).rounded(.down)), cy = Int((a.center.y / cell).rounded(.down))
            let boxA = a.footprint
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let list = grid[key(cx + dx, cy + dy)] else { continue }
                    for j in list where j > i {
                        let b = sim.vehicles[j]
                        guard sim.levelsCompatible(a, b) else { continue }
                        if boxA.overlaps(b.footprint, margin: overlapTolerance) {
                            record(.overlap, t, "\(a.id) [\(a.track) s=\(String(format1(a.s))) lat=\(String(format1(a.lateral)))] overlaps \(b.id) [\(b.track) s=\(String(format1(b.s))) lat=\(String(format1(b.lateral)))]")
                        }
                    }
                }
            }
        }
    }

    func maxLimit(_ sim: Simulation, _ v: Vehicle) -> Double {
        switch v.track {
        case .edge(let e): return sim.network.edge(e)?.speedLimit ?? 30
        case .connector(let c):
            guard let conn = sim.network.connector(c) else { return 30 }
            return max(sim.network.edge(conn.fromEdge)?.speedLimit ?? 0, sim.network.edge(conn.toEdge)?.speedLimit ?? 0)
        }
    }
}

extension Simulation {

    /// Grade level of a vehicle's position (ramps touch both levels).
    func levelRange(_ v: Vehicle) -> ClosedRange<Int> {
        func edgeRange(_ e: EdgeID) -> ClosedRange<Int> {
            guard let edge = network.edge(e) else { return 0...0 }
            if edge.roadClass == .ramp { return -1...1 }
            return edge.level...edge.level
        }
        switch v.track {
        case .edge(let e): return edgeRange(e)
        case .connector(let c):
            guard let conn = network.connector(c) else { return 0...0 }
            let a = edgeRange(conn.fromEdge), b = edgeRange(conn.toEdge)
            return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
        }
    }

    func levelsCompatible(_ a: Vehicle, _ b: Vehicle) -> Bool {
        // A ramp shares space with another road only where they meet (the
        // merge or diverge); elsewhere it crosses on its own grade.
        if case .edge(let ea) = a.track, case .edge(let eb) = b.track,
           let x = network.edge(ea), let y = network.edge(eb), x.road != y.road,
           x.roadClass == .ramp || y.roadClass == .ramp {
            let shared = [x.from, x.to].filter { $0 == y.from || $0 == y.to }
            // Only near the node they share (the merge / diverge area).
            return shared.contains { n in
                guard let p = network.node(n)?.position else { return false }
                return a.front.distance(to: p) < 80 && b.front.distance(to: p) < 80
            }
        }
        return levelRange(a).overlaps(levelRange(b))
    }

    /// Whether a vehicle is part of a detected gridlock (M3 fills this in).
    public func isInGridlock(_ id: VehicleID) -> Bool { gridlockVehicles.contains(id) }

    /// Hash of the full dynamic state, for determinism checks.
    public func traceHash() -> UInt64 {
        var h = TraceHasher()
        h.combine(time)
        h.combine(vehicles.count)
        for v in vehicles {
            h.combine(v.id.raw)
            h.combine(v.s); h.combine(v.speed); h.combine(v.lateral); h.combine(v.acceleration)
            switch v.track {
            case .edge(let e): h.combine(e.raw)
            case .connector(let c): h.combine(1_000_000 + c.raw)
            }
            h.combine(v.lane)
        }
        h.combine(rng.state)
        return h.value
    }
}
