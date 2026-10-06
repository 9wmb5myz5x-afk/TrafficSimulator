//
//  main.swift — trafficsim CLI
//
//  Run a scenario headless, check invariants every step, print a report and
//  optionally write SVG snapshots.
//
//  trafficsim --scenario signalGrid --side right --seed 1 --minutes 10 [--svg out.svg] [--through 240]
//
import Foundation
import TrafficEngine

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
// MARK: Soak mode: every scenario × both sides × seeds, invariants on every step.
if args.contains("--soak") {
    let hours = Double(option("hours") ?? "2") ?? 2
    let seeds = (option("seeds") ?? "1,2,3,4,5").split(separator: ",").compactMap { UInt64($0) }
    let kinds = (option("scenarios").map { $0.split(separator: ",").compactMap { ScenarioKind(rawValue: String($0)) } }) ?? ScenarioKind.allCases
    // Populated cities by default; `--empty` soaks the bare networks with
    // through traffic only (`--through`, veh/h per entry, default 240).
    let empty = args.contains("--empty")
    let through = option("through").flatMap(Double.init) ?? (empty ? 240 : nil)
    var failures = 0
    print("scenario           side   seed  simHours  maxVeh  trips  violations  stepms  pop")
    for kind in kinds {
        for side in DrivingSide.allCases {
            for seed in seeds {
                var cfg = SimulationConfig(); cfg.seed = seed
                if let d = option("demand").flatMap(Double.init) { cfg.demandMultiplier = d }
                let sim = empty
                    ? { let m = ScenarioNetworks.make(kind, side: side); return Simulation(network: m.network, terrain: m.terrain, config: cfg) }()
                    : ScenarioFactory.make(kind, side: side, seed: seed, config: cfg)
                if let through { sim.setExternalRate(perEntryPerHour: through) }
                let checker = InvariantChecker()
                sim.invariantChecker = checker
                let t0 = Date()
                let steps = Int(hours * 3600 / cfg.dt)
                for _ in 0..<steps { sim.step() }
                let ms = Date().timeIntervalSince(t0) / Double(steps) * 1000
                // Gridlocks are allowed (detected and reported) only in the stress scenario.
                let gridlocks = sim.gridlock.detected
                if checker.total > 0 || (kind != .stressCity && gridlocks > 0) { failures += 1 }
                print(String(format: "%-18@ %-6@ %4d  %8.2f  %6d  %5d  %10d  %6.3f", kind.rawValue as NSString, side.rawValue as NSString,
                             Int(seed), hours, checker.maxVehicles, sim.metrics.aggregate.completedTrips, checker.total, ms) + "  \(sim.city.population)  gridlocks=\(gridlocks)")
                for s in checker.samples.prefix(5) { print("    \(s)") }
                fflush(stdout)
            }
        }
    }
    print(failures == 0 ? "SOAK PASS" : "SOAK FAIL (\(failures) runs with violations)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: Fuzz mode: random edits while simulating, invariants on every step.
if args.contains("--fuzz") {
    let minutes = Double(option("minutes") ?? "60") ?? 60
    let every = Double(option("every") ?? "30") ?? 30
    let seeds = (option("seeds") ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
    let kinds = (option("scenarios").map { $0.split(separator: ",").compactMap { ScenarioKind(rawValue: String($0)) } })
        ?? ScenarioKind.allCases.filter { $0 != .stressCity }
    let verbose = args.contains("--verbose")
    var failures = 0
    print("scenario           side   seed  edits  rejected  maxVeh  trips  violations")
    for kind in kinds {
        for side in DrivingSide.allCases {
            for seed in seeds {
                var cfg = SimulationConfig(); cfg.seed = seed
                let sim = ScenarioFactory.make(kind, side: side, seed: seed, config: cfg)
                let checker = InvariantChecker()
                sim.invariantChecker = checker
                let editor = Editor(sim: sim)
                var fuzz = EditFuzzer(seed: seed)
                let steps = Int(minutes * 60 / cfg.dt)
                let editEvery = max(1, Int(every / cfg.dt))
                var lastTotal = 0
                for k in 0..<steps {
                    if k % editEvery == editEvery - 1 {
                        let what = fuzz.edit(editor)
                        if verbose { print(String(format: "  t=%.1f ", sim.time) + what) }
                    }
                    sim.step()
                    if verbose && checker.total != lastTotal {
                        lastTotal = checker.total
                        if let s = checker.samples.last { print("    ! \(s)") }
                    }
                }
                if checker.total > 0 { failures += 1 }
                print(String(format: "%-18@ %-6@ %4d  %5d  %8d  %6d  %5d  %10d", kind.rawValue as NSString, side.rawValue as NSString,
                             Int(seed), fuzz.applied, fuzz.rejected, checker.maxVehicles, sim.metrics.aggregate.completedTrips, checker.total))
                for s in checker.samples.prefix(5) { print("    \(s)") }
                fflush(stdout)
            }
        }
    }
    print(failures == 0 ? "FUZZ PASS" : "FUZZ FAIL (\(failures) runs with violations)")
    exit(failures == 0 ? 0 : 1)
}

let kind = ScenarioKind(rawValue: option("scenario") ?? "signalGrid") ?? .signalGrid
let side = DrivingSide(rawValue: option("side") ?? "right") ?? .right
var config = SimulationConfig()
config.seed = UInt64(option("seed") ?? "1") ?? 1
if let d = option("demand").flatMap(Double.init) { config.demandMultiplier = d }
let sim = args.contains("--empty")
    ? { let m = ScenarioNetworks.make(kind, side: side); return Simulation(network: m.network, terrain: m.terrain, config: config) }()
    : ScenarioFactory.make(kind, side: side, seed: config.seed, config: config)
let map = (network: sim.network, terrain: sim.terrain)
if let through = option("through").flatMap(Double.init) { sim.setExternalRate(perEntryPerHour: through) }
sim.debugForcedStops = args.contains("--debug")
let checker = InvariantChecker()
if !args.contains("--no-check") { sim.invariantChecker = checker }
let minutes = Double(option("minutes") ?? "0") ?? 0

func svgOptions() -> SVGOptions {
    var opts = SVGOptions()
    opts.showConnectors = args.contains("--connectors")
    opts.showNodeIDs = args.contains("--ids")
    if let c = option("crop") {
        let v = c.split(separator: ",").compactMap { Double($0) }
        if v.count == 4 { opts.crop = (Vector2(v[0], v[1]), Vector2(v[2], v[3])) }
    }
    opts.pixelsPerMetre = Double(option("ppm") ?? "2") ?? 2
    opts.title = "\(kind.rawValue) · \(side.rawValue) · t=\(Int(sim.time))s · \(sim.clockString) · \(sim.vehicles.count) vehicles"
    return opts
}

var stageTotals = [Double](repeating: 0, count: Simulation.stageNames.count)
if args.contains("--stages") {
    var last = DispatchTime.now().uptimeNanoseconds
    sim.stageHook = { k in
        let now = DispatchTime.now().uptimeNanoseconds
        if k == 0 { last = now; return }   // stage 0 timed from the previous step's end is noise: skip
        stageTotals[k] += Double(now - last) / 1e6
        last = now
    }
}
let start = Date()
var windowStart = Date()
var hash = TraceHasher()
let steps = Int(minutes * 60 / config.dt)
let watch = option("watch").flatMap(Int.init).map { VehicleID($0) }
let watchFrom = Double(option("watch-from") ?? "0") ?? 0
for k in 0..<steps {
    sim.step()
    if let w = watch, sim.time >= watchFrom, sim.time <= watchFrom + 20, let v = sim.vehicle(w) {
        print(String(format: "t=%.2f %@ s=%.2f lat=%.2f v=%.2f front=(%.2f,%.2f) mode=%@ need=%d lc=%@ next=%@", sim.time, "\(v.track)" as NSString, v.s, v.lateral, v.speed, v.front.x, v.front.y, v.mode.rawValue as NSString, Int(v.laneNeed), (v.laneChange.map { "\($0.phase.rawValue)->\($0.toLane)" } ?? "-") as NSString, (v.nextRouteEdge.map { "\($0)" } ?? "-") as NSString))
    }
    if k % 20 == 0 { hash.combine(sim.traceHash()) }
    if k % Int(60 / config.dt) == 0 && args.contains("--progress") {
        let now = Date()
        let ms = now.timeIntervalSince(windowStart) / (60 / config.dt) * 1000
        windowStart = now
        print("t=\(Int(sim.time))s clock=\(sim.clockString) vehicles=\(sim.vehicles.count) trips=\(sim.metrics.aggregate.completedTrips) step=\(String(format: "%.3f", ms))ms \(checker.summary())")
        fflush(stdout)
    }
}
let elapsed = Date().timeIntervalSince(start)

if let out = option("svg") {
    try SVGRenderer.cityDump(sim, options: svgOptions()).write(toFile: out, atomically: true, encoding: .utf8)
}
let a = sim.metrics.aggregate
print("scenario=\(kind.rawValue) side=\(side.rawValue) seed=\(config.seed) simTime=\(Int(sim.time))s wall=\(String(format: "%.2f", elapsed))s steps=\(steps)")
if steps > 0 { print(String(format: "step time: %.3f ms avg", elapsed / Double(steps) * 1000)) }
print("vehicles=\(sim.vehicles.count) spawned=\(a.spawned) completed=\(a.completedTrips) avgTrip=\(Int(a.averageTripTime))s missedTurns=\(a.missedTurns) reroutes=\(a.reroutes) forcedStops=\(a.forcedStops)")
print("buildings=\(sim.city.buildings.count) population=\(sim.city.population) clock=\(Simulation.dayNames[sim.dayOfWeek]) \(sim.clockString)")
print("invariants: \(checker.summary())")
if args.contains("--stages") {
    let tot = stageTotals.reduce(0, +)
    for (k, n) in Simulation.stageNames.enumerated() where stageTotals[k] > 0 {
        print(String(format: "  %-13@ %8.1f ms  %5.1f%%", n as NSString, stageTotals[k], stageTotals[k] / tot * 100))
    }
}
print(sim.policeSummary())
if args.contains("--hourly") {
    let d = sim.metrics.state.departuresByClockHour
    print("departures by clock hour (day 0): " + (0..<24).map { "\($0):\(d[$0])" }.joined(separator: " "))
}
let shown = option("show").map { Set($0.split(separator: ",").map(String.init)) }
for s in checker.samples.filter({ shown?.contains($0.kind.rawValue) ?? true }).prefix(30) { print("  \(s)") }
print(String(format: "trace hash: %016llx", hash.value))
if args.contains("--events") {
    for e in sim.events.suffix(option("events").flatMap(Int.init) ?? 40) { print("  [\(Int(e.time))] \(e.kind.rawValue): \(e.text)") }
}
if let d = option("diag") {
    for x in d.split(separator: ",") { if let n = Int(x) { print("  " + sim.diagnose(VehicleID(n))) } }
}
if args.contains("--stuck") {
    let stuck = sim.vehicles.filter { $0.stationaryTime > 120 }.sorted { $0.stationaryTime > $1.stationaryTime }
    print("stuck (>120 s): \(stuck.count)")
    for v in stuck.prefix(Int(option("stuck-n") ?? "8") ?? 8) { print("  " + sim.diagnose(v.id)) }
}
if args.contains("--police") {
    for (k, u) in sim.police.units.enumerated() {
        print("  unit \(k): \(u.status.rawValue) vehicle=\(u.vehicle.map { "\($0)" } ?? "-") incident=\(u.incident.map { "\($0)" } ?? "-") timer=\(Int(u.timer))")
    }
    for i in sim.police.incidents where i.status.rawValue != "cleared" {
        print("  incident \(i.id) at \(i.building) status=\(i.status.rawValue) unit=\(i.unit.map(String.init) ?? "-") created=\(Int(i.created))")
    }
    for v in sim.vehicles where v.cls == .police { print("  " + sim.diagnose(v.id) + " siren=\(v.siren) dest=\(v.destination)") }
}
if args.contains("--queues") { print(sim.queueReport(slow: Double(option("queues") ?? "") ?? 2)) }
if args.contains("--dump") {
    for e in map.network.allEdges {
        let lanes = e.lanes.map { "\($0.index):\($0.kind.rawValue)@\(String(format: "%.2f", $0.lateral))[\(Int($0.sStart))-\(Int($0.sEnd))]\($0.movements.map { $0.rawValue }.sorted())" }
        print("\(e.id) \(e.from)->\(e.to) \(e.roadClass.rawValue) len=\(Int(e.length)) \(lanes.joined(separator: " "))")
    }
}
exit(checker.total == 0 ? 0 : 1)
