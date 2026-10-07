//
//  Theme.swift
//  TrafficSimulator
//
//  Design tokens for "soft cartographic minimalism". Every colour has a day,
//  dusk and night variant; `Theme.color(_:at:)` blends them through the day
//  so the palette shifts gently (never truly dark).
//

import SwiftUI
import UIKit

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(red: r, green: g, blue: b) }
}

enum Token: CaseIterable {
    case land, water, waterGrid, beach, park, parkTree, road, roadEdge, laneMarking, centerLine, median
    case shadow, bridge
    case residential, residentialSide, commercial, commercialSide, industrial, industrialSide
    case civic, civicSide, police, policeSide
    case signalRed, signalAmber, signalGreen, policeRed, policeBlue, headlight, window
    case uiInk, uiSurface, uiMuted, uiAccent
}

enum Theme {
    /// (day, dusk, night)
    static let table: [Token: (UInt32, UInt32, UInt32)] = [
        .land: (0xF3EBDD, 0xE9D9C8, 0x5E6472),
        .water: (0xA9DCD6, 0x93BFC4, 0x3E5967),
        .waterGrid: (0x9BD1CB, 0x86B3B8, 0x37515E),
        .beach: (0xF2E3B6, 0xE6CFA4, 0x6F6A62),
        .park: (0xCFE3B8, 0xBCCDA6, 0x4F6253),
        .parkTree: (0xA9CC8B, 0x99B87F, 0x46594A),
        .road: (0xFCFAF6, 0xF1E9E1, 0x8A909B),
        .roadEdge: (0xDDD5C7, 0xCFC1B3, 0x6F7581),
        .laneMarking: (0xC9C1B3, 0xBCAFA2, 0xA7ADB6),
        .centerLine: (0xE0B85F, 0xD4A65A, 0xB7975A),
        .median: (0xCFDDB9, 0xBFCDA8, 0x55665A),
        .shadow: (0x6B5E4E, 0x5A4C47, 0x1E222A),
        .bridge: (0xF4F0E8, 0xE8DFD5, 0x7E848F),
        .residential: (0xF0B8A0, 0xE3A792, 0x8C6C66),
        .residentialSide: (0xD9967E, 0xC98A76, 0x6E5551),
        .commercial: (0x9CC3E0, 0x8EB0CC, 0x5D6F85),
        .commercialSide: (0x7AA4C4, 0x7095B2, 0x4A5A6D),
        .industrial: (0xC6B9D8, 0xB6A8C6, 0x6E6880),
        .industrialSide: (0xA698BC, 0x988AAD, 0x585369),
        .civic: (0xF1D58A, 0xE2C27E, 0x857955),
        .civicSide: (0xD6B865, 0xC8A863, 0x6B6045),
        .police: (0x8FA6C7, 0x8296B5, 0x55637A),
        .policeSide: (0x6E86AA, 0x667C9B, 0x434F63),
        .signalRed: (0xE5534B, 0xE5534B, 0xFF5D55),
        .signalAmber: (0xF2B33D, 0xF2B33D, 0xFFC04D),
        .signalGreen: (0x3FB96A, 0x3FB96A, 0x4FD67C),
        .policeRed: (0xE5413C, 0xE5413C, 0xFF4A44),
        .policeBlue: (0x2F6BFF, 0x2F6BFF, 0x4A80FF),
        .headlight: (0xFFF6D8, 0xFFF1C6, 0xFFE9A8),
        .window: (0xFFFFFF, 0xFFE7B0, 0xFFD27A),
        .uiInk: (0x2E3A46, 0x2E3A46, 0x2E3A46),
        .uiSurface: (0xFFFFFF, 0xFFFFFF, 0xFFFFFF),
        .uiMuted: (0x7A8592, 0x7A8592, 0x7A8592),
        .uiAccent: (0x3E7CB1, 0x3E7CB1, 0x3E7CB1)
    ]

    /// Muted, realistic vehicle body colours.
    static let vehicleBodies: [UInt32] = [
        0xF4F2EE, 0xEDEBE6, 0xC9CCD1, 0xA7ADB4, 0x8E949B, 0x5B6168, 0x3B4046, 0x2B2F33,
        0x5A7FA6, 0x47668A, 0xA65A5A, 0x8C4A4A, 0x6F8F72, 0xC7B07A, 0x8A7A68, 0xD9D2C3
    ]

    /// Lighting blend for a fraction of the day: 0 = day, 1 = dusk, 2 = night.
    static func phase(dayFraction f: Double) -> Double {
        let h = f * 24
        switch h {
        case 6.5..<17.5: return 0
        case 17.5..<19.5: return (h - 17.5) / 2          // day → dusk
        case 19.5..<21: return 1 + (h - 19.5) / 1.5      // dusk → night
        case 21..<24, 0..<5: return 2
        case 5..<6.5: return 2 - (h - 5) / 1.5 * 2       // night → day
        default: return 0
        }
    }

    static func rgb(_ t: Token, phase p: Double = 0) -> RGB {
        let (d, k, n) = table[t] ?? (0xFF00FF, 0xFF00FF, 0xFF00FF)
        if p <= 0 { return RGB(d) }
        if p <= 1 { return RGB(d).mix(RGB(k), p) }
        return RGB(k).mix(RGB(n), min(p - 1, 1) * 0.85)   // never fully night: stays readable
    }

    static func ui(_ t: Token, phase p: Double = 0) -> UIColor { rgb(t, phase: p).ui }
    static func color(_ t: Token) -> Color { rgb(t).color }
}

/// Spacing, radius and shadow tokens.
enum Metrics {
    static let gutter: CGFloat = 16
    static let spacing: CGFloat = 10
    static let radiusSmall: CGFloat = 10
    static let radius: CGFloat = 16
    static let radiusLarge: CGFloat = 24
    static let buttonSize: CGFloat = 52
    /// Round map buttons (side column).
    static let mapButton: CGFloat = 46
    static let shadowRadius: CGFloat = 10
    static let shadowY: CGFloat = 4
}

extension Font {
    /// Heavy rounded display face for the HUD.
    static func hud(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func hudLabel(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

extension View {
    /// Floating chrome: white surface, soft shadow, rounded.
    func floatingSurface(radius: CGFloat = Metrics.radius) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.color(.uiSurface).opacity(0.94)))
            .shadow(color: Color.black.opacity(0.12), radius: Metrics.shadowRadius, x: 0, y: Metrics.shadowY)
    }
}
