//
//  RenderSnapshot.swift
//  TrafficSimulator
//
//  Immutable state handed from the simulation queue to the renderer. The
//  renderer never touches the engine: it reads the latest two snapshots and
//  interpolates vehicle poses between them for smooth motion.
//

import Foundation
import QuartzCore
import TrafficEngine

struct VehiclePose: Equatable {
    var id: Int32
    var x: Float
    var y: Float
    var heading: Float
    var length: Float
    var width: Float
    var cls: VehicleClass
    var color: UInt8
    /// Bit flags: see `VehiclePose.Flag`.
    var flags: UInt8
    /// 0…1: fades going into / coming out of a garage.
    var visibility: Float = 1

    enum Flag {
        static let braking: UInt8 = 1
        static let blinkLeft: UInt8 = 2
        static let blinkRight: UInt8 = 4
        static let siren: UInt8 = 8
        static let hazard: UInt8 = 16
        static let parked: UInt8 = 32
    }
}

struct SignalHead: Equatable {
    var x: Float
    var y: Float
    var heading: Float
    var through: SignalIndication
    var across: SignalIndication
}

struct HUDMetrics: Equatable {
    var clock = "06:30"
    var day = "Mon"
    var vehicles = 0
    var population = 0
    var averageTripMinutes = 0.0
    var averageSpeedKmh = 0.0
    var flowLevel = 0.0          // 0 = free, 1 = jammed
    var completedTrips = 0
    var simTime = 0.0
    var activeIncidents = 0
    var responseMinutes: Double?
    var stepMs = 0.0
    var gridlocks = 0
    /// Police cars out on the road.
    var patrols = 0
    /// The traffic dial (1 = normal).
    var trafficLevel = 1.0
}

/// A building as the renderer draws it.
struct BuildingSprite: Equatable {
    var id: Int
    var kind: BuildingKind
    var center: Vector2
    var rotation: Double
    var width: Double
    var depth: Double
    var storeys: Double
}

/// Static map geometry, rebuilt only when the network or the buildings change.
struct StaticGeometry {
    var networkVersion: Int
    /// Changes only with the shape of the roads (see `RoadNetwork.geometryVersion`).
    var geometryVersion: Int
    var cityVersion: Int
    var roads: [RoadRenderData]
    var junctions: [JunctionRenderData]
    var roundabouts: [RoundaboutRenderData]
    var buildings: [BuildingSprite]
    /// Driveway paving (a few strokes per building).
    var driveways: [DrivewayStroke]
    var terrain: Terrain
    /// The countryside around the map (scenery).
    var outskirts: Outskirts
    var bounds: (min: Vector2, max: Vector2)
}

enum MapOverlay: String, CaseIterable, Identifiable {
    case none, congestion, coverage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Map"
        case .congestion: return "Congestion"
        case .coverage: return "Police coverage"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "map"
        case .congestion: return "car.2.fill"
        case .coverage: return "shield.lefthalf.filled"
        }
    }
}

/// Per-road overlay values 0…1 (0 = good, 1 = bad), refreshed every couple of seconds.
struct OverlayData {
    var kind: MapOverlay
    var values: [Int: Double]       // road raw id → value
}

struct RenderSnapshot {
    var wallTime: CFTimeInterval
    var simTime: Double
    var vehicles: [VehiclePose]          // sorted by id
    var signals: [SignalHead]
    var incidents: [Vector2]             // buildings with an open incident
    var networkVersion: Int
    var dayFraction: Double              // 0…1 through the day (for lighting)
}

/// Lock-protected double buffer shared between the sim queue and the main thread.
final class SnapshotBuffer {
    private let lock = NSLock()
    private var previous: RenderSnapshot?
    private var current: RenderSnapshot?
    private var geometry: StaticGeometry?
    private var overlay: OverlayData?
    private var highlight: [Vector2] = []

    func push(_ s: RenderSnapshot) {
        lock.lock(); previous = current; current = s; lock.unlock()
    }

    func pushGeometry(_ g: StaticGeometry) {
        lock.lock(); geometry = g; lock.unlock()
    }

    func latestGeometry() -> StaticGeometry? {
        lock.lock(); defer { lock.unlock() }
        return geometry
    }

    func pushOverlay(_ o: OverlayData?) {
        lock.lock(); overlay = o; lock.unlock()
    }

    func latestOverlay() -> OverlayData? {
        lock.lock(); defer { lock.unlock() }
        return overlay
    }

    func setHighlight(_ h: [Vector2]) {
        lock.lock(); highlight = h; lock.unlock()
    }

    func latestHighlight() -> [Vector2] {
        lock.lock(); defer { lock.unlock() }
        return highlight
    }

    /// Vehicles interpolated for display at `renderTime` (one snapshot behind real time).
    func interpolated(at renderTime: CFTimeInterval) -> (vehicles: [VehiclePose], signals: [SignalHead], incidents: [Vector2], dayFraction: Double)? {
        lock.lock()
        let a = previous, b = current
        lock.unlock()
        guard let cur = b else { return nil }
        guard let prev = a, cur.wallTime > prev.wallTime else { return (cur.vehicles, cur.signals, cur.incidents, cur.dayFraction) }
        let span = cur.wallTime - prev.wallTime
        let alpha = Float(((renderTime - span) - prev.wallTime) / span).clamped(0, 1)
        var out: [VehiclePose] = []
        out.reserveCapacity(cur.vehicles.count)
        var j = 0
        for v in cur.vehicles {
            while j < prev.vehicles.count && prev.vehicles[j].id < v.id { j += 1 }
            if j < prev.vehicles.count && prev.vehicles[j].id == v.id {
                let p = prev.vehicles[j]
                var w = v
                w.x = p.x + (v.x - p.x) * alpha
                w.y = p.y + (v.y - p.y) * alpha
                var dh = v.heading - p.heading
                if dh > .pi { dh -= 2 * .pi }
                if dh < -.pi { dh += 2 * .pi }
                w.heading = p.heading + dh * alpha
                w.visibility = p.visibility + (v.visibility - p.visibility) * alpha
                out.append(w)
            } else {
                out.append(v)
            }
        }
        return (out, cur.signals, cur.incidents, cur.dayFraction)
    }
}

extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(self, lo), hi) }
}
