# Master Prompt — Traffic City (iOS)

> **How to use:** start a Claude Code session in this repository and paste everything
> below the line (or say: *"Read `docs/MASTER_PROMPT.md` and execute it."*).
> The prompt is written so the agent works autonomously across many turns and
> context compactions until the Definition of Done is met.

---

## 0. Your mission

You are the lead engineer, simulation designer and product designer for **an iOS
city-building traffic simulation game**. The player builds a city (roads, homes,
businesses, services such as police stations), and a **realistic, agent-based
traffic engine** brings it to life. Every car is a simulated driver with a reason
to be on the road. Congestion, rush hours, gridlock and police response all
*emerge* from the simulation. Nothing is scripted.

This repository already contains a first build (`TrafficEngine/` Swift package +
`TrafficSimulatorApp/` SwiftUI/SpriteKit app). Your job is to **evolve it into a
polished, realistic, stable new version** and to **prove that it works**. Do not
stop at a plan, a scaffold, or "should work". Keep going, milestone by milestone,
until every item in §12 *Definition of Done* is checked off with evidence.

### Operating rules (read twice)

1. **Autonomy.** Do not ask the user questions that have a sensible default. Pick
   the default, write it down in `docs/DECISIONS.md`, and continue. Only stop to
   ask if you are truly blocked (e.g., a credential or paid service is required).
2. **Persistence across context.** You will run long enough for your context to be
   summarised. Keep `docs/PROGRESS.md` as the single source of truth: current
   milestone, checklist state, last verification results (with commands and
   outcomes), known bugs, and next steps. Update it at every milestone and
   before any long operation. On resume, read it first.
3. **Never claim something works without evidence.** "Works" means you ran the
   test, build or app and observed the result. Paste the command and the summarised
   output into `PROGRESS.md`. If you could not run something, say so explicitly.
4. **Never weaken tests to get green.** Don't skip, delete, loosen or `XCTExpectFailure`
   a test to make it pass. Fix the code. If a test's expectation was genuinely
   wrong, explain why in the commit message.
5. **Small, verified commits.** Commit at each green checkpoint with a clear
   message. Push to the working branch regularly so work survives the container.
6. **If stuck >3 attempts on the same bug**, write a short root-cause note in
   `PROGRESS.md`, add a focused failing test that reproduces it, then try a
   different approach. Don't loop on the same fix.
7. **No third-party dependencies** unless clearly justified in `DECISIONS.md`.
   Apple frameworks only is the strong default.

---

## 1. Start by auditing the existing build

Before writing new code, read every file in `TrafficEngine/` and
`TrafficSimulatorApp/`, run whatever tests you can (see §10), and write
`docs/AUDIT.md` with: what to **keep**, what to **refactor**, what to **rewrite**.

### Keep (these are good foundations)
- The **pure engine / thin renderer split**: the engine has no UIKit/SwiftUI/SpriteKit
  dependency and is testable headless. Preserve this strictly.
- **IDM** car-following (`CarFollowing/IDM.swift`), **MOBIL** lane-change decision
  (`LaneChange/MOBIL.swift`), **A\*** routing (`Routing/Router.swift`), seeded RNG
  and **determinism** (same seed + same inputs ⇒ identical run).
- The spill-back ("don't block the box") guard and the conflict-graph idea in
  `Intersections/IntersectionManager.swift`.

### Known defects you must fix (found in a pre-audit; verify each, then fix)
1. **Lane changes teleport.** `Simulation.applyLaneChanges` swaps a vehicle's lane
   instantly. `updatePose` then decays a cosmetic `lateralOffset *= 0.7` *per step*,
   which is frame-rate-dependent and finishes in ~0.3 s. The target-lane follower
   only "sees" the car after the swap, and there are no turn signals. Replace this
   with a real lateral manoeuvre (see §4.3).
2. **Turn paths go through the junction centre.** `RoadNetwork.connectorPath`
   draws every movement as a quadratic Bézier with the node centre as control
   point. Right turns swing wide, opposing left turns overlap, and paths look
   wrong. Replace this with proper turn geometry (§4.2).
3. **Permissive left turns don't yield to oncoming traffic.** On green,
   `permitToEnter` calls `gapAccepted`, which arbitrates by `lineWait`/id, not by
   oncoming time-gap. Implement real gap acceptance (§4.4).
4. **Signals are two-phase fixed-time only** (`makeDefaultSignalConfig`). There are
   no protected lefts, no actuation and no coordination (§4.4).
5. **Geometry bug on edit.** `RoadNetwork.rebuildAttachedGeometry` rebuilds
   lanes using `roadType.isTwoWayByDefault` instead of the edge's actual
   one-way/two-way state, so lanes break when a junction moves.
6. **Vehicles pop into existence** at the start of a lane at the origin junction.
   Zones are abstract weights attached to the nearest node, and placing a zone
   silently fails if no junction is within 60 m (`AppModel.placeZone`).
7. **Rendering/perf.** The sim runs on the main thread inside `SKScene.update`.
   Every road lane is two `SKShapeNode`s, and the whole layer is rebuilt on every
   edit. Vehicle poses aren't interpolated between sim steps, which causes visible
   stutter.
8. **Weak tests.** The no-collision test only checks same-lane longitudinal gaps.
   Nothing checks intersections, lateral overlap, teleporting, or stuck vehicles.
   The "congestion emerges" test only asserts density > 0.
9. **Project may fail to open/build.** `TrafficSimulator.xcodeproj/project.pbxproj`
   is hand-written (synthetic `AA000…` object IDs, `objectVersion = 77`, so
   Xcode 16+ only). The README's paths (`TrafficSimulator/TrafficSimulator.xcodeproj`,
   `cd TrafficSimulator/TrafficEngine`) don't match the repo layout, where the
   project is at the root. No build has ever been verified by CI. Treat
   "the app wouldn't load" as a top-priority bug class (§10).
10. No save/load, no undo, and no app-lifecycle handling (backgrounding).

---

## 2. Product vision

A calm, beautiful, **sandbox city builder where traffic is the star**.

- **Core loop:** build roads → place homes, workplaces, shops, services → residents
  start living their days (commute, shop, return home) → traffic emerges → the
  city grows and demand rises → the player reshapes the network (add lanes,
  turn pockets, signals, roundabouts, highways, bridges) to keep the city moving.
- **It should feel real.** People who drive should recognise what they see:
  keep-right-and-pass-on-the-left behaviour, cars lining up in the correct
  lane well before a turn, left-turners waiting for a gap in oncoming traffic,
  right-on-red, signals that react to queues, morning and evening rush hours, police
  cruising neighbourhoods and everyone pulling over for a siren.
- **Not a clone.** It is *not* Mini Motorways. Do not copy its rules: no
  colour-matched house-to-destination pins, no road-tile budget, and no
  weekly upgrade picks. Do not use its assets, fonts, icons, name or screen
  layout either. We borrow only the *feel* of its visual language (§3).
- **Modes:** *Sandbox* (unlimited, everything unlocked: the default and
  priority) and *Growth* (the city grows on its own as weeks pass and the player
  keeps up). Growth is a stretch goal after Sandbox is excellent.

---

## 3. Visual & UX direction — "soft cartographic minimalism"

The reference image from the user is **an aesthetic mood only**. **Do not
reproduce its layout, map, buttons or composition.** Capture the qualities below
in an **original** design.

### 3.1 Qualities to capture
- **Flat, top-down, map-like.** The land is a warm, muted cream. Water is a soft
  aqua with a subtle grid or ripple. Coastlines and sandy beaches are pale yellow,
  and parks have round soft-green trees with tiny drop shadows.
- **Roads are clean, rounded, light ribbons** (off-white/very light grey on the
  cream ground) with fully rounded caps and smooth curves. Lane markings appear
  only when zoomed in: thin dashed white lines, a double centre line on two-way
  roads, and stop bars at signals. Junctions are seamless, with no visible seams
  or overlapping strokes.
- **Buildings are soft, slightly extruded rounded tiles** with a long, soft,
  directional drop shadow (consistent light from the top-left) and a darker
  "side" band to suggest height. Each building type has its own muted colour
  family and a simple pictogram. Apartments are taller (longer shadow) than
  houses.
- **Vehicles are small rounded capsules** with a lighter roof and a tiny shadow.
  Each vehicle class has a distinct silhouette: sedan, SUV, van, box truck, bus,
  police car. Body colours come from a muted, realistic palette (whites, greys,
  blacks, dusty blues and reds), not a rainbow. Police cars are black-and-white
  with light bars that flash red/blue when responding. Turn signals blink amber,
  and brake lights glow when decelerating hard. Show these details at close zoom.
- **Typography:** one rounded, heavy geometric sans for the HUD (SF Pro Rounded,
  Heavy/Bold). Use a large, high-contrast clock/day indicator and generous
  letter-spacing for map labels (district or water names in faded caps).
- **Chrome is minimal and floating:** circular and rounded-square buttons with
  soft shadows, a dark slate icon colour, and no heavy panels over the map.
  Tool palettes slide in from an edge and collapse when not in use.
- **Motion:** everything eases (no linear UI animations). Placed buildings
  "pop" with a slight overshoot. Roads draw in along their length.
  Respect **Reduce Motion**.
- **Day/night cycle:** the palette shifts subtly through the day, with a cooler
  dusk and a dim night where headlights and windows glow softly. Keep it readable;
  never go truly dark.

### 3.2 Design system (implement as code, not ad-hoc values)
Create `DesignSystem/` in the app with:
- Colour tokens (`land`, `water`, `waterGrid`, `beach`, `park`, `road`, `roadEdge`,
  `laneMarking`, `centerLine`, `shadow`, building families, vehicle palette,
  signal red/amber/green, police red/blue, UI ink, UI surface), each with day,
  dusk and night variants.
- Spacing, corner-radius and shadow tokens; typography styles.
- A **design preview screen** (debug menu) that renders every token, building,
  vehicle and road type at multiple zooms. Use it, and screenshots of it, to
  judge visual quality.

### 3.3 Screens
- **Title / city picker:** an animated live mini-city in the background; New City
  (with map seed and driving-side options), Continue, Load, Settings.
- **Game screen:** full-bleed map; a compact HUD (day + clock, population,
  vehicles on the road, average commute, a flow indicator); a build palette;
  play/pause/speed controls; an overlay toggle (congestion, police coverage,
  noise-free "data view"); and a tap-to-inspect card for any car, road,
  junction or building.
- **Stats sheet:** time-series charts (Swift Charts) for flow, average speed, trip
  time and police response time, plus a per-intersection Level of Service (A–F)
  table.
- **Settings:** driving side, units (mph/km/h), sound, haptics, graphics quality,
  and a Show Debug Overlay toggle.
- Support **iPhone and iPad, landscape-first** (portrait should still work), all safe
  areas, Dynamic Type in sheets, VoiceOver labels on every control, and haptics on
  placement and errors.

---

## 4. Simulation realism specification (the heart of the project)

SI units throughout (metres, seconds, m/s). Use a fixed timestep (default 1/20 s).
Keep it deterministic. The engine stays UI-free.

### 4.1 Driving side & rules of the road
- `DrivingSide` = `.right` (default: US rules) or `.left` (UK/JP/AU). **Every**
  side-dependent behaviour is derived from this one setting: lane offsets,
  passing side, turn lane assignment, which turn is "across traffic",
  turn-on-red, and which curb to pull over to. Test both.
- **Keep right except to pass** (`.right`): discretionary passing happens on the
  **left**, and vehicles drift back right after passing (MOBIL asymmetric bias).
  Undertaking (passing on the right) is penalised on multi-lane highways and
  allowed on urban arterials. Mirror all of this for `.left`.
- No lane changes across solid lines, inside junctions, or within a configurable
  distance of the stop line (default 15 m on arterials).
- Speed limits are per road class and per segment, and drivers have a personal
  desired-speed factor (normal distribution, e.g. mean 1.03, σ 0.08, clamped).

### 4.2 Road & junction geometry
- **Road classes:** local street, collector, arterial (2–3 lanes/dir, optional
  median), highway (grade-separated only: no at-grade junctions), on/off ramps.
  Lane count and one-way/two-way can be configured per segment.
- **Curved roads.** Draw roads as smooth curves (Catmull-Rom → arc-length-
  parameterised polylines). Lanes are true offsets of the centreline.
- **Junction geometry:** compute stop lines from the approach widths. Turn paths
  are proper arcs/clothoid-ish curves from each in-lane to its out-lane,
  hugging the correct corner. Right turns are tight; left turns sweep through the
  junction on their own side so that **opposing left turns do not overlap** (US
  convention, mirrored for `.left`). Generate a polygonal junction surface for
  rendering.
- **Turn lanes:** arterials automatically get **left-turn pockets** (storage
  length scaled to approach speed) and optional right-turn lanes. Lane-use
  arrows are rendered. Lane assignment for multi-lane turns follows the
  "turn into the corresponding lane" rule.
- **Roundabouts:** real circulating lanes, yield on entry, gap acceptance against
  circulating traffic, and correct exit lane choice.
- **Highways:** on-ramp **acceleration lanes** with merge (cooperative yielding plus
  zipper behaviour), off-ramp **deceleration lanes**, optional **ramp meters**,
  and **grade separation** (overpasses, bridges and tunnels never create conflicts).
  Bridges over water are a road property.
- **Lane drops** use zipper merging; vehicles in the ending lane become
  mandatory changers with urgency rising toward the taper.

### 4.3 Vehicle dynamics & lane changing
- Longitudinal: **IDM** (or IDM+) with per-driver parameters. Add a small
  reaction-time/anticipation term so stop-and-go waves can form. Use bounded
  jerk for comfort, with an emergency braking limit (≈ −8 m/s²) that is used only
  when necessary.
- Vehicle classes with their own length, width, acceleration and braking:
  car, SUV, van, box truck, bus, police.
- **Lane change = a continuous manoeuvre, not a teleport:**
  1. Decide with **MOBIL** (discretionary: politeness, threshold, keep-right bias;
     mandatory: route-driven, urgency rising as the turn approaches).
  2. Signal for ~1.5–3 s (blinker visible), keep checking safety.
  3. Execute a smooth lateral move over ~3–5 s (scaled by speed) along a
     sigmoid/quintic path, with heading following the path tangent.
  4. **During the manoeuvre the vehicle occupies both lanes.** Followers in *both*
     lanes treat it as a leader, and it respects leaders in both lanes.
  5. Abort and return if safety is violated mid-manoeuvre.
  6. **Cooperative yielding:** a follower in the target lane may open a gap for a
     signalling mandatory changer (politeness-weighted).
- **Lane pre-positioning:** look ahead along the route 2–3 segments and move into a
  connecting lane early (e.g. ≥150 m before the junction on arterials), not
  at the last moment. If the driver can't get over, they **miss the turn and
  reroute**. They don't stop dead in the lane, except at a final-chance
  low-speed squeeze.

### 4.4 Intersections & "automated" traffic control
- **Automatic control selection** when a junction is created or edited, using
  simplified MUTCD-style warrants based on the classes of the meeting roads and
  their measured volumes:
  - local × local → uncontrolled (yield to the right) or all-way stop when volume rises
  - local/collector × arterial → two-way stop on the minor approach
  - arterial × arterial or high volume → **traffic signal**
  - Re-evaluate periodically (e.g. each sim-day) and **suggest** upgrades.
    Only auto-apply if "Auto traffic control" is on (default on in Sandbox).
    The player can always override and lock a junction's control.
- **Signals (NEMA-style dual-ring, 8-phase):**
  - Protected, permitted and protected-permitted left turns. Use a
    flashing-yellow-arrow equivalent for the permitted left.
  - **Actuated control**: virtual stop-bar and advance detectors, with min green,
    passage time/gap-out, max green, and skipping phases with no demand.
  - Compute yellow from the ITE formula `Y = t + v / (2a + 2Gg)` and all-red
    from junction width. Respect pedestrian timing only if you add pedestrians.
  - **Adaptive mode** (Webster's optimal cycle from measured flows) and
    **coordination** (offsets along a corridor to create green waves). Expose
    these in the junction inspector.
  - **Right-on-red** after a full stop with gap acceptance (`.right`; mirrored as
    left-on-red for `.left`). Can be toggled per city.
  - Dilemma-zone behaviour: on yellow, stop if you can stop comfortably, otherwise
    proceed.
- **Stop signs:** full stop, then first-come-first-served (arrival order) with
  gap acceptance. Two-way stop: the minor road yields to all major-road traffic.
- **Gap acceptance everywhere** is time-based: critical gap ≈ 4–7.5 s depending
  on the movement (HCM values), follow-up headway, per-driver variation.
  Permissive left turns yield to **oncoming through and right-turning traffic
  using actual arrival times**.
- **Conflict safety:** the intersection manager must guarantee that no two
  vehicles' footprints overlap inside a junction (crossing or merging movements).
  Keep the "don't enter unless the exit has room" rule. Keep a deadlock-free
  tie-break, and add **gridlock detection** (cycle in the wait-for graph). When
  it is detected, log it, surface it in the debug overlay, and resolve it the way
  real traffic does (a slow release by priority). Never teleport cars.

### 4.5 Demand: a realistic traffic-generation engine
Replace "zones as abstract weights" with **buildings that hold people and jobs**.
- **Buildings:** house (2–4 residents), townhouse row, apartment block (20–80),
  shop, office, factory/warehouse (generates truck trips), school, police
  station, plus optional fire station and hospital. Every building has a
  **driveway / access point** onto a specific road segment, and its own small
  parking capacity.
- **Population synthesis:** residents get an employment status, a workplace
  (gravity model weighted by jobs and travel time), and a schedule.
- **Activity-based trips:** home→work→(optional shop/school run)→home. Use
  realistic departure-time distributions: AM peak 07:00–09:00, PM peak
  16:00–18:30, midday shopping, a light evening and a very light night. Weekdays
  differ from weekends, and the HUD clock shows the day of week. Freight trips
  happen mostly midday.
- **Route choice:** A\* on live travel-time costs with **stochastic (logit)
  perturbation**, so equivalent routes share load. En-route rerouting has
  hysteresis (only switch when meaningfully better). Pre-trip and en-route
  choices can differ.
- **Spawning and despawning are physical:** cars back or pull out of the
  driveway onto the curb lane with gap acceptance, and finish by turning into
  the destination's driveway or lot. They never appear or vanish on a live lane.
  If the destination lot is full, the car circles or parks on-street (a
  stretch goal).
- **External traffic:** map edges have "regional connections" that inject and
  absorb through-traffic proportional to city size (highways especially).
- **Growth (rising traffic):** in Growth mode, population and jobs increase
  over days. New houses and businesses appear near well-connected roads, with
  demand ramping smoothly. In Sandbox, the player places buildings, and each
  placed building's occupancy fills in over a short period so traffic visibly
  increases. A global "demand multiplier" slider remains for experimentation.
- All of this must be deterministic with the seed and scale to **≥1,500
  simultaneous vehicles** (see §8).

### 4.6 Police & emergency services
- **Police station** (player-placeable): it houses N patrol units (default 3,
  scaled with station size).
- **Patrol behaviour:** units leave the station and **patrol residential
  neighbourhoods the player has placed**. Patrol routes are random-waypoint
  walks weighted toward home density and low recent-coverage streets, so police
  "move around the homes". They obey every traffic law while patrolling, cruise
  slightly below the limit, and occasionally park at a curb for a while.
- **Incidents:** a stochastic incident generator (rate scales with population,
  and is reduced locally by recent patrol coverage) creates calls at homes or
  businesses. Show a small pulsing marker on the building.
- **Dispatch:** the nearest *available* unit (by travel time, not distance)
  responds with lights and siren. Emergency driving: higher desired speed,
  proceeds through red signals **only after slowing and checking** that the
  junction is clear, and may use oncoming/centre space if blocked (stretch goal).
- **Civilian response to sirens:** vehicles ahead within a hearing/sight radius,
  and in the unit's path, **pull toward the curb (right for `.right`, left for
  `.left`) and slow or stop**. Vehicles approaching a junction the unit is
  crossing hold their position. Optional signal pre-emption gives the unit's
  approach a green.
- **On scene:** the unit parks at the building (hazard lights) for a sampled
  service time, then clears and resumes patrol.
- **Traffic stops (stretch goal):** patrols occasionally pull over a speeding
  driver (both pull to the curb). Passing traffic slows slightly (rubbernecking).
- **Minor collisions (optional, off by default):** rare fender-benders that
  block a lane until police clear them. These must be caused by a modelled
  risk factor, never by a physics glitch.
- **Metrics/overlay:** average and 90th-percentile response time, a coverage
  heatmap overlay (time-to-reach from the nearest station), and unit status in the
  station inspector.

### 4.7 Metrics
Per segment: flow (veh/h), density (veh/km/lane), space-mean speed, travel-time
index. Per junction: average delay and HCM **Level of Service A–F**, plus queue
length. Network-wide: VKT, VHT, average trip time, % time congested, completed
trips per hour, and police response times. Keep rolling history for charts.

---

## 5. City building & game features
- **Map:** a procedurally generated terrain from a seed (coastline, river, lakes,
  parks, gentle district labels). Water requires bridges. Provide 3–4 curated
  starter maps and an empty-land option.
- **Tools:** draw road (freeform, with smooth curves; snapping to existing roads
  creates junctions at crossings; class, lanes and one-way options), upgrade or
  downgrade road, bridge/tunnel, roundabout, junction control override (signal /
  stop / yield / roundabout / auto, with lock), turn-pocket toggle, place
  buildings (all types in §4.5), place police station, bulldoze, move junction,
  and **undo/redo** (full command stack).
- **Placement validation** gives clear feedback (red ghost plus a haptic) instead of
  silently failing. Buildings auto-orient their driveway to the nearest road.
- **Inspector** for any entity: a car shows its origin→destination, trip purpose,
  route polyline highlighted, speed, driver aggressiveness and state (e.g.
  "waiting for gap", "changing lanes left"). Roads, junctions and buildings show
  their stats and settings.
- **Time controls:** pause, 1×, 3×, 10× (and 30× in Sandbox). Sub-step correctly
  at high speed. The renderer interpolates.
- **Save/Load:** multiple named cities with JSON (`Codable`) snapshots, including
  the network, buildings, population, signal plans, sim time and RNG state.
  Autosave every in-game hour and on backgrounding. Schema version field +
  migration. **A load followed by a run must be bit-identical to an uninterrupted
  run** (test it).
- **Lifecycle:** pause on background, resume cleanly, handle low-memory warnings,
  and never crash or hang on launch even with a corrupted save (fall back to
  "could not load" UI).
- **Sound (optional, tasteful):** ambient city hum scaled by traffic, a soft UI
  click on placement, and a distant siren when police respond. Mute toggle.

---

## 6. Architecture

```
TrafficEngine/            Swift package — pure simulation (no UI imports)
  Sources/TrafficEngine/  Math, Network, Geometry, Agents, CarFollowing, LaneChange,
                          Intersections (control, signals, conflicts), Demand
                          (population, schedules, trips), Services (police),
                          Routing, Metrics, Persistence (Codable models), Simulation
  Sources/trafficsim/     Executable CLI: run a scenario headless, print metrics &
                          invariant violations, export a JSON trace (runs on Linux too)
  Tests/                  Unit, property/invariant, soak, determinism, perf tests
TrafficSimulatorApp/      SwiftUI app + rendering
  DesignSystem/           Tokens, styles, preview screen
  Rendering/              SpriteKit (or Metal) map, roads, buildings, vehicles, overlays
  Game/                   GameController (engine bridge), tools, undo stack, save/load
  UI/                     Screens, HUD, inspectors, charts, settings
TrafficSimulatorUITests/  XCUITest launch, smoke and screenshot tests
project.yml               XcodeGen spec (source of truth for the Xcode project)
.github/workflows/ci.yml  macOS CI: engine tests, app build, UI tests, screenshots
```

- **Threading:** run the simulation on a dedicated background actor or serial
  queue. Publish an immutable **render snapshot** (double-buffered) each step.
  The renderer reads the latest snapshot and **interpolates** poses between the
  last two steps for buttery motion. The UI never mutates engine state directly.
  Edits are queued as commands and applied between steps.
- **Rendering:** keep SpriteKit unless profiling proves it insufficient (document
  the decision). Bake static layers (land, water, roads, markings, buildings) into
  textures/tiles that are rebuilt **incrementally** only around edits. Vehicles are
  batched sprites sharing an atlas. Use LOD: hide markings and signals at far zoom,
  and show blinkers and brake lights only at near zoom. Pan, zoom and rotate-free
  camera with inertia and bounds.
- **Project file:** don't hand-edit `project.pbxproj`. Generate it with **XcodeGen**
  from `project.yml`, and commit both. CI regenerates and diffs to catch drift.
  If XcodeGen is unavailable, create the project with Xcode-standard tooling and
  validate it with `xcodebuild -list` before committing.
- Targets: iOS 17.0+, Swift 5.10+ (Swift 6 language mode if it compiles cleanly
  without hacks), Xcode 16+.

---

## 7. Milestones (do them in order; each has exit criteria)

Each milestone ends with: the full verification ladder (§10) green, `PROGRESS.md`
updated, a commit, and a push.

- **M0 — Ground truth.** Audit (§1). Set up the toolchain (§10.1). Make the
  *current* app build and launch with a launch smoke test, so you have a known
  baseline. Add CI. Fix the README paths. Move the project to XcodeGen.
  *Exit:* CI green on the old app plus the engine tests. A screenshot of the
  launched app is committed under `docs/screenshots/m0/`.
- **M1 — Geometry & rules.** `DrivingSide`, curved roads, proper junction
  geometry and turn paths, turn pockets, lane markings data, the geometry-on-edit
  fix. *Exit:* geometry unit tests pass, and both driving sides render correctly
  in the CLI's SVG/PNG debug dump and in-app.
- **M2 — Driving behaviour.** Continuous lane changes with blinkers, a two-lane
  footprint during manoeuvres, keep-right/pass-left, lane pre-positioning,
  missed-turn rerouting, cooperative merge, lane drops, vehicle classes.
  *Exit:* behaviour tests (§10.3) pass, and the no-teleport invariant holds in
  the soak tests.
- **M3 — Intersections.** Auto control selection, dual-ring actuated signals,
  protected/permissive lefts with real gap acceptance, right-on-red, stop-sign
  FCFS, roundabouts, footprint-level conflict safety, gridlock detection.
  *Exit:* intersection tests pass, and there are zero junction overlaps in
  1 hour of soak on all scenarios.
- **M4 — Demand engine.** Buildings with driveways, population and schedules,
  activity trips, logit routing, physical spawn and despawn, external traffic,
  growth. *Exit:* the time-of-day flow curve shows clear AM/PM peaks in the CLI
  report, and demand scales with population.
- **M5 — Police.** Stations, patrols around homes, incidents, dispatch,
  emergency driving, civilian pull-over, pre-emption, response metrics, coverage
  overlay. *Exit:* police tests pass, and the measured mean response time is
  finite and sensible in all scenarios.
- **M6 — Visual overhaul.** The design system (§3), terrain, buildings, vehicles,
  day/night, HUD, palette, inspectors, charts, title screen, animations.
  *Exit:* the screenshot set (§10.5) is reviewed by you against §3 and the
  issues are fixed. Commit before/after shots.
- **M7 — Game layer.** All tools, undo/redo, placement validation, save/load
  (bit-identical resume), autosave, lifecycle, settings, sound, accessibility.
  *Exit:* UI tests cover building a small town from scratch, saving, relaunching
  and loading.
- **M8 — Performance & polish.** Meet the budgets in §8 and fix every open bug in
  `PROGRESS.md`. Finalise the README, `ARCHITECTURE.md` and `DECISIONS.md`.
  *Exit:* the Definition of Done (§12) is fully checked.

---

## 8. Performance budgets
- Engine step with **1,500 vehicles** on a large scenario: **≤ 4 ms** average on CI
  macOS hardware (measured by an `XCTest` `measure` block or CLI benchmark;
  record the numbers).
- App: **60 fps** steady at 1,000 vehicles on an iPhone 13-class simulator or
  device at default zoom. No frame >50 ms during editing (incremental rebuilds).
- Cold launch to interactive map: **< 2 s** on the simulator.
- Memory: < 300 MB at 1,500 vehicles.
- Use spatial indexing (sorted per-lane arrays and a uniform grid for
  hit-testing and siren radius) rather than linear scans.

---

## 9. Scenarios (shared by tests, CLI and the app's starter maps)
Build these in `ScenarioFactory`; tests and the CLI must use the same code:
1. `corridor` — a single multi-lane road (car-following and lane-change tests).
2. `signalGrid` — a 5×4 arterial grid with signals and turn pockets.
3. `suburb` — winding local streets, cul-de-sacs, stop signs, a collector, many houses
   and one police station.
4. `downtown` — dense one-way pairs, offices and shops, coordinated signals.
5. `highwayTown` — a highway with on/off ramps, an interchange, and a bridge over a river.
6. `roundaboutVillage` — roundabouts and yield junctions.
7. `stressCity` — everything combined at high demand (≥1,500 vehicles).
Run each with `DrivingSide.right` **and** `.left`.

---

## 10. Testing & verification — mandatory, continuous

The previous build had glitches and sometimes **would not load**. Assume nothing
works until it is proven. Run this ladder at the end of every milestone, and run
levels 1–2 after every meaningful change.

### 10.1 Toolchain detection (do this first)
- On **macOS with Xcode** (`xcodebuild -version` succeeds): run every level locally,
  using `xcrun simctl` to boot simulators.
- On **Linux** (e.g. a cloud container): install a Swift toolchain (`swiftly`,
  or the official tarball from swift.org) so you can run levels 1–3 locally (the
  engine and CLI must stay Linux-compatible: no Apple-only APIs in
  `TrafficEngine`). Levels 4–5 then run on **GitHub Actions `macos-latest`
  runners** via `.github/workflows/ci.yml`. Push, wait for the run, read the
  job logs and downloaded artifacts (screenshots, xcresult summaries), and fix
  failures. Do not treat the app as verified until CI is green.
- Record which levels ran where in `PROGRESS.md`.

### 10.2 Level 1 — Engine unit tests (`swift test`)
Cover geometry, IDM, MOBIL, routing, signals (phase sequencing, yellow formula,
gap-out, max-out, skip), gap acceptance, demand (schedule distribution, gravity
model), police (dispatch picks the nearest by time, patrol coverage), persistence
round-trip, and determinism.

### 10.3 Level 2 — Behaviour tests (scripted micro-scenarios, assert outcomes)
- A faster car behind a slower car on a 2-lane road **passes on the left and
  returns right** (`.right`), and the mirror image holds for `.left`.
- A car needing a left turn 300 m ahead is in the left lane/pocket before the
  stop line in ≥95% of seeded runs. When blocked, it reroutes instead of
  stopping in the lane.
- A lane change takes ≥2.5 s of lateral motion, the blinker is on ≥1.5 s
  before lateral motion starts, and the follower in the target lane brakes
  for the changer when it is cut in front of.
- A permissive left never enters when oncoming traffic's time gap < the critical gap.
- No vehicle enters on red. Right-on-red happens only after a full stop.
- An actuated signal skips a phase with no demand and gaps out on empty approaches.
- An all-way stop serves vehicles in arrival order.
- On a siren, every civilian vehicle ahead within the radius moves toward the
  correct curb and slows to < 3 m/s. The police unit reaches the incident.
- Patrol units visit ≥80% of residential street segments within N sim-hours in
  `suburb`.
- A demand curve over a simulated weekday has AM and PM peaks ≥2× the midday trough.

### 10.4 Level 3 — Invariant soak tests & fuzzing (headless, via CLI and XCTest)
Run every §9 scenario for ≥2 sim-hours at high demand across ≥5 seeds, plus a
**fuzz run** that randomly adds and deletes roads, buildings, control changes and
police stations *while simulating*. Assert on every step:
- **No overlaps:** no two vehicle footprints (oriented boxes) intersect, on lanes,
  during lane changes, or inside junctions.
- **No teleporting:** per-step displacement ≤ `vmax·dt + ε`. Heading changes are
  bounded by the path curvature.
- **No off-road:** every vehicle's position is within its lane, connector or
  manoeuvre corridor.
- **Sanity:** no NaN/inf, speed ≥ 0, speed ≤ 1.3 × limit (non-emergency),
  acceleration within physical bounds.
- **Liveness:** no vehicle stationary >5 sim-minutes outside a detected and
  reported gridlock, and there are zero gridlocks in the non-stress scenarios.
  Trips complete at a steady rate.
- **Edit safety:** no crash, no dangling IDs, and vehicles on deleted roads are
  removed gracefully.
- **Determinism:** identical seeds produce an identical trace hash, and
  save→load→continue produces the same hash as an uninterrupted run.
The CLI prints a pass/fail report. It also renders a top-down PNG/SVG snapshot at
a requested time, so you can *see* the sim on Linux.

### 10.5 Level 4 — App build & launch (macOS / CI)
- `xcodebuild build` for iPhone and iPad simulators with zero errors and zero new
  warnings.
- **XCUITests:**
  - Launch → title screen visible within 5 s.
  - New City → map visible, and the vehicle count (exposed via an accessibility
    value on the HUD) increases within 10 s.
  - Draw a road and place a house + shop + police station via gestures, then
    confirm that trips start and a patrol car appears.
  - Save → terminate → relaunch → load → the city matches.
  - Launch with a deliberately corrupted save → no crash, an error message is
    shown.
  - Rotate the device, background and foreground the app → no crash, and the sim
    resumes.
- Run on **iPhone SE (small), iPhone 16 Pro Max (large) and an iPad** simulator.

### 10.6 Level 5 — Visual review (you must look)
- Capture screenshots (XCUITest `XCTAttachment`, or
  `xcrun simctl io booted screenshot`) of: title, an empty map, a busy rush
  hour in each starter map, zoomed-in lane changes with blinkers, a signalised
  junction with a protected left, a police response with civilians pulled over,
  night mode, every overlay, the inspector cards, the stats sheet and the design
  preview.
- **Open and look at every screenshot yourself.** Critique it against §3:
  rounded clean roads, no z-fighting or seams, shadows consistent, text legible,
  nothing clipped by safe areas, vehicles aligned to lanes, and no cars visibly
  overlapping or on the grass. Log issues in `PROGRESS.md` and fix them. Commit
  the final set to `docs/screenshots/`.

---

## 11. Code quality
- Readable, well-named Swift. Document the non-obvious maths (cite IDM, MOBIL,
  HCM gap acceptance, ITE yellow, Webster) in comments where it's implemented.
- Every tunable lives in a config struct with documented units and defaults.
- No force-unwraps on data that comes from user edits or save files.
- Keep files focused (< ~600 lines). Split `Simulation.swift` into stages.
- A debug overlay (toggle in Settings) shows FPS, step time, vehicle count, an
  invariant-violation counter, and a gridlock indicator.

---

## 12. Definition of Done (all must be true, with evidence in `PROGRESS.md`)

- [ ] The app builds from a clean clone with the documented command(s), opens in
      Xcode 16+, and launches on iPhone and iPad simulators without crashing.
- [ ] CI (`.github/workflows/ci.yml`) is green on the final commit: engine tests,
      behaviour tests, soak/fuzz (CI-length), app build, UI tests.
- [ ] Every behaviour in §4 is implemented, covered by a test in §10.3, and
      observed in screenshots.
- [ ] Zero invariant violations across all §9 scenarios × both driving sides × ≥5
      seeds × ≥2 sim-hours, plus fuzzing.
- [ ] Performance budgets in §8 are met, with the numbers recorded.
- [ ] The visual design meets §3 and is original (not a Mini Motorways clone).
      The final screenshots are committed and self-reviewed.
- [ ] Save/load is bit-identical. Autosave and lifecycle are handled.
      Corrupted saves are handled gracefully.
- [ ] Accessibility: VoiceOver labels, Dynamic Type in sheets, Reduce Motion
      respected.
- [ ] `README.md` (accurate paths, how to build/run/test on macOS and Linux),
      `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/PROGRESS.md` (final
      state, no open P0/P1 bugs) are all up to date.
- [ ] All work is committed and pushed.

If any box is unchecked, **you are not done — continue working.** When everything
is checked, give a final summary: what was built, how it was verified (with the
key numbers), known limitations, and suggested next steps.
