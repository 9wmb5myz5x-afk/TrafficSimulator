//
//  VehicleClass.swift
//  TrafficEngine
//
//  Physical vehicle classes with their own dimensions and performance.
//

public enum VehicleClass: String, Codable, Sendable, CaseIterable {
    public var displayName: String {
        switch self {
        case .car: return "Car"
        case .suv: return "SUV"
        case .van: return "Van"
        case .truck: return "Truck"
        case .bus: return "Bus"
        case .police: return "Police car"
        }
    }

    case car, suv, van, truck, bus, police

    /// Body length [m].
    public var length: Double {
        switch self {
        case .car: return 4.5
        case .suv: return 4.9
        case .van: return 5.3
        case .truck: return 8.5
        case .bus: return 12.0
        case .police: return 4.9
        }
    }

    /// Body width [m] (without mirrors).
    public var width: Double {
        switch self {
        case .car: return 1.82
        case .suv: return 1.95
        case .van: return 2.0
        case .truck: return 2.5
        case .bus: return 2.55
        case .police: return 1.95
        }
    }

    /// Maximum acceleration a_max [m/s²].
    public var maxAcceleration: Double {
        switch self {
        case .car: return 1.8
        case .suv: return 1.7
        case .van: return 1.4
        case .truck: return 0.9
        case .bus: return 0.8
        case .police: return 2.4
        }
    }

    /// Comfortable deceleration b [m/s²].
    public var comfortableDeceleration: Double {
        switch self {
        case .car, .suv, .police: return 2.3
        case .van: return 2.0
        case .truck: return 1.7
        case .bus: return 1.5
        }
    }

    /// Fraction of the speed limit this class may aim for on highways.
    public var speedCap: Double {
        switch self {
        case .truck, .bus: return 0.9
        default: return 1.25
        }
    }

    public var isHeavy: Bool { self == .truck || self == .bus }
}
