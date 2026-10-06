# Audit of the first build (v1)

Date: 2026-10-05 · Auditor: lead engineer (Claude Code) · Commit audited: `e964354`

Every file in `TrafficEngine/` and `TrafficSimulatorApp/` was read. The engine's
existing suite (25 XCTest cases) was run on Linux with Swift 6.0.3. All 25 passed
in 7.2 s. The app could not be built in the audit container (Linux, no Xcode),
and **no CI had ever built it** (see §4).

## 1. Keep (good foundations)

| Area | File(s) | Why keep it |
|---|---|---|
| Pure engine / thin renderer split | whole package | The engine imports nothing, not even Foundation. It compiles and tests headless on Linux. This is preserved strictly. |
| IDM car-following | `CarFollowing/IDM.swift` | Correct Treiber formulation, pure function. Keep it and extend it with reaction-time anticipation and a bounded-jerk wrapper. |
| MOBIL decision | `LaneChange/MOBIL.swift` | Correct safety and incentive criteria as a pure function. Keep it and extend it with the asymmetric keep-right rule. |
| A\* router | `Routing/Router.swift`, `PriorityQueue.swift` | Edge-graph A\* with a pluggable cost. Keep it, add turn costs and logit perturbation, and make tie-breaking deterministic. |
| Seeded RNG + determinism | `Math/SeededRandom.swift` | SplitMix64. Keep it and make its state `Codable` so save/load can resume bit-identically. |
| Foundation-free maths | `Vector2`, `IDM.swift` (`_exp`, `_ln`) | Accidentally valuable: hand-rolled maths gives **identical results on Linux and macOS** (libm differs between platforms). Keep the approach, but replace the low-precision approximations (atan ≈1e-5, a 4-term cos) with accurate pure-Swift implementations. |
| Spill-back guard ("don't block the box") | `Simulation.destinationHasRoom` | The right idea. Keep it, and make it length-aware. |
| Conflict-graph idea | `IntersectionManager` | Precomputed pairwise conflicts per node is the right structure. Upgrade it from centre-line crossing to **footprint** conflict zones (path ± half-widths), with diverge/merge/cross classification. |
| Deterministic iteration | `rebuildTopology` sorted by id | Keep the principle everywhere: never iterate a `Dictionary` where order matters. |

## 2. Refactor

| Area | Problem | Plan |
|---|---|---|
| `Simulation.swift` (813 lines) | One file holds every stage. | Split into stages: Signals, Demand, Indexing, CarFollowing, LaneChanges, Integration, Junctions, Metrics. Keep each file under ~600 lines. |
| Storage | `[ID: T]` dictionaries everywhere. Hot loops do hash lookups, and edge lists are rebuilt as `Array(dict.values)` each call. | Dense integer IDs with array storage (`[T?]` slots), so iteration is in id order and fast. |
| Lane model | Each lane owns its own offset polyline, and `s` is per lane. Lane changes therefore have to remap `s`. | Vehicles on an edge use the edge's **reference arc-length**. A lane is a lateral offset plus an `s`-range (this also gives turn pockets and lane drops for free). Lateral position is a continuous state. |
| Metrics | Space-mean speed is computed with an `O(edges × lanes)` scan, and flow is `k·v` only. | Add detector-based counts (veh/h), the travel-time index, junction delay and LOS, VKT/VHT, and police response metrics. |
| Config | Magic numbers are spread through `Simulation` (`lookAhead`, `spawnClearance`, `0.55` connector speed). | Put every tunable in documented config structs with units. |
| Zones → buildings | Abstract weights attached to the nearest node. | Replace them with buildings, driveways, residents and schedules (M4). |

## 3. Rewrite (verified defects)

Each pre-audit defect was checked against the code:

1. **Lane changes teleport. CONFIRMED.** `applyLaneChanges` sets `track = .lane(target)`
   instantly. `updatePose` does `lateralOffset *= 0.7` per step, which is frame-rate
   dependent and fully settles in about 0.3 s at 20 Hz. There is no blinker and no
   dual-lane occupancy. The follower in the target lane sees the car only after the swap.
   → Rewrite as a continuous manoeuvre (M2).
2. **Turn paths go through the node centre. CONFIRMED.** `connectorPath` is a quadratic
   Bézier with `ctrl = node.position`. Right turns therefore swing out to the centre, and
   opposing lefts share the centre point, so they overlap.
   → Ray-intersection Bézier turn geometry that hugs the correct corner (M1).
3. **Permissive lefts don't yield to oncoming traffic. CONFIRMED.** On green, `gapAccepted`
   compares `lineWait` and then `id`. It never looks at the oncoming time gap. Because
   `nearestApproacher` only looks 14 m upstream, an oncoming car at 15 m doing 15 m/s is
   invisible.
   → Time-based gap acceptance with HCM critical gaps (M3).
4. **Signals are two-phase fixed-time only. CONFIRMED** (`makeDefaultSignalConfig`,
   `TrafficLightController`).
   → NEMA dual-ring, actuated, with protected and permissive lefts (M3).
5. **Geometry bug on edit. CONFIRMED.** `rebuildAttachedGeometry` passes
   `twoWay: seg.roadType.isTwoWayByDefault`. A one-way arterial (or a two-way highway)
   gets the wrong lane offsets after `moveIntersection`. The edge also does not remember
   whether it has a partner.
   → Roads own their direction state (M1).
6. **Vehicles pop into existence. CONFIRMED.** `spawnOne` places the car at `s = 0` of a
   live lane, already moving at up to 8 m/s, and `finish` deletes it at the lane end.
   `AppModel.placeZone` returns silently when no node is within 60 m.
   → Driveways and physical spawn and despawn (M4). Placement validation gives feedback (M7).
7. **Rendering/perf. CONFIRMED.** `SimulationScene.update` calls `model.advance`, so the
   sim runs on the main thread. Every lane is drawn as two `SKShapeNode`s (road plus heat),
   and `rebuildNetworkGraphics` throws everything away on each edit. Vehicle poses are
   not interpolated. `advance` also caps `dt` at 1/20 s × timeScale and runs at most 16
   substeps, so at 4× the sim silently runs slower than requested when frames drop.
8. **Weak tests. CONFIRMED.** `testNoCollisionsWithinLanes` checks only longitudinal gaps
   on the same lane. Nothing checks connectors, lateral overlap, teleporting or liveness.
   `testCongestionEmergesWithHighDemand` asserts only `density > 0`.
9. **Project may fail to open/build. CONFIRMED risk.** `project.pbxproj` is hand-written,
   with synthetic `AA00…` IDs and `objectVersion = 77` (Xcode 16+), and it sets
   `IPHONEOS_DEPLOYMENT_TARGET = 18.0` while the README says iOS 18 and the brief says 17.
   The README paths `TrafficSimulator/TrafficSimulator.xcodeproj` and
   `cd TrafficSimulator/TrafficEngine` do not exist (the project is at the repo root).
   No CI existed.
   → XcodeGen `project.yml` + CI (M0).
10. **No save/load, undo or lifecycle handling. CONFIRMED.** None of `Codable` world
    state, a command stack or `scenePhase` handling exists.

### Additional defects found during the audit

11. **Hard stops violate physics.** In `advanceTrack`, when permission is denied at the
    line, the code does `speed = min(speed, 0)` and `s = lane.length`. This is an
    instantaneous stop from any speed (infinite deceleration). It happens whenever
    permission flips between the approach check and the crossing. → Commit-point
    reservations (M3).
12. **Entering a junction doesn't consider vehicle footprint.** Conflict is tested only on
    centre-line polylines (`Geometry.polylinesCross`). Two near-parallel paths that pass
    within one car width are treated as non-conflicting.
13. **Leader across diverging connectors is ignored.** A follower from the same in-lane
    on a different connector doesn't see the predecessor until it reaches the out-lane,
    which allows overlap at the start of the junction.
14. **`Route.edge(after:)` uses `firstIndex(of:)`.** Routes that revisit an edge (loops after
    rerouting) advance incorrectly. → Keep an explicit route cursor.
15. **Rerouting rebuilds a closure that captures `self` per call**, and the A\* heuristic
    recomputes `maxSpeedLimit` (an `O(E)` scan) on **every node expansion**, so routing
    is `O(E²)` on large networks.
16. **Metrics `flow` double-counts**, multiplying per-lane density × speed × lane count
    (which equals total density × speed). The meaning is fine, but no measured flow
    exists anywhere.
17. **`SeededRandom._cos` is a 4-term Taylor series on [-π, π].** Its error near ±π is
    about 0.02, which biases the Gaussian samples.
18. **Time of day:** `secondsPerHour = 60` couples the clock to physics at 60×, so a
    3-minute trip spans 3 clock-hours. It needs an explicit, documented clock scale.

## 4. Baseline verification (M0)

| Level | Where | Result |
|---|---|---|
| 1 — engine unit tests | Linux container, Swift 6.0.3 (Ubuntu `swiftlang` package; download.swift.org is blocked by egress policy) | `swift test`: 25 passed, 0 failed |
| 4 — app build | GitHub Actions `macos-15` | see `docs/PROGRESS.md` |

## 5. Decision

The engine is small (≈3k lines) and its core models are sound, but the network,
vehicle and intersection layers need structural changes: edge-s coordinates,
lateral state, footprint conflicts, commit reservations and Codable state. These
changes touch every file. We will **evolve the engine in place, milestone by
milestone**. The pure-function models (IDM, MOBIL, A\*, RNG) are kept, and the
network, simulation and intersection layers are rewritten around them. The app is
rebuilt on a background-threaded snapshot renderer in M6 and M7. Until then it
is kept compiling against the evolving engine API.
