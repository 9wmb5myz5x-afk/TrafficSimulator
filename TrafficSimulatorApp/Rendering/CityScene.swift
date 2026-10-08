//
//  CityScene.swift
//  TrafficSimulator
//
//  SpriteKit renderer — "soft cartographic minimalism". It reads only the
//  `SnapshotBuffer` (never the engine):
//   • static layers (terrain, roads, markings, buildings) rebuilt when the
//     network or the buildings change
//   • vehicles as pooled sprites from one texture atlas, interpolated between
//     simulation snapshots, with brake lights, blinkers, light bars and
//     headlights at night
//   • overlays (congestion, police coverage), the selection highlight and
//     incident markers
//   • a camera with pan / pinch-zoom; lane markings appear when zoomed in
//   • day / dusk / night palette blended through the day (never truly dark)
//
//  Lighting: a single light from the top-left, so building side bands and
//  shadows are offset towards the bottom-right in world space regardless of
//  each building's rotation.
//

import SpriteKit
import UIKit
import TrafficEngine

final class CityScene: SKScene {

    weak var controller: GameController?
    /// Called with a world point when the map is tapped.
    var onTap: ((Vector2, Double) -> Void)?
    /// One-finger drags with a drawing tool: the stroke in world metres, and
    /// the pick radius at the current zoom.
    var onDraw: (([Vector2], Double) -> Void)?
    /// Respect Reduce Motion (no pulsing markers, no pop animations).
    var reduceMotion = false

    private let world = SKNode()
    private let terrainLayer = SKNode()
    private let roadEdgeLayer = SKNode()
    private let roadFillLayer = SKNode()
    private let overlayLayer = SKNode()
    private let markingLayer = SKNode()
    private let shadowLayer = SKNode()
    private let buildingLayer = SKNode()
    private let highlightLayer = SKNode()
    private let vehicleLayer = SKNode()
    private let lightLayer = SKNode()
    private let signalLayer = SKNode()
    private let markerLayer = SKNode()
    private let labelLayer = SKNode()
    let ghostLayer = SKNode()
    let cam = SKCameraNode()
    private let nightTint = SKSpriteNode(color: .black, size: CGSize(width: 10, height: 10))

    private var networkVersion = -1
    private var cityVersion = -1
    var worldBounds: (min: Vector2, max: Vector2) = (Vector2(-200, -200), Vector2(200, 200))
    private var vehicleNodes: [Int32: VehicleNode] = [:]
    private var lastVehicleTime: CFTimeInterval = 0
    /// Scenery cars on the roads beyond the map.
    private struct Ghost {
        let node: SKSpriteNode
        let road: Int
        var s: Double
        let lateral: Double
        let speed: Double
        let inbound: Bool
    }
    private var ghosts: [Ghost] = []
    private var countryRoads: [Outskirts.Road] = []
    /// Per country road: when cars recently came in from it (wall time), and when the next scenery car sets off.
    private var arrivals: [[CFTimeInterval]] = []
    private var nextInbound: [CFTimeInterval] = []
    private var signalNodes: [SKSpriteNode] = []
    private var markerNodes: [SKSpriteNode] = []
    private var roadFillPaths: [Int: CGPath] = [:]            // road raw id → its surface outline (for overlays)
    private var geometryVersion = -1
    /// Countryside roads and town roads live in separate containers within
    /// the same layers, so either can be rebuilt alone.
    private let countryEdges = SKNode(), countryFills = SKNode(), countryMarks = SKNode()
    private let townEdges = SKNode(), townFills = SKNode(), townMarks = SKNode(), junctionMarks = SKNode()
    private var overlayShapes: [Int: SKShapeNode] = [:]
    private var shownOverlay: (kind: MapOverlay, values: [Int: Double])?
    private var highlightKey: Int = 0
    private var didFit = false
    private var phase: Double = 0

    // Camera state (see CityScene+Input.swift).
    var camScale: CGFloat = 1
    var pinchStart: CGFloat = 1
    /// The world point held under the fingers during a pinch.
    var pinchAnchor: CGPoint?
    /// Glide after a flick, in view points per second.
    var panVelocity = CGPoint.zero
    /// An animated camera move (double tap, recentre).
    var camAnimation: CameraAnimation?
    var lastFrameTime: TimeInterval = 0
    /// The stroke being drawn (nil while panning the camera).
    var stroke: [Vector2]?
    var strokeNode: SKShapeNode?
    /// The engine's preview of the road being drawn.
    var previewNode: SKNode?
    var shownPreview: RoadPreview?

    override func didMove(to view: SKView) {
        scaleMode = .resizeFill
        backgroundColor = Theme.ui(.land)
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        let layers = [terrainLayer, roadEdgeLayer, roadFillLayer, overlayLayer, markingLayer, shadowLayer,
                      buildingLayer, highlightLayer, vehicleLayer, lightLayer, signalLayer, markerLayer, labelLayer, ghostLayer]
        for (i, layer) in layers.enumerated() {
            layer.zPosition = CGFloat(i) * 10
            world.addChild(layer)
        }
        roadEdgeLayer.addChild(countryEdges); roadEdgeLayer.addChild(townEdges)
        roadFillLayer.addChild(countryFills); roadFillLayer.addChild(townFills)
        markingLayer.addChild(countryMarks); markingLayer.addChild(townMarks); markingLayer.addChild(junctionMarks)
        lightLayer.alpha = 0
        addChild(world)
        addChild(cam)
        camera = cam
        nightTint.zPosition = 1000
        nightTint.alpha = 0
        cam.addChild(nightTint)
        installGestures(on: view)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        nightTint.size = CGSize(width: size.width * 4, height: size.height * 4)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = lastFrameTime == 0 ? 0 : min(currentTime - lastFrameTime, 0.1)
        lastFrameTime = currentTime
        stepCamera(dt: dt)
        updateRoadPreview()
        guard let controller else { return }
        if let g = controller.buffer.latestGeometry(), g.networkVersion != networkVersion || g.cityVersion != cityVersion {
            let networkChanged = g.networkVersion != networkVersion
            let shapeChanged = g.geometryVersion != geometryVersion
            let cityChanged = g.cityVersion != cityVersion
            networkVersion = g.networkVersion
            geometryVersion = g.geometryVersion
            cityVersion = g.cityVersion
            // Only what changed: a junction control switch redraws the stop
            // and give-way lines alone; a new building redraws buildings alone.
            if shapeChanged { rebuildCountry(g); rebuildRoads(g); rebuildMarkings(g.roads.flatMap(\.markings), arrows: g.roads.flatMap(\.arrows), into: townMarks) }
            if networkChanged { rebuildMarkings(g.junctions.flatMap(\.markings), arrows: [], into: junctionMarks) }
            if shapeChanged || cityChanged { rebuildBuildings(g, animate: didFit && !reduceMotion) }
            // The navigable region: the whole map, not just where the roads are.
            worldBounds = (Vector2(min(g.bounds.min.x, g.terrain.minCorner.x), min(g.bounds.min.y, g.terrain.minCorner.y)),
                           Vector2(max(g.bounds.max.x, g.terrain.maxCorner.x), max(g.bounds.max.y, g.terrain.maxCorner.y)))
            if !didFit { fitCamera(roads: g.bounds); didFit = true }
        }
        let now = CACurrentMediaTime()
        guard let frame = controller.buffer.interpolated(at: now) else { return }
        phase = Theme.phase(dayFraction: frame.dayFraction)
        updateVehicles(frame.vehicles, time: now)
        updateSignals(frame.signals)
        updateMarkers(frame.incidents, time: now)
        updateOverlay(controller.buffer.latestOverlay())
        updateHighlight(controller.buffer.latestHighlight())
        applyLighting()
        // Lane markings and arrows only when zoomed in.
        markingLayer.alpha = camScale < 0.45 ? 1 : (camScale < 0.7 ? (0.7 - camScale) / 0.25 : 0)
        labelLayer.alpha = camScale > 0.35 ? 1 : 0.4
    }

    // MARK: - Static geometry

    func cg(_ v: Vector2) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    func path(_ pts: [Vector2], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: cg(first))
        for q in pts.dropFirst() { p.addLine(to: cg(q)) }
        if closed { p.closeSubpath() }
        return p
    }

    private func shape(_ pts: [Vector2], fill: UIColor?, stroke: UIColor? = nil, width: CGFloat = 0, closed: Bool = true) -> SKShapeNode {
        let n = SKShapeNode(path: path(pts, closed: closed))
        n.fillColor = fill ?? .clear
        n.strokeColor = stroke ?? .clear
        n.lineWidth = width
        n.lineJoin = .round
        n.lineCap = .round
        n.isAntialiased = true
        return n
    }

    /// The countryside, terrain (water, parks, beaches) and map labels: they
    /// only change with the shape of the network (the regional roads).
    private func rebuildCountry(_ g: StaticGeometry) {
        for l in [terrainLayer, labelLayer, countryEdges, countryFills, countryMarks] { l.removeAllChildren() }
        let p = phase
        drawCountryside(g.outskirts, phase: p)
        // Terrain.
        for f in g.terrain.features {
            switch f.kind {
            case .water:
                let crop = SKCropNode()
                crop.maskNode = shape(f.polygon, fill: .white)
                let water = shape(f.polygon, fill: Theme.ui(.water, phase: p))
                crop.addChild(water)
                // A subtle grid on the water.
                let xs = f.polygon.map { $0.x }, ys = f.polygon.map { $0.y }
                let grid = CGMutablePath()
                var x = (xs.min() ?? 0).rounded(.down)
                while x < (xs.max() ?? 0) { grid.move(to: CGPoint(x: x, y: ys.min() ?? 0)); grid.addLine(to: CGPoint(x: x, y: ys.max() ?? 0)); x += 14 }
                var y = (ys.min() ?? 0).rounded(.down)
                while y < (ys.max() ?? 0) { grid.move(to: CGPoint(x: xs.min() ?? 0, y: y)); grid.addLine(to: CGPoint(x: xs.max() ?? 0, y: y)); y += 14 }
                let gn = SKShapeNode(path: grid)
                gn.strokeColor = Theme.ui(.waterGrid, phase: p)
                gn.lineWidth = 0.6
                crop.addChild(gn)
                terrainLayer.addChild(crop)
            case .park:
                terrainLayer.addChild(shape(f.polygon, fill: Theme.ui(.park, phase: p)))
                addTrees(in: f.polygon)
            case .beach:
                terrainLayer.addChild(shape(f.polygon, fill: Theme.ui(.beach, phase: p)))
            }
        }
        for label in g.terrain.labels {
            let n = SKLabelNode(text: label.text.uppercased())
            n.fontName = Typography.mapLabel(size: 14).fontName
            n.fontSize = 14
            n.fontColor = Theme.ui(label.isWater ? .waterGrid : .roadEdge).withAlphaComponent(0.8)
            n.position = cg(label.position)
            n.verticalAlignmentMode = .center
            n.attributedText = NSAttributedString(string: label.text.uppercased(), attributes: [
                .kern: 6, .font: Typography.mapLabel(size: 14),
                .foregroundColor: Theme.ui(label.isWater ? .waterGrid : .roadEdge).withAlphaComponent(0.85),
            ])
            labelLayer.addChild(n)
        }
    }

    /// Road and junction surfaces. Each surface stays its own shape:
    /// SpriteKit fills a compound path even-odd, so overlapping surfaces
    /// merged into one would show holes. The edges beneath them (always
    /// covered where they overlap), medians and islands are merged.
    private func rebuildRoads(_ g: StaticGeometry) {
        for l in [townEdges, townFills] { l.removeAllChildren() }
        overlayLayer.removeAllChildren()
        overlayShapes.removeAll()
        shownOverlay = nil
        roadFillPaths.removeAll()
        let p = phase
        let edge = Theme.ui(.roadEdge, phase: p), fill = Theme.ui(.road, phase: p)
        func add(_ poly: [Vector2], to path: CGMutablePath) {
            guard poly.count >= 3 else { return }
            path.addLines(between: poly.map { cg($0) })
            path.closeSubpath()
        }
        func node(_ path: CGPath, fill: UIColor?, stroke: UIColor? = nil, width: CGFloat = 0, z: CGFloat) -> SKShapeNode {
            let n = SKShapeNode(path: path)
            n.fillColor = fill ?? .clear
            n.strokeColor = stroke ?? .clear
            n.lineWidth = width
            n.lineJoin = .round
            n.zPosition = z
            return n
        }
        let edges = CGMutablePath(), medians = CGMutablePath(), islands = CGMutablePath()
        for r in g.roads {
            add(r.surface.polygon, to: edges)
            let own = CGMutablePath()
            add(r.surface.polygon, to: own)
            roadFillPaths[r.surface.road.raw] = own
            let level = CGFloat(r.surface.level)
            if r.surface.isBridge || r.surface.level > 0 {
                // Raised roads cast a soft shadow.
                let sh = CGMutablePath()
                add(r.surface.polygon.map { $0 + Vector2(1.6, -1.6) }, to: sh)
                townFills.addChild(node(sh, fill: Theme.ui(.shadow).withAlphaComponent(0.16), z: level - 0.5))
            }
            townFills.addChild(node(own, fill: r.surface.isBridge ? Theme.ui(.bridge, phase: p) : fill, z: level))
            for m in r.medians { add(m, to: medians) }
        }
        for j in g.junctions where j.polygon.count >= 3 {
            add(j.polygon, to: edges)
            let path = CGMutablePath()
            add(j.polygon, to: path)
            townFills.addChild(node(path, fill: fill, z: CGFloat(j.level)))
        }
        for rb in g.roundabouts {
            add(rb.outer, to: edges)
            let path = CGMutablePath()
            add(rb.outer, to: path)
            townFills.addChild(node(path, fill: fill, z: 0))
            add(rb.island, to: islands)
        }
        townEdges.addChild(node(edges, fill: edge, stroke: edge, width: 1.2, z: 0))
        if !islands.isEmpty { townFills.addChild(node(islands, fill: Theme.ui(.median, phase: p), z: 2)) }
        if !medians.isEmpty { townFills.addChild(node(medians, fill: Theme.ui(.median, phase: p), z: 2)) }
    }

    /// Lane markings, stop and give-way lines and arrows, merged by style
    /// into a few shapes in `container`.
    private func rebuildMarkings(_ markings: [Marking], arrows laneArrows: [LaneArrow], into container: SKNode) {
        container.removeAllChildren()
        var groups: [String: (path: CGMutablePath, color: UIColor, width: CGFloat, cap: CGLineCap)] = [:]
        func add(_ m: Marking) {
            guard m.points.count >= 2 else { return }
            let color: UIColor, colorKey: String
            var dash: [CGFloat]?
            switch m.kind {
            case .laneDash: color = Theme.ui(.laneMarking); colorKey = "l"; dash = [3, 6]
            case .laneSolid, .edgeLine, .stopBar: color = Theme.ui(.laneMarking); colorKey = "l"
            case .centreDouble: color = Theme.ui(.centerLine); colorKey = "c"
            case .yieldLine: color = Theme.ui(.laneMarking); colorKey = "l"; dash = [0.6, 0.6]
            }
            let width = CGFloat(m.kind == .centreDouble ? m.width * 3 : m.width * 1.4)
            let key = "\(colorKey)-\(Int(width * 100))"
            let entry = groups[key] ?? (CGMutablePath(), color, width, .butt)
            var p: CGPath = path(m.points, closed: false)
            if let d = dash { p = p.copy(dashingWithPhase: 0, lengths: d) }
            entry.path.addPath(p)
            groups[key] = entry
        }
        markings.forEach(add)
        // Arrows: stems with a short head, bent towards the turn, all in one shape.
        let arrows = CGMutablePath()
        for a in laneArrows where !a.movements.isEmpty {
            let t = CGAffineTransform(translationX: a.position.x, y: a.position.y).rotated(by: CGFloat(a.heading))
            for mv in a.movements {
                let bend: CGFloat
                switch mv {
                case .straight: bend = 0
                case .left: bend = 1
                case .right: bend = -1
                case .uTurn: bend = 1.6
                }
                arrows.move(to: CGPoint(x: -2.2, y: 0), transform: t)
                arrows.addLine(to: CGPoint(x: 0.6, y: 0), transform: t)
                arrows.addLine(to: CGPoint(x: 1.6, y: bend * 0.9), transform: t)
            }
        }
        if !arrows.isEmpty { groups["arrows"] = (arrows, Theme.ui(.laneMarking), 0.28, .round) }
        for (_, gr) in groups {
            let n = SKShapeNode(path: gr.path)
            n.strokeColor = gr.color
            n.fillColor = .clear
            n.lineWidth = gr.width
            n.lineCap = gr.cap
            container.addChild(n)
        }
    }

    private func withZ(_ n: SKNode, _ z: CGFloat) -> SKNode { n.zPosition = z; return n }

    // MARK: - Countryside

    /// Fields, woods and farms around the map, and the regional roads
    /// carrying on beyond its edge.
    private func drawCountryside(_ o: Outskirts, phase p: Double) {
        for g in ghosts { g.node.removeFromParent() }
        ghosts.removeAll()
        countryRoads = o.roads
        arrivals = Array(repeating: [], count: o.roads.count)
        nextInbound = Array(repeating: 0, count: o.roads.count)
        // One compound shape per kind of field.
        for kind in Outskirts.FieldKind.allCases {
            let path = CGMutablePath()
            for f in o.fields where f.kind == kind {
                path.addLines(between: f.polygon.map { cg($0) })
                path.closeSubpath()
            }
            let n = SKShapeNode(path: path)
            switch kind {
            case .pasture: n.fillColor = Theme.ui(.park, phase: p).withAlphaComponent(0.55)
            case .crop: n.fillColor = Theme.ui(.beach, phase: p).withAlphaComponent(0.85)
            case .stubble: n.fillColor = Theme.ui(.roadEdge, phase: p).withAlphaComponent(0.2)
            case .wood: n.fillColor = Theme.ui(.park, phase: p)
            }
            n.strokeColor = Theme.ui(.parkTree, phase: p).withAlphaComponent(0.35)
            n.lineWidth = 1.2
            n.zPosition = -1
            terrainLayer.addChild(n)
        }
        for f in o.fields where f.kind == .wood { addTrees(in: f.polygon, density: 1 / 700, cap: 24) }
        // Roads, drawn like the town's (edge, surface, centre line).
        let edge = Theme.ui(.roadEdge, phase: p), fill = Theme.ui(.road, phase: p)
        for r in o.roads {
            let path = CGMutablePath()
            path.addLines(between: r.line.points.map { cg($0) })
            func stroke(_ color: UIColor, _ width: Double, layer: SKNode, dashed: Bool = false) {
                let n = SKShapeNode(path: dashed ? path.copy(dashingWithPhase: 0, lengths: [3, 6]) : path)
                n.strokeColor = color
                n.lineWidth = CGFloat(width)
                n.lineCap = .butt
                n.lineJoin = .round
                n.fillColor = .clear
                layer.addChild(n)
            }
            stroke(edge, 2 * r.halfWidth + 1.2, layer: countryEdges)
            stroke(fill, 2 * r.halfWidth, layer: countryFills)
            if r.isHighway {
                stroke(Theme.ui(.median, phase: p), 1.6, layer: countryMarks)
            } else {
                stroke(Theme.ui(.centerLine, phase: p), 0.3, layer: countryMarks)
            }
            for k in 1..<max(r.lanesEachWay, 1) {
                let lat = Double(k) * 3.5 + (r.isHighway ? 0.8 : 0)
                for side in [1.0, -1.0] {
                    let lane = CGMutablePath()
                    lane.addLines(between: r.line.offset(by: side * lat).points.map { cg($0) })
                    let n = SKShapeNode(path: lane.copy(dashingWithPhase: 0, lengths: [3, 6]))
                    n.strokeColor = Theme.ui(.laneMarking, phase: p)
                    n.lineWidth = 0.25
                    countryMarks.addChild(n)
                }
            }
        }
        // Farmsteads.
        for f in o.farms {
            let roof = SKSpriteNode(texture: Textures.roof(.house))
            roof.size = CGSize(width: f.width, height: f.depth)
            roof.position = cg(f.center)
            roof.zRotation = CGFloat(f.rotation - .pi / 2)
            roof.zPosition = 5
            terrainLayer.addChild(roof)
        }
    }

    /// The country road a car at `p` is on, its arc length and lateral offset there.
    private func countryRoad(at p: CGPoint, reach: Double) -> (index: Int, s: Double, lateral: Double)? {
        let w = Vector2(Double(p.x), Double(p.y))
        for (k, r) in countryRoads.enumerated() where r.line.start.distance(to: w) < reach + 60 {
            let pr = r.line.project(w)
            if pr.distance < r.halfWidth + reach { return (k, pr.s, pr.lateral) }
        }
        return nil
    }

    /// A car that has just left the map at a regional connection carries on
    /// along the road beyond. Returns false if it didn't leave that way.
    private func driveOff(_ body: SKSpriteNode, velocity: CGVector) -> Bool {
        guard let (k, s, lat) = countryRoad(at: body.position, reach: 12) else { return false }
        let r = countryRoads[k]
        let speed = Double(hypot(velocity.dx, velocity.dy))
        let dir = r.line.tangent(at: s)
        guard speed > 1, (Double(velocity.dx) * dir.x + Double(velocity.dy) * dir.y) / speed > 0.5 else { return false }
        ghosts.append(Ghost(node: body, road: k, s: s, lateral: lat, speed: speed, inbound: false))
        return true
    }

    /// A car appeared: if it came in from a country road, remember (sets the
    /// rate of scenery traffic heading into town on that road).
    private func noteArrival(at p: CGPoint, time: CFTimeInterval) {
        guard let (k, s, _) = countryRoad(at: p, reach: 8), s < 30 else { return }
        arrivals[k].append(time)
    }

    private func updateGhosts(dt: Double, time: CFTimeInterval) {
        // Scenery cars heading into town at the rate cars have been arriving.
        let running = !(controller?.isPaused ?? true)
        let simSpeed = controller?.speed ?? 1
        if running, !countryRoads.isEmpty {
            for k in countryRoads.indices {
                arrivals[k].removeAll { time - $0 > 90 }
                guard !arrivals[k].isEmpty else { continue }
                if nextInbound[k] == 0 { nextInbound[k] = time + Double.random(in: 0...8) }
                guard time >= nextInbound[k] else { continue }
                let rate = Double(arrivals[k].count) / 90
                nextInbound[k] = time + min(30, max(0.6, -log(Double.random(in: 0.05...1)) / rate))
                let r = countryRoads[k]
                let side = controller?.setup.side ?? .right
                let lat = (r.halfWidth - (r.isHighway ? 2.6 : 1.8)) * (side == .right ? 1 : -1) * 0.75
                let body = SKSpriteNode(texture: Textures.vehicle(.car))
                body.size = CGSize(width: 4.5, height: 1.85)
                body.color = RGB(Theme.vehicleBodies[Int.random(in: 0..<Theme.vehicleBodies.count)]).ui
                body.colorBlendFactor = 1
                let top = SKSpriteNode(texture: Textures.vehicleTop(.car))
                top.size = body.size
                top.zPosition = 0.5
                body.addChild(top)
                body.alpha = 0
                vehicleLayer.addChild(body)
                let speed = (r.isHighway ? 29.0 : 22.0) * simSpeed * Double.random(in: 0.85...1.1)
                ghosts.append(Ghost(node: body, road: k, s: min(r.line.length, 1100), lateral: lat, speed: speed, inbound: true))
            }
        }
        guard dt > 0 else { return }
        var keep: [Ghost] = []
        for var g in ghosts {
            let r = countryRoads[g.road]
            if running { g.s += (g.inbound ? -1 : 1) * g.speed * dt }
            let done = g.inbound ? g.s <= 2 : g.s >= min(r.line.length, 1100)
            if done || g.s < 0 { g.node.removeFromParent(); continue }
            let pos = r.line.position(at: g.s, lateral: g.lateral)
            let t = r.line.tangent(at: g.s)
            g.node.position = cg(pos)
            g.node.zRotation = CGFloat((g.inbound ? -t : t).angle)
            // Fade with distance from town; an incoming car fades out as it reaches the edge.
            let far = (1 - (g.s - 600) / 500).clamped(to: 0...1)
            g.node.alpha = CGFloat(g.inbound ? min(far, ((g.s - 2) / 25).clamped(to: 0...1)) : far)
            keep.append(g)
        }
        ghosts = keep
    }

    /// Round trees scattered deterministically inside a park.
    private func addTrees(in polygon: [Vector2], density: Double = 1 / 260, cap: Int = 400) {
        let xs = polygon.map { $0.x }, ys = polygon.map { $0.y }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return }
        var k: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(x0 * 31 + y0 * 17))
        func rnd() -> Double { k ^= k << 13; k ^= k >> 7; k ^= k << 17; return Double(k % 10_000) / 10_000 }
        let count = Int(((x1 - x0) * (y1 - y0) * density).clamped(to: 3...Double(cap)))
        for _ in 0..<count {
            let p = Vector2(x0 + rnd() * (x1 - x0), y0 + rnd() * (y1 - y0))
            guard Geometry.pointInPolygon(p, polygon) else { continue }
            let t = SKSpriteNode(texture: Textures.tree)
            let s = 4.5 + rnd() * 3.5
            t.size = CGSize(width: s, height: s)
            t.position = cg(p)
            terrainLayer.addChild(t)
        }
    }

    // MARK: - Buildings

    private func rebuildBuildings(_ g: StaticGeometry, animate: Bool) {
        let previous = Set(buildingLayer.children.compactMap { $0.userData?["id"] as? Int })
        shadowLayer.removeAllChildren()
        buildingLayer.removeAllChildren()
        // Driveways: paved like the road, under the buildings' shadows. All of
        // them as a couple of compound strokes (thousands of separate shapes
        // would swamp the renderer).
        let paving = Theme.ui(.road, phase: phase), kerb = Theme.ui(.roadEdge, phase: phase)
        var byWidth: [Int: CGMutablePath] = [:]
        for d in g.driveways where d.points.count >= 2 {
            let key = Int((d.width * 2).rounded())
            let p = byWidth[key] ?? CGMutablePath()
            p.addLines(between: d.points.map { cg($0) })
            byWidth[key] = p
        }
        for (key, p) in byWidth {
            let w = CGFloat(key) / 2
            for (color, width, z) in [(kerb, w + 0.6, CGFloat(-3)), (paving, w, CGFloat(-2))] {
                let n = SKShapeNode(path: p)
                n.strokeColor = color
                n.lineWidth = width
                n.lineCap = .round
                n.lineJoin = .round
                n.fillColor = .clear
                n.zPosition = z
                shadowLayer.addChild(n)
            }
        }
        // Shadows and side bands are plain rotated sprites: SpriteKit draws
        // untextured sprites in one batch (one shape node per building is a
        // draw call each), and overlapping neighbours still darken as before.
        let shadowColor = Theme.ui(.shadow).withAlphaComponent(0.14)
        var sideColors: [BuildingKind: UIColor] = [:]
        for b in g.buildings {
            let size = CGSize(width: b.width, height: b.depth)
            let angle = CGFloat(b.rotation - .pi / 2)
            // Shadow and side band: offset towards the bottom-right in world space.
            let h = b.storeys
            let shadow = SKSpriteNode(color: shadowColor, size: size)
            shadow.position = cg(b.center + Vector2(1.2 + h * 1.1, -(1.2 + h * 1.1)))
            shadow.zRotation = angle
            shadowLayer.addChild(shadow)
            let sideColor = sideColors[b.kind] ?? Theme.ui(b.kind.tokens.side, phase: phase)
            sideColors[b.kind] = sideColor
            let side = SKSpriteNode(color: sideColor, size: size)
            side.position = cg(b.center + Vector2(0.5, -(0.9 + h * 0.25)))
            side.zRotation = angle
            side.zPosition = 0
            buildingLayer.addChild(side)
            // Roof tile (texture carries the pictogram), rotated with the building.
            let roof = SKSpriteNode(texture: Textures.roof(b.kind))
            roof.size = CGSize(width: b.width, height: b.depth)
            roof.position = cg(b.center)
            // Texture x runs along the frontage, y along the depth (towards the road).
            roof.zRotation = CGFloat(b.rotation - .pi / 2)
            roof.zPosition = 1
            roof.userData = ["id": b.id]
            buildingLayer.addChild(roof)
            if animate && !previous.contains(b.id) {
                // Pop in with a slight overshoot.
                roof.setScale(0.2)
                let up = SKAction.scale(to: 1.12, duration: 0.18)
                up.timingMode = .easeOut
                let settle = SKAction.scale(to: 1.0, duration: 0.12)
                settle.timingMode = .easeInEaseOut
                roof.run(SKAction.sequence([up, settle]))
            }
        }
    }

    // MARK: - Vehicles

    private final class VehicleNode {
        let body: SKSpriteNode
        var brake: [SKSpriteNode] = []
        var blinkL: [SKSpriteNode] = []
        var blinkR: [SKSpriteNode] = []
        var bar: [SKSpriteNode] = []
        var headlights: SKSpriteNode?
        /// Recent velocity [points per wall second], for cars driving off the map.
        var velocity = CGVector.zero
        var lastPosition: CGPoint?
        init(body: SKSpriteNode) { self.body = body }
    }

    private func lamp(_ color: UIColor, size: CGFloat, at p: CGPoint, in parent: SKNode) -> SKSpriteNode {
        let n = SKSpriteNode(texture: Textures.dot)
        n.color = color
        n.colorBlendFactor = 1
        n.size = CGSize(width: size, height: size)
        n.position = p
        n.zPosition = 1
        n.isHidden = true
        parent.addChild(n)
        return n
    }

    private func makeVehicle(_ p: VehiclePose) -> VehicleNode {
        let body = SKSpriteNode(texture: Textures.vehicle(p.cls))
        let len = CGFloat(p.length), wid = CGFloat(p.width)
        body.size = CGSize(width: len + 2 / Textures.ppm, height: wid + 2 / Textures.ppm)
        if p.cls == .police {
            body.colorBlendFactor = 0
        } else if p.cls == .bus {
            body.color = Theme.ui(.uiAccent)
            body.colorBlendFactor = 0.85
        } else {
            body.color = RGB(Theme.vehicleBodies[Int(p.color) % Theme.vehicleBodies.count]).ui
            body.colorBlendFactor = 1
        }
        // A tiny drop shadow of the whole outline.
        let shadow = SKSpriteNode(texture: Textures.vehicleShape(p.cls))
        shadow.color = .black
        shadow.colorBlendFactor = 1
        shadow.alpha = 0.18
        shadow.size = body.size
        shadow.position = CGPoint(x: 0.35, y: -0.35)
        shadow.zPosition = -1
        body.addChild(shadow)
        // What makes the type readable: glass, roof, cargo box, livery (untinted).
        let top = SKSpriteNode(texture: Textures.vehicleTop(p.cls))
        top.size = body.size
        top.zPosition = 0.5
        body.addChild(top)
        let node = VehicleNode(body: body)
        func lampLayer(_ lamp: Textures.Lamp) -> SKSpriteNode {
            let n = SKSpriteNode(texture: Textures.lamps(p.cls, lamp))
            n.size = body.size
            n.zPosition = 1
            n.isHidden = true
            body.addChild(n)
            return n
        }
        node.brake = [lampLayer(.brake)]
        node.blinkL = [lampLayer(.left)]
        node.blinkR = [lampLayer(.right)]
        let hy = wid / 2
        if p.cls == .police {
            node.bar = [lamp(Theme.ui(.policeRed), size: 0.9, at: CGPoint(x: 0, y: hy * 0.45), in: body),
                        lamp(Theme.ui(.policeBlue), size: 0.9, at: CGPoint(x: 0, y: -hy * 0.45), in: body)]
        }
        let hl = SKSpriteNode(texture: Textures.glow)
        hl.size = CGSize(width: 9, height: 5)
        hl.color = Theme.ui(.headlight)
        hl.colorBlendFactor = 1
        hl.blendMode = .add
        hl.alpha = 0.55
        node.headlights = hl
        lightLayer.addChild(hl)
        vehicleLayer.addChild(body)
        return node
    }

    private func updateVehicles(_ poses: [VehiclePose], time: CFTimeInterval) {
        var live = Set<Int32>()
        live.reserveCapacity(poses.count)
        let blinkOn = Int(time * 2.6) % 2 == 0
        let flash = Int(time * 6) % 2 == 0
        let night = phase > 1.0
        let dt = lastVehicleTime == 0 ? 0 : min(time - lastVehicleTime, 0.1)
        lastVehicleTime = time
        // Zoomed out, vehicles are drawn a little larger so their type stays
        // readable (up to 1.6×; at that zoom the overlap is under a point).
        let boost = (camScale / 0.3).clamped(1, 1.6)
        for p in poses {
            live.insert(p.id)
            let pos = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            let node = vehicleNodes[p.id] ?? {
                let n = makeVehicle(p)
                vehicleNodes[p.id] = n
                noteArrival(at: pos, time: time)
                return n
            }()
            if let last = node.lastPosition, dt > 0 {
                let k = CGFloat(min(dt * 4, 1))
                node.velocity = CGVector(dx: node.velocity.dx + ((pos.x - last.x) / CGFloat(dt) - node.velocity.dx) * k,
                                         dy: node.velocity.dy + ((pos.y - last.y) / CGFloat(dt) - node.velocity.dy) * k)
            }
            node.lastPosition = pos
            node.body.position = pos
            node.body.zRotation = CGFloat(p.heading)
            if node.body.xScale != boost { node.body.setScale(boost) }
            node.body.alpha = CGFloat(p.visibility)
            let braking = p.flags & VehiclePose.Flag.braking != 0
            let hazard = p.flags & VehiclePose.Flag.hazard != 0
            for b in node.brake { b.isHidden = !(braking || night) ; b.alpha = braking ? 1 : 0.45 }
            let left = (p.flags & VehiclePose.Flag.blinkLeft != 0 || hazard) && blinkOn
            let right = (p.flags & VehiclePose.Flag.blinkRight != 0 || hazard) && blinkOn
            for b in node.blinkL { b.isHidden = !left }
            for b in node.blinkR { b.isHidden = !right }
            if node.bar.count == 2 {
                let siren = p.flags & VehiclePose.Flag.siren != 0
                node.bar[0].isHidden = !(siren && flash)
                node.bar[1].isHidden = !(siren && !flash)
            }
            if let hl = node.headlights {
                hl.isHidden = !night || p.flags & VehiclePose.Flag.parked != 0 || p.visibility < 0.6
                if !hl.isHidden {
                    let h = CGFloat(p.heading)
                    hl.position = CGPoint(x: pos.x + cos(h) * (CGFloat(p.length) / 2 + 3.5), y: pos.y + sin(h) * (CGFloat(p.length) / 2 + 3.5))
                    hl.zRotation = h
                }
            }
        }
        for (id, node) in vehicleNodes where !live.contains(id) {
            node.headlights?.removeFromParent()
            // Leaving the map: it drives on into the countryside.
            if !driveOff(node.body, velocity: node.velocity) { node.body.removeFromParent() }
            vehicleNodes[id] = nil
        }
        updateGhosts(dt: dt, time: time)
    }

    private func updateSignals(_ heads: [SignalHead]) {
        while signalNodes.count < heads.count {
            let n = SKSpriteNode(texture: Textures.dot)
            n.size = CGSize(width: 1.6, height: 1.6)
            n.colorBlendFactor = 1
            signalLayer.addChild(n)
            signalNodes.append(n)
        }
        for (k, n) in signalNodes.enumerated() {
            guard k < heads.count else { n.isHidden = true; continue }
            let h = heads[k]
            n.isHidden = false
            n.position = CGPoint(x: CGFloat(h.x), y: CGFloat(h.y))
            switch h.through {
            case .green: n.color = Theme.ui(.signalGreen)
            case .yellow, .permissive: n.color = Theme.ui(.signalAmber)
            case .red: n.color = Theme.ui(.signalRed)
            }
        }
    }

    private func updateMarkers(_ incidents: [Vector2], time: CFTimeInterval) {
        while markerNodes.count < incidents.count {
            let n = SKSpriteNode(texture: Textures.marker)
            markerLayer.addChild(n)
            markerNodes.append(n)
        }
        let pulse = reduceMotion ? 1 : 1 + 0.12 * CGFloat(sin(time * 4))
        let s = max(9, 22 * camScale) * pulse
        for (k, n) in markerNodes.enumerated() {
            guard k < incidents.count else { n.isHidden = true; continue }
            n.isHidden = false
            n.position = cg(incidents[k] + Vector2(0, 6))
            n.size = CGSize(width: s, height: s)
        }
    }

    // MARK: - Overlays & selection

    private func updateOverlay(_ o: OverlayData?) {
        guard let o else {
            if !overlayShapes.isEmpty { overlayLayer.removeAllChildren(); overlayShapes.removeAll() }
            shownOverlay = nil
            return
        }
        // Recolour only when the data changed (it refreshes every couple of seconds).
        if let shown = shownOverlay, shown.kind == o.kind, shown.values == o.values, !overlayShapes.isEmpty { return }
        shownOverlay = (o.kind, o.values)
        for (road, value) in o.values {
            guard let p = roadFillPaths[road] else { continue }
            let n = overlayShapes[road] ?? {
                let s = SKShapeNode(path: p)
                s.lineWidth = 0
                overlayLayer.addChild(s)
                overlayShapes[road] = s
                return s
            }()
            // Green (0) → amber → red (1).
            let c: UIColor = value < 0.5
                ? blend(Theme.ui(.signalGreen), Theme.ui(.signalAmber), value * 2)
                : blend(Theme.ui(.signalAmber), Theme.ui(.signalRed), (value - 0.5) * 2)
            n.fillColor = c.withAlphaComponent(0.55)
        }
    }

    private func blend(_ a: UIColor, _ b: UIColor, _ t: Double) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(min(max(t, 0), 1))
        return UIColor(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k, alpha: 1)
    }

    private func updateHighlight(_ pts: [Vector2]) {
        var key = pts.count
        if let f = pts.first { key = key &* 31 &+ Int(f.x * 10) &* 17 &+ Int(f.y * 10) }
        if let l = pts.last { key = key &* 31 &+ Int(l.x * 10) &* 13 &+ Int(l.y * 10) }
        guard key != highlightKey else { return }
        highlightKey = key
        highlightLayer.removeAllChildren()
        guard pts.count >= 2 else { return }
        let n = shape(pts, fill: nil, stroke: Theme.ui(.uiAccent).withAlphaComponent(0.75), width: 1.6, closed: false)
        highlightLayer.addChild(n)
    }

    // MARK: - Lighting

    private func applyLighting() {
        backgroundColor = Theme.ui(.land, phase: phase)
        // A gentle blue-grey veil towards night (never truly dark).
        let night = max(0, phase - 0.6) / 1.4
        nightTint.color = UIColor(red: 0.10, green: 0.13, blue: 0.24, alpha: 1)
        nightTint.alpha = CGFloat(night * 0.32)
        lightLayer.alpha = CGFloat(max(0, phase - 1))
    }

    // MARK: - Camera

    private func fitCamera(roads: (min: Vector2, max: Vector2)) {
        let span = CGSize(width: roads.max.x - roads.min.x, height: roads.max.y - roads.min.y)
        cam.position = CGPoint(x: (roads.min.x + roads.max.x) / 2, y: (roads.min.y + roads.max.y) / 2)
        let viewSize = view?.bounds.size ?? CGSize(width: 844, height: 390)
        // Fit the town, but start close enough to see the cars.
        camScale = min(span.width / max(viewSize.width, 1), span.height / max(viewSize.height, 1)) * 0.75
        camScale = min(max(camScale, 0.15), maxCamScale)
        // UI tests / screenshots: -zoom <scale> (smaller = closer).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-zoom"), i + 1 < args.count, let z = Double(args[i + 1]) { camScale = CGFloat(z) }
        // UI tests: -camera x,y,scale pins the view so gestures land on known world points.
        if let i = args.firstIndex(of: "-camera"), i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 3 {
                cam.position = CGPoint(x: v[0], y: v[1])
                camScale = CGFloat(v[2])
            }
        }
        cam.setScale(camScale)
    }

}
