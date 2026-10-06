//
//  BuildTool.swift
//  TrafficSimulator
//
//  The build palette's tools and their options.
//

import Foundation
import TrafficEngine

enum BuildTool: Hashable {
    /// Tap to inspect (the default).
    case inspect
    /// Drag to draw a road with the current road options.
    case drawRoad
    /// Tap a road to apply the current road options (upgrade / downgrade).
    case restyleRoad
    /// Tap to place a building (snaps to the nearest plot that reaches a road).
    case building(BuildingKind)
    /// Tap a junction to override its control (`.auto` hands it back; `.roundabout` rebuilds it).
    case control(ControlType)
    /// Tap a road to toggle its turn pockets.
    case pockets
    /// Drag a junction to move it.
    case moveJunction
    /// Tap to remove a building or road.
    case bulldoze

    /// Tools whose gesture is a one-finger drag (two fingers still pan).
    var drags: Bool { self == .drawRoad || self == .moveJunction }

    var title: String {
        switch self {
        case .inspect: return "Inspect"
        case .drawRoad: return "Draw road"
        case .restyleRoad: return "Upgrade road"
        case .building(let k): return k.displayName
        case .control(let c): return c == .auto ? "Automatic control" : c.displayName
        case .pockets: return "Turn pockets"
        case .moveJunction: return "Move junction"
        case .bulldoze: return "Bulldoze"
        }
    }

    var symbol: String {
        switch self {
        case .inspect: return "hand.point.up.left.fill"
        case .drawRoad: return "scribble.variable"
        case .restyleRoad: return "arrow.up.arrow.down.circle.fill"
        case .building(let k): return k.symbol
        case .control(let c): return c.symbol
        case .pockets: return "arrow.turn.up.left"
        case .moveJunction: return "arrow.up.and.down.and.arrow.left.and.right"
        case .bulldoze: return "xmark.bin.fill"
        }
    }

    /// Stable identifier for UI tests.
    var identifier: String {
        switch self {
        case .inspect: return "tool.inspect"
        case .drawRoad: return "tool.road"
        case .restyleRoad: return "tool.restyle"
        case .building(let k): return "tool.\(k.rawValue)"
        case .control(let c): return "tool.control.\(c.rawValue)"
        case .pockets: return "tool.pockets"
        case .moveJunction: return "tool.move"
        case .bulldoze: return "tool.bulldoze"
        }
    }

    /// One-line hint shown while the tool is active.
    var hint: String {
        switch self {
        case .inspect: return "Tap anything to inspect it."
        case .drawRoad: return "Drag to draw. Crossings become junctions; water becomes a bridge."
        case .restyleRoad: return "Tap a road to apply the selected type and lanes."
        case .building: return "Tap near a road to build."
        case .control: return "Tap a junction to change how it's controlled."
        case .pockets: return "Tap a road to toggle its turn lanes."
        case .moveJunction: return "Drag a junction to move it."
        case .bulldoze: return "Tap a building or road to remove it."
        }
    }
}

/// Options for drawing / restyling roads.
struct RoadOptions: Equatable {
    var roadClass: RoadClass = .local
    var lanes = 1
    var oneWay = false

    static let classes: [RoadClass] = [.local, .collector, .arterial, .highway]
}

/// Result of an edit, for the toast, the haptic and the ghost.
struct EditFeedback: Equatable {
    var id: Int
    var message: String
    var ok: Bool
    /// Where to flash the ghost (world metres), if anywhere.
    var at: Vector2?
    var path: [Vector2] = []
    var size: Double = 12
}

extension BuildingKind {
    var symbol: String {
        switch self {
        case .house: return "house.fill"
        case .townhouse: return "house.and.flag.fill"
        case .apartment: return "building.fill"
        case .shop: return "cart.fill"
        case .office: return "building.2.fill"
        case .factory: return "shippingbox.fill"
        case .school: return "graduationcap.fill"
        case .policeStation: return "shield.lefthalf.filled"
        case .fireStation: return "flame.fill"
        case .hospital: return "cross.case.fill"
        }
    }
}

extension ControlType {
    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .uncontrolled: return "circle.dashed"
        case .yield: return "triangle"
        case .twoWayStop: return "octagon"
        case .allWayStop: return "octagon.fill"
        case .signal: return "light.beacon.max.fill"
        case .roundabout: return "arrow.triangle.2.circlepath"
        }
    }
}

extension RoadClass {
    var paletteName: String {
        switch self {
        case .local: return "Street"
        case .collector: return "Avenue"
        case .arterial: return "Boulevard"
        case .highway: return "Highway"
        case .ramp: return "Ramp"
        }
    }
}
