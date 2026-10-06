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
    private var signalNodes: [SKSpriteNode] = []
    private var markerNodes: [SKSpriteNode] = []
    private var roadFills: [Int: [SKShapeNode]] = [:]        // road raw id → fill shapes (for overlays)
    private var overlayShapes: [Int: SKShapeNode] = [:]
    private var highlightKey: Int = 0
    private var didFit = false
    private var phase: Double = 0

    // Camera gesture state.
    var camScale: CGFloat = 1
    var panStart = CGPoint.zero
    var pinchStart: CGFloat = 1
    /// The stroke being drawn (nil while panning the camera).
    var stroke: [Vector2]?
    var strokeNode: SKShapeNode?

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
        guard let controller else { return }
        if let g = controller.buffer.latestGeometry(), g.networkVersion != networkVersion || g.cityVersion != cityVersion {
            let networkChanged = g.networkVersion != networkVersion
            networkVersion = g.networkVersion
            cityVersion = g.cityVersion
            if networkChanged { rebuildTerrainAndRoads(g) }
            rebuildBuildings(g, animate: didFit && !reduceMotion)
            worldBounds = g.bounds
            if !didFit { fitCamera(); didFit = true }
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

    private func rebuildTerrainAndRoads(_ g: StaticGeometry) {
        for l in [terrainLayer, roadEdgeLayer, roadFillLayer, markingLayer, labelLayer] { l.removeAllChildren() }
        overlayLayer.removeAllChildren()
        overlayShapes.removeAll()
        roadFills.removeAll()
        let p = phase
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
        // Roads: edge strokes beneath, fills above, so junctions merge seamlessly.
        let edge = Theme.ui(.roadEdge, phase: p), fill = Theme.ui(.road, phase: p)
        for r in g.roads {
            roadEdgeLayer.addChild(shape(r.surface.polygon, fill: edge, stroke: edge, width: 1.2))
            let f = shape(r.surface.polygon, fill: r.surface.isBridge ? Theme.ui(.bridge, phase: p) : fill)
            f.zPosition = CGFloat(r.surface.level)
            if r.surface.isBridge || r.surface.level > 0 {
                // Raised roads cast a soft shadow.
                let sh = shape(r.surface.polygon.map { $0 + Vector2(1.6, -1.6) }, fill: Theme.ui(.shadow).withAlphaComponent(0.16))
                sh.zPosition = f.zPosition - 0.5
                roadFillLayer.addChild(sh)
            }
            roadFillLayer.addChild(f)
            roadFills[r.surface.road.raw, default: []].append(f)
        }
        for j in g.junctions where j.polygon.count >= 3 {
            roadEdgeLayer.addChild(shape(j.polygon, fill: edge, stroke: edge, width: 1.2))
            let f = shape(j.polygon, fill: fill)
            f.zPosition = CGFloat(j.level)
            roadFillLayer.addChild(f)
        }
        for rb in g.roundabouts {
            roadEdgeLayer.addChild(shape(rb.outer, fill: edge, stroke: edge, width: 1.2))
            roadFillLayer.addChild(shape(rb.outer, fill: fill))
            let island = shape(rb.island, fill: Theme.ui(.median, phase: p))
            island.zPosition = 2
            roadFillLayer.addChild(island)
        }
        for r in g.roads {
            for m in r.medians { roadFillLayer.addChild(withZ(shape(m, fill: Theme.ui(.median, phase: p)), 2)) }
            for m in r.markings { addMarking(m) }
            for a in r.arrows { addArrow(a) }
        }
        for j in g.junctions { for m in j.markings { addMarking(m) } }
    }

    private func withZ(_ n: SKNode, _ z: CGFloat) -> SKNode { n.zPosition = z; return n }

    /// Round trees scattered deterministically inside a park.
    private func addTrees(in polygon: [Vector2]) {
        let xs = polygon.map { $0.x }, ys = polygon.map { $0.y }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return }
        var k: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double { k ^= k << 13; k ^= k >> 7; k ^= k << 17; return Double(k % 10_000) / 10_000 }
        let count = Int(((x1 - x0) * (y1 - y0) / 260).clamped(to: 3...400))
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

    private func addMarking(_ m: Marking) {
        let color: UIColor
        var dash: [CGFloat]?
        switch m.kind {
        case .laneDash: color = Theme.ui(.laneMarking); dash = [3, 6]
        case .laneSolid, .edgeLine: color = Theme.ui(.laneMarking)
        case .centreDouble: color = Theme.ui(.centerLine)
        case .stopBar: color = Theme.ui(.laneMarking)
        case .yieldLine: color = Theme.ui(.laneMarking); dash = [0.6, 0.6]
        }
        var p = path(m.points, closed: false)
        if let d = dash { p = p.copy(dashingWithPhase: 0, lengths: d) }
        let n = SKShapeNode(path: p)
        n.strokeColor = color
        n.lineWidth = CGFloat(m.kind == .centreDouble ? m.width * 3 : m.width * 1.4)
        n.lineCap = .butt
        markingLayer.addChild(n)
    }

    private func addArrow(_ a: LaneArrow) {
        guard !a.movements.isEmpty else { return }
        let n = SKShapeNode()
        let p = CGMutablePath()
        for mv in a.movements {
            // A stem with a short head, bent towards the turn.
            let bend: CGFloat
            switch mv {
            case .straight: bend = 0
            case .left: bend = 1
            case .right: bend = -1
            case .uTurn: bend = 1.6
            }
            p.move(to: CGPoint(x: -2.2, y: 0))
            p.addLine(to: CGPoint(x: 0.6, y: 0))
            p.addLine(to: CGPoint(x: 1.6, y: bend * 0.9))
        }
        n.path = p
        n.strokeColor = Theme.ui(.laneMarking)
        n.lineWidth = 0.28
        n.lineCap = .round
        n.position = cg(a.position)
        n.zRotation = CGFloat(a.heading)
        markingLayer.addChild(n)
    }

    // MARK: - Buildings

    private func rebuildBuildings(_ g: StaticGeometry, animate: Bool) {
        let previous = Set(buildingLayer.children.compactMap { $0.userData?["id"] as? Int })
        shadowLayer.removeAllChildren()
        buildingLayer.removeAllChildren()
        for b in g.buildings {
            let f = Vector2.unit(angle: b.rotation), r = f.perpendicular
            let hw = b.width / 2, hd = b.depth / 2
            let poly = [b.center + r * hw - f * hd, b.center - r * hw - f * hd, b.center - r * hw + f * hd, b.center + r * hw + f * hd]
            // Shadow and side band: offset towards the bottom-right in world space.
            let h = b.storeys
            let shadowOffset = Vector2(1.2 + h * 1.1, -(1.2 + h * 1.1))
            let shadow = shape(poly.map { $0 + shadowOffset }, fill: Theme.ui(.shadow).withAlphaComponent(0.14))
            shadowLayer.addChild(shadow)
            let side = shape(poly.map { $0 + Vector2(0.5, -(0.9 + h * 0.25)) }, fill: Theme.ui(b.kind.tokens.side, phase: phase))
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
        // A tiny drop shadow.
        let shadow = SKSpriteNode(texture: Textures.vehicle(p.cls))
        shadow.color = .black
        shadow.colorBlendFactor = 1
        shadow.alpha = 0.18
        shadow.size = body.size
        shadow.position = CGPoint(x: 0.35, y: -0.35)
        shadow.zPosition = -1
        body.addChild(shadow)
        let node = VehicleNode(body: body)
        let hx = len / 2, hy = wid / 2
        let red = Theme.ui(.signalRed), amber = Theme.ui(.signalAmber)
        node.brake = [lamp(red, size: 0.55, at: CGPoint(x: -hx + 0.15, y: hy - 0.3), in: body),
                      lamp(red, size: 0.55, at: CGPoint(x: -hx + 0.15, y: -hy + 0.3), in: body)]
        // Left is +y in the vehicle frame (heading along +x).
        node.blinkL = [lamp(amber, size: 0.6, at: CGPoint(x: hx - 0.2, y: hy - 0.15), in: body),
                       lamp(amber, size: 0.6, at: CGPoint(x: -hx + 0.2, y: hy - 0.15), in: body)]
        node.blinkR = [lamp(amber, size: 0.6, at: CGPoint(x: hx - 0.2, y: -hy + 0.15), in: body),
                       lamp(amber, size: 0.6, at: CGPoint(x: -hx + 0.2, y: -hy + 0.15), in: body)]
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
        for p in poses {
            live.insert(p.id)
            let node = vehicleNodes[p.id] ?? { let n = makeVehicle(p); vehicleNodes[p.id] = n; return n }()
            let pos = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            node.body.position = pos
            node.body.zRotation = CGFloat(p.heading)
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
                hl.isHidden = !night || p.flags & VehiclePose.Flag.parked != 0
                if !hl.isHidden {
                    let h = CGFloat(p.heading)
                    hl.position = CGPoint(x: pos.x + cos(h) * (CGFloat(p.length) / 2 + 3.5), y: pos.y + sin(h) * (CGFloat(p.length) / 2 + 3.5))
                    hl.zRotation = h
                }
            }
        }
        for (id, node) in vehicleNodes where !live.contains(id) {
            node.body.removeFromParent()
            node.headlights?.removeFromParent()
            vehicleNodes[id] = nil
        }
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
            return
        }
        for (road, value) in o.values {
            guard let fills = roadFills[road], let first = fills.first, let p = first.path else { continue }
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

    private func fitCamera() {
        let span = CGSize(width: worldBounds.max.x - worldBounds.min.x, height: worldBounds.max.y - worldBounds.min.y)
        cam.position = CGPoint(x: (worldBounds.min.x + worldBounds.max.x) / 2, y: (worldBounds.min.y + worldBounds.max.y) / 2)
        let viewSize = view?.bounds.size ?? CGSize(width: 844, height: 390)
        // Fit the map, but start close enough to see the cars.
        camScale = min(span.width / max(viewSize.width, 1), span.height / max(viewSize.height, 1)) * 0.75
        camScale = min(max(camScale, 0.15), 3)
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
