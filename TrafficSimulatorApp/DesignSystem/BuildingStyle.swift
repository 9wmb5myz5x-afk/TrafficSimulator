//
//  BuildingStyle.swift
//  TrafficSimulator
//
//  Per-building-type colour family and pictogram, plus vehicle details.
//

import UIKit
import TrafficEngine

extension BuildingKind {
    /// (roof, side band) colour tokens.
    var tokens: (roof: Token, side: Token) {
        switch self {
        case .house, .townhouse, .apartment: return (.residential, .residentialSide)
        case .shop, .office: return (.commercial, .commercialSide)
        case .factory: return (.industrial, .industrialSide)
        case .school, .hospital, .fireStation: return (.civic, .civicSide)
        case .policeStation: return (.police, .policeSide)
        }
    }

    /// SF Symbol drawn on the roof.
    var pictogram: String {
        switch self {
        case .house: return "house.fill"
        case .townhouse: return "building.fill"
        case .apartment: return "building.2.fill"
        case .shop: return "bag.fill"
        case .office: return "briefcase.fill"
        case .factory: return "shippingbox.fill"
        case .school: return "graduationcap.fill"
        case .policeStation: return "shield.fill"
        case .fireStation: return "flame.fill"
        case .hospital: return "cross.fill"
        }
    }
}

enum Typography {
    /// Faded, widely spaced map labels.
    static func mapLabel(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .bold).rounded
    }
}

extension UIFont {
    var rounded: UIFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
