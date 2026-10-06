//
//  EditFuzzer.swift
//  TrafficEngine
//
//  Random player edits for fuzzing (§10.4): roads drawn, removed, restyled;
//  junction controls overridden; junctions moved and turned into
//  roundabouts; buildings placed and bulldozed; undo and redo — all while
//  the simulation runs. Rejected edits (validation) are part of the test.
//

public struct EditFuzzer {
    var rng: SeededRandom
    public private(set) var applied = 0
    public private(set) var rejected = 0

    public init(seed: UInt64) { rng = SeededRandom(seed: seed &* 0xA24BAED4963EE407 &+ 99) }

    /// Make one random edit; returns what was attempted.
    @discardableResult
    public mutating func edit(_ editor: Editor) -> String {
        let sim = editor.sim
        let net = sim.network
        let roads = net.allRoads.filter { $0.roadClass != .highway && $0.roadClass != .ramp }
        let junctions = net.allNodes.filter { !$0.isRegionalConnection && net.degree(of: $0.id) >= 3 }
        let movable = net.allNodes.filter { !$0.isRegionalConnection && net.degree(of: $0.id) >= 1 }
        let roll = rng.nextUnit()
        var what = ""
        do {
            switch roll {
            case ..<0.22:
                // A new road from somewhere on the network.
                guard let start = randomRoadPoint(roads, net) else { what = "draw (no roads)"; break }
                let a = rng.nextUnit() * 2 * 3.141592653589793
                let len = 60 + rng.nextUnit() * 240
                let dir = Vector2(DMath.cos(a), DMath.sin(a))
                let mid = start + dir * (len / 2) + dir.perpendicular * (rng.nextUnit() * 40 - 20)
                let end = start + dir * len
                let cls: RoadClass = [.local, .local, .collector, .arterial][rng.nextInt(4)]
                let lanes = cls == .arterial ? 1 + rng.nextInt(2) : 1
                what = "draw \(cls.rawValue)×\(lanes)"
                try editor.drawRoad([start, mid, end], roadClass: cls, lanes: lanes, oneWay: rng.nextUnit() < 0.12)
            case ..<0.30:
                guard let r = pick(roads) else { break }
                what = "remove \(r.id)"
                try editor.removeRoad(r.id)
            case ..<0.38:
                guard let r = pick(roads) else { break }
                let cls: RoadClass = [.local, .collector, .arterial][rng.nextInt(3)]
                what = "restyle \(r.id) → \(cls.rawValue)"
                try editor.changeRoad(r.id, roadClass: cls, lanes: cls == .arterial ? 2 : 1)
            case ..<0.46:
                guard let n = pick(junctions) else { break }
                let c: ControlType = [.auto, .signal, .allWayStop, .twoWayStop, .yield, .uncontrolled][rng.nextInt(6)]
                what = "control \(n.id) → \(c.rawValue)"
                try editor.setControl(n.id, to: c, locked: c != .auto)
            case ..<0.50:
                guard let n = pick(junctions) else { break }
                what = "roundabout \(n.id)"
                try editor.makeRoundabout(at: n.id)
            case ..<0.56:
                guard let n = pick(movable) else { break }
                let to = n.position + Vector2(rng.nextUnit() * 30 - 15, rng.nextUnit() * 30 - 15)
                what = "move \(n.id)"
                try editor.moveJunction(n.id, to: to)
            case ..<0.60:
                guard let r = pick(roads) else { break }
                what = "pockets \(r.id)"
                try editor.toggleTurnPockets(r.id)
            case ..<0.74:
                guard let p = randomRoadPoint(roads, net) else { break }
                let kinds: [BuildingKind] = [.house, .house, .townhouse, .apartment, .shop, .office, .factory, .policeStation, .school]
                let k = kinds[rng.nextInt(kinds.count)]
                let a = rng.nextUnit() * 2 * 3.141592653589793
                what = "place \(k.rawValue)"
                if case .failure(let e) = editor.placeBuilding(k, near: p + Vector2(DMath.cos(a), DMath.sin(a)) * 22, search: 12) { throw e }
            case ..<0.84:
                guard let b = pick(sim.city.buildings) else { break }
                what = "bulldoze \(b.id)"
                try editor.removeBuilding(b.id)
            case ..<0.94:
                what = "undo"
                editor.undo()
            default:
                what = "redo"
                editor.redo()
            }
            applied += 1
        } catch {
            rejected += 1
            what += " (rejected)"
        }
        return what
    }

    private mutating func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[rng.nextInt(a.count)] }

    private mutating func randomRoadPoint(_ roads: [Road], _ net: RoadNetwork) -> Vector2? {
        guard let r = pick(roads), let line = net.centreline(of: r.id) else { return nil }
        return line.point(at: rng.nextUnit() * line.length)
    }
}
