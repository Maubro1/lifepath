# Stage 3b: Travel Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split each trip into stretches of walk, run, bike, car, bus, tram, train or boat; use the mode so rail rides match only rail, bikes take cycle paths and slow trams match their tracks; colour the map by mode.

**Architecture:** Core gets `TravelModes`, a small HMM/Viterbi over 30 s windows of a trip (features: CoreMotion activity, speed, halts at mapped stops, nearness to each network, share of rough fixes). It runs *before* the map matcher on the same `RoadGraph`, and `MapMatcher.match` takes the confident mode stretches to choose which networks each point may match. OSM tiles gain stops (bus, tram, station, ferry terminal) and a `cycle` way kind, so stored tiles are re-fetched once. CoreMotion activity, kept by iOS for only 7 days, is copied into the diary at each street run. Diary v7 stores activities, stops and mode stretches additively. The map gets a third "Colour lines by" option, Mode.

**Tech Stack:** Swift 6; Core (Foundation only, local + CI tests), Diary (GRDB, CI), app (SwiftUI/MapKit/CoreMotion, CI build).

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md`: Principles, "Ways of moving", "Streets: map matching and coverage" (bullet "Travel mode per stretch"), "Screens" (Map). Also `docs/superpowers/specs/2026-11-16-tracking-under-pressure-design.md` §1 and §3: trains report rough fixes and vehicles use `otherNavigation`. Builds on `docs/superpowers/plans/2026-11-17-stage-3a-streets-matching.md`. Streets walked coverage (3c) is a later plan.

## Global Constraints

- Top priority: accuracy, battery efficiency and a cool phone, together. Classification and matching run only inside `StreetService.run`, i.e. while the app is open or the phone is charging. The only new sensor work is one CoreMotion history query per run. No live sensor is added.
- Honest: nothing is invented. A stretch below `TravelModes.confident` is shown as "Unsure" (grey) and is matched by the 3a rules, never by a guessed mode. With no motion data the classifier uses only speed, networks and stops.
- Stored points are never modified. Migrations are additive (v7). Modes and matches are a recomputable cache, versioned in `meta matcherVersion` as `"\(MapMatcher.version).\(TravelModes.version)"`. Activities are *not* recomputable after 7 days, so they are stored permanently, like points.
- Privacy and Overpass etiquette as in 3a: only a bounding box leaves the phone; one request at a time; backoff from 60 s doubling to 30 min; `[timeout:60]`.
- Ponytail: smallest complete change. Mark known limits with `// shortcut: <limit>, <when to upgrade>`. Synthetic fixtures only (the repo is public).
- Subagents never run `scripts/ci-wait.sh` (GitHub's anonymous API allows 60 requests an hour). They push and report the sha.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A walk to a bus stop, a 10 min bus ride halting at mapped bus stops, then a walk: three stretches (walk, bus, walk), each boundary within one 30 s window of the truth. The bus stretch matches roads only. Test in Task 2 (`testWalkBusWalk`).
- A train ride of rough fixes beside a parallel motorway: one confident train stretch, matched to rail and never to the road, including a slow (8 m/s) stretch into a station. Tests in Task 2 (`testRoughTrainBesideMotorway`) and Task 3 (`testSlowRoughTrainStillMatchesRail`).
- A car in town halting at red lights away from any bus stop: car, not bus. Test in Task 2 (`testCarAtRedLightsIsCar`).
- A trip with no motion data (older than 7 days, or motion permission off), including a walk across a park with no mapped path: still classified by speed, networks and stops. The park walk stays walk, never boat. Test in Task 2 (`testNoActivityStillClassifies`).
- Tiles stored by 3a (no stops; cycleways stored as foot): re-fetched once, one request at a time, with the 3a backoff. Until a trip's tiles are fresh its old matches stay drawn and nothing is deleted. Test in Task 4 (`testStaleTileIsNotFresh`); the review checks the run on the phone through the `streets` event.

---

### Task 1: Stops and cycle ways from OSM (Core)

**Files:** Modify `Core/Sources/Core/Streets.swift`, `Core/Sources/Core/MapMatcher.swift` (kind sets only); Test `Core/Tests/CoreTests/StreetsTests.swift`.

**Interfaces:**
- Produces: `WayKind.cycle` (raw value `"cycle"`), added as the last case. `public enum StopKind: String, Sendable { case bus, tram, rail, ferry }`. `public struct Stop: Sendable, Equatable { id: Int64; kind: StopKind; lat, lon: Double }`. `OSM.parse(_ data: Data) throws -> (ways: [Way], stops: [Stop])`. `OSM.version = 2`: the tile content version, which says what a stored tile contains.
- Kind mapping changes: `highway=cycleway`, or `highway=path|footway|track` with `bicycle=designated`, → `.cycle`. The rest is unchanged.
- Stops: node `highway=bus_stop` → bus. Node `railway=tram_stop` → tram. Node `railway=station|halt` → rail. Node `amenity=ferry_terminal` → ferry. `public_transport=platform` nodes without these tags are ignored.
- Query adds `node["highway"="bus_stop"]\(b);node["railway"~"^(tram_stop|station|halt)$"]\(b);node["amenity"="ferry_terminal"]\(b);` inside the union. `out body geom;` stays, and returns `lat`/`lon` on nodes.
- `MapMatcher` kind sets: walkers get `[.foot, .cycle, .road]`; others stay as they are. This keeps 3a's behaviour until Task 3.

- [ ] Failing tests: `testParseStopsAndCycleways`, using the fixture JSON plus a `highway=cycleway` way, a `highway=path` way with `bicycle=designated`, a bus-stop node, a tram-stop node, a station node and a ferry-terminal node. It checks kinds, ids and coordinates, and that an untagged node is dropped. Update `testParseOverpassJSON` to the tuple result. `testQueryAsksForStops`: the query string contains `bus_stop`, `tram_stop` and `ferry_terminal`.
- [ ] Implement. Fix the one caller in `LifePath/Streets/StreetService.swift` (`fetch` returns `(ways, stops)`; stops are ignored until Task 5). Core tests pass. Commit.

### Task 2: Travel-mode classifier (Core)

**Files:** Create `Core/Sources/Core/TravelModes.swift`; Modify `Core/Sources/Core/MapMatcher.swift` (expose the rough-run speed); Test `Core/Tests/CoreTests/TravelModesTests.swift`; Modify `Core/Tests/CoreTests/Synthetic.swift` (one helper).

**Interfaces:**
- Consumes: `RoadGraph` (internal `ways`, `index`, `candidates`), `Stop`, `StopKind`, `WayKind`, `Activity`, `FilteredPoint`.
- Produces:
  - `public enum TravelMode: String, Sendable, Codable, CaseIterable { case walk, run, bike, car, bus, tram, train, boat }`
  - `public struct ModeStretch: Sendable, Equatable, Codable { seq: Int; mode: TravelMode; confidence: Double; first: Int; last: Int /* point indices */ }`
  - `TravelModes.classify(_ points: [FilteredPoint], graph: RoadGraph, stops: [Stop], activities: [(t: Date, activity: Activity)]) -> [ModeStretch]`
  - `TravelModes.version = 1` and `TravelModes.confident = 0.6`
  - `MapMatcher.roughRunSpeed(_ p: [FilteredPoint]) -> [Double]`: per point, the first-to-last straight-line speed of its rough run (0 for precise points). `fastRough` becomes `roughRunSpeed(p).map { $0 > 15 }`.
  - Test helper `ride(path: [(north: Double, east: Double)], speed: Double, every: TimeInterval, noise: Double, seed: UInt64, start: Date, halts: [(atM: Double, seconds: Double)] = [], rough: Bool = false) -> [FilteredPoint]`. It gives `.moving` points with Doppler `speed` (0 during halts). With `rough`, it gives `.rough` points every 10 s, hAcc 700–1500, error ≤ 300 m, speed −1.

**The model** (the values are decisions; the implementer writes the code):
- **Windows:** 30 s from the trip start; still points are skipped. Empty windows are skipped, and the transitions join the windows on either side (a tunnel).
- **Window features:**
  - `v`: the median valid Doppler speed of its precise points. Without Doppler, the straight-line distance first to last precise point divided by the time. A window with only rough points takes the median `roughRunSpeed`.
  - `halted`: at least two precise points ≥ 10 s apart, all with speed < 0.5 m/s (Doppler, or displacement over time). The halt position is their mean.
  - `act`: the majority over its points of the latest activity at or before each point. Stationary and unknown count as none.
  - `near[k]`: the share of points with a way of kind k within 25 m (precise) or within min(hAcc, 300 m) (rough).
  - `open`: the share of precise points with no way of any kind within 50 m.
  - `r`: the share of rough points.
- **Emission** (log, summed per window):
  - Speed (moving windows only): Gaussian `−ln σ − ½((v−μ)/σ)²` with (μ, σ) in m/s: walk (1.4, 0.4), run (3.2, 0.8), bike (5, 1.5), car (12, 9), bus (12, 9), tram (8, 4), train (25, 12), boat (6, 3).
  - Activity (when `act` is not none): walking→walk, running→run, cycling→bike, automotive→car|bus|tram|train|boat. A matching mode scores 0, any other mode −2.
  - Network: `w·(s−1)`, where s is the share near the mode's network. bike: s = near[cycle|foot|road], w = 1. car and bus: near[road], w = 3. tram: near[tram|rail], w = 3. train: near[rail], w = 3. boat: max(near[ferry], open), w = 3. walk and run: no term (walkers go anywhere).
  - Rough: −2r for walk, run, bike, car and bus; −1r for tram; 0 for train and boat. Trains report rough fixes; cars rarely do.
  - Halts (halted windows only): bus needs a bus stop within 30 m (0 if so, else −1). tram needs a tram stop within 50 m (0, else −1). train needs a rail stop within 300 m (0, else −2). boat needs a ferry terminal within 100 m (0, else −0.5). car scores −1 within 30 m of a bus stop, else 0. walk, run and bike score 0.
  - Bus needs evidence: −0.1 per moving window.
- **Transitions:** stay 0; walk↔run −2; walk↔any other mode −4; between two non-walking modes −8. Start: uniform.
- **Output:** the Viterbi path. Runs of one mode become stretches (point indices of the first and last point in the run). Confidence = 1 − exp(−m), where m = the minimum over the other modes of Σ(emission of the chosen mode − emission of that mode) over the stretch's windows, clamped to ≥ 0.
- `// shortcut: stops are scanned linearly per halted window (a trip's tiles hold hundreds), upgrade to a grid if the run time shows it`.

- [ ] Failing tests. Synthetic networks are built with the `way(...)` helper as in `MapMatcherTests`. Activities are given as `[(t, Activity)]`.
  - `testWalkBusWalk`: 3 min walk on a footway, then 10 min at 9 m/s on a road with 20 s halts at 6 mapped bus stops 500 m apart, then 3 min walk. Activities: walking, automotive, walking. Expect modes `[.walk, .bus, .walk]`, all ≥ `confident`, and each boundary within 30 s of the truth.
  - `testCarAtRedLightsIsCar`: 10 min at 12 m/s on a road with 5 halts of 40 s at points ≥ 200 m from the bus stops along the road. Expect `[.car]` ≥ confident.
  - `testRoughTrainBesideMotorway`: the rail/motorway layout and rough fixes of `MapMatcherTests.testRoughTrainMatchesRailNotMotorway`, automotive activity, and a station at each end. Expect `[.train]` ≥ confident.
  - `testTramOnTramTracks`: 8 m/s along a `.tram` way, halting at 4 tram stops, with a road 60 m away. Expect `[.tram]`.
  - `testBikeOnCyclePath`: 5 m/s on a `.cycle` way, with cycling activity. Expect `[.bike]`.
  - `testWaterbusOpenWater`: 6 m/s with no way within 200 m, plus a ferry terminal halt at the end. Expect `[.boat]`.
  - `testNoActivityStillClassifies`: (a) the bus and walk trip of `testWalkBusWalk` with `activities: []` → `[.walk, .bus, .walk]`. (b) a park walk at 1.3 m/s, 100 m from any way → `[.walk]`.
  - `testRunIsRun`: 3.3 m/s on a footway with running activity → `[.run]`.
  - `testTwoPointTrip`: two points give one stretch and no crash.
- [ ] Implement. Core tests pass (existing `MapMatcherTests` still green). Commit.

### Task 3: Modes steer the matcher (Core)

**Files:** Modify `Core/Sources/Core/MapMatcher.swift`; Test `Core/Tests/CoreTests/MapMatcherTests.swift`.

**Interfaces:**
- Consumes: Task 2's `ModeStretch`, `TravelMode`, `TravelModes.confident`; Task 1's `.cycle`.
- Produces: `MapMatcher.match(_ points: [FilteredPoint], graph: RoadGraph, modes: [ModeStretch] = []) -> [MatchedStretch]`; `MapMatcher.version = 2`.

- [ ] Failing tests:
  - `testTrainStretchNeverMatchesRoad`: precise fixes at 25 m/s, 10 m from a road and 40 m from a rail line, inside a `.train` stretch. Every matched stretch is on rail.
  - `testBikePrefersCyclePath`: a `.cycle` way 8 m beside a road, and fixes with 4 m noise centred between them, inside a `.bike` stretch. At least 90% of the time is on the cycle way.
  - `testSlowRoughTrainStillMatchesRail`: rough fixes at 8 m/s inside a `.train` stretch. Matched to rail; without modes it stays unmatched (the 3a rule for slow rough fixes).
  - `testUnsureModeKeepsOldRules`: the canyon walk with a `.car` stretch of confidence 0.3 matches exactly as with no modes.
- [ ] Implement. A point inside a stretch with confidence ≥ `TravelModes.confident` takes its kinds from the mode:
  - walk and run: `[.foot, .cycle, .road]`, one-way ignored.
  - bike: `[.cycle, .foot, .road]`, one-way ignored, and road candidates get an extra −2 log emission.
  - car and bus: `[.road]`, one-way respected.
  - tram: `[.tram, .rail]`.
  - train: `[.rail]`.
  - boat: `[.ferry]`.

  Rough points match only inside tram, train or boat stretches, at any speed. Points outside a confident stretch keep the 3a rules exactly. Remove the two 3a shortcut comments this resolves.
  - `// shortcut: bikes may ride against one-way roads and the -2 road penalty ignores oneway:bicycle and cycle lanes on the road, upgrade if matches show bikes on the wrong side`.
- [ ] Core tests pass. Commit.

### Task 4: Diary v7

**Files:** Modify `Diary/Sources/Diary/Diary.swift`; Test `Diary/Tests/DiaryTests/DiaryTests.swift`.

**Interfaces:**
- Consumes: `Stop`, `ModeStretch`, `Activity`, `OSM.version`.
- Produces:
  - Migration `v7`:
    - `CREATE TABLE activity(t REAL PRIMARY KEY, kind TEXT)`, kept like points and never pruned.
    - `CREATE TABLE stop(id INTEGER PRIMARY KEY, kind TEXT, lat REAL, lon REAL); CREATE INDEX stop_lat ON stop(lat)`.
    - `CREATE TABLE modeStretch(tripStart REAL, seq INTEGER, mode TEXT, confidence REAL, first INTEGER, last INTEGER, PRIMARY KEY(tripStart, seq))`.
    - `ALTER TABLE tile ADD COLUMN version INTEGER`. NULL marks a 3a tile.
  - Functions:
    - `saveActivities(_ a: [(t: Date, activity: Activity)])` (INSERT OR REPLACE).
    - `activities(from: Date, to: Date) -> [(t: Date, activity: Activity)]`, which also returns the latest row before `from`, so the first point has a state.
    - `saveTile(_ tile: Tile, ways: [Way], stops: [Stop], version: Int)`, one transaction with the tile row last.
    - `hasTile(_ tile: Tile, version: Int) -> Bool`, true only when the stored version ≥ `version`.
    - `stops(minLat:maxLat:minLon:maxLon:) -> [Stop]`.
    - `saveMatches(tripStart: Date, _ stretches: [MatchedStretch], modes: [ModeStretch])`, which replaces both of that trip's sets in one transaction.
    - `modes(tripStart: Date) -> [ModeStretch]`.

- [ ] Failing tests:
  - `testStaleTileIsNotFresh`: saved with version 1, `hasTile(version: 2)` is false; saved with 2, it is true.
  - `testStopsInBox`.
  - `testActivitiesIncludeStateBeforeRange`.
  - `testModesSavedWithMatches`: a replace drops the old modes too.
  - `testV6DiaryMigrates`: a diary opened, closed and reopened keeps its points.
- [ ] Implement. Update the callers in `StreetService` (`OSM.version` passed; `modes: []` until Task 5). CI green. Commit.

### Task 5: Activities, stops and modes in the street run (app)

**Files:** Modify `LifePath/Recorder/MotionService.swift`, `LifePath/Streets/StreetService.swift`.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `MotionService.activities(from: Date, to: Date) async -> [(t: Date, activity: Activity)]` (nonisolated static). It uses `CMMotionActivityManager.queryActivityStarting`, drops low confidence, and maps with `activity(_:)`. It returns empty without permission.
  - The `streets` event gains ` modes=N unsure=K`, so the owner's health report shows it working.

- [ ] Implement:
  - At the start of `work`, copy activities from `max(meta activityUntil, now − 7 days)` to now, then set `activityUntil`. This runs even when downloads are off.
  - Rematch when `meta matcherVersion != "\(MapMatcher.version).\(TravelModes.version)"`, and store that string.
  - A tile is missing when `!hasTile(tile, version: OSM.version)`. `fetch` saves stops with the ways.
  - Per trip:
    1. Read the stops of its tiles and `activities(from: trip.start, to: trip.end)`.
    2. `modes = TravelModes.classify(...)`.
    3. `saveMatches(tripStart:, MapMatcher.match(trip.points, graph:, modes:), modes:)`.
  - `// shortcut: trips are classified only once their tiles are fresh, so with downloads off nothing gets a mode, upgrade if the owner turns downloads off`.
- [ ] CI build green. Commit.

### Task 6: Colour lines by mode (app)

**Files:** Modify `LifePath/Map/MapScreen.swift`, `LifePath/Map/TrackMapView.swift`.

**Interfaces:**
- Consumes: `diary.modes(tripStart:)`, `TravelMode`, `TravelModes.confident`.
- Produces: `enum LineColour: String, CaseIterable { case date = "Date", speed = "Speed", mode = "Mode" }` replaces `bySpeed: Bool` (MapScreen state, TrackMapView property, coordinator `shownBySpeed`, and the overlay key prefix `"l\(colour)-"`). `MapLine.modes: [TravelMode?]` has one entry per coord; nil means unsure or unknown. `extension TravelMode { var color: UIColor; var label: String }` lives in `TrackMapView.swift`.

- [ ] Implement:
  - In `MapLoader.load`, read `diary.modes(tripStart:)` per trip (in both recorded and matched views: the mode belongs to the trip, not the geometry). Each point takes the mode of the stretch that holds it when confidence ≥ `TravelModes.confident`, else nil. Spliced matched vertices borrow the nearest fix's mode, as they already do for speeds. Combine the modes into the line hash.
  - Zoomed-out cached trip lines take one colour: their trip's longest confident mode, else nil. This is less detail, never fewer trips.
  - The renderer for mode is `MKGradientPolylineRenderer` with each vertex's `color`:
    - walk `.systemGreen`, run `.systemMint`, bike `.systemBlue`, car `.systemRed`, bus `.systemOrange`
    - tram `.systemYellow`, train `.systemPurple`, boat `.systemTeal`, unsure `.systemGray`
    - The rough dashing stays.
  - The picker "Colour lines by" gets a third segment, "Mode". While Mode is chosen, one small row under the pickers shows a dot and label per mode, plus "Unsure" (accessibility label "Mode colours"). These are plain system styles; stage 6 restyles them.
- [ ] CI build green. Commit.

### Task 7: Review and release

- [ ] Whole-branch ponytail review against the spec bullet "Travel mode per stretch", the Global Constraints and the Review Focus.
- [ ] One fix wave.
- [ ] Write `docs/decisions/stage-3b.md`. It records the decisions below, so the owner can be asked later:
  - Network nearness stands in for "which network the matcher fits": the classifier runs before the matcher, one matching pass.
  - Tiles are re-fetched once for stops and cycle paths.
  - Activities are stored permanently.
  - Bus needs evidence: car wins ties.
  - The mode colours.
- [ ] Version 0.4.0. The build number is one above the last released build. Merge to `main` and tag the next `v0.4.0-preview.N`. If stage 3a's Task 6 has not shipped yet, this release covers both, as `v0.4.0-preview.1`.
