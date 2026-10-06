//
//  FastEquality.swift
//  TrafficEngine
//
//  Enums with String raw values get `==`, `!=` and `hash(into:)` from the
//  standard library's RawRepresentable defaults, which compare and hash the
//  *strings*. In the step loop that was over 10 % of the time. These
//  payload-free enums compare their case tag instead (one byte), which is
//  equivalent: two values are equal exactly when their cases are.
//

@inline(__always)
func caseTag<T>(_ x: T) -> UInt8 {
    withUnsafeBytes(of: x) { $0.isEmpty ? 0 : $0[0] }
}


extension SignalIndication {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension SignalState.Interval {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension SimEvent.Kind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension ScenarioKind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension InvariantViolation.Kind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension EditKind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension RoadClass {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension LaneKind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension MarkingKind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension ControlType {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension AcrossTurnMode {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension SignalMode {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension TerrainFeature.Kind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension PoliceUnitStatus {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension IncidentStatus {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension LevelOfService {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension DrivingSide {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension TurnDirection {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension BuildingKind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension PersonRole {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension CityMode {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension LaneChange.Phase {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension VehicleMode {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension TripPurpose {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension Destination.Kind {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}

extension VehicleClass {
    @inline(__always) public static func == (a: Self, b: Self) -> Bool { caseTag(a) == caseTag(b) }
    @inline(__always) public static func != (a: Self, b: Self) -> Bool { caseTag(a) != caseTag(b) }
    @inline(__always) public func hash(into h: inout Hasher) { h.combine(caseTag(self)) }
}
