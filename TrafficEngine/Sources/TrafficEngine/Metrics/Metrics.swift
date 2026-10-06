//
//  Metrics.swift
//  TrafficEngine
//
//  Traffic measurements, all from the agents (congestion is emergent):
//
//   per segment  — flow q [veh/h] from a virtual mid-block detector, density
//                  k [veh/km/lane], space-mean speed, travel-time index
//                  (free-flow speed / mean speed)
//   per junction — average control delay and HCM Level of Service (A–F),
//                  maximum queue length
//   network      — VKT, VHT, average trip time, % of vehicle-time congested,
//                  completed trips per hour, police response time (mean, p90)
//
//  Smoothed edge travel times feed route choice, so this state is Codable
//  and saved with the city.
//

public struct EdgeMetrics: Codable, Sendable, Equatable {
    public var vehicles: Int = 0
    /// Space-mean speed [m/s] (speed limit when empty).
    public var meanSpeed: Double = 0
    /// Density [veh/km/lane].
    public var density: Double = 0
    /// Flow [veh/h] over the detector window.
    public var flow: Double = 0
    /// Travel-time index ≥ 1.
    public var travelTimeIndex: Double = 1
    /// Smoothed travel time [s].
    public var travelTime: Double = 0
    public var speedLimit: Double = 0

    /// 0 = free flow, 1 = jammed (from the travel-time index).
    public var congestion: Double {
        guard vehicles > 0 else { return 0 }
        return (1 - 1 / max(travelTimeIndex, 1)).clamped(to: 0...1)
    }
}

public enum LevelOfService: String, Codable, Sendable, CaseIterable {
    case A, B, C, D, E, F

    /// HCM control-delay thresholds [s/veh].
    public static func from(delay: Double, signalised: Bool) -> LevelOfService {
        let t: [Double] = signalised ? [10, 20, 35, 55, 80] : [10, 15, 25, 35, 50]
        for (k, limit) in t.enumerated() where delay <= limit { return allCases[k] }
        return .F
    }
}

public struct JunctionMetrics: Codable, Sendable, Equatable {
    public var served: Int = 0
    public var delaySum: Double = 0
    public var averageDelay: Double { served > 0 ? delaySum / Double(served) : 0 }
    public var maxQueue: Double = 0
    public var queue: Double = 0
    public var los: LevelOfService = .A
}

public struct MetricsSample: Codable, Sendable, Equatable {
    public var time: Double
    public var clock: Double
    public var activeVehicles: Int
    public var averageSpeed: Double     // m/s
    public var tripsPerHour: Double
    public var averageTripTime: Double  // s
    public var congestedShare: Double   // 0…1
    public var responseTime: Double     // s (mean of recent)
    public var departuresPerHour: Double
}

public struct AggregateMetrics: Codable, Sendable, Equatable {
    public var spawned: Int = 0
    public var completedTrips: Int = 0
    public var tripTimeSum: Double = 0
    public var vkt: Double = 0             // vehicle-km travelled
    public var vht: Double = 0             // vehicle-hours travelled
    public var congestedVehicleSeconds: Double = 0
    public var missedTurns: Int = 0
    public var reroutes: Int = 0
    public var forcedStops: Int = 0
    public var activeVehicles: Int = 0
    public var averageSpeed: Double = 0
    public var responseTimes: [Double] = []
    public var averageTripTime: Double { completedTrips > 0 ? tripTimeSum / Double(completedTrips) : 0 }
    public var congestedShare: Double { vht > 0 ? congestedVehicleSeconds / (vht * 3600) : 0 }
    public var meanResponseTime: Double { responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count) }
    public var p90ResponseTime: Double {
        guard !responseTimes.isEmpty else { return 0 }
        let s = responseTimes.sorted()
        return s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.up)) - 1)]
    }
}

public struct MetricsState: Codable, Sendable, Equatable {
    public var aggregate = AggregateMetrics()
    public var edges: [EdgeMetrics] = []
    public var junctions: [JunctionMetrics] = []
    public var history: [MetricsSample] = []
    /// Detector crossings per edge in the current window.
    var crossings: [Int] = []
    var window: Double = 0
    var sampleTimer: Double = 0
    var completedInWindow: [Double] = []    // completion times, last hour (sim)
    var departuresInWindow: [Double] = []
    /// Departures per clock hour of the week (index 0…167) for the demand curve.
    public var departuresByClockHour: [Int] = Array(repeating: 0, count: 168)
    public var completionsByClockHour: [Int] = Array(repeating: 0, count: 168)
}

public final class MetricsCollector {
    public internal(set) var state = MetricsState()
    public var historyCapacity = 2000
    /// Sampling interval for the history [s of sim time].
    public var sampleInterval = 10.0

    public init() {}

    public var aggregate: AggregateMetrics { state.aggregate }
    public var history: [MetricsSample] { state.history }

    public func edge(_ e: EdgeID) -> EdgeMetrics? { e.raw < state.edges.count ? state.edges[e.raw] : nil }
    public func junction(_ n: NodeID) -> JunctionMetrics? { n.raw < state.junctions.count ? state.junctions[n.raw] : nil }

    func recordSpawn() { state.aggregate.spawned += 1 }
    func recordMissedTurn() { state.aggregate.missedTurns += 1 }
    func recordReroute() { state.aggregate.reroutes += 1 }
    func recordForcedStop() { state.aggregate.forcedStops += 1 }

    func recordDeparture(time: Double, clockHourOfWeek: Int) {
        state.departuresInWindow.append(time)
        if clockHourOfWeek >= 0 && clockHourOfWeek < 168 { state.departuresByClockHour[clockHourOfWeek] += 1 }
    }

    func recordCompletion(tripTime: Double, distance: Double, delay: Double) {
        state.aggregate.completedTrips += 1
        state.aggregate.tripTimeSum += tripTime
        state.completedInWindow.append(lastTime)
    }

    func recordCompletion(clockHourOfWeek: Int) {
        if clockHourOfWeek >= 0 && clockHourOfWeek < 168 { state.completionsByClockHour[clockHourOfWeek] += 1 }
    }

    func recordResponse(_ seconds: Double) {
        state.aggregate.responseTimes.append(seconds)
        if state.aggregate.responseTimes.count > 500 { state.aggregate.responseTimes.removeFirst() }
    }

    func recordJunctionEntry(node: NodeID, delay: Double) {
        // Per-vehicle control delay is recorded by the simulation via recordControlDelay.
    }

    func recordControlDelay(node: NodeID, delay: Double, signalised: Bool) {
        guard node.raw < state.junctions.count else { return }
        state.junctions[node.raw].served += 1
        state.junctions[node.raw].delaySum += max(delay, 0)
        state.junctions[node.raw].los = LevelOfService.from(delay: state.junctions[node.raw].averageDelay, signalised: signalised)
    }

    var lastTime = 0.0

    func resize(edges: Int, nodes: Int) {
        if state.edges.count != edges {
            state.edges = Array(repeating: EdgeMetrics(), count: edges)
            state.crossings = Array(repeating: 0, count: edges)
        }
        if state.junctions.count != nodes { state.junctions = Array(repeating: JunctionMetrics(), count: nodes) }
    }
}

extension Simulation {

    func updateMetrics(dt: Double) {
        let m = metrics
        m.lastTime = time
        m.resize(edges: network.edgeSlotCount, nodes: network.nodeCount)
        var active = 0
        var speedSum = 0.0
        var congestedCount = 0
        for v in vehicles where v.mode != .finished && v.mode != .waitingToEnter {
            active += 1
            speedSum += v.speed
            m.state.aggregate.vkt += v.speed * dt / 1000
            if v.speed < 0.5 * speedLimit(of: v.track) { congestedCount += 1 }
            // Mid-block detector crossing.
            if case .edge(let e) = v.track, let edge = network.edge(e) {
                let mid = edge.length / 2
                let prev = v.s - v.speed * dt
                if prev < mid && v.s >= mid { m.state.crossings[e.raw] += 1 }
            }
        }
        m.state.aggregate.vht += Double(active) * dt / 3600
        m.state.aggregate.congestedVehicleSeconds += Double(congestedCount) * dt
        m.state.aggregate.activeVehicles = active
        m.state.aggregate.averageSpeed = active > 0 ? speedSum / Double(active) : 0

        m.state.window += dt
        m.state.sampleTimer += dt
        // Segment and junction measurements every 5 s.
        if m.state.window >= 5 {
            let window = m.state.window
            m.state.window = 0
            var count = Array(repeating: 0, count: network.edgeSlotCount)
            var sum = Array(repeating: 0.0, count: network.edgeSlotCount)
            for v in vehicles where v.mode == .driving {
                if case .edge(let e) = v.track { count[e.raw] += 1; sum[e.raw] += v.speed }
            }
            for e in network.allEdges {
                var em = m.state.edges[e.id.raw]
                em.speedLimit = e.speedLimit
                em.vehicles = count[e.id.raw]
                em.meanSpeed = count[e.id.raw] > 0 ? sum[e.id.raw] / Double(count[e.id.raw]) : e.speedLimit
                em.density = Double(count[e.id.raw]) / max(e.length / 1000, 1e-3) / Double(max(e.travelLanes, 1))
                // Exponentially weighted flow (≈ 1 min memory).
                let q = Double(m.state.crossings[e.id.raw]) / window * 3600
                em.flow = em.flow * 0.92 + q * 0.08
                m.state.crossings[e.id.raw] = 0
                em.travelTimeIndex = e.speedLimit / max(em.meanSpeed, 0.5)
                let freeTime = e.length / max(e.speedLimit, 1)
                let measured = count[e.id.raw] > 0 ? e.length / max(em.meanSpeed, 1.0) : freeTime
                em.travelTime = em.travelTime == 0 ? freeTime : em.travelTime * 0.8 + measured * 0.2
                m.state.edges[e.id.raw] = em
                if e.id.raw < router.edgeTime.count { router.edgeTime[e.id.raw] = em.travelTime }
            }
            // Queues: contiguous stopped vehicles back from each stop line.
            for n in network.allNodes {
                var q = 0.0
                for e in network.incoming(n.id) {
                    guard let edge = network.edge(e) else { continue }
                    for l in edge.lanes {
                        var back = 0.0
                        for o in laneOcc[laneKey(e, l.index)].reversed() where o.s <= edge.length {
                            let w = vehicles[Int(o.index)]
                            if w.speed > 1.0 || w.lane != l.index { break }
                            back = edge.length - (o.s - w.length)
                        }
                        q = max(q, back)
                    }
                }
                m.state.junctions[n.id.raw].queue = q
                m.state.junctions[n.id.raw].maxQueue = max(m.state.junctions[n.id.raw].maxQueue, q)
            }
        }
        if m.state.sampleTimer >= m.sampleInterval {
            m.state.sampleTimer = 0
            m.state.completedInWindow.removeAll { $0 < time - 3600 }
            m.state.departuresInWindow.removeAll { $0 < time - 3600 }
            let span = min(time, 3600)
            let sample = MetricsSample(
                time: time, clock: clock, activeVehicles: active,
                averageSpeed: m.state.aggregate.averageSpeed,
                tripsPerHour: span > 0 ? Double(m.state.completedInWindow.count) / span * 3600 : 0,
                averageTripTime: m.state.aggregate.averageTripTime,
                congestedShare: active > 0 ? Double(congestedCount) / Double(active) : 0,
                responseTime: m.state.aggregate.meanResponseTime,
                departuresPerHour: span > 0 ? Double(m.state.departuresInWindow.count) / span * 3600 : 0)
            m.state.history.append(sample)
            if m.state.history.count > m.historyCapacity { m.state.history.removeFirst(m.state.history.count - m.historyCapacity) }
        }
    }

    var clockHourOfWeek: Int { Int(clock / 3600) % 168 }
}
