//
//  Textures.swift
//  TrafficSimulator
//
//  Procedural textures, drawn once with UIKit and packed into one atlas so
//  SpriteKit can batch every vehicle into a few draw calls.
//
//  Vehicles are two layers: a body silhouette tinted with the paint colour
//  and an untinted detail layer (glass, roofs, cargo box, livery), each class
//  with its own shape. Lamps are one layer per group (brake, left, right).
//

import UIKit
import SpriteKit
import TrafficEngine

enum Textures {
    /// Pixels per metre for vehicle textures.
    static let ppm: CGFloat = 12

    private static var cache: [String: SKTexture] = [:]
    private static var atlas: SKTextureAtlas?

    static func vehicle(_ cls: VehicleClass) -> SKTexture { texture("veh.\(cls.rawValue)") }
    static func vehicleShape(_ cls: VehicleClass) -> SKTexture { texture("veh.\(cls.rawValue).shape") }
    static func vehicleTop(_ cls: VehicleClass) -> SKTexture { texture("veh.\(cls.rawValue).top") }
    static func lamps(_ cls: VehicleClass, _ lamp: Lamp) -> SKTexture { texture("veh.\(cls.rawValue).\(lamp.rawValue)") }
    static var tree: SKTexture { texture("tree") }
    static var glow: SKTexture { texture("glow") }
    static var dot: SKTexture { texture("dot") }
    static var marker: SKTexture { texture("marker") }
    static func roof(_ kind: BuildingKind) -> SKTexture { texture("roof.\(kind.rawValue)") }

    private static func texture(_ name: String) -> SKTexture {
        if let t = cache[name] { return t }
        if atlas == nil { buildAtlas() }
        let t = atlas!.textureNamed(name)
        cache[name] = t
        return t
    }

    private static func buildAtlas() {
        var images: [String: UIImage] = [:]
        for cls in VehicleClass.allCases {
            images["veh.\(cls.rawValue)"] = drawVehicleBody(cls)
            images["veh.\(cls.rawValue).top"] = drawVehicleTop(cls)
            images["veh.\(cls.rawValue).shape"] = drawVehicleShape(cls)
            for lamp in [Lamp.brake, .left, .right] { images["veh.\(cls.rawValue).\(lamp.rawValue)"] = drawLamps(cls, lamp) }
        }
        for kind in BuildingKind.allCases { images["roof.\(kind.rawValue)"] = drawRoof(kind) }
        images["tree"] = drawTree()
        images["glow"] = drawGlow()
        images["dot"] = drawDot()
        images["marker"] = drawMarker()
        atlas = SKTextureAtlas(dictionary: images)
    }

    // MARK: Vehicles (drawn facing +x)
    //
    // Each class has two layers: a body silhouette drawn in greys (the renderer
    // tints it with the car's paint colour) and a detail layer drawn in fixed
    // colours (glass, roofs, cargo box, livery) laid over it untinted — so a
    // truck reads as a truck and a bus as a bus whatever the paint.
    //   car    rounded, windscreen + rear window, a short roof
    //   SUV    squarer and bigger, long roof with roof rails
    //   van    a box with a short nose, sliding-door seam, roof vent
    //   truck  painted cab, white ribbed cargo box behind it
    //   bus    long, window bands along both sides, roof units
    //   police black and white livery with a light bar

    /// Body texture size for a class (with a 1 px margin all round).
    private static func vehicleSize(_ cls: VehicleClass) -> (len: CGFloat, wid: CGFloat, size: CGSize) {
        let len = CGFloat(cls.length) * ppm, wid = CGFloat(cls.width) * ppm
        return (len, wid, CGSize(width: len + 2, height: wid + 2))
    }

    private static func cornerRadius(_ cls: VehicleClass, _ len: CGFloat, _ wid: CGFloat) -> CGFloat {
        switch cls {
        case .car: return min(wid * 0.42, len * 0.2)
        case .police: return min(wid * 0.38, len * 0.2)
        case .suv: return wid * 0.24
        case .van: return wid * 0.16
        case .truck, .bus: return wid * 0.1
        }
    }

    private static func drawVehicleBody(_ cls: VehicleClass) -> UIImage {
        let (len, wid, size) = vehicleSize(cls)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let body = CGRect(x: 1, y: 1, width: len, height: wid)
            let r = cornerRadius(cls, len, wid)
            // A slightly darker rim reads as an outline once tinted.
            UIColor(white: 0.72, alpha: 1).setFill()
            UIBezierPath(roundedRect: body, cornerRadius: r).fill()
            UIColor.white.setFill()
            UIBezierPath(roundedRect: body.insetBy(dx: 1.2, dy: 1.2), cornerRadius: max(r - 1.2, 1)).fill()
            if cls == .truck {
                // Only the cab is painted; the box is drawn by the detail layer.
                UIColor.clear.setFill()
                UIGraphicsGetCurrentContext()?.clear(CGRect(x: 0, y: 0, width: 1 + len * 0.74, height: size.height))
            }
        }
    }

    /// The whole outline in white (for the drop shadow).
    private static func drawVehicleShape(_ cls: VehicleClass) -> UIImage {
        let (len, wid, size) = vehicleSize(cls)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: len, height: wid), cornerRadius: cornerRadius(cls, len, wid)).fill()
        }
    }

    private static func drawVehicleTop(_ cls: VehicleClass) -> UIImage {
        let (len, wid, size) = vehicleSize(cls)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let glassColor = UIColor(red: 0.13, green: 0.17, blue: 0.22, alpha: 0.82)
            func rect(_ x0: CGFloat, _ w: CGFloat, _ y0: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: 1 + len * x0, y: 1 + wid * y0, width: len * w, height: wid * h)
            }
            func fill(_ r: CGRect, _ c: UIColor, radius: CGFloat = 2) {
                c.setFill(); UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
            }
            func line(_ a: CGPoint, _ b: CGPoint, _ c: UIColor, _ w: CGFloat) {
                c.setStroke(); g.setLineWidth(w); g.setLineCap(.round)
                g.move(to: a); g.addLine(to: b); g.strokePath()
            }
            let roofShade = UIColor(white: 1, alpha: 0.28)
            switch cls {
            case .car:
                fill(rect(0.58, 0.15, 0.12, 0.76), glassColor, radius: wid * 0.14)      // windscreen
                fill(rect(0.14, 0.11, 0.16, 0.68), glassColor, radius: wid * 0.12)      // rear window
                fill(rect(0.27, 0.30, 0.16, 0.68), roofShade, radius: wid * 0.12)       // roof
            case .suv:
                fill(rect(0.62, 0.13, 0.10, 0.80), glassColor, radius: wid * 0.1)
                fill(rect(0.08, 0.08, 0.14, 0.72), glassColor, radius: wid * 0.08)
                fill(rect(0.17, 0.44, 0.12, 0.76), roofShade, radius: wid * 0.08)
                // Roof rails.
                line(CGPoint(x: 1 + len * 0.2, y: 1 + wid * 0.2), CGPoint(x: 1 + len * 0.58, y: 1 + wid * 0.2), UIColor(white: 0.12, alpha: 0.75), 1.6)
                line(CGPoint(x: 1 + len * 0.2, y: 1 + wid * 0.8), CGPoint(x: 1 + len * 0.58, y: 1 + wid * 0.8), UIColor(white: 0.12, alpha: 0.75), 1.6)
            case .van:
                fill(rect(0.80, 0.10, 0.10, 0.80), glassColor, radius: wid * 0.08)
                fill(rect(0.05, 0.74, 0.12, 0.76), roofShade, radius: wid * 0.06)        // long flat roof
                fill(rect(0.38, 0.16, 0.36, 0.28), UIColor(white: 0.2, alpha: 0.22), radius: 2)   // roof vent
                // Sliding-door seam on each side.
                line(CGPoint(x: 1 + len * 0.55, y: 1 + wid * 0.06), CGPoint(x: 1 + len * 0.55, y: 1 + wid * 0.2), UIColor(white: 0, alpha: 0.35), 1)
                line(CGPoint(x: 1 + len * 0.55, y: 1 + wid * 0.8), CGPoint(x: 1 + len * 0.55, y: 1 + wid * 0.94), UIColor(white: 0, alpha: 0.35), 1)
            case .truck:
                // White cargo box with ribs, a gap, then the (painted) cab.
                let box = CGRect(x: 1, y: 1, width: len * 0.72, height: wid)
                UIColor(white: 0.6, alpha: 1).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: wid * 0.06).fill()
                UIColor(white: 0.96, alpha: 1).setFill()
                UIBezierPath(roundedRect: box.insetBy(dx: 1.2, dy: 1.2), cornerRadius: wid * 0.05).fill()
                for k in 1...5 {
                    let x = 1 + len * 0.72 * CGFloat(k) / 6
                    line(CGPoint(x: x, y: 3), CGPoint(x: x, y: wid - 1), UIColor(white: 0.78, alpha: 1), 1)
                }
                fill(rect(0.86, 0.08, 0.10, 0.80), glassColor, radius: wid * 0.06)      // windscreen
                fill(rect(0.77, 0.08, 0.16, 0.68), roofShade, radius: wid * 0.06)       // cab roof
            case .bus:
                // Window bands along both sides, windscreen, roof units.
                fill(rect(0.05, 0.86, 0.05, 0.13), glassColor, radius: 2)
                fill(rect(0.05, 0.86, 0.82, 0.13), glassColor, radius: 2)
                fill(rect(0.93, 0.05, 0.08, 0.84), glassColor, radius: wid * 0.06)
                fill(rect(0.12, 0.16, 0.30, 0.40), UIColor(white: 0.93, alpha: 0.95), radius: 3)
                fill(rect(0.55, 0.12, 0.34, 0.32), UIColor(white: 0.93, alpha: 0.95), radius: 3)
            case .police:
                // Black body with white doors and roof; the renderer tints nothing.
                let body = CGRect(x: 1, y: 1, width: len, height: wid)
                let r = cornerRadius(cls, len, wid)
                let clip = UIBezierPath(roundedRect: body, cornerRadius: r)
                g.saveGState(); clip.addClip()
                UIColor(white: 0.1, alpha: 1).setFill(); g.fill(body)
                UIColor.white.setFill(); g.fill(rect(0.30, 0.40, 0, 1))
                g.restoreGState()
                fill(rect(0.58, 0.14, 0.12, 0.76), glassColor, radius: wid * 0.12)
                fill(rect(0.12, 0.11, 0.16, 0.68), glassColor, radius: wid * 0.12)
                // Light bar (the renderer flashes red/blue over it).
                fill(rect(0.44, 0.09, 0.10, 0.80), UIColor(white: 0.25, alpha: 1), radius: 2)
            }
            // Headlights and rear lamps (dim; the renderer adds brake lights).
            UIColor(white: 1, alpha: 0.95).setFill()
            UIBezierPath(ovalIn: CGRect(x: len - 3, y: 1 + wid * 0.12, width: 3, height: 3)).fill()
            UIBezierPath(ovalIn: CGRect(x: len - 3, y: wid - 2.5, width: 3, height: 3)).fill()
            UIColor(red: 0.55, green: 0.12, blue: 0.10, alpha: 0.85).setFill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: 1 + wid * 0.1, width: 2, height: 3), cornerRadius: 1).fill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: wid - 3, width: 2, height: 3), cornerRadius: 1).fill()
        }
    }

    enum Lamp: String { case brake, left, right }

    /// A class's lamps of one kind, as a layer the size of the body: brake
    /// lights at the rear corners, or the front and rear indicators on one side.
    private static func drawLamps(_ cls: VehicleClass, _ lamp: Lamp) -> UIImage {
        let (len, wid, size) = vehicleSize(cls)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let d = max(5, wid * 0.24)
            switch lamp {
            case .brake:
                UIColor(red: 1, green: 0.16, blue: 0.12, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: wid * 0.08, width: d, height: d)).fill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: wid + 2 - wid * 0.08 - d, width: d, height: d)).fill()
            case .left, .right:
                // Left is +y in the vehicle frame, which is the top of the image (flipped).
                let y = lamp == .left ? 0 : wid + 2 - d
                UIColor(red: 1, green: 0.66, blue: 0.1, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: len + 2 - d, y: y, width: d, height: d)).fill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: y, width: d, height: d)).fill()
            }
        }
    }

    // MARK: Buildings

    /// A rounded roof tile with its pictogram, drawn at 6 px/m for a 20 m tile.
    private static func drawRoof(_ kind: BuildingKind) -> UIImage {
        let w = CGFloat(kind.size.width) * 6, d = CGFloat(kind.size.depth) * 6
        let size = CGSize(width: w, height: d)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            Theme.ui(kind.tokens.roof).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: min(w, d) * 0.14).fill()
            // A soft inner highlight: light from the top-left.
            UIColor(white: 1, alpha: 0.18).setFill()
            UIBezierPath(roundedRect: CGRect(x: rect.minX + 3, y: rect.minY + 3, width: rect.width * 0.55, height: rect.height * 0.35),
                         cornerRadius: min(w, d) * 0.1).fill()
            let pt = min(w, d) * 0.42
            let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: .bold)
            if let sym = UIImage(systemName: kind.pictogram, withConfiguration: cfg)?
                .withTintColor(Theme.ui(kind.tokens.side).withAlphaComponent(0.75), renderingMode: .alwaysOriginal) {
                let s = sym.size
                sym.draw(in: CGRect(x: (w - s.width) / 2, y: (d - s.height) / 2, width: s.width, height: s.height))
            }
        }
    }

    // MARK: Misc

    private static func drawTree() -> UIImage {
        let size = CGSize(width: 44, height: 44)
        return UIGraphicsImageRenderer(size: size).image { _ in
            Theme.ui(.shadow).withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 34, height: 34)).fill()
            Theme.ui(.parkTree).setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 34, height: 34)).fill()
            UIColor(white: 1, alpha: 0.18).setFill()
            UIBezierPath(ovalIn: CGRect(x: 8, y: 7, width: 14, height: 12)).fill()
        }
    }

    private static func drawGlow() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 1, alpha: 0.9).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawRadialGradient(grad, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                                                 endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
            }
        }
    }

    private static func drawDot() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 16, height: 16)).fill()
        }
    }

    /// Incident pin: a white disc with a red ring and an exclamation mark.
    private static func drawMarker() -> UIImage {
        let size = CGSize(width: 48, height: 48)
        return UIGraphicsImageRenderer(size: size).image { _ in
            Theme.ui(.signalRed).setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 44, height: 44)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 34, height: 34)).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .black)
            if let sym = UIImage(systemName: "exclamationmark", withConfiguration: cfg)?
                .withTintColor(Theme.ui(.signalRed), renderingMode: .alwaysOriginal) {
                let s = sym.size
                sym.draw(in: CGRect(x: (48 - s.width) / 2, y: (48 - s.height) / 2, width: s.width, height: s.height))
            }
        }
    }
}
