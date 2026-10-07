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
    @State private var toast: EditFeedback?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .accessibilityIdentifier("city.map")
                .accessibilityLabel("City map")
                .accessibilityValue("\(game.hud.vehicles) vehicles on the road")
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    HUDView(hud: game.hud, scenario: game.scenarioName)
                    Spacer(minLength: 0)
                    RunControls(game: game)
                }
                if settings.showDebugOverlay { DebugOverlay(hud: game.hud) }
                if game.tool != .inspect {
                    Text(game.tool.hint)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.color(.uiMuted))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .floatingSurface(radius: 12)
                        .accessibilityIdentifier("tool.hint")
                }
                // The flexible part of the column: the inspector gets whatever
                // height the HUD and palette leave (its rows scroll if needed),
                // so nothing is pushed off-screen on a landscape phone.
                HStack(alignment: .bottom) {
                    inspectorCard
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .layoutPriority(-1)
                if let toast {
                    FeedbackToast(feedback: toast)
                        .transition(.opacity)
                }
                BuildPalette(game: game)
            }
            .overlay(alignment: .trailing) { mapActions }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 8)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: game.inspector?.title)
        }
        .sheet(isPresented: $showStats) { StatsSheet(game: game) }
        .sheet(isPresented: $showSave) { SaveSheet(game: game) }
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
        if let info = game.inspector {
            InspectorCard(info: info) { game.clearSelection() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var mapActions: some View {
        MapActions(game: game, showStats: $showStats, showSave: $showSave, onMenu: onMenu)
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
    @Binding var showStats: Bool
    @Binding var showSave: Bool
    var onMenu: () -> Void

    var body: some View {
        VStack(spacing: 10) {
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
            .accessibilityHint("Switches between the plain map, congestion and police coverage")
            Button { showStats = true } label: { RoundIcon(symbol: "chart.xyaxis.line") }
                .accessibilityIdentifier("map.stats")
                .accessibilityLabel("Statistics")
            Button { showSave = true } label: { RoundIcon(symbol: "square.and.arrow.down") }
                .accessibilityIdentifier("map.save")
                .accessibilityLabel("Save city")
            Button(action: onMenu) { RoundIcon(symbol: "line.3.horizontal") }
                .accessibilityIdentifier("map.menu")
                .accessibilityLabel("Menu")
        }
        .buttonStyle(.plain)
    }
}

struct RoundIcon: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(active ? Color.white : Theme.color(.uiInk))
            .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
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
