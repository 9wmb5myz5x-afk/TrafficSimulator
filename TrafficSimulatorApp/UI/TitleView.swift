//
//  TitleView.swift
//  TrafficSimulator
//
//  Title / city picker over a live mini-city, the New City sheet and Settings.
//

import SwiftUI
import SpriteKit
import TrafficEngine

final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var drivingSide: DrivingSide { didSet { d.set(drivingSide.rawValue, forKey: "drivingSide") } }
    @Published var useMph: Bool { didSet { d.set(useMph, forKey: "useMph") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "sound") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var highQuality: Bool { didSet { d.set(highQuality, forKey: "highQuality") } }
    @Published var showDebugOverlay: Bool { didSet { d.set(showDebugOverlay, forKey: "debugOverlay") } }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["sound": true, "haptics": true, "highQuality": true])
        drivingSide = DrivingSide(rawValue: d.string(forKey: "drivingSide") ?? "") ?? .right
        useMph = d.bool(forKey: "useMph")
        sound = d.bool(forKey: "sound")
        haptics = d.bool(forKey: "haptics")
        highQuality = d.bool(forKey: "highQuality")
        // UI tests can force the overlay on.
        showDebugOverlay = d.bool(forKey: "debugOverlay") || ProcessInfo.processInfo.arguments.contains("-debugOverlay")
    }
}

struct TitleView: View {
    @ObservedObject var background: GameController
    var hasCity: Bool
    var onNewCity: (CitySetup) -> Void
    var onContinue: () -> Void
    var onLoad: (SavedCity) -> Void = { _ in }
    @State private var showNew = false
    @State private var showLoad = false
    @State private var showSettings = false
    @State private var showPreview = false
    @State private var scene: CityScene = {
        let s = CityScene(size: CGSize(width: 844, height: 390))
        s.scaleMode = .resizeFill
        return s
    }()

    var body: some View {
        ZStack {
            SpriteView(scene: scene)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            LinearGradient(colors: [Theme.color(.land).opacity(0.0), Theme.color(.land).opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 18) {
                Spacer()
                VStack(spacing: 4) {
                    Text("TRAFFIC CITY")
                        .font(.hud(44)).tracking(6)
                        .foregroundStyle(Theme.color(.uiInk))
                        .accessibilityIdentifier("title.logo")
                    Text("Build roads. Watch a town come alive.")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.color(.uiMuted))
                }
                VStack(spacing: 10) {
                    if hasCity {
                        menuButton("Continue", symbol: "play.fill", id: "title.continue", primary: true, action: onContinue)
                    }
                    HStack(spacing: 10) {
                        menuButton("New City", symbol: "plus", id: "title.new", primary: !hasCity) { showNew = true }
                        menuButton("Load", symbol: "folder.fill", id: "title.load") { showLoad = true }
                    }
                    HStack(spacing: 10) {
                        menuButton("Settings", symbol: "gearshape.fill", id: "title.settings") { showSettings = true }
                        menuButton("Design", symbol: "paintpalette.fill", id: "title.design") { showPreview = true }
                    }
                }
                .frame(maxWidth: 360)
                Spacer().frame(height: 24)
            }
            .padding(Metrics.gutter)
        }
        .sheet(isPresented: $showNew) { NewCitySheet { setup in showNew = false; onNewCity(setup) } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showLoad) { LoadSheet { city in showLoad = false; onLoad(city) } }
        .fullScreenCover(isPresented: $showPreview) { DesignPreview { showPreview = false } }
        .onAppear {
            scene.controller = background
            scene.reduceMotion = true
            background.speed = 3
            background.start()
        }
    }

    private func menuButton(_ title: String, symbol: String, id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.hud(18))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(primary ? Color.white : Theme.color(.uiInk))
                .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(primary ? Theme.color(.uiAccent) : Theme.color(.uiSurface)))
                .shadow(color: .black.opacity(0.12), radius: Metrics.shadowRadius, x: 0, y: Metrics.shadowY)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct NewCitySheet: View {
    var onCreate: (CitySetup) -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var setup = CitySetup()
    @State private var seedText = "1"

    private let maps: [ScenarioKind] = [.emptyLand, .signalGrid, .suburb, .downtown, .highwayTown, .roundaboutVillage, .corridor, .stressCity]

    var body: some View {
        NavigationStack {
            Form {
                Section("Starter map") {
                    Picker("Map", selection: $setup.scenario) {
                        ForEach(maps, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("new.map")
                }
                Section("Rules of the road") {
                    Picker("Drive on the", selection: $setup.side) {
                        Text("Right").tag(DrivingSide.right)
                        Text("Left").tag(DrivingSide.left)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("new.side")
                }
                Section("Map seed") {
                    TextField("Seed", text: $seedText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("new.seed")
                }
            }
            .navigationTitle("New City")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        setup.seed = UInt64(seedText) ?? 1
                        onCreate(setup)
                    }
                    .accessibilityIdentifier("new.create")
                }
            }
            .onAppear { setup.side = settings.drivingSide }
        }
    }
}

/// Saved cities, newest first. Damaged files are listed (and fail gracefully).
struct LoadSheet: View {
    var onOpen: (SavedCity) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cities: [SavedCity] = []

    var body: some View {
        NavigationStack {
            List {
                if cities.isEmpty {
                    Text("No saved cities yet.").foregroundStyle(.secondary)
                }
                ForEach(cities) { c in
                    Button { onOpen(c) } label: {
                        HStack {
                            Image(systemName: c.readable ? (c.isAutosave ? "clock.arrow.circlepath" : "building.2.crop.circle")
                                                         : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.readable ? Theme.color(.uiAccent) : Theme.color(.signalRed))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.isAutosave ? "\(c.name) (autosave)" : c.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.color(.uiInk))
                                Text(c.summary + " · " + c.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("load.\(c.id)")
                }
                .onDelete { idx in
                    for i in idx { SaveStore.delete(cities[i].id) }
                    cities.remove(atOffsets: idx)
                }
            }
            .navigationTitle("Load City")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { cities = SaveStore.list() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Driving") {
                    Picker("Drive on the", selection: $settings.drivingSide) {
                        Text("Right").tag(DrivingSide.right)
                        Text("Left").tag(DrivingSide.left)
                    }
                    Toggle("Miles per hour", isOn: $settings.useMph)
                }
                Section("Feedback") {
                    Toggle("Sound", isOn: $settings.sound)
                    Toggle("Haptics", isOn: $settings.haptics)
                }
                Section("Graphics") {
                    Toggle("High quality", isOn: $settings.highQuality)
                    Toggle("Show debug overlay", isOn: $settings.showDebugOverlay)
                        .accessibilityIdentifier("settings.debug")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
