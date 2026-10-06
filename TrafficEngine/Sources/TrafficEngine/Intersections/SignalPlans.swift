//
//  SignalPlans.swift
//  TrafficEngine
//
//  Building a NEMA dual-ring plan for a junction: main axis and side
//  approaches mapped to phases 2/6 and 4/8 with their across turns on 1/5 and
//  3/7 (protected, protected-permitted or permitted by opposing lanes and
//  pockets), ITE yellow and all-red, and fixed-time splits by lanes served.
//

extension SignalSystem {

    static func makePlan(network: RoadNetwork, node: Node) -> SignalPlan? {
        let incoming = network.incoming(node.id).compactMap { network.edge($0) }
        guard !incoming.isEmpty else { return nil }
        let side = network.side
        var plan = SignalPlan(node: node.id)

        // Main axis: the most opposite pair of approaches with the highest class.
        var best: (Int, Int, Double)?
        for i in 0..<incoming.count {
            for j in (i + 1)..<incoming.count {
                let a = incoming[i], b = incoming[j]
                let opp = -a.reference.endTangent.dot(b.reference.endTangent)
                let score = Double(a.roadClass.rank + b.roadClass.rank) * 2 + opp * 3 + Double(a.travelLanes + b.travelLanes) * 0.2
                if best == nil || score > best!.2 + 1e-9 { best = (i, j, score) }
            }
        }
        var main: [Edge] = []
        if let (i, j, _) = best, -incoming[i].reference.endTangent.dot(incoming[j].reference.endTangent) > 0.5 {
            main = [incoming[i], incoming[j]]
        } else {
            main = [incoming[0]]
        }
        let side1 = incoming.filter { e in !main.contains { $0.id == e.id } }
        var sides: [Edge] = []
        if side1.count >= 2 {
            sides = [side1[0], side1[1]]
        } else {
            sides = side1
        }
        // Junction width for all-red: the larger setback span.
        let geom = network.geometry(of: node.id)
        let width = (geom?.ends.map { $0.setback }.max() ?? 10) * 2

        // Assign: main[0] → ϕ2 through, ϕ5 across; main[1] → ϕ6 through, ϕ1 across;
        // sides[0] → ϕ4 / ϕ7; sides[1] → ϕ8 / ϕ3.
        let slots: [(Edge?, Int, Int)] = [
            (main.first, 2, 5), (main.count > 1 ? main[1] : nil, 6, 1),
            (sides.first, 4, 7), (sides.count > 1 ? sides[1] : nil, 8, 3)
        ]
        let opposite: [Int: Int] = [2: 6, 6: 2, 4: 8, 8: 4]
        func opposingLanes(_ throughPhase: Int) -> Int {
            guard let op = opposite[throughPhase], let e = slots.first(where: { $0.1 == op })?.0 else { return 0 }
            return e.travelLanes
        }
        for (edge, through, across) in slots {
            guard let e = edge else { continue }
            let conns = e.lanes.flatMap { network.connectors(from: $0.id) }.compactMap { network.connector($0) }
            let acrossConns = conns.filter { $0.turn.isAcross(side) }
            let otherConns = conns.filter { !$0.turn.isAcross(side) }
            let hasOpposing = slots.contains { $0.1 == opposite[through] && $0.0 != nil }
            // Across-turn treatment.
            var mode = node.control.signal.acrossTurnMode
            if mode == .auto {
                let pocketCount = e.lanes.filter { $0.kind == .acrossPocket }.count
                let opp = opposingLanes(through)
                if !hasOpposing || acrossConns.isEmpty { mode = .permitted }
                else if opp >= 3 || pocketCount >= 2 { mode = .protectedOnly }
                // Against two or more opposing lanes gaps get scarce: give the
                // turn its own (leading) arrow, with or without a pocket.
                else if opp >= 2 { mode = .protectedPermitted }
                else { mode = .permitted }
            }
            plan.protected[through] = otherConns.map { $0.id }
            plan.approaches[through] = [e.id]
            plan.detectorLanes[through] = e.lanes.filter { $0.kind != .acrossPocket || acrossConns.isEmpty }.map { $0.id }
            let v = e.speedLimit
            let yellow = (1.0 + v / (2 * 3.05)).clamped(to: 3...6)
            let allRed = ((width + 6) / max(v, 5)).clamped(to: 1...3)
            plan.timing[through] = PhaseTiming(minGreen: 8, maxGreen: e.roadClass.rank >= 2 ? 45 : 30, passage: 2.5,
                                               yellow: yellow, allRed: allRed, split: 30)
            plan.recall[through] = through == 2 || through == 6
            if acrossConns.isEmpty { continue }
            // Lanes (pockets) of turns that run with the through phase must call it.
            let acrossLanes = Array(Set(acrossConns.map { $0.from })).sorted()
            if !hasOpposing {
                // Unopposed across turn runs protected with the through phase.
                plan.protected[through] += acrossConns.map { $0.id }
                plan.detectorLanes[through] = Array(Set(plan.detectorLanes[through] + acrossLanes)).sorted()
                continue
            }
            switch mode {
            case .permitted:
                plan.permitted[through] += acrossConns.map { $0.id }
                plan.detectorLanes[through] = Array(Set(plan.detectorLanes[through] + acrossLanes)).sorted()
            case .protectedPermitted, .auto:
                plan.permitted[through] += acrossConns.map { $0.id }
                fallthrough
            case .protectedOnly:
                plan.protected[across] = acrossConns.map { $0.id }
                plan.approaches[across] = [e.id]
                plan.detectorLanes[across] = Array(Set(acrossConns.map { $0.from })).sorted()
                plan.timing[across] = PhaseTiming(minGreen: 5, maxGreen: 20, passage: 2.0, yellow: yellow,
                                                  allRed: allRed, split: 12)
            }
        }
        // Approaches that found no slot (a fifth leg, or a skewed junction with
        // no opposing pair): they run with the side-street phase, yielding to
        // everything else (permitted), so every movement gets a green.
        let slotted = Set(slots.compactMap { $0.0?.id })
        for e in incoming where !slotted.contains(e.id) {
            let phase = plan.used(4) ? 4 : (plan.used(8) ? 8 : 4)
            if !plan.used(phase) {
                let v = e.speedLimit
                plan.timing[phase] = PhaseTiming(minGreen: 8, maxGreen: 30, passage: 2.5,
                                                 yellow: (1.0 + v / (2 * 3.05)).clamped(to: 3...6),
                                                 allRed: ((width + 6) / max(v, 5)).clamped(to: 1...3), split: 25)
            }
            let conns = e.lanes.flatMap { network.connectors(from: $0.id) }
            plan.permitted[phase] += conns
            plan.approaches[phase].append(e.id)
            plan.detectorLanes[phase] += e.lanes.map { $0.id }
        }
        // A side street with no ϕ4 but a ϕ8 (or vice versa) still works: rings dwell.
        return plan
    }

    static func applyFixedSplits(_ plan: inout SignalPlan, cycle: Double) {
        // Split the cycle between barrier groups by the number of lanes served.
        var lost = 0.0
        var weight = Array(repeating: 0.0, count: 9)
        for p in 1...8 {
            guard let t = plan.timing[p] else { continue }
            weight[p] = Double(max(plan.detectorLanes[p].count, 1)) * (p % 2 == 0 ? 1.0 : 0.5)
            _ = t
        }
        for ring in SignalPlan.rings {
            var l = 0.0
            for p in ring { if let t = plan.timing[p] { l += t.yellow + t.allRed } }
            lost = max(lost, l)
        }
        let available = max(cycle - lost, 20)
        for group in SignalPlan.groups {
            let ringA = group.filter { $0 <= 4 }, ringB = group.filter { $0 > 4 }
            let wA = ringA.map { weight[$0] }.reduce(0, +), wB = ringB.map { weight[$0] }.reduce(0, +)
            let wTotal = SignalPlan.groups.map { g in max(g.filter { $0 <= 4 }.map { weight[$0] }.reduce(0, +), g.filter { $0 > 4 }.map { weight[$0] }.reduce(0, +)) }.reduce(0, +)
            let groupGreen = wTotal > 0 ? available * max(wA, wB) / wTotal : 0
            for ring in [ringA, ringB] {
                let w = ring.map { weight[$0] }.reduce(0, +)
                for p in ring where plan.timing[p] != nil {
                    plan.timing[p]!.split = max(plan.timing[p]!.minGreen, w > 0 ? groupGreen * weight[p] / w : 0)
                }
            }
        }
    }
}
