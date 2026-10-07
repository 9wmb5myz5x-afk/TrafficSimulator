# PROGRESS — single source of truth

> On resume: read this file first, then `docs/DECISIONS.md` and `docs/ARCHITECTURE.md`.

## Status

Milestones M0–M8 are complete. Every Definition of Done item has evidence below.

- **Engine:** complete for every behaviour in §4. All 71 engine tests pass on Linux (CI last ran them on macOS at `cb06069`).
- **Soak and fuzz:** clean on the final engine commit `636bfe3`. Raw outputs are in `docs/verification/`:
  - general soak: 70/70;
  - Stress City: 10/10;
  - edit fuzz: 56/56.
- **App:** builds, and all UI tests pass on an iPhone, an iPhone SE and an iPad in CI.
- **CI is green:** Linux engine tests, plus the macOS app build and UI tests on three devices, all pass on `main`.

## Milestones

### M0 — Ground truth ✅
- [x] Audit (`docs/AUDIT.md`), Linux toolchain, XcodeGen project, CI, launch smoke test.

### M1 — Geometry & rules ✅
- [x] `DrivingSide` drives:
  - lane offsets and the passing side;
  - across/kerb turn classification;
  - roundabout circulation;
  - ramp sides.
- [x] Curved roads (centripetal Catmull–Rom); setbacks from widths and kerb radii; a taper where a road changes width.
- [x] Turn paths; across-turn pockets; kerb lanes; acceleration and deceleration lanes; lane-use arrows; lane drops; cul-de-sac bulbs.
- [x] Footprint conflict map.
- [x] Roundabouts sized so every ring segment is drivable.
- [x] Splitting a curved road preserves its exact shape.

### M2 — Driving behaviour ✅
- [x] IDM with reaction time, jerk limit and emergency braking.
- [x] MOBIL lane changes with blinkers, a quintic lateral move, abort, and a body model where the rear follows the front.
- [x] Pre-positioning with two-junction look-ahead; missed turns reroute; zipper courtesy; acceleration-lane merges.

### M3 — Intersections ✅
- [x] Automatic control from road-class and volume warrants (reviewed every 5 sim-minutes, D11).
- [x] NEMA dual ring: actuated / fixed / Webster / coordinated. ITE yellow and all-red; pre-emption.
- [x] Every approach gets a phase (D17); cycles survive edits.
- [x] HCM gap acceptance with impatience; turn-on-red; all-way stop FCFS; two-way stop; roundabout yields.
- [x] Gridlock detection (wait-for cycles plus spillback lock) and release.

### M4 — Demand ✅
- [x] Buildings with kerb-side driveways (≥ 12 m from junctions); population, schedules, gravity choice; regional commuting; external traffic.
- [x] Physical spawn and despawn through driveways, one car at a time per stretch of kerb.
- [x] Time compression (D6).

### M5 — Police ✅
- [x] Stations deploy units that patrol with kerb breaks. Population-based incidents; nearest-unit dispatch.
- [x] Emergency driving:
  - pre-emption and junction holds;
  - proceeding through a red only after slowing;
  - civilians pull over;
  - passing on the centre side;
  - a unit dispatched from a break pulls out as soon as there is a gap.
- [x] Coverage overlay; response-time metrics.

### M6 — Visual overhaul ✅
- [x] Design system tokens with day/night palettes; terrain; seamless roads; zoom-dependent markings; buildings with shadows; vehicle atlas; lights; overlays; HUD; title over a live city; stats sheet; design preview.
- [x] Final self-review of the screenshot set (`docs/screenshots/`: iPhone, iPhone SE, iPad). The review found four issues, all fixed and re-checked:
  - the HUD was pushed off-screen on landscape phones when the inspector was open;
  - screenshots were stored with sideways pixels;
  - a road drawn onto a road of a different width left an unpaved gap;
  - rush-hour shots were zoomed out too far to see traffic.

### M7 — Game layer ✅
- [x] `Editor`:
  - draw, restyle, remove and pocket roads;
  - control overrides with lock; roundabout; move junction;
  - place and bulldoze buildings;
  - undo/redo.

  Validation rejects edits with clear messages (D16), and vehicles are reconciled without ever teleporting (D15).
- [x] Build palette, one-finger drawing (two-finger pan), ghost and haptic feedback, toasts.
- [x] Save sheet, Load list, damaged-save alert, hourly and background autosave, pause on background, low-memory handling.
- [x] Empty Land sandbox (D19).
- [x] UI tests:
  - build a town by gestures → save → relaunch → load;
  - corrupt save;
  - rotate/background;
  - launch.

### M8 — Performance & polish ✅
- [x] Profiled with callgrind and fixed the hot spots (D18). Stress City step time: **9.3 → 3.7 ms at the 1,845-vehicle peak**, **2.9 ms at 1,477 vehicles** (Linux container, no invariant checks). The budget is ≤ 4 ms at 1,500.
- [x] On the final binary `636bfe3`, measured the same day on the same container: **3.1 ms at 1,441 vehicles** and **4.0 ms at 1,846**. The older binary measured 3.0 ms at 1,434 that day, so the liveness and safety fixes cost about 4 %. That interpolates to ≈ 3.3 ms at 1,500, within budget.
- [x] Files kept under ~600 lines (police emergency driving, signal plans and scene input split out).
- [x] `docs/ARCHITECTURE.md`, README rewrite, DECISIONS D15–D22.
- [x] Final soak and fuzz evidence on the final engine binary `636bfe3` (verification log; outputs in `docs/verification/`).
- [x] CI green on the final commit (all four jobs).

## Verification log

| When | Level | Where | What | Result |
|---|---|---|---|---|
| 2026-10-05 | 1–3 | Linux | `swift test` (engine v2) | 35 tests, 0 failures |
| 2026-10-06 | 4 | CI run 28 (`cb06069`) | iPhone build + UI tests | app builds; all 4 GameplayTests and LaunchSmokeTests **pass** (town by gestures, save/relaunch/load, corrupt save, rotate/background); 1 screenshot test failed on an identifier clash (fixed) |
| 2026-10-06 | 4 | CI run 33 (`a0bc45d`) | iPhone, iPhone SE, iPad | launch, corrupt save and rotate pass on all three. Failures, all fixed since: town test on small screens (compact HUD lacked population; save sheet in landscape; iPad AX timeout during double rotation); overlay menu items off-screen in landscape |
| 2026-10-06 | 3 | Linux | `trafficsim --soak --hours 2 --seeds 1,2,3,4,5` (6 maps × 2 sides) | **60/60 runs, 0 violations** (binary `tsim11`) |
| 2026-10-06 | 3 | Linux | `trafficsim --fuzz --minutes 45 --seeds 1,2,3,4` (7 maps × 2 sides) | 53/56 clean before the last round of fixes (driveway sides, ring segments, kerbside staleness) |
| 2026-10-06 | 1–3 | Linux | `swift test -c release` | **69 tests, 0 failures** (148 s) |
| 2026-10-06 | perf | Linux | `trafficsim --scenario stressCity --minutes 32 --no-check --progress --stages` | 2.9 ms/step @ 1,477 veh; 3.7 ms @ 1,845 veh |
| 2026-10-06 | 1–3 | Linux | `swift test -c release` on `636bfe3` | **71 tests, 0 failures** |
| 2026-10-06 | 3 | Linux | `trafficsim --soak --hours 2 --seeds 1,2,3,4,5` (7 maps × 2 sides, `636bfe3`) | **70/70 runs, 0 violations, 0 gridlocks** (`docs/verification/soak-636bfe3.txt`) |
| 2026-10-06 | 3 | Linux | `trafficsim --soak --hours 2 --scenarios stressCity --seeds 1,2,3,4,5` (`636bfe3`) | **10/10 runs, 0 violations.** Peak 1,815–1,991 vehicles. 20–55 gridlocks per run, each detected, reported and released (§10.4) (`docs/verification/stress-636bfe3.txt`) |
| 2026-10-06 | 3 | Linux | `trafficsim --fuzz --minutes 45 --seeds 1,2,3,4` (7 maps × 2 sides, an edit every 30 s, `636bfe3`) | **56/56 runs, 0 violations.** 3,962 edits applied, 1,078 rejected by validation (`docs/verification/fuzz-636bfe3.txt`) |
| 2026-10-06 | perf | Linux | `trafficsim --scenario stressCity --minutes 30 --no-check --progress --stages` (`636bfe3`) | 3.1 ms/step @ 1,441 veh; 4.0 ms @ 1,846 veh |
| 2026-10-07 | 4–5 | CI | app build + UI tests on iPhone, iPhone SE, iPad; Linux engine tests | **all 4 jobs pass**; screenshot set reviewed and committed to `docs/screenshots/` |

## Where each level runs
- L1–L3: Linux container (local), CI `engine-linux`, CI `app-macos`.
- L4–L5: CI `app-macos` (iPhone) and `app-devices` (iPhone SE, iPad).

## Known issues / next steps
1. Sound: a placement click only (the system "Tock", which respects the mute switch). There is no ambient traffic audio; it is optional in the brief.
2. The bundle identifier is the placeholder `com.example.TrafficSimulator`. Set your own team and bundle id before running on a device or shipping.
