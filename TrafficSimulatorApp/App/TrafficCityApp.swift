//
//  TrafficCityApp.swift
//  TrafficSimulator
//
//  App entry point: title screen → game, loading saved cities, and the app
//  lifecycle (pause + autosave on backgrounding, low-memory handling).
//

import SwiftUI
import UIKit
import Combine
import TrafficEngine

@main
struct TrafficCityApp: App {
    @StateObject private var settings = AppSettings()

    init() {
        let args = ProcessInfo.processInfo.arguments
        // UI tests: start from a clean slate and/or plant a damaged save.
        if args.contains("-resetSaves") {
            for c in SaveStore.list() { SaveStore.delete(c.id) }
        }
        if args.contains("-corruptSave") { SaveStore.plantCorruptSave() }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(settings)
                .preferredColorScheme(.light)
                .statusBarHidden()
        }
    }
}

/// Which screen is showing, and the live controllers behind them.
struct AppRoot: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var background = GameController(setup: CitySetup(scenario: .roundaboutVillage, side: .right, seed: 7))
    @State private var game: GameController?
    @State private var showingGame = false
    @State private var loadError: String?
    @State private var loading = false
    /// Run state to restore when coming back from the background.
    @State private var wasRunning = false

    var body: some View {
        ZStack {
            if showingGame, let game {
                GameView(game: game, onMenu: {
                    game.isPaused = true
                    game.autosave()
                    showingGame = false
                })
                .transition(.opacity)
            } else {
                TitleView(background: background, hasCity: game != nil, onNewCity: { setup in
                    open(setup)
                }, onContinue: {
                    game?.isPaused = false
                    showingGame = true
                }, onLoad: { city in
                    load(city)
                })
                .transition(.opacity)
            }
            if loading {
                ProgressView("Opening city…")
                    .padding(20)
                    .floatingSurface()
                    .accessibilityIdentifier("loading")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showingGame)
        .alert("Couldn't load this city", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .onAppear {
            // UI tests / screenshots can jump straight into a city.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-openCity"), i + 1 < args.count, let kind = ScenarioKind(rawValue: args[i + 1]) {
                let side: DrivingSide = args.contains("-leftHand") ? .left : .right
                open(CitySetup(scenario: kind, side: side, seed: 1))
            }
        }
        .onChange(of: showingGame) { _, nowGame in
            if nowGame { background.stop() } else { background.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Pause and save; resume where we were when we come back.
                if let game, showingGame {
                    wasRunning = !game.isPaused
                    game.enterBackground()
                }
                background.stop()
            case .active:
                if let game, showingGame {
                    game.start()
                    if wasRunning { game.isPaused = false }
                } else {
                    background.start()
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            game?.handleMemoryWarning()
            if showingGame { background.stop() }
        }
    }

    private func open(_ setup: CitySetup) {
        if let game {
            game.newCity(setup)
            game.isPaused = false
        } else {
            game = GameController(setup: setup)
        }
        showingGame = true
    }

    /// Read, validate and restore a saved city off the main thread. Any
    /// failure (damaged file, unknown schema, invalid data) shows an alert.
    private func load(_ city: SavedCity) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(Simulation, String), Error> = Result {
                let save = try SaveStore.read(city.id)
                return (try Simulation.restore(save), save.name)
            }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let (sim, name)):
                    if let game {
                        game.open(restored: sim, name: name)
                        game.isPaused = false
                    } else {
                        game = GameController(restored: sim, name: name)
                    }
                    showingGame = true
                case .failure(let error):
                    // Let the Load sheet finish dismissing before the alert.
                    let message = AppRoot.describe(error)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { loadError = message }
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case LoadError.unsupportedSchema(let v):
            return "It was saved by a newer version of Traffic City (format \(v))."
        case LoadError.corrupt(let why):
            return "The file is damaged (\(why))."
        case is DecodingError:
            return "The file is damaged or incomplete."
        default:
            return "The file couldn't be read."
        }
    }
}
