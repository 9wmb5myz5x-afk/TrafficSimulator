//
//  Signals.swift
//  TrafficEngine
//
//  NEMA dual-ring, eight-phase traffic signals.
//
//      Ring 1:  ϕ1 → ϕ2  ‖  ϕ3 → ϕ4
//      Ring 2:  ϕ5 → ϕ6  ‖  ϕ7 → ϕ8
//               barrier A    barrier B
//
//  ϕ2/ϕ6 are the main-street throughs (opposite directions), ϕ1/ϕ5 the
//  main-street across-traffic turns (ϕ1 opposes ϕ2, so 1+5 run as dual
//  leading lefts, 1+6 / 2+5 as lead-lag, 2+6 as throughs with permitted
//  lefts). ϕ4/ϕ8 and ϕ3/ϕ7 are the side street equivalents. Rings run
//  independently within a barrier group and cross the barrier together.
//
//  Modes:
//   • actuated — virtual stop-bar and advance detectors place calls; a
//     phase runs at least minGreen, each actuation extends it by the
//     passage time (gap-out), up to maxGreen once a conflicting call exists
//     (max-out). Phases without calls are skipped; the main street has
//     minimum recall so the controller rests there.
//   • fixedTime — fixed splits of the cycle, every phase served.
//   • adaptive — Webster's optimal cycle C₀ = (1.5L + 5)/(1 − Y) and splits
//     proportional to measured critical flow ratios, recomputed periodically.
//   • coordination — junctions sharing a group run a common cycle with
//     offsets = distance / progression speed, creating a green wave.
//
//  Change intervals: yellow from the ITE formula Y = t + v / (2a + 2Gg)
//  (t = 1 s, a = 3.05 m/s², level grade), all-red = (W + L) / v from the
//  junction width W and a design vehicle length L = 6 m.
//

public enum SignalIndication: String, Codable, Sendable {
    /// Protected: proceed.
    case green
    /// Permitted (flashing yellow arrow): proceed after yielding.
    case permissive
    case yellow
    case red
}

public struct PhaseTiming: Codable, Sendable, Equatable {
    public var minGreen: Double
    public var maxGreen: Double
    public var passage: Double
    public var yellow: Double
    public var allRed: Double
    /// Fixed-time / adaptive split (green time) [s].
    public var split: Double
}

/// Static description of one junction's phasing (derived from geometry).
public struct SignalPlan: Codable, Sendable {
    public let node: NodeID
    /// Phases 1...8 (index 0 unused). nil = phase not used.
    public var protected: [[ConnectorID]] = Array(repeating: [], count: 9)
    public var permitted: [[ConnectorID]] = Array(repeating: [], count: 9)
    /// Detector lanes for each phase.
    public var detectorLanes: [[LaneID]] = Array(repeating: [], count: 9)
    public var timing: [PhaseTiming?] = Array(repeating: nil, count: 9)
    public var recall: [Bool] = Array(repeating: false, count: 9)
    /// Approach edges served by each phase (for signal heads).
    public var approaches: [[EdgeID]] = Array(repeating: [], count: 9)
    public var mode: SignalMode = .actuated
    public var cycle: Double = 90
    public var offset: Double = 0
    public var coordinated = false

    public func used(_ p: Int) -> Bool { timing[p] != nil }
    static let rings: [[Int]] = [[1, 2, 3, 4], [5, 6, 7, 8]]
    static let groups: [[Int]] = [[1, 2, 5, 6], [3, 4, 7, 8]]
    static func group(of p: Int) -> Int { (p == 1 || p == 2 || p == 5 || p == 6) ? 0 : 1 }
}

/// Live controller state (Codable: part of the save file).
public struct SignalState: Codable, Sendable, Equatable {
    public enum Interval: String, Codable, Sendable { case green, yellow, red, dwell }
    public var node: NodeID
    public var group: Int = 0
    /// Per ring: current phase (0 = dwelling, no phase), interval, time in interval.
    public var phase: [Int] = [2, 6]
    public var interval: [Interval] = [.green, .green]
    public var timer: [Double] = [0, 0]
    /// Passage (gap) timer per ring, and time since a conflicting call appeared.
    public var gapTimer: [Double] = [0, 0]
    public var maxTimer: [Double] = [0, 0]
    /// Locked calls per phase (index 1...8).
    public var calls: [Bool] = Array(repeating: false, count: 9)
    /// Vehicle counts per phase since the last adaptive update.
    public var counts: [Int] = Array(repeating: 0, count: 9)
    public var countWindow: Double = 0
    /// Fixed-time cycle clock.
    public var cycleClock: Double = 0
    /// Pre-emption request: phase to serve for an emergency vehicle (0 = none).
    public var preemptPhase: Int = 0
    /// Last vehicle seen on each advance detector (to count crossings).
    /// Vehicles recently counted by each phase's advance detectors (a short
    /// ring of ids, so a car is counted once however long it sits there and
    /// however many lanes the approach has).
    public var recentlyCounted: [[Int]] = Array(repeating: [], count: 9)
    /// Phase each ring will start after its current change interval (0 = barrier).
    public var pending: [Int] = [0, 0]
}

public struct SignalSystem: Codable, Sendable {
    public private(set) var plans: [SignalPlan?] = []
    public var states: [SignalState?] = []
    /// connector raw → (phase protected, phase permitted)
    private(set) var protectedPhase: [Int] = []
    private(set) var permittedPhase: [Int] = []

    public init() {}

    public func plan(for node: NodeID) -> SignalPlan? { node.raw < plans.count ? plans[node.raw] : nil }
    public func state(for node: NodeID) -> SignalState? { node.raw < states.count ? states[node.raw] : nil }

    // MARK: - Build

    mutating func rebuild(network: RoadNetwork, config: SimulationConfig, time: Double) {
        let old = states
        plans = Array(repeating: nil, count: network.nodeCount)
        states = Array(repeating: nil, count: network.nodeCount)
        protectedPhase = Array(repeating: 0, count: network.connectors.count)
        permittedPhase = Array(repeating: 0, count: network.connectors.count)
        for n in network.allNodes where n.effectiveControl == .signal {
            guard var plan = Self.makePlan(network: network, node: n) else { continue }
            for p in 1...8 {
                for c in plan.protected[p] { protectedPhase[c.raw] = p }
                for c in plan.permitted[p] { permittedPhase[c.raw] = p }
            }
            plan.mode = n.control.signal.mode
            plan.cycle = n.control.signal.cycleLength
            plan.offset = n.control.signal.offset
            if plan.mode != .actuated { Self.applyFixedSplits(&plan, cycle: plan.cycle) }
            plans[n.id.raw] = plan
            var st = SignalState(node: n.id)
            if n.id.raw < old.count, let prev = old[n.id.raw], prev.phase.allSatisfy({ $0 == 0 || plan.used($0) }) {
                st = prev
            } else {
                st.phase = [plan.used(2) ? 2 : 0, plan.used(6) ? 6 : 0]
                st.interval = st.phase.map { $0 == 0 ? .dwell : .green }
                st.cycleClock = plan.offset
            }
            states[n.id.raw] = st
        }
        applyCoordination(network: network, time: time)
    }

    /// Green waves: junctions in a coordination group share a cycle, with
    /// offsets from their distance along the group divided by a progression speed.
    /// The cycle position follows sim time, so a rebuild (any network edit)
    /// keeps every coordinated signal exactly where it was in its cycle.
    mutating func applyCoordination(network: RoadNetwork, time: Double) {
        var groups: [Int: [NodeID]] = [:]
        for n in network.allNodes {
            guard let g = n.control.signal.coordinationGroup, plans[n.id.raw] != nil else { continue }
            groups[g, default: []].append(n.id)
        }
        for g in groups.keys.sorted() {
            guard let members = groups[g], let first = members.first, let p0 = network.node(first)?.position else { continue }
            let cycle = members.compactMap { plans[$0.raw]?.cycle }.max() ?? 90
            for m in members {
                guard var plan = plans[m.raw], let pos = network.node(m)?.position else { continue }
                // Progression along the main axis at 90 % of a typical urban limit.
                let along = abs(pos.x - p0.x) + abs(pos.y - p0.y)
                let progression = 0.9 * RoadClass.arterial.defaultSpeedLimit
                plan.coordinated = true
                plan.cycle = cycle
                plan.offset = (along / progression).truncatingRemainder(dividingBy: cycle)
                if plan.mode == .actuated { plan.mode = .fixedTime }
                Self.applyFixedSplits(&plan, cycle: cycle)
                plans[m.raw] = plan
                states[m.raw]?.cycleClock = (time - plan.offset).nonNegativeMod(cycle)
            }
        }
    }

    // MARK: - Indication

    public func indication(for c: ConnectorID, at node: NodeID) -> SignalIndication {
        guard node.raw < states.count, let st = states[node.raw], c.raw < protectedPhase.count else { return .green }
        let pp = protectedPhase[c.raw], pm = permittedPhase[c.raw]
        var result: SignalIndication = .red
        for r in 0..<2 {
            let p = st.phase[r]
            guard p != 0 else { continue }
            if p == pp {
                switch st.interval[r] {
                case .green: return .green
                case .yellow: result = .yellow
                default: break
                }
            }
            if p == pm {
                switch st.interval[r] {
                case .green: if result == .red { result = .permissive }
                case .yellow: if result == .red { result = .yellow }
                default: break
                }
            }
        }
        return result
    }

    /// Seconds until the connector's indication turns red (0 if red, ∞ if not ending).
    public func timeUntilRed(for c: ConnectorID, at node: NodeID) -> Double {
        guard node.raw < states.count, let st = states[node.raw], let plan = plans[node.raw],
              c.raw < protectedPhase.count else { return .infinity }
        let pp = protectedPhase[c.raw], pm = permittedPhase[c.raw]
        var best = 0.0
        for r in 0..<2 {
            let p = st.phase[r]
            guard p != 0, p == pp || p == pm, let t = plan.timing[p] else { continue }
            switch st.interval[r] {
            case .green: best = .infinity
            case .yellow: best = max(best, t.yellow - st.timer[r])
            default: break
            }
        }
        return best
    }

    /// Indication for an approach's through and across movements (signal heads).
    public func headState(edge: EdgeID, network: RoadNetwork) -> (through: SignalIndication, across: SignalIndication) {
        guard let e = network.edge(edge) else { return (.red, .red) }
        var through: SignalIndication = .red, across: SignalIndication = .red
        func rank(_ s: SignalIndication) -> Int { [.red: 0, .yellow: 1, .permissive: 2, .green: 3][s] ?? 0 }
        for l in e.lanes {
            for c in network.connectors(from: l.id) {
                guard let conn = network.connector(c) else { continue }
                let ind = indication(for: c, at: conn.node)
                if conn.turn.isAcross(network.side) { if rank(ind) > rank(across) { across = ind } }
                else if rank(ind) > rank(through) { through = ind }
            }
        }
        return (through, across)
    }

    // MARK: - Control loop

    mutating func advance(sim: Simulation, dt: Double) {
        for n in 0..<states.count {
            guard var st = states[n], let plan = plans[n] else { continue }
            detect(&st, plan: plan, sim: sim, dt: dt)
            switch plan.mode {
            case .actuated: stepActuated(&st, plan: plan, dt: dt)
            case .fixedTime, .adaptive: stepFixed(&st, plan: plan, dt: dt)
            }
            states[n] = st
            if plan.mode == .adaptive && st.countWindow >= 600 { adapt(node: n) }
        }
    }

    /// Virtual detectors: a stop-bar zone (last 12 m) and an advance zone
    /// (≈ 3 s of travel upstream) on every lane of each phase.
    func detect(_ st: inout SignalState, plan: SignalPlan, sim: Simulation, dt: Double) {
        st.countWindow += dt
        for p in 1...8 where plan.used(p) {
            var occupied = false
            var advanceHit = false
            for lane in plan.detectorLanes[p] {
                guard let e = sim.network.edge(lane.edge) else { continue }
                let key = sim.laneKey(lane.edge, lane.index)
                let advanceS = e.length - max(25, e.speedLimit * 3)
                for o in sim.laneOcc[key] {
                    let v = sim.vehicles[Int(o.index)]
                    guard case .edge(let ve) = v.track, ve == lane.edge, v.lane == lane.index else { continue }
                    // Only vehicles that want a movement of this phase.
                    if let pc = v.plannedConnector, !(plan.protected[p].contains(pc) || plan.permitted[p].contains(pc)) { continue }
                    if o.s >= e.length - 12 && o.s <= e.length + 1 { occupied = true }
                    if o.s >= advanceS && o.s - v.length <= advanceS + 2 {
                        advanceHit = true
                        if !st.recentlyCounted[p].contains(v.id.raw) {
                            st.recentlyCounted[p].append(v.id.raw)
                            if st.recentlyCounted[p].count > 24 { st.recentlyCounted[p].removeFirst() }
                            st.counts[p] += 1
                        }
                    }
                }
            }
            if occupied || advanceHit { st.calls[p] = true }
            // Actuation extends the green of a running phase.
            for r in 0..<2 where st.phase[r] == p && st.interval[r] == .green && (occupied || advanceHit) {
                st.gapTimer[r] = 0
            }
        }
        if st.preemptPhase != 0 { st.calls[st.preemptPhase] = true }
    }

    func phasesInGroup(_ ring: Int, _ group: Int) -> [Int] {
        SignalPlan.rings[ring].filter { SignalPlan.group(of: $0) == group }
    }

    func hasCall(_ st: SignalState, plan: SignalPlan, _ p: Int) -> Bool {
        plan.used(p) && (st.calls[p] || plan.recall[p])
    }

    func groupHasCalls(_ st: SignalState, plan: SignalPlan, _ g: Int) -> Bool {
        SignalPlan.groups[g].contains { hasCall(st, plan: plan, $0) && $0 != 0 }
    }

    mutating func stepActuated(_ st: inout SignalState, plan: SignalPlan, dt: Double) {
        let other = 1 - st.group
        let preemptOther = st.preemptPhase != 0 && SignalPlan.group(of: st.preemptPhase) == other
        let otherCalls = groupHasCalls(st, plan: plan, other) || preemptOther
        // readyForBarrier[r]: ring r has nothing more to do in this group.
        var readyForBarrier = [false, false]
        for r in 0..<2 {
            st.timer[r] += dt
            let p = st.phase[r]
            switch st.interval[r] {
            case .dwell:
                if let next = phasesInGroup(r, st.group).first(where: { hasCall(st, plan: plan, $0) }) {
                    start(&st, ring: r, phase: next)
                } else {
                    readyForBarrier[r] = true
                }
            case .green:
                guard let t = plan.timing[p] else { readyForBarrier[r] = true; continue }
                st.gapTimer[r] += dt
                if st.preemptPhase == p { continue }   // hold green for the emergency vehicle
                let next = nextInGroup(st, plan: plan, ring: r, after: p)
                let conflictingCall = otherCalls || next != nil || st.preemptPhase != 0
                if conflictingCall { st.maxTimer[r] += dt } else { st.maxTimer[r] = 0 }
                let minDone = st.timer[r] >= t.minGreen
                let gappedOut = st.gapTimer[r] >= t.passage
                let maxedOut = st.maxTimer[r] >= t.maxGreen
                let preempted = st.preemptPhase != 0 && st.timer[r] >= min(t.minGreen, 4)
                guard conflictingCall && (preempted || (minDone && (gappedOut || maxedOut))) else { continue }
                if let n = next, !preemptOther {
                    st.calls[p] = false
                    st.interval[r] = .yellow; st.timer[r] = 0; st.pending[r] = n
                } else {
                    readyForBarrier[r] = true
                }
            case .yellow:
                if let t = plan.timing[p], st.timer[r] >= t.yellow { st.interval[r] = .red; st.timer[r] = 0 }
            case .red:
                guard let t = plan.timing[p], st.timer[r] >= t.allRed else { continue }
                if st.pending[r] != 0 {
                    start(&st, ring: r, phase: st.pending[r]); st.pending[r] = 0
                } else if !otherCalls, let again = phasesInGroup(r, st.group).first(where: { hasCall(st, plan: plan, $0) }) {
                    // The other side's calls went away (or the plan changed under
                    // us): serve this group again rather than rest in red.
                    start(&st, ring: r, phase: again)
                } else {
                    readyForBarrier[r] = true
                }
            }
        }
        guard readyForBarrier[0] && readyForBarrier[1] && otherCalls else { return }
        // Cross the barrier: terminate greens, wait for both rings to clear.
        var cleared = true
        for r in 0..<2 {
            switch st.interval[r] {
            case .green:
                if st.phase[r] != 0 { st.calls[st.phase[r]] = false }
                st.interval[r] = .yellow; st.timer[r] = 0; st.pending[r] = 0; cleared = false
            case .yellow: cleared = false
            case .red, .dwell: break
            }
        }
        guard cleared else { return }
        st.group = other
        for r in 0..<2 {
            if let first = phasesInGroup(r, other).first(where: { hasCall(st, plan: plan, $0) || $0 == st.preemptPhase }) {
                start(&st, ring: r, phase: first)
            } else {
                st.phase[r] = 0; st.interval[r] = .dwell; st.timer[r] = 0
            }
        }
    }

    func nextInGroup(_ st: SignalState, plan: SignalPlan, ring r: Int, after p: Int) -> Int? {
        let seq = phasesInGroup(r, st.group)
        guard let k = seq.firstIndex(of: p) else { return nil }
        for q in seq[(k + 1)...] where hasCall(st, plan: plan, q) { return q }
        return nil
    }

    func start(_ st: inout SignalState, ring r: Int, phase p: Int) {
        st.phase[r] = p
        st.interval[r] = .green
        st.timer[r] = 0
        st.gapTimer[r] = 0
        st.maxTimer[r] = 0
    }

    /// Fixed-time sequencing on a cycle clock: 1→2 | 3→4 and 5→6 | 7→8.
    mutating func stepFixed(_ st: inout SignalState, plan: SignalPlan, dt: Double) {
        st.cycleClock = (st.cycleClock + dt).nonNegativeMod(max(plan.cycle, 1))
        // Duration of each barrier group = max over rings of (Σ split + yellow + red).
        func ringSpan(_ r: Int, _ g: Int) -> Double {
            phasesInGroup(r, g).compactMap { plan.timing[$0] }.reduce(0) { $0 + $1.split + $1.yellow + $1.allRed }
        }
        let g0 = max(ringSpan(0, 0), ringSpan(1, 0))
        let g1 = max(ringSpan(0, 1), ringSpan(1, 1))
        let scale = (g0 + g1) > 0 ? plan.cycle / (g0 + g1) : 1
        var t = st.cycleClock / scale
        let group = t < g0 ? 0 : 1
        if group == 1 { t -= g0 }
        st.group = group
        let groupLen = group == 0 ? g0 : g1
        for r in 0..<2 {
            let phases = phasesInGroup(r, group).filter { plan.used($0) }
            if phases.isEmpty { st.phase[r] = 0; st.interval[r] = .dwell; continue }
            // Stretch the last phase so both rings reach the barrier together.
            let span = ringSpan(r, group)
            var acc = 0.0
            var set = false
            for (k, p) in phases.enumerated() {
                let tm = plan.timing[p]!
                let extra = k == phases.count - 1 ? groupLen - span : 0
                let green = tm.split + extra
                if t < acc + green { st.phase[r] = p; st.interval[r] = .green; set = true; break }
                acc += green
                if t < acc + tm.yellow { st.phase[r] = p; st.interval[r] = .yellow; set = true; break }
                acc += tm.yellow
                if t < acc + tm.allRed { st.phase[r] = p; st.interval[r] = .red; set = true; break }
                acc += tm.allRed
            }
            if !set { st.phase[r] = phases.last!; st.interval[r] = .red }
        }
    }

    /// Webster's method from counted flows.
    mutating func adapt(node n: Int) {
        guard var plan = plans[n], var st = states[n] else { return }
        let hours = max(st.countWindow / 3600, 1e-3)
        var y = Array(repeating: 0.0, count: 9)
        for p in 1...8 where plan.used(p) {
            let lanes = Double(max(plan.detectorLanes[p].count, 1))
            let saturation = 1800.0 * lanes                     // veh/h
            y[p] = Double(st.counts[p]) / hours / saturation
        }
        // Critical flow ratio per group = max over rings of the ring's sum.
        var Y = 0.0
        var lost = 0.0
        for g in SignalPlan.groups {
            let r1 = g.filter { $0 <= 4 }, r2 = g.filter { $0 > 4 }
            Y += max(r1.map { y[$0] }.reduce(0, +), r2.map { y[$0] }.reduce(0, +))
            lost += 4 * Double(max(r1.filter { plan.used($0) }.count, r2.filter { plan.used($0) }.count))
        }
        // Shares of green follow the raw ratios; the cycle uses Y capped
        // below saturation (oversaturated junctions get the maximum cycle).
        let totalY = max(Y, 0.05)
        Y = min(Y, 0.9)
        let c0 = ((1.5 * lost + 5) / (1 - Y)).clamped(to: 40...150)
        plan.cycle = c0
        let effective = c0 - lost
        for p in 1...8 where plan.used(p) {
            let share = y[p] > 0 ? y[p] / totalY : 0.1
            plan.timing[p]!.split = max(plan.timing[p]!.minGreen, effective * share)
        }
        st.counts = Array(repeating: 0, count: 9)
        st.countWindow = 0
        plans[n] = plan
        states[n] = st
    }

    // MARK: - Pre-emption

    /// Request a green for the phase serving `edge` at `node` (emergency vehicle).
    mutating func preempt(node: NodeID, edge: EdgeID) {
        guard let plan = plan(for: node), node.raw < states.count, states[node.raw] != nil else { return }
        for p in [2, 6, 4, 8, 1, 5, 3, 7] where plan.approaches[p].contains(edge) {
            states[node.raw]!.preemptPhase = p
            return
        }
    }

    mutating func clearPreemption(node: NodeID) {
        if node.raw < states.count { states[node.raw]?.preemptPhase = 0 }
    }
}
