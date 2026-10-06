//
//  DrivingSide.swift
//  TrafficEngine
//
//  Every side-dependent rule is derived from this one setting: lane offsets,
//  passing side, turn-lane assignment, which turn crosses traffic,
//  turn-on-red, and which kerb to pull over to.
//

public enum DrivingSide: String, Codable, Sendable, CaseIterable {
    /// Keep right (US, continental Europe). Default.
    case right
    /// Keep left (UK, Japan, Australia).
    case left

    /// Sign that converts a "towards the kerb" lateral distance into the
    /// engine's left-positive lateral convention. Kerb is to the right (−) for
    /// `.right`, to the left (+) for `.left`.
    @inlinable public var kerbSign: Double { self == .right ? -1 : 1 }

    /// The geometric turn that crosses opposing traffic (left for `.right`).
    public var acrossTurn: TurnDirection { self == .right ? .left : .right }
    /// The kerb-side turn (right for `.right`).
    public var kerbTurn: TurnDirection { self == .right ? .right : .left }

    /// Lateral direction (left-positive) of the passing side: overtaking happens
    /// on the left for `.right`.
    public var passingLateralSign: Double { -kerbSign }

    public var displayName: String { self == .right ? "Drive on the right" : "Drive on the left" }
}

/// Geometric classification of a movement through a junction.
public enum TurnDirection: String, Codable, Sendable, CaseIterable {
    case straight, left, right, uTurn

    /// Does this movement cross the opposing stream for the given side?
    public func isAcross(_ side: DrivingSide) -> Bool {
        self == side.acrossTurn || self == .uTurn
    }

    public func isKerbSide(_ side: DrivingSide) -> Bool { self == side.kerbTurn }
}
