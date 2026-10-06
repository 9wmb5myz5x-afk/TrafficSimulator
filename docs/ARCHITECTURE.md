# Architecture

Traffic City has two layers:

1. **TrafficEngine**: a Swift package that is pure, deterministic and Foundation-free. It builds and runs on macOS, iOS and Linux.
2. **The iOS app**: SwiftUI chrome around a SpriteKit map.

The engine knows nothing about rendering. The app never mutates engine state outside the simulation queue.

```
TrafficEngine/
  Sources/TrafficEngine/
    Core/           ids, DrivingSide
    Math/           Vector2, Polyline, Catmull–Rom / Bézier curves, DMath (pure-Swift
                    transcendental functions, identical on every platform), SeededRandom
    Network/        authored model (NetworkData: nodes, roads, roundabouts, controls)
                    → NetworkBuilder derives edges, lanes, junction geometry, connectors,
                    conflict map; RoadNetwork owns both and rebuilds on edit
    Agents/         Vehicle, Driver, VehicleClass
    CarFollowing/   IDM (+ reaction time, jerk limit)
    LaneChange/     MOBIL
    Intersections/  Signals (NEMA dual ring: actuated / fixed / Webster / coordinated),
                    Warrants (automatic control), Gridlock (wait-for cycles, spillback lock)
    Demand/         buildings, population, activity schedules, trips, external traffic, growth
    Routing/        A* on the edge graph with live travel times
    Services/       police: stations, units, patrols, incidents, dispatch, emergency driving
    Metrics/        per-edge / per-junction stats, LOS, time series
    Simulation/     Simulation (the step loop) and its stages, Editing (player edits +
                    undo/redo), Persistence (save files), Queries (hit-test, inspector),
                    Invariants, ScenarioNetworks / ScenarioFactory
    Debug/          SVG dumps, diagnostics, EditFuzzer
  Sources/trafficsim/   headless CLI: run / soak / fuzz / SVG
  Tests/TrafficEngineTests/
TrafficSimulatorApp/
  App/            entry point, title ↔ game routing, lifecycle (pause + autosave), loading
  Game/           GameController (sim queue, tick, snapshots, edits, saves), BuildTool,
                  RenderSnapshot (double buffer), SaveStore
  Rendering/      CityScene (SpriteKit layers), Textures (one atlas)
  DesignSystem/   Theme tokens (day/night palettes), building styles, design preview
  UI/             HUD, run controls, build palette, inspector, stats (Swift Charts),
                  title, new city, load, save, settings
TrafficSimulatorUITests/   launch, game layer, screenshots
```

## The simulation step

`Simulation.step()` advances by a fixed `dt` (0.05 s) in this order:

1. If the network was edited since the last step, `networkDidChange()` rebuilds the derived indices and reconciles vehicles (see *Edits*).
2. `rebuildIndex`: per-lane and per-connector occupancy lists, sorted by arc length.
3. `signals.advance`: detectors, then actuated or fixed-time sequencing, pre-emption.
4. `updateDemand`: activity plans become departures; driveway pull-outs; boundary entries.
5. `rebuildIndex` (new vehicles), then `updateJunctions`:
   - plan the connector for the next route edge;
   - re-check commitments at yellow;
   - commit candidates that are permitted (signal / priority / gap acceptance / FCFS, footprint conflict check, exit room, courtesy, impatience);
   - set stop targets.
6. `updateLaneChanges`: MOBIL, mandatory pre-positioning, signalling → quintic lateral move, cooperative yielding.
7. `updateServices`: emergency approach (pre-emption, holds, pull-over of civilians), siren passing.
8. `updateMotion`: IDM acceleration against leaders (lane, connector, exit lane, siblings), stop targets, speed anticipation (curves, short links, destinations); integrate speed and position.
9. `advanceTracks`: edge → connector → edge transitions, arrivals, missed turns and reroutes.
10. Poses (front, rear, body yaw), metrics, warrants, gridlock detection, post-step police logic, invariants (when a checker is attached), and compaction of finished vehicles.

Everything is deterministic for a given seed: no wall-clock time, no hashing order, no Foundation maths. `traceHash()` digests the full dynamic state; tests compare it across runs, across save/load, and across Linux and macOS.

## Networks: authored vs derived

`NetworkData` is the small, `Codable` thing the player edits: nodes, roads (class, lanes, shape, one-way, pockets, level, bridge), roundabouts and junction controls. `NetworkBuilder` derives everything else deterministically:

- trimmed carriageways (edges) with lanes;
- junction setbacks (from approach widths and kerb radii, with a taper where widths change);
- junction surfaces;
- connectors (turn paths that hug the right corner for the driving side);
- lane-use;
- the footprint conflict map (cross / merge / diverge zones).

Saves store only `NetworkData`. Derived geometry is rebuilt on load.

## Edits

`Editor` wraps every player action. It snapshots `NetworkData` (or records the inverse for building edits) for undo/redo, and validates the result. An edit is rolled back with a clear message if it would create:

- a carriageway shorter than 18 m between junctions (8 m for roundabout ring segments);
- a bend tighter than 8 m;
- roads meeting at less than 20°.

After any change, `reconcileVehiclesAfterEdit`:

- keeps vehicles whose road is unchanged;
- re-anchors vehicles on reshaped or split roads by world position;
- repairs or recomputes routes and destinations (including police re-entry targets);
- lets a car that is already too close to a new junction through;
- removes, rather than teleports, any vehicle whose pose would visibly change. Its occupants go home.

`trafficsim --fuzz` and `EditFuzzer` exercise all of this while simulating, with invariants checked every step.

## Threading in the app

The `Simulation` lives on a private serial queue (`GameController.simQueue`). A 60 Hz timer on that queue:

- steps the simulation to keep pace with wall time × speed, with a budget so the device is never starved;
- pushes an immutable `RenderSnapshot` into a double buffer.

SpriteKit (main thread) interpolates between the two latest snapshots. Static geometry (roads, buildings) is pushed only when the network or city version changes.

UI actions (tools, saves, selection) are closures queued onto the sim queue. Their results come back to `@Published` properties on the main thread.

## Persistence

`SaveFile` (schema 1) contains `NetworkData`, terrain, config and the complete dynamic state:

- time, step count, RNG;
- vehicles, signals, router travel times;
- metrics, city, police, events, warrants, gridlock.

`Simulation.restore` validates it (schema, config sanity, references) and rebuilds the derived data. The resumed run is bit-identical (`PersistenceTests`).

The app writes atomically to Application Support/Cities:

- autosave every in-game hour and on backgrounding;
- named saves from the Save sheet.

The Load list shows damaged files, and opening one reports an error instead of crashing.

## Tests

| Level | What | Where |
|---|---|---|
| 1 | Unit tests (geometry, routing, IDM/MOBIL, signals, persistence) | `swift test` on Linux and macOS |
| 2 | Behaviour micro-scenarios (lane changes, merges, gap acceptance, pre-emption, pull-over, …) | `swift test` |
| 3 | Invariant soak and fuzz (`SoakTests`, `trafficsim --soak`, `trafficsim --fuzz`) | `swift test`, CLI |
| 4 | App build plus XCUITests (launch, build a town by gestures, save/relaunch/load, corrupt save, rotate/background) on iPhone, small iPhone and iPad | CI macOS |
| 5 | Screenshot set, reviewed by eye | CI → `ci-screenshots/<branch>` |
