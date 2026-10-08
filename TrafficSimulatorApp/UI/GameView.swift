//
//  GameView.swift
//  TrafficSimulator
//
//  Full-bleed map with floating chrome: HUD (top-left), run controls
//  (top-right), overlay + stats + menu (bottom-right), inspector card
//  (bottom-left) when something is selected.
//

import SwiftUI
import SpriteKit
import UIKit
import AudioToolbox
import TrafficEngine

struct GameView: View {
    @ObservedObject var game: GameController
    @EnvironmentObject var settings: AppSettings
    var onMenu: () -> Void = {}
    @State private var scene: CityScene = {
        let s = CityScene(size: CGSize(width: 844, height: 390))
        s.scaleMode = .resizeFill
        return s
    }()
    @State private var showStats = false
    @State private var showSave = false
    @State private var showTraffic = false
    @State private var toast: EditFeedback?
    @State private var perfReport = "running"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if PerfProbe.enabled {
                PerfProbeView(probe: game.probe)
                Text("perf")
                    .font(.system(size: 2))
                    .opacity(0.02)
                    .frame(width: 4, height: 4)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("perf.script")
                    .accessibilityValue(perfReport)
            }
            SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .accessibilityIdentifier("city.map")
                .accessibilityLabel("City map")
                .accessibilityHint("Tap to inspect; drag to pan; pinch to zoom")
            GeometryReader { geo in
                // Portrait phones put the run controls in the side column; the
                // side column splits in two when the screen is short.
                let narrow = geo.size.width < 560
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        LiveHUD(model: game.hudModel, scenario: game.scenarioName)
                        Spacer(minLength: 0)
                        if !narrow { RunControls(game: game) }
                    }
                    if settings.showDebugOverlay { LiveDebugOverlay(model: game.hudModel) }
                    if game.tool != .inspect {
                        // While drawing a road: what it will do (or why it can't).
                        Text(game.roadPreview?.summary ?? game.tool.hint)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(game.roadPreview.map { $0.ok ? Theme.color(.uiInk) : Theme.color(.signalRed) } ?? Theme.color(.uiMuted))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .floatingSurface(radius: 12)
                            .accessibilityIdentifier("tool.hint")
                    }
                    // The flexible middle band: the inspector (left) and the map
                    // buttons (right) get whatever height the top bar and palette
                    // leave, so nothing is ever pushed off-screen.
                    HStack(alignment: .bottom, spacing: 10) {
                        inspectorCard
                        Spacer(minLength: 0)
                        ViewThatFits(in: .vertical) {
                            mapActions(columns: 1, runControls: narrow)
                            mapActions(columns: 2, runControls: narrow)
                            mapActions(columns: 3, runControls: narrow)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .layoutPriority(-1)
                    if let toast {
                        FeedbackToast(feedback: toast)
                            .transition(.opacity)
                    }
                    BuildPalette(game: game)
                }
                .padding(.horizontal, narrow ? 10 : Metrics.gutter)
                .padding(.vertical, 6)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: game.inspector?.title)
        }
        .sheet(isPresented: $showStats) { StatsSheet(game: game) }
        .sheet(isPresented: $showTraffic) {
            TrafficSheet(game: game)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSave) { SaveSheet(game: game) }
        .task { if PerfProbe.enabled && PerfProbe.scripted { await runPerfScript() } }
        .onAppear {
            scene.controller = game
            scene.reduceMotion = reduceMotion
            scene.onTap = { [weak game] p, r in
                guard let game else { return }
                if game.tool == .inspect { game.select(at: p, radius: r) } else { game.toolTap(at: p, radius: r) }
            }
            scene.onDraw = { [weak game] pts, r in
                guard let game, let first = pts.first, let last = pts.last else { return }
                switch game.tool {
                case .drawRoad: game.drawRoad(pts)
                case .moveJunction: game.moveJunction(from: first, to: last, radius: r)
                default: break
                }
            }
            game.start()
        }
        .onChange(of: game.feedback) { _, f in
            guard let f else { return }
            scene.showFeedback(f)
            if settings.haptics {
                let h = UINotificationFeedbackGenerator()
                h.notificationOccurred(f.ok ? .success : .error)
            }
            // A soft click when something is built (system "Tock"; respects the mute switch).
            if settings.sound && f.ok { AudioServicesPlaySystemSound(1104) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { toast = f }
            let id = f.id
            DispatchQueue.main.asyncAfter(deadline: .now() + (f.ok ? 1.6 : 2.6)) {
                if toast?.id == id { withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { toast = nil } }
            }
        }
    }

    @ViewBuilder private var inspectorCard: some View {
        if game.inspector != nil {
            LiveInspector(model: game.inspectorModel) { game.clearSelection() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func mapActions(columns: Int, runControls: Bool) -> some View {
        MapActions(game: game, columns: columns, includeRunControls: runControls,
                   showStats: $showStats, showSave: $showSave, showTraffic: $showTraffic,
                   onRecentre: { scene.showWholeCity() }, onMenu: onMenu)
    }
}

/// Name and save the city.
struct SaveSheet: View {
    @ObservedObject var game: GameController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("City name") {
                    TextField(game.cityName, text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("save.name")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.color(.signalRed)) }
                }
                if let saved = game.lastSaved {
                    Section { Text("Last saved \(saved.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Save City")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                    .disabled(saving)
                    .accessibilityIdentifier("save.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !saving else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        saving = true
        game.save(as: n.isEmpty ? game.cityName : n) { err in
            saving = false
            if let err { error = err } else { dismiss() }
        }
    }
}

// MARK: - HUD

struct HUDView: View {
    let hud: HUDMetrics
    let scenario: String
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide
            compact
            mini
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingSurface()
        .accessibilityElement(children: .contain)
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hud.day.uppercased())
                .font(.hudLabel(11)).tracking(2)
                .foregroundStyle(Theme.color(.uiMuted))
            Text(hud.clock)
                .font(.hud(26)).monospacedDigit()
                .foregroundStyle(Theme.color(.uiInk))
                .accessibilityIdentifier("hud.clock")
                .accessibilityLabel("Time \(hud.day) \(hud.clock)")
        }
        .fixedSize()
    }

    private var vehicles: some View {
        stat("car.fill", "\(hud.vehicles)", "Vehicles on the road")
            .accessibilityIdentifier("hud.vehicles")
            .accessibilityValue("\(hud.vehicles)")
    }

    private var wide: some View {
        HStack(spacing: 14) {
            clock
            Divider().frame(height: 34)
            stat("person.2.fill", "\(hud.population)", "Population")
                .accessibilityIdentifier("hud.population")
            vehicles
            stat("clock.arrow.circlepath", String(format: "%.0f min", hud.averageTripMinutes), "Average trip time")
            FlowIndicator(level: hud.flowLevel)
            patrols
            if hud.activeIncidents > 0 {
                stat("light.beacon.max.fill", "\(hud.activeIncidents)", "Police incidents", tint: Theme.color(.policeRed))
            }
        }
        .fixedSize()
    }

    private var patrols: some View {
        stat("shield.lefthalf.filled", "\(hud.patrols)", "Police cars on patrol", tint: Theme.color(.policeBlue))
            .accessibilityIdentifier("hud.patrols")
            .accessibilityValue("\(hud.patrols)")
    }

    private var compact: some View {
        HStack(spacing: 10) {
            clock
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    stat("person.2.fill", "\(hud.population)", "Population").accessibilityIdentifier("hud.population")
                    vehicles
                    patrols
                }
                FlowIndicator(level: hud.flowLevel)
            }
        }
        .fixedSize()
    }

    /// The narrowest phones: clock, cars and flow.
    private var mini: some View {
        HStack(spacing: 8) {
            clock
            VStack(alignment: .leading, spacing: 2) {
                vehicles
                FlowIndicator(level: hud.flowLevel)
            }
        }
        .fixedSize()
    }

    private func stat(_ icon: String, _ value: String, _ label: String, tint: Color = Theme.color(.uiMuted)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            Text(value).font(.hud(15)).monospacedDigit().foregroundStyle(Theme.color(.uiInk))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Free-flowing → jammed, as a small five-segment bar.
struct FlowIndicator: View {
    let level: Double
    var body: some View {
        let lit = Int((level * 5).rounded(.up)).clamped(0, 5)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { k in
                Capsule()
                    .fill(k < max(lit, 1) ? color(for: k) : Theme.color(.uiMuted).opacity(0.25))
                    .frame(width: 6, height: 12)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Traffic flow")
        .accessibilityValue(level < 0.2 ? "Free flowing" : level < 0.5 ? "Busy" : "Congested")
    }
    private func color(for k: Int) -> Color {
        k < 2 ? Theme.color(.signalGreen) : (k < 4 ? Theme.color(.signalAmber) : Theme.color(.signalRed))
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - Controls

struct RunControls: View {
    @ObservedObject var game: GameController

    var body: some View {
        HStack(spacing: 4) {
            Button {
                game.isPaused.toggle()
            } label: {
                Image(systemName: game.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier("run.pause")
            .accessibilityLabel(game.isPaused ? "Play" : "Pause")
            ForEach([1.0, 3.0, 10.0, 30.0], id: \.self) { s in
                Button {
                    game.speed = s
                    game.isPaused = false
                } label: {
                    Text("\(Int(s))×")
                        .font(.hud(14))
                        .frame(width: 38, height: 40)
                        .foregroundStyle(game.speed == s && !game.isPaused ? Theme.color(.uiAccent) : Theme.color(.uiInk))
                }
                .accessibilityIdentifier("run.speed.\(Int(s))")
                .accessibilityLabel("Speed \(Int(s)) times")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.color(.uiInk))
        .padding(.horizontal, 6)
        .floatingSurface()
    }
}

struct MapActions: View {
    @ObservedObject var game: GameController
    var columns = 1
    /// Portrait phones: pause and speed live here instead of the top bar.
    var includeRunControls = false
    @Binding var showStats: Bool
    @Binding var showSave: Bool
    @Binding var showTraffic: Bool
    var onRecentre: () -> Void
    var onMenu: () -> Void

    private static let speeds: [Double] = [1, 3, 10, 30]

    var body: some View {
        let items = buttons
        let perColumn = Int((Double(items.count) / Double(columns)).rounded(.up))
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<columns, id: \.self) { c in
                VStack(spacing: 8) {
                    ForEach(Array(items.enumerated()).filter { $0.offset / perColumn == c }, id: \.offset) { _, b in b }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var buttons: [AnyView] {
        var out: [AnyView] = []
        if includeRunControls {
            out.append(AnyView(
                Button { game.isPaused.toggle() } label: {
                    RoundIcon(symbol: game.isPaused ? "play.fill" : "pause.fill", active: game.isPaused)
                }
                .accessibilityIdentifier("run.pause")
                .accessibilityLabel(game.isPaused ? "Play" : "Pause")))
            out.append(AnyView(
                Button {
                    let k = Self.speeds.firstIndex(of: game.speed) ?? 0
                    game.speed = Self.speeds[(k + 1) % Self.speeds.count]
                    game.isPaused = false
                } label: {
                    Text("\(Int(game.speed))×")
                        .font(.hud(16))
                        .foregroundStyle(Theme.color(.uiInk))
                        .frame(width: Metrics.mapButton, height: Metrics.mapButton)
                        .background(Circle().fill(Theme.color(.uiSurface)))
                        .shadow(color: .black.opacity(0.14), radius: Metrics.shadowRadius, x: 0, y: Metrics.shadowY)
                }
                .accessibilityIdentifier("run.speed")
                .accessibilityLabel("Speed")
                .accessibilityValue("\(Int(game.speed)) times")))
        }
        out.append(AnyView(
            // Cycles map → congestion → police coverage.
            Button {
                let all = MapOverlay.allCases
                let k = all.firstIndex(of: game.overlay) ?? 0
                game.overlay = all[(k + 1) % all.count]
            } label: {
                RoundIcon(symbol: game.overlay.symbol, active: game.overlay != .none)
            }
            .accessibilityIdentifier("map.overlay")
            .accessibilityLabel("Map overlay")
            .accessibilityValue(game.overlay.title)
            .accessibilityHint("Switches between the plain map, congestion and police coverage")))
        out.append(AnyView(
            Button { showTraffic = true } label: {
                RoundIcon(symbol: "car.2.fill", active: game.trafficLevel > 1.01)
            }
            .accessibilityIdentifier("map.traffic")
            .accessibilityLabel("Traffic level")
            .accessibilityValue(TrafficSheet.describe(game.trafficLevel))))
        out.append(AnyView(
            Button(action: onRecentre) { RoundIcon(symbol: "scope") }
                .accessibilityIdentifier("map.recentre")
                .accessibilityLabel("Show the whole city")))
        out.append(AnyView(
            Button { showStats = true } label: { RoundIcon(symbol: "chart.xyaxis.line") }
                .accessibilityIdentifier("map.stats")
                .accessibilityLabel("Statistics")))
        out.append(AnyView(
            Button { showSave = true } label: { RoundIcon(symbol: "square.and.arrow.down") }
                .accessibilityIdentifier("map.save")
                .accessibilityLabel("Save city")))
        out.append(AnyView(
            Button(action: onMenu) { RoundIcon(symbol: "line.3.horizontal") }
                .accessibilityIdentifier("map.menu")
                .accessibilityLabel("Menu")))
        return out
    }
}

/// The traffic dial: how many people drive, and how much through traffic.
struct TrafficSheet: View {
    @ObservedObject var game: GameController
    @Environment(\.dismiss) private var dismiss
    @State private var level = 1.0

    static func describe(_ v: Double) -> String {
        switch v {
        case ..<0.6: return "Quiet"
        case ..<1.3: return "Normal"
        case ..<2.2: return "Busy"
        case ..<3.4: return "Heavy"
        default: return "Gridlock"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Traffic").font(.hud(22)).foregroundStyle(Theme.color(.uiInk))
                Spacer()
                Text("\(Self.describe(level)) · \(Int((level * 100).rounded()))%")
                    .font(.hud(15)).foregroundStyle(Theme.color(.uiAccent))
                    .accessibilityIdentifier("traffic.value")
            }
            Slider(value: $level, in: Simulation.trafficLevelRange, step: 0.25) {
                Text("Traffic level")
            } minimumValueLabel: {
                Image(systemName: "car.fill").foregroundStyle(Theme.color(.uiMuted))
            } maximumValueLabel: {
                Image(systemName: "car.2.fill").foregroundStyle(Theme.color(.signalRed))
            } onEditingChanged: { editing in
                if !editing { game.setTrafficLevel(level) }
            }
            .accessibilityIdentifier("traffic.slider")
            HStack(spacing: 8) {
                preset("Quiet", 0.5)
                preset("Normal", 1)
                preset("Busy", 2)
                preset("Heavy", 3)
                preset("Gridlock", 5)
            }
            Text("More residents drive, and more through traffic arrives from beyond the map. Changes take effect straight away; rush hours are still the busiest times.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Theme.color(.uiMuted))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { level = game.trafficLevel }
    }

    private func preset(_ title: String, _ v: Double) -> some View {
        Button {
            level = v
            game.setTrafficLevel(v)
        } label: {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(abs(level - v) < 0.01 ? Color.white : Theme.color(.uiInk))
                .background(Capsule().fill(abs(level - v) < 0.01 ? Theme.color(.uiAccent) : Theme.color(.land)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("traffic.preset.\(title.lowercased())")
    }
}

struct RoundIcon: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(active ? Color.white : Theme.color(.uiInk))
            .frame(width: Metrics.mapButton, height: Metrics.mapButton)
            .background(Circle().fill(active ? Theme.color(.uiAccent) : Theme.color(.uiSurface)))
            .shadow(color: .black.opacity(0.14), radius: Metrics.shadowRadius, x: 0, y: Metrics.shadowY)
    }
}

// MARK: - Inspector

struct InspectorCard: View {
    let info: InspectorInfo
    var onClose: () -> Void

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label).font(.hudLabel(12)).foregroundStyle(Theme.color(.uiMuted))
                    Spacer(minLength: 8)
                    Text(row.value).font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.color(.uiInk))
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.title).font(.hud(18)).foregroundStyle(Theme.color(.uiInk))
                    Text(info.subtitle).font(.hudLabel(11)).foregroundStyle(Theme.color(.uiMuted))
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.color(.uiMuted))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("inspector.close")
            }
            // All rows when they fit, otherwise a scrolling list.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }.scrollIndicators(.automatic)
            }
        }
        .padding(14)
        .frame(maxWidth: 300)
        .floatingSurface()
        .accessibilityIdentifier("inspector")
    }
}

// MARK: - Debug overlay

struct DebugOverlay: View {
    let hud: HUDMetrics
    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "step %.2f ms", hud.stepMs))
            Text("veh \(hud.vehicles)")
            Text("gridlocks \(hud.gridlocks)").foregroundStyle(hud.gridlocks > 0 ? Theme.color(.signalRed) : Theme.color(.uiInk))
            Text("trips \(hud.completedTrips)")
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .floatingSurface(radius: 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("debug.overlay")
    }
}

// MARK: - Performance probe (UI tests)

/// Frame-time probe, on with the launch argument `-perfProbe` (UI tests).
/// Counts main-thread hitches (frames that took too long) and how long work
/// waits for the simulation queue, and publishes a summary the tests read
/// through accessibility.
final class PerfProbe: ObservableObject {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-perfProbe")
    /// The app drives a scripted session itself (see `GameView.runPerfScript`).
    static let scripted = ProcessInfo.processInfo.arguments.contains("-perfScript")

    @Published private(set) var summary = "frames=0"
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var frames = 0, over50 = 0, over100 = 0, over250 = 0, over1000 = 0
    private var maxMs = 0.0
    /// Recent frame times (time, ms) for the max over the last few seconds.
    private var recent: [(CFTimeInterval, Double)] = []
    /// Simulation-queue wait times, recent (time, ms).
    private var simWaits: [(CFTimeInterval, Double)] = []

    /// Runs a block on the simulation queue (set by the controller).
    private var throughSim: ((@escaping () -> Void) -> Void)?
    private var lastPing: CFTimeInterval = 0

    func start(throughSim: @escaping (@escaping () -> Void) -> Void) {
        guard Self.enabled, link == nil else { return }
        self.throughSim = throughSim
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// A ping that went through the simulation queue (main thread).
    func simWait(_ ms: Double) {
        simWaits.append((CACurrentMediaTime(), ms))
        windowSim = max(windowSim, ms)
    }

    // A measurement window around one action of the scripted session.
    private var windowMax = 0.0, windowSim = 0.0
    private var windowStart = (frames: 0, h100: 0, h250: 0, h1000: 0)

    func beginWindow() {
        windowMax = 0; windowSim = 0
        windowStart = (frames, over100, over250, over1000)
    }

    func endWindow(_ name: String) -> String {
        String(format: "%-26@ frames=%4d hitches>100ms=%2d >250ms=%2d >1s=%d  worstFrame=%5dms  simQueueWait=%4dms",
               name as NSString, frames - windowStart.frames, over100 - windowStart.h100, over250 - windowStart.h250,
               over1000 - windowStart.h1000, Int(windowMax), Int(windowSim))
    }

    var totals: String {
        "total: frames=\(frames) worstFrame=\(Int(maxMs))ms hitches>100ms=\(over100) >250ms=\(over250) >1s=\(over1000)"
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        if last > 0 {
            let ms = (t - last) * 1000
            frames += 1
            maxMs = max(maxMs, ms)
            if ms > 50 { over50 += 1 }
            if ms > 100 { over100 += 1 }
            if ms > 250 { over250 += 1 }
            if ms > 1000 { over1000 += 1 }
            recent.append((t, ms))
            windowMax = max(windowMax, ms)
        }
        last = t
        if t - lastPing > 0.25, let throughSim {
            // How long a tap's work would wait behind the simulation.
            lastPing = t
            let sent = CACurrentMediaTime()
            throughSim {
                // Measured on the simulation queue: the main thread's own
                // stalls show in the frame times, not here.
                let waited = (CACurrentMediaTime() - sent) * 1000
                DispatchQueue.main.async { [weak self] in self?.simWait(waited) }
            }
        }
        recent.removeAll { t - $0.0 > 4 }
        simWaits.removeAll { t - $0.0 > 4 }
        if t - lastPublish > 0.5 {
            lastPublish = t
            let recentMax = recent.map(\.1).max() ?? 0
            let simMax = simWaits.map(\.1).max() ?? 0
            summary = "frames=\(frames);max=\(Int(maxMs));recentMax=\(Int(recentMax));h50=\(over50);h100=\(over100);h250=\(over250);h1000=\(over1000);simWait=\(Int(simMax))"
        }
    }
}

private struct PerfProbeView: View {
    @ObservedObject var probe: PerfProbe
    var body: some View {
        Text(probe.summary)
            .font(.system(size: 2))
            .opacity(0.02)
            .frame(width: 4, height: 4)
            .allowsHitTesting(false)
            .accessibilityIdentifier("perf.probe")
            .accessibilityValue(probe.summary)
    }
}

/// The HUD, redrawn on its own when the numbers change.
private struct LiveHUD: View {
    @ObservedObject var model: HUDModel
    let scenario: String
    var body: some View { HUDView(hud: model.metrics, scenario: scenario) }
}

private struct LiveDebugOverlay: View {
    @ObservedObject var model: HUDModel
    var body: some View { DebugOverlay(hud: model.metrics) }
}

/// The inspector card, redrawn on its own as the selection's numbers change.
private struct LiveInspector: View {
    @ObservedObject var model: InspectorModel
    var onClose: () -> Void
    var body: some View {
        if let info = model.info { InspectorCard(info: info, onClose: onClose) }
    }
}

// MARK: - Scripted performance session (`-perfProbe -perfScript`)

extension GameView {
    /// Drives a session through the controller (tools, overlays, sheets,
    /// selection, edits, speeds) and times each action with the probe. No UI
    /// test queries run meanwhile (they stall the app themselves), so this is
    /// what a player feels. The report ends up in `perf.script`.
    @MainActor func runPerfScript() async {
        let probe = game.probe
        var lines: [String] = []
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func step(_ name: String, settle: Double = 1.5, _ action: () -> Void) async -> String {
            probe.beginWindow()
            action()
            await wait(settle)
            return probe.endWindow(name)
        }
        func ask<T>(_ body: @escaping (Simulation) -> T) async -> T {
            await withCheckedContinuation { c in game.query(body) { c.resume(returning: $0) } }
        }
        await wait(6)
        lines.append(await step("idle at 1x", settle: 4) {})
        lines.append(await step("speed 10x (idle 5 s)", settle: 5) { game.speed = 10 })
        for c in PaletteCategory.allCases where c != .inspect {
            lines.append(await step("palette \(c.rawValue)") { game.tool = c.tools[0] })
        }
        lines.append(await step("palette inspect") { game.tool = .inspect })
        for k in 1...3 {
            lines.append(await step("overlay cycle \(k)", settle: 2.5) {
                let all = MapOverlay.allCases
                game.overlay = all[((all.firstIndex(of: game.overlay) ?? 0) + 1) % all.count]
            })
        }
        lines.append(await step("traffic sheet open") { showTraffic = true })
        lines.append(await step("traffic preset heavy") { game.setTrafficLevel(3) })
        lines.append(await step("traffic sheet close") { showTraffic = false })
        lines.append(await step("stats open", settle: 2) { showStats = true })
        lines.append(await step("stats close") { showStats = false })
        // Select cars, a building and a road, as taps on the map would.
        let targets = await ask { sim -> [Vector2] in
            var pts = sim.vehicles.filter { $0.mode == .driving }.prefix(3).map(\.center)
            if let b = sim.city.buildings.first { pts.append(b.center) }
            return pts
        }
        for (k, p) in targets.enumerated() {
            lines.append(await step("select \(k + 1)") { game.select(at: p, radius: 5) })
        }
        lines.append(await step("clear selection") { game.clearSelection() })
        lines.append(await step("show whole city") { scene.showWholeCity() })
        // An edit through the middle of town, a house beside a road, undo both.
        let (lo, hi) = await ask { ($0.terrain.minCorner, $0.terrain.maxCorner) }
        let w = hi - lo
        let a = lo + Vector2(w.x * 0.3, w.y * 0.45), b = lo + Vector2(w.x * 0.7, w.y * 0.47)
        game.tool = .drawRoad
        lines.append(await step("draw road", settle: 3) { game.drawRoad([a, (a + b) * 0.5, b]) })
        game.tool = .building(.house)
        let spot = targets.first.map { $0 + Vector2(9, 9) } ?? (a + b) * 0.5
        lines.append(await step("place a house", settle: 2) { game.toolTap(at: spot, radius: 6) })
        lines.append(await step("undo", settle: 2) { game.undo() })
        lines.append(await step("undo again", settle: 2) { game.undo() })
        game.tool = .inspect
        lines.append(await step("speed 30x (idle 6 s)", settle: 6) { game.speed = 30 })
        lines.append(probe.totals)
        perfReport = "done\n" + lines.joined(separator: "\n")
    }
}

