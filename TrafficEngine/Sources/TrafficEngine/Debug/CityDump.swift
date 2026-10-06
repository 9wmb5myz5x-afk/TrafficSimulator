//
//  CityDump.swift
//  TrafficEngine
//
//  SVG snapshot of a running simulation: terrain, network, signals, vehicles.
//

public extension SVGRenderer {
    static let vehiclePalette = ["#F4F2EE", "#C9CCD1", "#8E949B", "#3B4046", "#5A7FA6", "#A65A5A", "#6F8F72", "#C7B07A"]

    static func cityDump(_ sim: Simulation, options: SVGOptions = SVGOptions()) -> String {
        var extra = SVGExtra()
        for f in sim.terrain.features {
            let fill = f.kind == .water ? "#BFE3E0" : (f.kind == .park ? "#CFE3B8" : "#F1E2B8")
            extra.polygons.append((f.polygon, fill, fill))
        }
        var signals: [(Vector2, String)] = []
        for n in sim.network.allNodes where n.effectiveControl == .signal {
            for e in sim.network.incoming(n.id) {
                guard let edge = sim.network.edge(e) else { continue }
                let head = sim.signals.headState(edge: e, network: sim.network)
                let lanes = edge.lanesAtEnd
                guard let outer = lanes.map({ $0.lateral }).max(by: { abs($0) < abs($1) }) else { continue }
                let p = edge.position(s: edge.length - 1, lateral: outer + (outer < 0 ? -2.5 : 2.5))
                func color(_ s: SignalIndication) -> String {
                    switch s { case .green: return "#3FB96A"; case .permissive: return "#E8B54A"; case .yellow: return "#F2C230"; case .red: return "#E05050" }
                }
                signals.append((p, color(head.through)))
            }
        }
        let vehicles = sim.vehicles.filter { $0.mode != .finished && $0.mode != .waitingToEnter }.map { v -> SVGVehicle in
            let fill = v.cls == .police ? "#FFFFFF" : (v.cls == .bus ? "#3E7CB1" : vehiclePalette[v.colorIndex % vehiclePalette.count])
            return SVGVehicle(box: v.footprint, fill: fill, blinker: v.blinker(side: sim.side) == 2 ? 0 : v.blinker(side: sim.side),
                              braking: v.braking, siren: v.siren)
        }
        return render(sim.network, vehicles: vehicles, extra: extra, signals: signals, options: options)
    }
}
