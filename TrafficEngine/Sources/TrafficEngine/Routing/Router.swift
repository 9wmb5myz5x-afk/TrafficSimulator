//
//  Router.swift
//  TrafficEngine
//
//  A* over the directed edge graph. Edge cost = live travel time (smoothed
//  measurements from the metrics stage, falling back to free-flow time) plus
//  a turn penalty at each junction.
//
//  Stochastic route choice: each trip perturbs edge costs with a per-trip,
//  per-edge Gumbel term, c'_e = c_e · exp(σ·ε_e). Choosing the cheapest
//  route under i.i.d. Gumbel noise is the random-utility form of a logit
//  model, so equivalent routes share load instead of everyone piling onto a
//  single shortest path. The perturbation is a pure hash of (trip seed,
//  edge), so it is deterministic and needs no stored state.
//

public final class Router {
    public unowned let network: RoadNetwork
    /// Current travel-time estimate per edge raw id [s].
    public var edgeTime: [Double] = []
    /// Turn penalties [s].
    public var acrossTurnPenalty = 7.0
    public var kerbTurnPenalty = 3.0
    public var uTurnPenalty = 45.0
    /// Logit dispersion σ of the multiplicative perturbation.
    public var dispersion = 0.12

    private var g: [Double] = []
    private var stamp: [Int] = []
    private var cameFrom: [Int] = []
    private var generation = 0
    private var maxSpeed = 30.0
    private var builtVersion = -1

    public init(network: RoadNetwork) {
        self.network = network
        refresh()
    }

    /// Re-size buffers and reset costs to free flow after a network change.
    public func refresh() {
        let n = network.edgeSlotCount
        edgeTime = (0..<n).map { i in
            guard let e = network.edge(EdgeID(i)) else { return .infinity }
            return e.length / max(e.speedLimit, 1)
        }
        g = Array(repeating: .infinity, count: n)
        stamp = Array(repeating: -1, count: n)
        cameFrom = Array(repeating: -1, count: n)
        maxSpeed = max(network.allEdges.map { $0.speedLimit }.max() ?? 30, 1)
        builtVersion = network.version
    }

    public func freeFlowTime(_ e: EdgeID) -> Double {
        guard let edge = network.edge(e) else { return .infinity }
        return edge.length / max(edge.speedLimit, 1)
    }

    func turnPenalty(_ from: EdgeID, _ to: EdgeID) -> Double {
        guard let t = network.turn(from: from, to: to) else { return 0 }
        switch t {
        case .straight: return 0
        case .uTurn: return uTurnPenalty
        default: return t.isAcross(network.side) ? acrossTurnPenalty : kerbTurnPenalty
        }
    }

    /// Least-cost edge sequence from `start` (inclusive) to `goal` (inclusive).
    /// - Parameters:
    ///   - firstSteps: if given, the second edge must be one of these (a vehicle
    ///     that can no longer change lanes is limited to its lane's exits).
    ///   - seed: per-trip perturbation seed (nil = deterministic shortest path).
    ///   - avoid: edges that must not be used (e.g. blocked).
    public func route(from start: EdgeID, to goal: EdgeID, firstSteps: [EdgeID]? = nil,
                      seed: UInt64? = nil, avoid: Set<EdgeID> = []) -> [EdgeID]? {
        if builtVersion != network.version || g.count != network.edgeSlotCount { refresh() }
        guard network.edge(start) != nil, let goalEdge = network.edge(goal) else { return nil }
        if start == goal {
            // Already on the goal edge. With `firstSteps` the vehicle must leave
            // it first (its destination is behind it, or it missed a turn):
            // go round the block and come back.
            guard let fs = firstSteps else { return [start] }
            var best: (path: [EdgeID], cost: Double)?
            for f in network.successors(of: start) where fs.contains(f) && !avoid.contains(f) {
                guard let r = route(from: f, to: goal, seed: seed, avoid: avoid) else { continue }
                let c = self.cost(of: r[...]) + turnPenalty(start, f)
                if best == nil || c < best!.cost { best = ([start] + r, c) }
            }
            return best?.path
        }
        let target = network.node(goalEdge.to)?.position ?? goalEdge.reference.end
        generation += 1
        let gen = generation

        func heuristic(_ e: Int) -> Double {
            guard let edge = network.edges[e] else { return 0 }
            return edge.reference.end.distance(to: target) / (maxSpeed * 1.3)
        }
        func cost(_ e: Int) -> Double {
            var c = edgeTime[e]
            if let seed {
                let u = hashUnit(seed, UInt64(e))
                let gumbel = -DMath.log(-DMath.log(max(u, 1e-12)))
                c *= DMath.exp(dispersion * (gumbel - 0.5772))
            }
            return c
        }

        struct Item { let f: Double; let edge: Int; let seq: Int }
        var open = PriorityQueue<Item> { $0.f != $1.f ? $0.f < $1.f : $0.seq < $1.seq }
        var seq = 0
        g[start.raw] = 0; stamp[start.raw] = gen; cameFrom[start.raw] = -1
        open.push(Item(f: heuristic(start.raw), edge: start.raw, seq: seq))
        var closed = Set<Int>()

        while let cur = open.pop() {
            let e = cur.edge
            if closed.contains(e) { continue }
            closed.insert(e)
            if e == goal.raw {
                var path: [EdgeID] = []
                var x = e
                while x >= 0 { path.append(EdgeID(x)); x = cameFrom[x] }
                return path.reversed()
            }
            var succ = network.successors(of: EdgeID(e))
            if e == start.raw, let fs = firstSteps { succ = succ.filter { fs.contains($0) } }
            for nxt in succ where !avoid.contains(nxt) {
                let n = nxt.raw
                // The goal edge only needs to be reached up to the destination
                // point; charge it in full anyway (it keeps A* consistent).
                let tentative = g[e] + cost(n) + turnPenalty(EdgeID(e), nxt)
                if stamp[n] != gen || tentative < g[n] {
                    stamp[n] = gen
                    g[n] = tentative
                    cameFrom[n] = e
                    seq += 1
                    open.push(Item(f: tentative + heuristic(n), edge: n, seq: seq))
                }
            }
        }
        return nil
    }

    /// Travel time of an edge sequence under current costs (no perturbation).
    public func cost(of path: ArraySlice<EdgeID>) -> Double {
        var c = 0.0
        var prev: EdgeID?
        for e in path {
            c += e.raw < edgeTime.count ? edgeTime[e.raw] : .infinity
            if let p = prev { c += turnPenalty(p, e) }
            prev = e
        }
        return c
    }
}
