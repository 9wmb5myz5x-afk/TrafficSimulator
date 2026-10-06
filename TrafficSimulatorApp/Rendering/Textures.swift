//
//  Textures.swift
//  TrafficSimulator
//
//  Procedural textures, drawn once with UIKit and packed into one atlas so
//  SpriteKit can batch every vehicle into a few draw calls.
//
//  Vehicle bodies are drawn white (tinted per car via colorBlendFactor) with
//  a lighter roof and darker glass, each class with its own silhouette.
//  Police cars are drawn in their black-and-white livery and never tinted.
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
        for cls in VehicleClass.allCases { images["veh.\(cls.rawValue)"] = drawVehicle(cls) }
        for kind in BuildingKind.allCases { images["roof.\(kind.rawValue)"] = drawRoof(kind) }
        images["tree"] = drawTree()
        images["glow"] = drawGlow()
        images["dot"] = drawDot()
        images["marker"] = drawMarker()
        atlas = SKTextureAtlas(dictionary: images)
    }

    // MARK: Vehicles (drawn facing +x)

    private static func drawVehicle(_ cls: VehicleClass) -> UIImage {
        let len = CGFloat(cls.length) * ppm, wid = CGFloat(cls.width) * ppm
        let size = CGSize(width: len + 2, height: wid + 2)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let body = CGRect(x: 1, y: 1, width: len, height: wid)
            let r = min(wid * 0.38, len * 0.2)
            let police = cls == .police
            // Body.
            (police ? UIColor(white: 0.12, alpha: 1) : UIColor.white).setFill()
            UIBezierPath(roundedRect: body, cornerRadius: r).fill()
            if police {
                // White doors band.
                UIColor.white.setFill()
                UIBezierPath(rect: CGRect(x: 1 + len * 0.32, y: 1, width: len * 0.36, height: wid)).fill()
            }
            func glass(_ x0: CGFloat, _ w: CGFloat) {
                UIColor(red: 0.20, green: 0.25, blue: 0.30, alpha: 0.55).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1 + len * x0, y: 1 + wid * 0.16, width: len * w, height: wid * 0.68),
                             cornerRadius: wid * 0.12).fill()
            }
            func roof(_ x0: CGFloat, _ w: CGFloat, shade: CGFloat = 0.9) {
                UIColor(white: shade, alpha: 0.9).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1 + len * x0, y: 1 + wid * 0.2, width: len * w, height: wid * 0.6),
                             cornerRadius: wid * 0.12).fill()
            }
            switch cls {
            case .car:
                glass(0.24, 0.52); roof(0.34, 0.3)
            case .suv:
                glass(0.18, 0.62); roof(0.26, 0.46)
            case .van:
                glass(0.62, 0.14); roof(0.08, 0.52, shade: 0.94)
            case .truck:
                // Box body (lighter) and cab at the front.
                UIColor(white: 0.97, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: len * 0.72, height: wid), cornerRadius: r * 0.4).fill()
                UIColor(white: 0.82, alpha: 1).setStroke()
                g.setLineWidth(1)
                for k in 1...3 {
                    let x = 1 + len * 0.72 * CGFloat(k) / 4
                    g.move(to: CGPoint(x: x, y: 3)); g.addLine(to: CGPoint(x: x, y: wid - 1)); g.strokePath()
                }
                glass(0.80, 0.1)
            case .bus:
                // Long glass band and roof units.
                UIColor(red: 0.20, green: 0.25, blue: 0.30, alpha: 0.45).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1 + len * 0.04, y: 1 + wid * 0.12, width: len * 0.92, height: wid * 0.76),
                             cornerRadius: wid * 0.1).fill()
                roof(0.08, 0.84, shade: 0.96)
                UIColor(white: 0.85, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1 + len * 0.3, y: 1 + wid * 0.32, width: len * 0.18, height: wid * 0.36), cornerRadius: 2).fill()
            case .police:
                glass(0.22, 0.54)
                // Light bar (the renderer flashes red/blue sprites over it).
                UIColor(white: 0.25, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 1 + len * 0.46, y: 1 + wid * 0.12, width: len * 0.08, height: wid * 0.76), cornerRadius: 2).fill()
            }
            // Headlights (front) and rear lamps (dim; the renderer brightens them).
            UIColor(white: 1, alpha: 0.9).setFill()
            UIBezierPath(ovalIn: CGRect(x: len - 3, y: 1 + wid * 0.12, width: 3, height: 3)).fill()
            UIBezierPath(ovalIn: CGRect(x: len - 3, y: wid - 2.5, width: 3, height: 3)).fill()
            UIColor(red: 0.55, green: 0.12, blue: 0.10, alpha: 0.8).setFill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: 1 + wid * 0.1, width: 2, height: 3), cornerRadius: 1).fill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: wid - 3, width: 2, height: 3), cornerRadius: 1).fill()
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
