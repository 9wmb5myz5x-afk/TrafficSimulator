//
//  SVGRenderer.swift
//  TrafficEngine
//
//  Headless top-down snapshot of the city as SVG, so the simulation can be
//  *seen* on Linux. Draws the same RenderGeometry the app draws, plus optional
//  debug layers (turn connectors, conflict zones) and vehicle footprints.
//

public struct SVGOptions: Sendable {
    public var showConnectors = false
    public var showLaneCentres = false
    public var showNodeIDs = false
    /// Optional world-space crop (min, max). nil = fit the whole network.
    public var crop: (Vector2, Vector2)?
    public var pixelsPerMetre = 2.0
    public var maxPixels = 2400.0
    public var title: String?
    public init() {}
}

/// A drawable vehicle footprint for snapshots.
public struct SVGVehicle: Sendable {
    public var box: OrientedBox
    public var fill: String
    public var blinker: Int     // -1 left, 0 none, +1 right
    public var braking: Bool
    public var siren: Bool
    public init(box: OrientedBox, fill: String, blinker: Int = 0, braking: Bool = false, siren: Bool = false) {
        self.box = box
        self.fill = fill
        self.blinker = blinker
        self.braking = braking
        self.siren = siren
    }
}

public struct SVGExtra: Sendable {
    public var polygons: [(points: [Vector2], fill: String, stroke: String)] = []
    public var circles: [(center: Vector2, radius: Double, fill: String)] = []
    public var labels: [(at: Vector2, text: String, size: Double)] = []
    public init() {}
}

public enum SVGRenderer {

    public static func render(_ net: RoadNetwork, vehicles: [SVGVehicle] = [], extra: SVGExtra = SVGExtra(),
                              signals: [(Vector2, String)] = [], options: SVGOptions = SVGOptions()) -> String {
        let geo = RenderGeometryBuilder.all(net)
        var lo = Vector2(.infinity, .infinity), hi = Vector2(-.infinity, -.infinity)
        if let c = options.crop {
            lo = c.0; hi = c.1
        } else {
            for r in geo.roads { for p in r.surface.polygon { lo = Vector2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vector2(max(hi.x, p.x), max(hi.y, p.y)) } }
            for j in geo.junctions { for p in j.polygon { lo = Vector2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vector2(max(hi.x, p.x), max(hi.y, p.y)) } }
            for p in extra.polygons { for q in p.points { lo = Vector2(min(lo.x, q.x), min(lo.y, q.y)); hi = Vector2(max(hi.x, q.x), max(hi.y, q.y)) } }
            if !lo.x.isFinite { lo = Vector2(-50, -50); hi = Vector2(50, 50) }
            lo = lo - Vector2(15, 15); hi = hi + Vector2(15, 15)
        }
        let span = hi - lo
        let ppm = min(options.pixelsPerMetre, options.maxPixels / max(span.x, span.y, 1))
        let W = span.x * ppm, H = span.y * ppm

        func f(_ v: Double) -> String {
            let r = (v * 100).rounded() / 100
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        // World y is up; SVG y is down.
        func pt(_ p: Vector2) -> String { "\(f((p.x - lo.x) * ppm)),\(f((hi.y - p.y) * ppm))" }
        func path(_ pts: [Vector2], closed: Bool) -> String {
            guard let first = pts.first else { return "" }
            var d = "M\(pt(first))"
            for p in pts.dropFirst() { d += " L\(pt(p))" }
            if closed { d += " Z" }
            return d
        }

        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(W))\" height=\"\(f(H))\" viewBox=\"0 0 \(f(W)) \(f(H))\">\n"
        s += "<rect width=\"100%\" height=\"100%\" fill=\"#F3EBDD\"/>\n"
        for p in extra.polygons {
            s += "<path d=\"\(path(p.points, closed: true))\" fill=\"\(p.fill)\" stroke=\"\(p.stroke)\" stroke-width=\"1\"/>\n"
        }
        // Surfaces: road edge (slightly darker) then pavement, so junctions merge seamlessly.
        let levels = Set(geo.roads.map { $0.surface.level } + geo.junctions.map { $0.level }).sorted()
        for level in levels {
            for r in geo.roads where r.surface.level == level {
                s += "<path d=\"\(path(r.surface.polygon, closed: true))\" fill=\"#D9D3C7\" stroke=\"#D9D3C7\" stroke-width=\"\(f(ppm * 1.2))\" stroke-linejoin=\"round\"/>\n"
            }
            for j in geo.junctions where j.level == level && j.polygon.count >= 3 {
                s += "<path d=\"\(path(j.polygon, closed: true))\" fill=\"#D9D3C7\" stroke=\"#D9D3C7\" stroke-width=\"\(f(ppm * 1.2))\" stroke-linejoin=\"round\"/>\n"
            }
            for r in geo.roads where r.surface.level == level {
                let fill = r.surface.isBridge ? "#F4F1EA" : "#FBFAF7"
                s += "<path d=\"\(path(r.surface.polygon, closed: true))\" fill=\"\(fill)\"/>\n"
            }
            for j in geo.junctions where j.level == level && j.polygon.count >= 3 {
                s += "<path d=\"\(path(j.polygon, closed: true))\" fill=\"#FBFAF7\"/>\n"
            }
            if level == 0 {
                for rb in RenderGeometryBuilder.roundabouts(net) {
                    s += "<path d=\"\(path(rb.outer, closed: true))\" fill=\"#FBFAF7\" stroke=\"#D9D3C7\" stroke-width=\"\(f(ppm * 0.6))\"/>\n"
                    s += "<path d=\"\(path(rb.island, closed: true))\" fill=\"#C9D8B6\" stroke=\"#B9C8A6\" stroke-width=\"\(f(ppm * 0.3))\"/>\n"
                }
            }
            for r in geo.roads where r.surface.level == level {
                for m in r.medians {
                    s += "<path d=\"\(path(m, closed: true))\" fill=\"#C9D8B6\" stroke=\"#B9C8A6\" stroke-width=\"\(f(ppm * 0.2))\"/>\n"
                }
                for m in r.markings { s += marking(m, ppm: ppm, path: path) }
                for a in r.arrows { s += arrow(a, ppm: ppm, pt: pt) }
            }
            for j in geo.junctions where j.level == level {
                for m in j.markings { s += marking(m, ppm: ppm, path: path) }
            }
        }
        if options.showConnectors {
            for c in net.connectors {
                let color: String
                switch c.turn {
                case .left: color = "#D0533F"
                case .right: color = "#3F7FD0"
                case .straight: color = "#6A9A55"
                case .uTurn: color = "#9A55A0"
                }
                s += "<path d=\"\(path(c.path.points, closed: false))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(f(ppm * 0.25))\" stroke-opacity=\"0.8\"/>\n"
            }
        }
        if options.showLaneCentres {
            for e in net.allEdges {
                for l in e.lanes {
                    let n = max(1, Int(((l.sEnd - l.sStart) / 4).rounded(.up)))
                    let pts = (0...n).map { e.position(s: l.sStart + (l.sEnd - l.sStart) * Double($0) / Double(n), lateral: l.lateral) }
                    s += "<path d=\"\(path(pts, closed: false))\" fill=\"none\" stroke=\"#8899AA\" stroke-width=\"\(f(ppm * 0.15))\" stroke-dasharray=\"\(f(ppm)),\(f(ppm))\"/>\n"
                }
            }
        }
        for c in extra.circles {
            s += "<circle cx=\"\(f((c.center.x - lo.x) * ppm))\" cy=\"\(f((hi.y - c.center.y) * ppm))\" r=\"\(f(c.radius * ppm))\" fill=\"\(c.fill)\"/>\n"
        }
        for (p, color) in signals {
            s += "<circle cx=\"\(f((p.x - lo.x) * ppm))\" cy=\"\(f((hi.y - p.y) * ppm))\" r=\"\(f(0.9 * ppm))\" fill=\"\(color)\" stroke=\"#33383D\" stroke-width=\"\(f(0.2 * ppm))\"/>\n"
        }
        for v in vehicles {
            let shadow = OrientedBox(center: v.box.center + Vector2(0.35, -0.35), axis: v.box.axis,
                                     halfLength: v.box.halfLength, halfWidth: v.box.halfWidth)
            s += "<path d=\"\(path(shadow.corners, closed: true))\" fill=\"#000\" fill-opacity=\"0.15\"/>\n"
            s += "<path d=\"\(path(v.box.corners, closed: true))\" fill=\"\(v.fill)\" stroke=\"#2E3338\" stroke-width=\"\(f(ppm * 0.08))\" stroke-linejoin=\"round\"/>\n"
            let front = v.box.center + v.box.axis * (v.box.halfLength - 0.3)
            let rear = v.box.center - v.box.axis * (v.box.halfLength - 0.3)
            let side = v.box.axis.perpendicular * (v.box.halfWidth - 0.3)
            if v.blinker != 0 {
                let sgn = Double(v.blinker) * -1   // +1 = right → negative perpendicular
                for p in [front + side * sgn, rear + side * sgn] {
                    s += "<circle cx=\"\(f((p.x - lo.x) * ppm))\" cy=\"\(f((hi.y - p.y) * ppm))\" r=\"\(f(0.35 * ppm))\" fill=\"#FFB000\"/>\n"
                }
            }
            if v.braking {
                for p in [rear + side, rear - side] {
                    s += "<circle cx=\"\(f((p.x - lo.x) * ppm))\" cy=\"\(f((hi.y - p.y) * ppm))\" r=\"\(f(0.3 * ppm))\" fill=\"#E03030\"/>\n"
                }
            }
            if v.siren {
                s += "<circle cx=\"\(f((v.box.center.x - lo.x) * ppm))\" cy=\"\(f((hi.y - v.box.center.y) * ppm))\" r=\"\(f(0.6 * ppm))\" fill=\"#2050FF\"/>\n"
            }
        }
        if options.showNodeIDs {
            for n in net.allNodes {
                s += "<text x=\"\(f((n.position.x - lo.x) * ppm))\" y=\"\(f((hi.y - n.position.y) * ppm))\" font-size=\"\(f(3 * ppm))\" fill=\"#555\" font-family=\"sans-serif\">\(n.id)</text>\n"
            }
        }
        for l in extra.labels {
            s += "<text x=\"\(f((l.at.x - lo.x) * ppm))\" y=\"\(f((hi.y - l.at.y) * ppm))\" font-size=\"\(f(l.size * ppm))\" fill=\"#5A5048\" font-family=\"sans-serif\" letter-spacing=\"2\">\(l.text)</text>\n"
        }
        if let t = options.title {
            s += "<text x=\"10\" y=\"24\" font-size=\"18\" fill=\"#333\" font-family=\"sans-serif\">\(t)</text>\n"
        }
        s += "</svg>\n"
        return s
    }

    static func marking(_ m: Marking, ppm: Double, path: ([Vector2], Bool) -> String) -> String {
        let w = m.width * ppm
        func fmt(_ v: Double) -> String { String((v * 100).rounded() / 100) }
        switch m.kind {
        case .laneDash:
            return "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#B9B2A5\" stroke-width=\"\(fmt(w))\" stroke-dasharray=\"\(fmt(3 * ppm)),\(fmt(6 * ppm))\"/>\n"
        case .laneSolid, .edgeLine:
            return "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#C9C2B5\" stroke-width=\"\(fmt(w))\"/>\n"
        case .centreDouble:
            return "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#D8B45A\" stroke-width=\"\(fmt(w * 3))\"/>\n" +
                   "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#FBFAF7\" stroke-width=\"\(fmt(w))\"/>\n"
        case .stopBar:
            return "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#9E978A\" stroke-width=\"\(fmt(w))\"/>\n"
        case .yieldLine:
            return "<path d=\"\(path(m.points, false))\" fill=\"none\" stroke=\"#9E978A\" stroke-width=\"\(fmt(w))\" stroke-dasharray=\"\(fmt(0.6 * ppm)),\(fmt(0.6 * ppm))\"/>\n"
        }
    }

    static func arrow(_ a: LaneArrow, ppm: Double, pt: (Vector2) -> String) -> String {
        var s = ""
        let dir = Vector2.unit(angle: a.heading)
        for m in a.movements {
            let tip: Vector2
            switch m {
            case .straight: tip = a.position + dir * 2.5
            case .left: tip = a.position + dir * 1.2 + dir.perpendicular * 1.3
            case .right: tip = a.position + dir * 1.2 - dir.perpendicular * 1.3
            case .uTurn: tip = a.position - dir * 0.8 + dir.perpendicular * 1.0
            }
            let tail = a.position - dir * 2.0
            s += "<path d=\"M\(pt(tail)) L\(pt(a.position)) L\(pt(tip))\" fill=\"none\" stroke=\"#B9B2A5\" stroke-width=\"\((0.35 * ppm * 100).rounded() / 100)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
        }
        return s
    }
}
