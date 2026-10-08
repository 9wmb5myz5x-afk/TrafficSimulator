//
//  GameController.swift
//  TrafficSimulator
//
//  The bridge between the headless engine and the UI.
//
//  Threading: the `Simulation` lives on a private serial queue and is only
//  ever touched there. A 60 Hz timer on that queue advances it in fixed
//  steps to keep pace with wall-clock time × the speed setting, then pushes
//  an immutable snapshot into a double buffer that the renderer interpolates.
//  UI edits are queued as commands and applied between steps.
//

import Foundation
import QuartzCore
import Combine
import TrafficEngine

/// What a new city is made from.
struct CitySetup: Equatable {
    var scenario: ScenarioKind = .signalGrid
    var side: DrivingSide = .right
    var seed: UInt64 = 1
    /// Clock hour the city opens at (UI tests use -startHour for night shots).
    var startHour: Double = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-startHour"), i + 1 < args.count, let h = Double(args[i + 1]) { return h }
        return 6.5
    }()
}

/// The HUD's numbers (see `GameController.hudModel`).
final class HUDModel: ObservableObject {
    @Published var metrics = HUDMetrics()
}

/// The selected thing's live details (see `GameController.inspectorModel`).
final class InspectorModel: ObservableObject {
    @Published var info: InspectorInfo?
}

final class GameController: ObservableObject {

    // MARK: Published UI state (main thread)
    /// The HUD's numbers live in their own model: they change four times a
    /// second, and only the HUD should redraw for that (not the whole screen).
    let hudModel = HUDModel()
    var hud: HUDMetrics { hudModel.metrics }
    /// The traffic dial's level (changes rarely; drives the map button).
    @Published private(set) var trafficLevel = 1.0
    @Published var isPaused = false { didSet { syncRunState() } }
    @Published var speed: Double = 1 { didSet { syncRunState() } }
    @Published private(set) var scenarioName: String
    @Published private(set) var setup: CitySetup
    @Published var overlay: MapOverlay = .none { didSet { syncRunState() } }
    @Published private(set) var selection: EntityRef?
    /// What is selected, for layout: changes only when the selection does.
    /// Its live numbers (a moving car's speed…) go to `inspectorModel`, so
    /// only the card redraws as they change.
    @Published private(set) var inspector: InspectorInfo? {
        didSet { inspectorModel.info = inspector }
    }
    let inspectorModel = InspectorModel()
    /// The active build tool and its options.
    @Published var tool: BuildTool = .inspect { didSet { if tool != .inspect { clearSelection() } } }
    @Published var roadOptions = RoadOptions()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// The latest edit result (toast + haptic + ghost).
    @Published private(set) var feedback: EditFeedback?
    /// The city's name (save file name).
    @Published private(set) var cityName: String {
        didSet { let n = cityName; simQueue.async { [weak self] in self?.runCityName = n } }
    }
    @Published private(set) var lastSaved: Date?

    let buffer = SnapshotBuffer()
    /// Frame / queue-latency probe (UI tests, `-perfProbe`).
    let probe = PerfProbe()

    // MARK: Simulation (sim queue only)
    private let simQueue = DispatchQueue(label: "traffic.sim", qos: .userInitiated)
    private var sim: Simulation
    private var editor: Editor
    private let ioQueue = DispatchQueue(label: "traffic.io", qos: .utility)
    private var lastAutosaveHour = -1
    private var runCityName = ""
    private var feedbackCounter = 0
    private var timer: DispatchSourceTimer?
    private var lastTick: CFTimeInterval = 0
    private var accumulator = 0.0
    private var publishedNetwork = -1
    private var publishedCity = -1
    private var hudTimer = 0.0
    private var overlayTimer = 0.0
    private var stepMsEMA = 0.0
    // Mirrors of the run state, read on the sim queue.
    private var runPaused = false
    private var runSpeed = 1.0
    private var runOverlay: MapOverlay = .none
    private var runSelection: EntityRef?

    init(setup: CitySetup = CitySetup()) {
        self.setup = setup
        let sim = GameController.makeSimulation(setup)
        self.sim = sim
        editor = Editor(sim: sim)
        scenarioName = setup.scenario.displayName
        cityName = GameController.defaultName(setup)
        runCityName = cityName
        lastAutosaveHour = Int(sim.clock / 3600)
        simQueue.async { [weak self] in self?.publishGeometryIfNeeded(force: true) }
    }

    /// Open a restored city.
    init(restored sim: Simulation, name: String) {
        setup = CitySetup(scenario: .emptyLand, side: sim.side, seed: sim.config.seed)
        self.sim = sim
        editor = Editor(sim: sim)
        scenarioName = name
        cityName = name
        runCityName = name
        lastAutosaveHour = Int(sim.clock / 3600)
        simQueue.async { [weak self] in self?.publishGeometryIfNeeded(force: true) }
    }

    static func defaultName(_ s: CitySetup) -> String {
        s.scenario == .emptyLand ? "New Town \(s.seed)" : "\(s.scenario.displayName) \(s.seed)"
    }

    private static func makeSimulation(_ setup: CitySetup) -> Simulation {
        var cfg = SimulationConfig()
        cfg.seed = setup.seed
        cfg.startClock = setup.startHour * 3600     // default: the morning build-up
        return ScenarioFactory.make(setup.scenario, side: setup.side, seed: setup.seed, config: cfg)
    }

    deinit { timer?.cancel() }

    // MARK: Run control

    func start() {
        guard timer == nil else { return }
        probe.start { [weak self] done in self?.simQueue.async(execute: done) }
        let t = DispatchSource.makeTimerSource(queue: simQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        lastTick = CACurrentMediaTime()
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Replace the city (title screen → New City).
    func newCity(_ s: CitySetup) {
        setup = s
        scenarioName = s.scenario.displayName
        cityName = GameController.defaultName(s)
        replace(with: nil, setup: s)
    }

    /// Swap in a restored simulation (Load).
    func open(restored sim: Simulation, name: String) {
        scenarioName = name
        cityName = name
        replace(with: sim, setup: nil)
    }

    private func replace(with restored: Simulation?, setup s: CitySetup?) {
        selection = nil
        inspector = nil
        tool = .inspect
        canUndo = false
        canRedo = false
        lastSaved = nil
        simQueue.async { [weak self] in
            guard let self else { return }
            self.sim = restored ?? GameController.makeSimulation(s ?? CitySetup())
            self.outskirtsCache = nil
            self.renderCache = nil
            self.drivewayCacheGeometry = -1
            self.drivewayCache.removeAll()
            self.editor = Editor(sim: self.sim)
            self.lastAutosaveHour = Int(self.sim.clock / 3600)
            self.accumulator = 0
            self.runSelection = nil
            self.buffer.setHighlight([])
            self.publishGeometryIfNeeded(force: true)
            self.buffer.push(self.makeSnapshot(wallTime: CACurrentMediaTime()))
        }
    }

    private func syncRunState() {
        let paused = isPaused, speed = self.speed, overlay = self.overlay
        simQueue.async { [weak self] in
            guard let self else { return }
            self.runPaused = paused
            self.runSpeed = speed
            if self.runOverlay != overlay {
                self.runOverlay = overlay
                self.overlayTimer = 99   // refresh now
            }
        }
    }

    /// Apply an edit to the simulation between steps.
    func perform(_ body: @escaping (Simulation) -> Void) {
        simQueue.async { [weak self] in
            guard let self else { return }
            body(self.sim)
            self.publishGeometryIfNeeded(force: false)
        }
    }

    /// Run a read-only query on the sim queue and deliver the result on main.
    func query<T>(_ body: @escaping (Simulation) -> T, completion: @escaping (T) -> Void) {
        simQueue.async { [weak self] in
            guard let self else { return }
            let r = body(self.sim)
            DispatchQueue.main.async { completion(r) }
        }
    }

    // MARK: Editing (tools)

    /// A tap with the active tool at a world point.
    func toolTap(at p: Vector2, radius: Double) {
        let tool = self.tool, options = roadOptions
        edit { ed, sim -> EditFeedback in
            switch tool {
            case .inspect, .drawRoad, .moveJunction:
                return EditFeedback(id: 0, message: "", ok: true)
            case .building(let kind):
                switch ed.placeBuilding(kind, near: p, search: 14) {
                case .success(let id):
                    let at = sim.city.building(id)?.center ?? p
                    return EditFeedback(id: 0, message: "\(kind.displayName) placed", ok: true, at: at, size: kind.size.width)
                case .failure(let e):
                    return EditFeedback(id: 0, message: e.rawValue, ok: false, at: p, size: kind.size.width)
                }
            case .bulldoze:
                try ed.bulldoze(at: p, radius: radius)
                return EditFeedback(id: 0, message: "Removed", ok: true, at: p)
            case .restyleRoad:
                guard let r = GameController.road(near: p, radius: radius, in: sim) else { throw EditError.nothingThere }
                try ed.changeRoad(r, roadClass: options.roadClass, lanes: options.lanes, oneWay: options.oneWay)
                return EditFeedback(id: 0, message: "Road changed to \(options.roadClass.paletteName.lowercased())", ok: true, at: p)
            case .pockets:
                guard let r = GameController.road(near: p, radius: radius, in: sim) else { throw EditError.nothingThere }
                try ed.toggleTurnPockets(r)
                let on = sim.network.road(r)?.turnPockets ?? false
                return EditFeedback(id: 0, message: on ? "Turn pockets on" : "Turn pockets off", ok: true, at: p)
            case .control(let c):
                guard let n = GameController.junction(near: p, radius: radius + 10, in: sim) else { throw EditError.nothingThere }
                if c == .roundabout {
                    try ed.makeRoundabout(at: n)
                } else {
                    try ed.setControl(n, to: c, locked: c != .auto)
                }
                return EditFeedback(id: 0, message: c == .auto ? "Control set to automatic" : "\(c.displayName) set", ok: true,
                                    at: sim.network.node(n)?.position ?? p)
            }
        }
    }

    /// What the road being drawn would do, worked out as the finger moves
    /// (main thread; nil when not drawing).
    @Published private(set) var roadPreview: RoadPreview?
    private var previewActive = false
    private var previewBusy = false
    private var previewQueued: [Vector2]?

    /// Ask for a preview of a road along `points` (nil: drawing finished).
    /// One preview runs at a time; the latest request waits its turn.
    func previewRoad(_ points: [Vector2]?) {
        guard let points else {
            previewActive = false
            previewQueued = nil
            roadPreview = nil
            return
        }
        previewActive = true
        if previewBusy { previewQueued = points; return }
        previewBusy = true
        let o = roadOptions
        simQueue.async { [weak self] in
            guard let self else { return }
            let result = self.editor.previewRoad(points, roadClass: o.roadClass, lanes: o.lanes, oneWay: o.oneWay)
            DispatchQueue.main.async {
                self.previewBusy = false
                if self.previewActive { self.roadPreview = result }
                // The latest request, after a breath (the simulation shares the queue).
                if self.previewQueued != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        guard let q = self.previewQueued else { return }
                        self.previewQueued = nil
                        self.previewRoad(q)
                    }
                }
            }
        }
    }

    /// A finished drag with the road tool.
    func drawRoad(_ points: [Vector2]) {
        let o = roadOptions
        edit { ed, _ -> EditFeedback in
            do {
                let preview = ed.previewRoad(points, roadClass: o.roadClass, lanes: o.lanes, oneWay: o.oneWay)
                try ed.drawRoad(points, roadClass: o.roadClass, lanes: o.lanes, oneWay: o.oneWay)
                return EditFeedback(id: 0, message: preview.builtMessage, ok: true,
                                    path: preview.centrelines.isEmpty ? points : preview.centrelines.flatMap { $0 })
            } catch {
                return EditFeedback(id: 0, message: GameController.message(for: error), ok: false, path: points)
            }
        }
    }

    /// A finished drag with the move tool.
    func moveJunction(from a: Vector2, to b: Vector2, radius: Double) {
        edit { ed, sim -> EditFeedback in
            guard let n = GameController.junction(near: a, radius: radius + 10, in: sim) else { throw EditError.nothingThere }
            try ed.moveJunction(n, to: b)
            return EditFeedback(id: 0, message: "Junction moved", ok: true, at: b)
        }
    }

    /// Turn the traffic dial (takes effect at once; see `Simulation.setTrafficLevel`).
    func setTrafficLevel(_ level: Double) {
        hudModel.metrics.trafficLevel = level
        trafficLevel = level
        simQueue.async { [weak self] in self?.sim.setTrafficLevel(level) }
    }

    func undo() { edit { ed, _ in ed.undo(); return EditFeedback(id: 0, message: "Undone", ok: true) } }
    func redo() { edit { ed, _ in ed.redo(); return EditFeedback(id: 0, message: "Redone", ok: true) } }

    /// Run an edit on the sim queue and publish its outcome.
    private func edit(_ body: @escaping (Editor, Simulation) throws -> EditFeedback) {
        simQueue.async { [weak self] in
            guard let self else { return }
            var fb: EditFeedback
            do { fb = try body(self.editor, self.sim) } catch { fb = EditFeedback(id: 0, message: GameController.message(for: error), ok: false) }
            self.publishGeometryIfNeeded(force: false)
            self.buffer.push(self.makeSnapshot(wallTime: CACurrentMediaTime()))
            let undo = self.editor.canUndo, redo = self.editor.canRedo
            DispatchQueue.main.async {
                self.canUndo = undo
                self.canRedo = redo
                guard !fb.message.isEmpty else { return }
                self.feedbackCounter += 1
                fb.id = self.feedbackCounter
                self.feedback = fb
            }
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? EditError { return e.rawValue }
        if let e = error as? PlacementError { return e.rawValue }
        return "That didn't work."
    }

    static func road(near p: Vector2, radius: Double, in sim: Simulation) -> RoadID? {
        if case .road(let r)? = sim.hitTest(p, radius: radius) { return r }
        return sim.network.allRoads.compactMap { r -> (RoadID, Double)? in
            guard let l = sim.network.centreline(of: r.id) else { return nil }
            return (r.id, l.project(p).distance)
        }.filter { $0.1 < radius + 6 }.min { $0.1 < $1.1 }?.0
    }

    static func junction(near p: Vector2, radius: Double, in sim: Simulation) -> NodeID? {
        sim.network.allNodes
            .filter { sim.network.degree(of: $0.id) >= 2 && !$0.isRegionalConnection }
            .map { ($0.id, $0.position.distance(to: p)) }
            .filter { $0.1 < radius }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Saving

    /// Save under `name` (Save As) or the current name.
    func save(as name: String? = nil, completion: ((String?) -> Void)? = nil) {
        if let name { cityName = name }
        let n = name ?? cityName
        writeSave(name: n, id: SaveStore.fileID(for: n), completion: completion)
    }

    /// Autosave (every in-game hour and on backgrounding).
    func autosave(wait: Bool = false) {
        writeSave(name: nil, id: SaveStore.autosaveID, wait: wait, completion: nil)
    }

    private func writeSave(name: String?, id: String, wait: Bool = false, completion: ((String?) -> Void)?) {
        let work = { [weak self] in
            guard let self else { return }
            let save = self.sim.makeSave(name: name ?? self.runCityName, savedAt: Date().timeIntervalSince1970)
            let write = {
                var err: String?
                do { try SaveStore.write(save, id: id) } catch { err = "Couldn't save: \(error.localizedDescription)" }
                DispatchQueue.main.async {
                    if err == nil && id != SaveStore.autosaveID { self.lastSaved = Date() }
                    completion?(err)
                }
            }
            // A save the player asked for is written now, at their priority (a
            // low-priority queue can starve while the device is busy rendering);
            // autosaves go to the background.
            if wait || completion != nil { write() } else { self.ioQueue.async(execute: write) }
        }
        if wait { simQueue.sync(execute: work) } else { simQueue.async(execute: work) }
    }

    // MARK: Lifecycle

    /// The app is going to the background: pause and save now.
    func enterBackground() {
        isPaused = true
        stop()
        autosave(wait: true)
    }

    /// Low memory: drop what can be rebuilt.
    func handleMemoryWarning() {
        overlay = .none
        clearSelection()
        simQueue.async { [weak self] in
            self?.buffer.pushOverlay(nil)
        }
    }

    // MARK: Selection / inspector

    /// Select whatever is at a world point (or clear the selection).
    func select(at p: Vector2, radius: Double) {
        simQueue.async { [weak self] in
            guard let self else { return }
            let hit = self.sim.hitTest(p, radius: radius)
            self.runSelection = hit
            let info = hit.flatMap { self.sim.inspect($0) }
            self.buffer.setHighlight(info?.highlight ?? [])
            DispatchQueue.main.async {
                self.selection = hit
                self.inspector = info
            }
        }
    }

    func clearSelection() {
        selection = nil
        inspector = nil
        simQueue.async { [weak self] in
            self?.runSelection = nil
            self?.buffer.setHighlight([])
        }
    }

    // MARK: Loop (sim queue)

    private func tick() {
        let now = CACurrentMediaTime()

        let real = min(now - lastTick, 0.25)
        lastTick = now
        var stepped = 0
        if !runPaused {
            accumulator += real * runSpeed
            let budgetEnd = now + 0.012
            let t0 = CACurrentMediaTime()
            while accumulator >= sim.config.dt {
                sim.step()
                accumulator -= sim.config.dt
                stepped += 1
                // Never starve the device: if we fall behind, slow down gracefully.
                if stepped % 8 == 0 && CACurrentMediaTime() > budgetEnd {
                    accumulator = min(accumulator, sim.config.dt * 4)
                    break
                }
            }
            if stepped > 0 {
                let ms = (CACurrentMediaTime() - t0) * 1000 / Double(stepped)
                stepMsEMA = stepMsEMA == 0 ? ms : stepMsEMA * 0.95 + ms * 0.05
            }
        }
        publishGeometryIfNeeded(force: false)
        let hour = Int(sim.clock / 3600)
        if hour != lastAutosaveHour {
            lastAutosaveHour = hour
            let save = sim.makeSave(name: runCityName, savedAt: Date().timeIntervalSince1970)
            ioQueue.async { try? SaveStore.write(save, id: SaveStore.autosaveID) }
        }
        if stepped > 0 || buffer.interpolated(at: now) == nil {
            buffer.push(makeSnapshot(wallTime: now))
        }
        overlayTimer += real
        if overlayTimer >= 2 {
            overlayTimer = 0
            buffer.pushOverlay(makeOverlay())
        }
        hudTimer += real
        if hudTimer >= 0.25 {
            hudTimer = 0
            let h = makeHUD()
            var info: InspectorInfo?
            if let sel = runSelection {
                info = sim.inspect(sel)
                if case .vehicle = sel { buffer.setHighlight(info?.highlight ?? []) }
                if info == nil {
                    runSelection = nil
                    buffer.setHighlight([])
                }
            }
            let stillSelected = runSelection
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.hudModel.metrics != h { self.hudModel.metrics = h }
                if self.trafficLevel != h.trafficLevel { self.trafficLevel = h.trafficLevel }
                if self.selection != nil {
                    if stillSelected == nil {
                        self.selection = nil; self.inspector = nil
                    } else if self.inspector?.title != info?.title || self.inspector?.subtitle != info?.subtitle {
                        self.inspector = info
                    } else if self.inspectorModel.info != info {
                        self.inspectorModel.info = info
                    }
                }
            }
        }
    }

    private func publishGeometryIfNeeded(force: Bool) {
        let net = sim.network
        guard force || net.version != publishedNetwork || sim.city.version != publishedCity else { return }
        publishedNetwork = net.version
        publishedCity = sim.city.version
        // Road geometry only changes with the network (not with buildings).
        if renderCache?.version != net.version {
            renderCache = (net.version, RenderGeometryBuilder.all(net), RenderGeometryBuilder.roundabouts(net))
        }
        let all = renderCache!.all
        var lo = Vector2(.infinity, .infinity), hi = Vector2(-.infinity, -.infinity)
        for r in all.roads { for p in r.surface.polygon { lo = Vector2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vector2(max(hi.x, p.x), max(hi.y, p.y)) } }
        if !lo.x.isFinite { lo = Vector2(-200, -200); hi = Vector2(200, 200) }
        // A nearly empty map: frame the whole terrain instead.
        if hi.x - lo.x < 400 || hi.y - lo.y < 400 {
            lo = Vector2(min(lo.x, sim.terrain.minCorner.x), min(lo.y, sim.terrain.minCorner.y))
            hi = Vector2(max(hi.x, sim.terrain.maxCorner.x), max(hi.y, sim.terrain.maxCorner.y))
        }
        let buildings = sim.city.buildings.map { b -> BuildingSprite in
            let size = b.kind.size
            return BuildingSprite(id: b.id.raw, kind: b.kind, center: b.center, rotation: b.rotation,
                                  width: size.width, depth: size.depth, storeys: size.height)
        }
        // The countryside and the driveways only change with the shape of the
        // roads (not with a junction's control): reuse them otherwise.
        let geometry = net.geometryVersion
        if outskirtsCache?.geometry != geometry {
            outskirtsCache = (geometry, sim.outskirts(margin: 1100))
        }
        if drivewayCacheGeometry != geometry {
            drivewayCacheGeometry = geometry
            drivewayCache.removeAll(keepingCapacity: true)
        }
        var driveways: [DrivewayStroke] = []
        var live = Set<Int>()
        for b in sim.city.buildings {
            live.insert(b.id.raw)
            let key = DrivewayKey(access: b.access, center: b.center, rotation: b.rotation, kind: b.kind)
            if let c = drivewayCache[b.id.raw], c.key == key {
                driveways += c.strokes
            } else {
                let s = sim.drivewayStrokes(for: b)
                drivewayCache[b.id.raw] = (key, s)
                driveways += s
            }
        }
        for k in drivewayCache.keys where !live.contains(k) { drivewayCache[k] = nil }
        buffer.pushGeometry(StaticGeometry(networkVersion: net.version, geometryVersion: geometry, cityVersion: sim.city.version,
                                           roads: all.roads, junctions: all.junctions,
                                           roundabouts: renderCache!.roundabouts,
                                           buildings: buildings,
                                           driveways: driveways,
                                           terrain: sim.terrain, outskirts: outskirtsCache!.value,
                                           bounds: (lo, hi)))
    }

    private struct DrivewayKey: Equatable {
        var access: BuildingAccess?
        var center: Vector2
        var rotation: Double
        var kind: BuildingKind
    }
    private var outskirtsCache: (geometry: Int, value: Outskirts)?
    private var renderCache: (version: Int, all: (roads: [RoadRenderData], junctions: [JunctionRenderData]), roundabouts: [RoundaboutRenderData])?
    private var drivewayCache: [Int: (key: DrivewayKey, strokes: [DrivewayStroke])] = [:]
    private var drivewayCacheGeometry = -1

    private func makeOverlay() -> OverlayData? {
        switch runOverlay {
        case .none:
            return nil
        case .congestion:
            var values: [Int: Double] = [:]
            for e in sim.network.allEdges {
                guard let m = sim.metrics.edge(e.id) else { continue }
                values[e.road.raw] = max(values[e.road.raw] ?? 0, m.congestion)
            }
            return OverlayData(kind: .congestion, values: values)
        case .coverage:
            var values: [Int: Double] = [:]
            for (e, t) in sim.policeCoverage() {
                guard let edge = sim.network.edge(e) else { continue }
                // 0 = reached within 1 min, 1 = 5 min or more.
                let v = min(max((t - 60) / 240, 0), 1)
                values[edge.road.raw] = min(values[edge.road.raw] ?? 1, v)
            }
            for r in sim.network.allRoads where values[r.id.raw] == nil { values[r.id.raw] = 1 }
            return OverlayData(kind: .coverage, values: values)
        }
    }

    private func makeSnapshot(wallTime: CFTimeInterval) -> RenderSnapshot {
        let side = sim.side
        var poses: [VehiclePose] = []
        poses.reserveCapacity(sim.vehicles.count)
        for v in sim.vehicles where v.mode != .finished && v.mode != .waitingToEnter {
            var flags: UInt8 = 0
            if v.braking { flags |= VehiclePose.Flag.braking }
            switch v.blinker(side: side) {
            case -1: flags |= VehiclePose.Flag.blinkLeft
            case 1: flags |= VehiclePose.Flag.blinkRight
            case 2: flags |= VehiclePose.Flag.hazard
            default: break
            }
            if v.siren { flags |= VehiclePose.Flag.siren }
            if v.mode == .parkedAtKerb { flags |= VehiclePose.Flag.parked }
            poses.append(VehiclePose(id: Int32(v.id.raw), x: Float(v.center.x), y: Float(v.center.y),
                                     heading: Float(v.heading), length: Float(v.length), width: Float(v.width),
                                     cls: v.cls, color: UInt8(v.colorIndex & 0xff), flags: flags,
                                     visibility: Float(v.visibility)))
        }
        var heads: [SignalHead] = []
        for n in sim.network.allNodes where n.effectiveControl == .signal {
            for e in sim.network.incoming(n.id) {
                guard let edge = sim.network.edge(e) else { continue }
                let state = sim.signals.headState(edge: e, network: sim.network)
                let lanes = edge.lanesAtEnd
                guard let outer = lanes.map({ $0.lateral }).max(by: { abs($0) < abs($1) }) else { continue }
                let p = edge.position(s: edge.length - 0.5, lateral: outer + (outer < 0 ? -2.6 : 2.6))
                heads.append(SignalHead(x: Float(p.x), y: Float(p.y), heading: Float(edge.reference.endTangent.angle),
                                        through: state.through, across: state.across))
            }
        }
        let incidents = sim.police.activeIncidents.compactMap { sim.city.building($0.building)?.center }
        let dayFraction = (sim.clock / 86400).truncatingRemainder(dividingBy: 1)
        return RenderSnapshot(wallTime: wallTime, simTime: sim.time, vehicles: poses, signals: heads,
                              incidents: incidents, networkVersion: sim.network.version, dayFraction: dayFraction)
    }

    private func makeHUD() -> HUDMetrics {
        let a = sim.metrics.aggregate
        var h = HUDMetrics()
        h.clock = sim.clockString
        h.day = Simulation.dayNames[sim.dayOfWeek]
        h.vehicles = a.activeVehicles
        h.population = sim.city.population
        h.averageTripMinutes = a.averageTripTime / 60
        h.averageSpeedKmh = a.averageSpeed * 3.6
        h.flowLevel = sim.metrics.history.last?.congestedShare ?? 0
        h.completedTrips = a.completedTrips
        h.simTime = sim.time
        h.activeIncidents = sim.police.activeIncidents.count
        h.responseMinutes = sim.police.meanResponseTime.map { $0 / 60 }
        h.stepMs = stepMsEMA
        h.gridlocks = sim.gridlock.activeCycles.count
        h.trafficLevel = sim.trafficLevel
        h.patrols = sim.vehicles.reduce(0) { $0 + ($1.cls == .police && $1.mode != .finished && $1.mode != .waitingToEnter ? 1 : 0) }
        return h
    }

    // MARK: Stats

    struct JunctionRow: Identifiable {
        var id: Int
        var name: String
        var los: LevelOfService
        var delay: Double
    }

    struct StatsData {
        var history: [MetricsSample]
        var junctions: [JunctionRow]
        var responseTimes: [Double]
    }

    func loadStats(_ completion: @escaping (StatsData) -> Void) {
        query({ sim -> StatsData in
            var rows: [JunctionRow] = []
            for n in sim.network.allNodes where sim.network.degree(of: n.id) >= 3 && !n.isRegionalConnection {
                guard let m = sim.metrics.junction(n.id), m.served > 0 else { continue }
                rows.append(JunctionRow(id: n.id.raw, name: "\(n.id) · \(n.effectiveControl.displayName)", los: m.los, delay: m.averageDelay))
            }
            rows.sort { $0.delay > $1.delay }
            return StatsData(history: sim.metrics.history, junctions: rows, responseTimes: sim.police.responseTimes)
        }, completion: completion)
    }
}
