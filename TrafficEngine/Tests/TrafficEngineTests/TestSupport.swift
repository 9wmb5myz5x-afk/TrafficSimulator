import XCTest
@testable import TrafficEngine

/// Small builders for scripted micro-scenarios.
enum Micro {

    /// A straight one-way road a → b of `length` with `lanes` lanes.
    static func straight(_ side: DrivingSide, length: Double = 2000, lanes: Int = 2, cls: RoadClass = .highway,
                         limit: Double? = nil) -> (Simulation, EdgeID) {
        let net = RoadNetwork(side: side)
        let a = net.addNode(at: .zero)
        let b = net.addNode(at: Vector2(length, 0))
        net.updateNode(a) { $0.isRegionalConnection = true }
        net.updateNode(b) { $0.isRegionalConnection = true }
        let r = net.addRoad(from: a, to: b, roadClass: cls, lanes: lanes, oneWay: true)!
        if let limit { net.updateRoad(r) { $0.speedLimitOverride = limit } }
        var cfg = SimulationConfig()
        cfg.seed = 7
        let sim = Simulation(network: net, config: cfg)
        sim.setExternalRate(perEntryPerHour: 0)
        return (sim, EdgeID(road: r, forward: true))
    }

    /// A driver with a fixed desired speed factor and default behaviour.
    static func driver(speedFactor: Double, politeness: Double = 0.35, reaction: Double = 0.4) -> Driver {
        var d = Driver()
        d.speedFactor = speedFactor
        d.mobil.politeness = politeness
        d.reactionTime = reaction
        d.signalTime = 2.0
        d.gapFactor = 1.0
        return d
    }

    /// A four-arm junction: approaches 400 m long, with optional control.
    static func crossroads(_ side: DrivingSide, cls: RoadClass = .arterial, control: ControlType = .auto,
                           armLength: Double = 400, seed: UInt64 = 1) -> (Simulation, NodeID, [NodeID]) {
        let net = RoadNetwork(side: side)
        var c = NodeID(0)
        var arms: [NodeID] = []
        net.batch {
            c = net.addNode(at: .zero)
            for d in [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)] {
                let n = net.addNode(at: d * armLength)
                net.updateNode(n) { $0.isRegionalConnection = true }
                net.addRoad(from: n, to: c, roadClass: cls)
                arms.append(n)
            }
            if control != .auto { net.updateNode(c) { $0.control.requested = control } }
        }
        var cfg = SimulationConfig()
        cfg.seed = seed
        let sim = Simulation(network: net, config: cfg)
        sim.setExternalRate(perEntryPerHour: 0)
        return (sim, c, arms)
    }

    /// The edge from `arm` into the centre, and from the centre out to `arm`.
    static func edges(_ sim: Simulation, arm: NodeID, centre: NodeID) -> (inbound: EdgeID, outbound: EdgeID) {
        let inb = sim.network.incoming(centre).first { sim.network.edge($0)?.from == arm }!
        let outb = sim.network.outgoing(centre).first { sim.network.edge($0)?.to == arm }!
        return (inb, outb)
    }
}

extension Simulation {
    /// Run with invariant checking and return the checker.
    @discardableResult
    func runChecked(seconds: Double, every: (() -> Void)? = nil) -> InvariantChecker {
        let checker = invariantChecker ?? InvariantChecker()
        invariantChecker = checker
        let n = Int((seconds / config.dt).rounded())
        for _ in 0..<n {
            step()
            every?()
        }
        return checker
    }
}
