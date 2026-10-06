//
//  ScenarioNetworks.swift
//  TrafficEngine
//
//  Road layouts of the shared scenarios (tests, CLI and the app's starter
//  maps all use these). Each layout is built for a driving side; layouts
//  with one-way carriageways (highways) place them on the correct side.
//

public enum ScenarioKind: String, CaseIterable, Codable, Sendable {
    case corridor, signalGrid, suburb, downtown, highwayTown, roundaboutVillage, stressCity, emptyLand

    public var displayName: String {
        switch self {
        case .corridor: return "Corridor"
        case .signalGrid: return "Signal Grid"
        case .suburb: return "Suburb"
        case .downtown: return "Downtown"
        case .highwayTown: return "Highway Town"
        case .roundaboutVillage: return "Roundabout Village"
        case .stressCity: return "Stress City"
        case .emptyLand: return "Empty Land"
        }
    }
}

/// A map: authored network + terrain. Buildings are added by `ScenarioFactory`.
public struct CityMap {
    public var network: RoadNetwork
    public var terrain: Terrain
    /// Areas where the scenario places homes / jobs (used by ScenarioFactory).
    public var residentialAreas: [[Vector2]] = []
    public var commercialAreas: [[Vector2]] = []
    public var industrialAreas: [[Vector2]] = []
    public var policeSites: [Vector2] = []
}

public enum ScenarioNetworks {

    public static func make(_ kind: ScenarioKind, side: DrivingSide, seed: UInt64 = 1) -> CityMap {
        switch kind {
        case .corridor: return corridor(side: side)
        case .signalGrid: return signalGrid(side: side)
        case .suburb: return suburb(side: side)
        case .downtown: return downtown(side: side)
        case .highwayTown: return highwayTown(side: side)
        case .roundaboutVillage: return roundaboutVillage(side: side)
        case .stressCity: return stressCity(side: side)
        case .emptyLand: return emptyLand(side: side, seed: seed)
        }
    }

    // MARK: - Empty land (sandbox)

    /// Seeded terrain — a river that needs bridging, a lake, a park — with a
    /// single regional road ending in a cul-de-sac. Traffic appears only once
    /// the player builds homes and workplaces.
    static func emptyLand(side: DrivingSide, seed: UInt64) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        var r = SeededRandom(seed: seed &* 0x9E3779B97F4A7C15 &+ 77)
        net.batch {
            let w = regional(net, Vector2(-900, 0))
            let end = net.addNode(at: Vector2(-520, 0))
            net.addRoad(from: w, to: end, roadClass: .arterial, lanes: 1)
        }
        map.terrain.minCorner = Vector2(-900, -600)
        map.terrain.maxCorner = Vector2(900, 600)
        let riverX = r.nextDouble(in: 250..<420)
        map.terrain.features.append(Terrain.river(from: Vector2(riverX, -700), to: Vector2(riverX + r.nextDouble(in: -80..<80), 700),
                                                  width: 60, wiggle: 30, seed: seed &+ 3))
        map.terrain.features.append(Terrain.blob(center: Vector2(r.nextDouble(in: -300..<0), r.nextDouble(in: 300..<420)),
                                                 radius: 80, kind: .water, seed: seed &+ 5))
        map.terrain.features.append(Terrain.blob(center: Vector2(r.nextDouble(in: -250..<50), r.nextDouble(in: (-420)..<(-300))),
                                                 radius: 90, kind: .park, seed: seed &+ 7))
        map.terrain.labels.append(MapLabel(text: "GREEN VALLEY", position: Vector2(-150, 150)))
        map.terrain.labels.append(MapLabel(text: "WILLOW RIVER", position: Vector2(riverX + 40, -420), isWater: true))
        return map
    }

    // MARK: - Helpers

    static func regional(_ net: RoadNetwork, _ p: Vector2) -> NodeID {
        let n = net.addNode(at: p)
        net.updateNode(n) { $0.isRegionalConnection = true }
        return n
    }

    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Vector2] {
        [Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]
    }

    /// A grid of nodes; returns nodes[row][col].
    @discardableResult
    static func grid(_ net: RoadNetwork, origin: Vector2, cols: Int, rows: Int, dx: Double, dy: Double,
                     horizontal: (Int) -> (RoadClass, Int, Bool, Bool)?,   // row → (class, lanes, oneWay, eastbound)
                     vertical: (Int) -> (RoadClass, Int, Bool, Bool)?)      // col → (class, lanes, oneWay, northbound)
    -> [[NodeID]] {
        var nodes: [[NodeID]] = []
        for r in 0..<rows {
            var row: [NodeID] = []
            for c in 0..<cols { row.append(net.addNode(at: origin + Vector2(Double(c) * dx, Double(r) * dy))) }
            nodes.append(row)
        }
        for r in 0..<rows {
            guard let (cls, lanes, oneWay, east) = horizontal(r) else { continue }
            for c in 0..<(cols - 1) {
                let (a, b) = east ? (nodes[r][c], nodes[r][c + 1]) : (nodes[r][c + 1], nodes[r][c])
                net.addRoad(from: a, to: b, roadClass: cls, lanes: lanes, oneWay: oneWay)
            }
        }
        for c in 0..<cols {
            guard let (cls, lanes, oneWay, north) = vertical(c) else { continue }
            for r in 0..<(rows - 1) {
                let (a, b) = north ? (nodes[r][c], nodes[r + 1][c]) : (nodes[r + 1][c], nodes[r][c])
                net.addRoad(from: a, to: b, roadClass: cls, lanes: lanes, oneWay: oneWay)
            }
        }
        return nodes
    }

    /// Add a stub to a regional connection from `node` in direction `dir`.
    static func stub(_ net: RoadNetwork, from node: NodeID, dir: Vector2, length: Double, cls: RoadClass, lanes: Int? = nil) {
        guard let p = net.node(node)?.position else { return }
        let r = regional(net, p + dir * length)
        net.addRoad(from: node, to: r, roadClass: cls, lanes: lanes)
    }

    /// A winding cul-de-sac street from `node`.
    static func culDeSac(_ net: RoadNetwork, from node: NodeID, dir: Vector2, length: Double, bend: Double) -> NodeID {
        guard let p = net.node(node)?.position else { return node }
        let n = dir.perpendicular
        let end = net.addNode(at: p + dir * length + n * bend * 0.5)
        net.addRoad(from: node, to: end, roadClass: .local,
                    shape: [p + dir * (length * 0.35) + n * bend, p + dir * (length * 0.7) + n * (bend * 0.2)])
        return end
    }

    // MARK: - 1. Corridor

    static func corridor(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        net.batch {
            let w = regional(net, Vector2(-800, 0))
            let e = regional(net, Vector2(800, 0))
            net.addRoad(from: w, to: e, roadClass: .arterial,
                        shape: [Vector2(-400, 0), Vector2(-150, 25), Vector2(150, -25), Vector2(400, 0)], lanes: 2)
        }
        map.terrain.minCorner = Vector2(-850, -300)
        map.terrain.maxCorner = Vector2(850, 300)
        map.residentialAreas = [rect(-700, 25, 700, 90)]
        map.commercialAreas = [rect(-700, -90, 700, -25)]
        map.policeSites = [Vector2(-20, 45)]
        return map
    }

    // MARK: - 2. Signal grid

    static func signalGrid(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        let cols = 5, rows = 4, dx = 240.0, dy = 210.0
        net.batch {
            let g = grid(net, origin: .zero, cols: cols, rows: rows, dx: dx, dy: dy,
                         horizontal: { _ in (.arterial, 2, false, true) },
                         vertical: { _ in (.arterial, 2, false, true) })
            for r in 0..<rows {
                stub(net, from: g[r][0], dir: Vector2(-1, 0), length: 180, cls: .arterial)
                stub(net, from: g[r][cols - 1], dir: Vector2(1, 0), length: 180, cls: .arterial)
            }
            for c in 0..<cols {
                stub(net, from: g[0][c], dir: Vector2(0, -1), length: 180, cls: .arterial)
                stub(net, from: g[rows - 1][c], dir: Vector2(0, 1), length: 180, cls: .arterial)
            }
        }
        map.terrain.minCorner = Vector2(-260, -260)
        map.terrain.maxCorner = Vector2(Double(cols - 1) * dx + 260, Double(rows - 1) * dy + 260)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let x0 = Double(c) * dx + 40, y0 = Double(r) * dy + 40
                let block = rect(x0, y0, x0 + dx - 80, y0 + dy - 80)
                if (r + c) % 3 == 0 { map.commercialAreas.append(block) } else { map.residentialAreas.append(block) }
            }
        }
        map.policeSites = [Vector2(2 * dx - 60, dy + 40)]
        return map
    }

    // MARK: - 3. Suburb

    static func suburb(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        net.batch {
            // A gently curving collector with junctions every ~250 m.
            let xs: [Double] = [-750, -500, -250, 0, 250, 500, 750]
            var spine: [NodeID] = []
            for x in xs {
                let p = Vector2(x, 45 * DMath.sin(x / 260))
                spine.append(x == xs.first || x == xs.last ? regional(net, p) : net.addNode(at: p))
            }
            for i in 0..<(spine.count - 1) {
                let a = net.node(spine[i])!.position, b = net.node(spine[i + 1])!.position
                let mid = (a + b) * 0.5 + Vector2(0, 12 * DMath.sin(a.x / 90))
                net.addRoad(from: spine[i], to: spine[i + 1], roadClass: .collector, shape: [mid])
            }
            // A second collector crossing north–south (all-way stop where they meet).
            let northEnd = regional(net, Vector2(20, 650))
            let southEnd = regional(net, Vector2(-20, -650))
            net.addRoad(from: spine[3], to: northEnd, roadClass: .collector, shape: [Vector2(40, 250), Vector2(-10, 450)])
            net.addRoad(from: spine[3], to: southEnd, roadClass: .collector, shape: [Vector2(-40, -250), Vector2(10, -450)])
            // Winding local streets with cul-de-sacs, some looped together.
            for (k, i) in [1, 2, 4, 5].enumerated() {
                let up = culDeSac(net, from: spine[i], dir: Vector2(0, 1), length: 300, bend: k % 2 == 0 ? 50 : -50)
                let down = culDeSac(net, from: spine[i], dir: Vector2(0, -1), length: 280, bend: k % 2 == 0 ? -40 : 40)
                _ = (up, down)
            }
            // A crescent connecting two locals north of the collector.
            if let a = net.allRoads.first(where: { $0.a == spine[1] && $0.roadClass == .local }),
               let b = net.allRoads.first(where: { $0.a == spine[2] && $0.roadClass == .local }) {
                let na = net.splitRoad(a.id, near: (net.node(spine[1])!.position + Vector2(0, 160)))
                let nb = net.splitRoad(b.id, near: (net.node(spine[2])!.position + Vector2(0, 160)))
                if let na, let nb {
                    let pa = net.node(na)!.position, pb = net.node(nb)!.position
                    net.addRoad(from: na, to: nb, roadClass: .local, shape: [(pa + pb) * 0.5 + Vector2(0, 40)])
                }
            }
        }
        map.terrain.minCorner = Vector2(-800, -700)
        map.terrain.maxCorner = Vector2(800, 700)
        map.terrain.features.append(Terrain.blob(center: Vector2(380, 330), radius: 90, kind: .park, seed: 7))
        map.terrain.features.append(Terrain.blob(center: Vector2(-380, -380), radius: 70, kind: .water, seed: 11))
        map.terrain.labels.append(MapLabel(text: "MAPLE HEIGHTS", position: Vector2(-500, 420)))
        map.residentialAreas = [rect(-650, 30, -100, 420), rect(100, 30, 650, 420), rect(-650, -420, -100, -30), rect(100, -420, 650, -30)]
        map.commercialAreas = [rect(-120, -90, 140, -40)]
        map.policeSites = [Vector2(120, 70)]
        return map
    }

    // MARK: - 4. Downtown

    static func downtown(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        let cols = 6, rows = 5, dx = 140.0, dy = 125.0
        net.batch {
            let g = grid(net, origin: .zero, cols: cols, rows: rows, dx: dx, dy: dy,
                         horizontal: { r in (.arterial, 2, true, r % 2 == 0) },
                         vertical: { c in (.arterial, 3, true, c % 2 == 0) })
            for r in 0..<rows {
                // One-way streets: the stub direction must continue the street.
                let east = r % 2 == 0
                let w = regional(net, Vector2(-160, Double(r) * dy))
                let e = regional(net, Vector2(Double(cols - 1) * dx + 160, Double(r) * dy))
                if east {
                    net.addRoad(from: w, to: g[r][0], roadClass: .arterial, lanes: 2, oneWay: true)
                    net.addRoad(from: g[r][cols - 1], to: e, roadClass: .arterial, lanes: 2, oneWay: true)
                } else {
                    net.addRoad(from: e, to: g[r][cols - 1], roadClass: .arterial, lanes: 2, oneWay: true)
                    net.addRoad(from: g[r][0], to: w, roadClass: .arterial, lanes: 2, oneWay: true)
                }
            }
            for c in 0..<cols {
                let north = c % 2 == 0
                let s = regional(net, Vector2(Double(c) * dx, -160))
                let n = regional(net, Vector2(Double(c) * dx, Double(rows - 1) * dy + 160))
                if north {
                    net.addRoad(from: s, to: g[0][c], roadClass: .arterial, lanes: 3, oneWay: true)
                    net.addRoad(from: g[rows - 1][c], to: n, roadClass: .arterial, lanes: 3, oneWay: true)
                } else {
                    net.addRoad(from: n, to: g[rows - 1][c], roadClass: .arterial, lanes: 3, oneWay: true)
                    net.addRoad(from: g[0][c], to: s, roadClass: .arterial, lanes: 3, oneWay: true)
                }
            }
            // Coordinate the signals along each avenue.
            for c in 0..<cols {
                for r in 0..<rows {
                    net.updateNode(g[r][c]) { n in
                        n.control.signal.coordinationGroup = 1
                    }
                }
            }
        }
        map.terrain.minCorner = Vector2(-200, -200)
        map.terrain.maxCorner = Vector2(Double(cols - 1) * dx + 200, Double(rows - 1) * dy + 200)
        map.terrain.labels.append(MapLabel(text: "DOWNTOWN", position: Vector2(dx * 2, dy * 4.4)))
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let x0 = Double(c) * dx + 22, y0 = Double(r) * dy + 22
                let block = rect(x0, y0, x0 + dx - 44, y0 + dy - 44)
                if r == 0 || c == cols - 2 { map.residentialAreas.append(block) } else { map.commercialAreas.append(block) }
            }
        }
        map.policeSites = [Vector2(dx * 2 + 30, dy * 2 + 30)]
        return map
    }

    // MARK: - 5. Highway town

    static func highwayTown(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        let sgn: Double = side == .right ? -1 : 1     // eastbound carriageway is on this side
        net.batch {
            // Dual carriageway highway, elevated through the interchange.
            let ebW = regional(net, Vector2(-400, sgn * 14)), ebDiv = net.addNode(at: Vector2(700, sgn * 14))
            let ebMer = net.addNode(at: Vector2(1300, sgn * 14)), ebE = regional(net, Vector2(2700, sgn * 14))
            let wbE = regional(net, Vector2(2700, -sgn * 14)), wbDiv = net.addNode(at: Vector2(1300, -sgn * 14))
            let wbMer = net.addNode(at: Vector2(700, -sgn * 14)), wbW = regional(net, Vector2(-400, -sgn * 14))
            for n in [ebDiv, ebMer, wbDiv, wbMer] { net.updateNode(n) { $0.level = 1 } }
            var hw: [RoadID] = []
            for (a, b) in [(ebW, ebDiv), (ebDiv, ebMer), (ebMer, ebE), (wbE, wbDiv), (wbDiv, wbMer), (wbMer, wbW)] {
                if let r = net.addRoad(from: a, to: b, roadClass: .highway, lanes: 3, oneWay: true) { hw.append(r) }
            }
            for r in hw { net.updateRoad(r) { $0.level = 1 } }
            // North–south arterial under the highway with diamond ramp terminals.
            let artS = regional(net, Vector2(1000, -760)), artN = regional(net, Vector2(1000, 760))
            let tEB = net.addNode(at: Vector2(1000, sgn * 95)), tWB = net.addNode(at: Vector2(1000, -sgn * 95))
            let townS1 = net.addNode(at: Vector2(1000, sgn * 330)), townS2 = net.addNode(at: Vector2(1000, sgn * 540))
            let townN1 = net.addNode(at: Vector2(1000, -sgn * 330))
            let (south, north) = sgn < 0 ? (artS, artN) : (artN, artS)
            net.addRoad(from: south, to: townS2, roadClass: .arterial)
            net.addRoad(from: townS2, to: townS1, roadClass: .arterial)
            net.addRoad(from: townS1, to: tEB, roadClass: .arterial)
            net.addRoad(from: tEB, to: tWB, roadClass: .arterial)
            net.addRoad(from: tWB, to: townN1, roadClass: .arterial)
            net.addRoad(from: townN1, to: north, roadClass: .arterial)
            // Ramps.
            net.addRoad(from: ebDiv, to: tEB, roadClass: .ramp, shape: [Vector2(880, sgn * 40)])
            net.addRoad(from: tEB, to: ebMer, roadClass: .ramp, shape: [Vector2(1120, sgn * 40)])
            net.addRoad(from: wbDiv, to: tWB, roadClass: .ramp, shape: [Vector2(1120, -sgn * 40)])
            net.addRoad(from: tWB, to: wbMer, roadClass: .ramp, shape: [Vector2(880, -sgn * 40)])
            // Town streets west of the arterial, and a bridge east over the river.
            let w1 = net.addNode(at: Vector2(780, sgn * 330)), w2 = net.addNode(at: Vector2(560, sgn * 330))
            let w3 = net.addNode(at: Vector2(780, sgn * 540)), w4 = net.addNode(at: Vector2(560, sgn * 540))
            net.addRoad(from: townS1, to: w1, roadClass: .local)
            net.addRoad(from: w1, to: w2, roadClass: .local)
            net.addRoad(from: townS2, to: w3, roadClass: .local)
            net.addRoad(from: w3, to: w4, roadClass: .local)
            net.addRoad(from: w1, to: w3, roadClass: .local)
            net.addRoad(from: w2, to: w4, roadClass: .local)
            let e1 = net.addNode(at: Vector2(1650, sgn * 330)), e2 = net.addNode(at: Vector2(2350, sgn * 330))
            let eEnd = regional(net, Vector2(2700, sgn * 330))
            net.addRoad(from: townS1, to: e1, roadClass: .collector)
            if let bridge = net.addRoad(from: e1, to: e2, roadClass: .collector) { net.updateRoad(bridge) { $0.isBridge = true } }
            net.addRoad(from: e2, to: eEnd, roadClass: .collector)
            let n1 = net.addNode(at: Vector2(1220, -sgn * 330)), n2 = net.addNode(at: Vector2(1220, -sgn * 520))
            net.addRoad(from: townN1, to: n1, roadClass: .local)
            net.addRoad(from: n1, to: n2, roadClass: .local)
            _ = culDeSac(net, from: n1, dir: Vector2(1, 0), length: 200, bend: 30)
            // Highway crossing the river.
            for r in hw {
                guard let road = net.road(r), let a = net.node(road.a), let b = net.node(road.b) else { continue }
                if min(a.position.x, b.position.x) < 2000 && max(a.position.x, b.position.x) > 2000 {
                    net.updateRoad(r) { $0.isBridge = true }
                }
            }
        }
        map.terrain.minCorner = Vector2(-450, -800)
        map.terrain.maxCorner = Vector2(2750, 800)
        map.terrain.features.append(Terrain.river(from: Vector2(2000, -900), to: Vector2(2000, 900), width: 110, wiggle: 40, seed: 3))
        map.terrain.labels.append(MapLabel(text: "SILVER RIVER", position: Vector2(2060, 520), isWater: true))
        map.residentialAreas = [rect(560, sgn * 360, 960, sgn * 600).map { $0 }, rect(1060, -sgn * 360, 1500, -sgn * 600)]
        map.commercialAreas = [rect(1060, sgn * 140, 1500, sgn * 300)]
        map.industrialAreas = [rect(2400, sgn * 360, 2650, sgn * 600)]
        map.policeSites = [Vector2(1060, sgn * 360)]
        return map
    }

    // MARK: - 6. Roundabout village

    static func roundaboutVillage(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        var hubs: [NodeID] = []
        net.batch {
            let r1 = net.addNode(at: Vector2(0, 0))
            let r2 = net.addNode(at: Vector2(420, 60))
            let r3 = net.addNode(at: Vector2(160, -380))
            hubs = [r1, r2, r3]
            net.addRoad(from: r1, to: r2, roadClass: .collector, shape: [Vector2(210, 60)])
            net.addRoad(from: r1, to: r3, roadClass: .collector, shape: [Vector2(40, -200)])
            net.addRoad(from: r2, to: r3, roadClass: .collector, shape: [Vector2(330, -190)])
            stub(net, from: r1, dir: Vector2(-1, 0.1).normalized, length: 420, cls: .collector)
            stub(net, from: r1, dir: Vector2(-0.1, 1).normalized, length: 380, cls: .collector)
            stub(net, from: r2, dir: Vector2(1, 0.15).normalized, length: 380, cls: .collector)
            stub(net, from: r3, dir: Vector2(0.2, -1).normalized, length: 330, cls: .collector)
            stub(net, from: r3, dir: Vector2(1, -0.4).normalized, length: 420, cls: .collector)
            // Village lanes off the collectors with yield junctions.
            if let link = net.allRoads.first(where: { $0.a == r1 && $0.b == r2 }) {
                if let j = net.splitRoad(link.id, near: Vector2(210, 60)) {
                    net.updateNode(j) { $0.control.requested = .yield }
                    _ = culDeSac(net, from: j, dir: Vector2(0, 1), length: 220, bend: 40)
                    _ = culDeSac(net, from: j, dir: Vector2(0, -1), length: 180, bend: -30)
                }
            }
            if let link = net.allRoads.first(where: { $0.a == r1 && $0.b == r3 }) {
                if let j = net.splitRoad(link.id, near: Vector2(40, -200)) {
                    net.updateNode(j) { $0.control.requested = .yield }
                    _ = culDeSac(net, from: j, dir: Vector2(-1, 0), length: 220, bend: 30)
                }
            }
        }
        for h in hubs { net.makeRoundabout(at: h) }
        map.terrain.minCorner = Vector2(-480, -760)
        map.terrain.maxCorner = Vector2(840, 420)
        map.terrain.features.append(Terrain.blob(center: Vector2(230, -150), radius: 80, kind: .park, seed: 5))
        map.terrain.labels.append(MapLabel(text: "OLD MILL", position: Vector2(-300, 200)))
        map.residentialAreas = [rect(-380, 40, -60, 300), rect(240, 120, 600, 300), rect(-260, -420, 80, -120)]
        map.commercialAreas = [rect(260, -120, 520, 20)]
        map.policeSites = [Vector2(110, 40)]
        return map
    }

    // MARK: - 7. Stress city

    static func stressCity(side: DrivingSide) -> CityMap {
        let net = RoadNetwork(side: side)
        var map = CityMap(network: net, terrain: Terrain())
        let sgn: Double = side == .right ? -1 : 1
        net.batch {
            // Arterial grid 7 × 6 with collectors between.
            let cols = 7, rows = 6, dx = 300.0, dy = 260.0
            let g = grid(net, origin: .zero, cols: cols, rows: rows, dx: dx, dy: dy,
                         horizontal: { r in r % 2 == 0 ? (.arterial, 2, false, true) : (.collector, 1, false, true) },
                         vertical: { c in c % 2 == 0 ? (.arterial, 2, false, true) : (.collector, 1, false, true) })
            for r in 0..<rows where r % 2 == 0 {
                stub(net, from: g[r][0], dir: Vector2(-1, 0), length: 200, cls: .arterial)
                stub(net, from: g[r][cols - 1], dir: Vector2(1, 0), length: 200, cls: .arterial)
            }
            for c in 0..<cols where c % 2 == 0 {
                stub(net, from: g[rows - 1][c], dir: Vector2(0, 1), length: 200, cls: .arterial)
            }
            // Local streets inside every block (a cross of locals per block).
            for r in 0..<(rows - 1) {
                for c in 0..<(cols - 1) {
                    let x = Double(c) * dx + dx / 2, y = Double(r) * dy + dy / 2
                    let centre = net.addNode(at: Vector2(x, y))
                    if let e = net.allRoads.first(where: { $0.a == g[r][c] && $0.b == g[r][c + 1] }),
                       let s = net.splitRoad(e.id, near: Vector2(x, Double(r) * dy)) {
                        net.addRoad(from: s, to: centre, roadClass: .local)
                    }
                    if let e = net.allRoads.first(where: { $0.a == g[r][c] && $0.b == g[r + 1][c] }),
                       let s = net.splitRoad(e.id, near: Vector2(Double(c) * dx, y)) {
                        net.addRoad(from: s, to: centre, roadClass: .local)
                    }
                }
            }
            // Highway along the south edge with two diamond interchanges.
            let yHW = -220.0
            let xs: [Double] = [-500, 380, 820, 1380, 1820, 2300]
            var eb: [NodeID] = [], wb: [NodeID] = []
            for (i, x) in xs.enumerated() {
                let last = i == 0 || i == xs.count - 1
                eb.append(last ? regional(net, Vector2(x, yHW + sgn * 14)) : net.addNode(at: Vector2(x, yHW + sgn * 14)))
                wb.append(last ? regional(net, Vector2(x, yHW - sgn * 14)) : net.addNode(at: Vector2(x, yHW - sgn * 14)))
            }
            for i in 0..<(xs.count - 1) {
                if let r = net.addRoad(from: eb[i], to: eb[i + 1], roadClass: .highway, lanes: 3, oneWay: true) { net.updateRoad(r) { $0.level = 1 } }
                if let r = net.addRoad(from: wb[i + 1], to: wb[i], roadClass: .highway, lanes: 3, oneWay: true) { net.updateRoad(r) { $0.level = 1 } }
            }
            for n in eb + wb { net.updateNode(n) { if !$0.isRegionalConnection { $0.level = 1 } } }
            // Interchanges at x = 600 (col 2) and x = 1600 (between cols 5/6).
            for (k, xi) in [(1, 600.0), (3, 1600.0)] {
                // Arterial spur from the grid south to the highway, passing under it.
                let top = net.addNode(at: Vector2(xi, -40))
                let tN = net.addNode(at: Vector2(xi, yHW - sgn * 95))
                let tS = net.addNode(at: Vector2(xi, yHW + sgn * 95))
                let bottom = regional(net, Vector2(xi, yHW - 500))
                if let gridNode = net.allNodes.first(where: { $0.position.distance(to: Vector2(xi, 0)) < 1 })?.id {
                    net.addRoad(from: gridNode, to: top, roadClass: .arterial)
                } else if let e = net.allRoads.first(where: {
                    guard let a = net.node($0.a)?.position, let b = net.node($0.b)?.position else { return false }
                    return abs(a.y) < 1 && abs(b.y) < 1 && min(a.x, b.x) < xi && max(a.x, b.x) > xi
                }), let s = net.splitRoad(e.id, near: Vector2(xi, 0)) {
                    net.addRoad(from: s, to: top, roadClass: .arterial)
                }
                let (north, south) = sgn < 0 ? (tN, tS) : (tS, tN)
                net.addRoad(from: top, to: north, roadClass: .arterial)
                net.addRoad(from: north, to: south, roadClass: .arterial)
                net.addRoad(from: south, to: bottom, roadClass: .arterial)
                let tEB = sgn < 0 ? tS : tN, tWB = sgn < 0 ? tN : tS
                net.addRoad(from: eb[k], to: tEB, roadClass: .ramp, shape: [Vector2((net.node(eb[k])!.position.x + xi) / 2, yHW + sgn * 45)])
                net.addRoad(from: tEB, to: eb[k + 1], roadClass: .ramp, shape: [Vector2((net.node(eb[k + 1])!.position.x + xi) / 2, yHW + sgn * 45)])
                net.addRoad(from: wb[k + 1], to: tWB, roadClass: .ramp, shape: [Vector2((net.node(wb[k + 1])!.position.x + xi) / 2, yHW - sgn * 45)])
                net.addRoad(from: tWB, to: wb[k], roadClass: .ramp, shape: [Vector2((net.node(wb[k])!.position.x + xi) / 2, yHW - sgn * 45)])
            }
        }
        map.terrain.minCorner = Vector2(-550, -760)
        map.terrain.maxCorner = Vector2(2350, 1550)
        map.terrain.features.append(Terrain.blob(center: Vector2(150, 1450), radius: 110, kind: .park, seed: 13))
        for r in 0..<5 {
            for c in 0..<6 {
                let x0 = Double(c) * 300 + 25, y0 = Double(r) * 260 + 25
                let quads = [rect(x0, y0, x0 + 115, y0 + 100), rect(x0 + 160, y0, x0 + 275, y0 + 100),
                             rect(x0, y0 + 145, x0 + 115, y0 + 235), rect(x0 + 160, y0 + 145, x0 + 275, y0 + 235)]
                if (r == 2 || r == 3) && (c == 2 || c == 3) {
                    map.commercialAreas.append(contentsOf: quads)
                } else if r == 0 && c >= 4 {
                    map.industrialAreas.append(contentsOf: quads)
                } else {
                    map.residentialAreas.append(contentsOf: quads)
                    if (r + c) % 4 == 0 { map.commercialAreas.append(quads[0]) }
                }
            }
        }
        map.policeSites = [Vector2(470, 400), Vector2(1370, 900)]
        return map
    }
}
