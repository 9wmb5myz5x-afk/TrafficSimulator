# Traffic City

A native iOS city builder where the traffic is the point. You draw roads, zone homes and workplaces, place police stations, and watch a town of simulated drivers commute, queue, change lanes, give way and pull over for sirens. All of it emerges from a deterministic microscopic simulation, not scripted animations.

- **Drives on the right or the left.** Everything flips: lane offsets, turn rules, roundabout direction, which turns cross traffic, ramp sides.
- **Real driving models:**
  - the Intelligent Driver Model with reaction time;
  - MOBIL lane changes with blinkers and smooth lateral motion;
  - pre-positioning two junctions ahead;
  - cooperative merges and zipper courtesy.
- **Junctions that run themselves.** Control follows road classes and measured volumes: uncontrolled, yield, two-way stop, all-way stop, actuated NEMA dual-ring signals with protected or permitted turns, coordination, Webster splits, and roundabouts. Gridlock is detected and resolved.
- **A living demand engine.** Residents have jobs, schools, shops and schedules (AM/PM peaks, weekends). Cars back out of garages, roll down driveways, wait at the kerb for a gap and turn into driveways at the other end. Regional commuters and through traffic drive in from the countryside around the town.
- **A traffic dial** from quiet to gridlock, taking effect at once.
- **Police.** Stations deploy units that patrol, respond to incidents with signal pre-emption, and pass civilians who pull over.
- **Game layer:**
  - build palette with undo/redo;
  - live road preview while drawing (green or red, with what the road will do);
  - a maps-style camera (pinch around the fingers, flick to glide, double tap to zoom);
  - placement feedback and haptics;
  - inspector cards;
  - stats with Swift Charts and per-junction Level of Service;
  - overlays;
  - named saves (bit-identical resume) and autosave;
  - Empty Land sandbox plus six starter maps.

## Requirements

- **Xcode 16+** on macOS. The app targets **iOS 17+** (iPhone and iPad, landscape-first).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46+ only if you change `project.yml`.
- To work on the engine on Linux: Swift 6.0 (`scripts/install-swift-linux.sh`).

## Build and run (macOS)

```bash
git clone <this repo> && cd traffic-simulator
open TrafficSimulator.xcodeproj          # or: xcodegen generate && open TrafficSimulator.xcodeproj
```

Select the **TrafficSimulator** scheme and an iOS 17+ simulator, then press ⌘R. To run on a device, set your team under *Signing & Capabilities* (the bundle id is `com.example.TrafficSimulator`).

The app links the local Swift package `TrafficEngine/`. Xcode resolves it on first open.

Useful launch arguments (Scheme → Run → Arguments):

| Argument | Effect |
|---|---|
| `-openCity <map>` | Skip the title. `<map>` is one of `emptyLand`, `signalGrid`, `suburb`, `downtown`, `highwayTown`, `roundaboutVillage`, `corridor`, `stressCity` |
| `-leftHand` | Drive on the left (with `-openCity`) |
| `-startHour 21.5` | Clock hour the city opens at |
| `-zoom 0.2`, `-camera x,y,scale` | Initial camera |
| `-debugOverlay` | FPS / step time / vehicles / gridlock overlay |
| `-resetSaves`, `-corruptSave` | Used by UI tests |

## Tests

**Engine (macOS or Linux):**

```bash
swift test --package-path TrafficEngine -c release -Xswiftc -enable-testing
```

The suite covers four areas:

- geometry and rules for both driving sides;
- driving behaviour micro-scenarios (overtaking, blinkers, merges, pre-positioning, pocket use);
- intersections (ITE yellow, actuated gap-out and max-out, permissive gaps, turn-on-red, all-way and two-way stops, roundabouts, coordination, gridlock);
- demand peaks and scaling, police (coverage, pull-over, response), persistence (bit-identical resume, corrupt saves), editing (undo/redo, validation, building a town on empty land) and short soaks.

**Headless CLI** (soak, fuzz, profiling, SVG dumps):

```bash
cd TrafficEngine && swift build -c release
.build/release/trafficsim --scenario suburb --side left --minutes 30 --svg out.svg
.build/release/trafficsim --soak --hours 2 --seeds 1,2,3,4,5          # every map × both sides
.build/release/trafficsim --fuzz --minutes 45 --seeds 1,2,3            # random edits while simulating
.build/release/trafficsim --scenario stressCity --minutes 32 --no-check --progress --stages   # timing
```

Every step is checked against the invariants: no overlaps, no teleports, no heading jumps, no off-road vehicles, no stuck vehicles outside a detected gridlock, no forced stops. Any violation fails the run.

**App build and UI tests (macOS):**

```bash
xcodebuild test -project TrafficSimulator.xcodeproj -scheme TrafficSimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

The UI tests cover:

- launch, New City and traffic flowing;
- building a small town by gestures, then save, relaunch and load;
- a corrupted save;
- rotate and background;
- the screenshot set (rush hour on every map, close-ups, night, left-hand, inspector, overlays, stats, design preview).

CI (`.github/workflows/ci.yml`) runs:

- the engine tests on Linux and macOS;
- the app build and UI tests on an iPhone, a small iPhone and an iPad.

Documentation-only pushes skip CI. Screenshots are published to the `ci-screenshots/<branch>` branches.

## Repository layout

```
project.yml                    XcodeGen spec (source of truth for the Xcode project)
TrafficSimulator.xcodeproj     generated project
TrafficEngine/                 Swift package: deterministic, Foundation-free engine + trafficsim CLI + tests
TrafficSimulatorApp/           SwiftUI + SpriteKit app
TrafficSimulatorUITests/       XCUITests
docs/                          ARCHITECTURE, DECISIONS, PROGRESS, AUDIT, screenshots
scripts/                       Linux toolchain install, simulator picker for CI
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how the engine, its step loop, editing, persistence and the app's threading fit together. See [`docs/DECISIONS.md`](docs/DECISIONS.md) for the defaults chosen, and [`docs/PROGRESS.md`](docs/PROGRESS.md) for status and evidence.
