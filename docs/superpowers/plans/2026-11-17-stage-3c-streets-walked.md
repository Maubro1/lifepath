# Stage 3c: Streets Walked Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count the streets the owner has walked, by the CityStrides rule, show them highlighted on the map with a "Streets" toggle and a one-line tally, and let cycling count when the owner wants it.

**Architecture:** Core gets `Coverage`: ways cut into ~20 m segments; each trip's confident matched stretches that fall inside confident walk, run or bike stretches (by time) mark the segments they pass within 15 m of; streets are named ways joined at shared nodes (or one unnamed way) and are covered at ≥ 90% of their length (every segment when 10 or fewer). OSM tiles learn which ways count as streets (no motorways, driveways or separately mapped sidewalks), so tiles are re-fetched once. Hits are stored per trip with the matches (Diary v8), so a re-match replaces them. After matching, the street run recomputes the covered ways and the tally, both with and without cycling, so flipping the setting needs no work. The map draws covered streets under the trip lines.

**Tech Stack:** Swift 6; Core (Foundation only, local + CI tests), Diary (GRDB, CI), app (SwiftUI/MapKit, CI build).

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md`: Principles; "Streets: map matching and coverage" (bullet "Coverage"); "Screens" (Map toggle "Streets"; Stats section "Streets walked"). Builds on `docs/superpowers/plans/2026-11-17-stage-3a-streets-matching.md` and `docs/superpowers/plans/2026-11-17-stage-3b-travel-modes.md`.

**Where the numbers live until stage 4:** the Stats screen does not exist yet. The smallest home is the map: the "Streets" toggle shows the covered streets and one caption line, "Streets walked: 42 of 1,310 (3.2%)". The full Stats section ("% of downloaded streets covered, per area") is stage 4; it reads the same `coveredWay` table and `streetsWalked` meta, so nothing here is thrown away.

## Global Constraints

- Top priority: accuracy, battery efficiency and a cool phone, together. Hits and coverage are computed only inside `StreetService.run` (app open or charging). The map only reads stored results. No sensor work is added.
- Coverage rule, verbatim from the spec: "ways split into ~20 m segments; a segment is hit when a confident matched stretch classified as walking (cycling optional, setting) runs along it; vehicle stretches never count. A street (all segments of a named way, or the way if unnamed) is covered at ≥ 90% of its length hit (100% for 10 or fewer segments), the CityStrides rule."
- Confident means both: matched stretch `confidence ≥ MapMatcher.confident` and mode stretch `confidence ≥ TravelModes.confident`. Walking means mode `.walk` or `.run`; `.bike` counts only with the setting on; every other mode never counts.
- Stretches are identified by timestamps (`start`, `end`), never by point indices.
- Setting: title "Count cycling in Streets walked", key `countCycling`, default off.
- Honest: unsure stretches never count; until tiles are re-fetched with street flags, nothing counts (old rows read as not countable).
- Stored points are never modified. Migration v8 is additive. Hits and coverage are a recomputable cache: `meta matcherVersion` becomes `"\(MapMatcher.version).\(TravelModes.version).\(Coverage.version)"`.
- Privacy and Overpass etiquette as in 3a (bounding box only, one request at a time, backoff 60 s doubling to 30 min).
- Ponytail: smallest complete change; `// shortcut: <limit>, <when to upgrade>`; synthetic fixtures only (public repo).
- Subagents never run `scripts/ci-wait.sh` (GitHub's anonymous API allows 60 requests an hour). They push and report the sha.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A walk to a bus stop and a bus ride along the same street: one matched stretch can span both; only the walked part counts. Test in Task 2 (`testBusPartNeverCounts`).
- Sidewalks mapped as separate footways (common in Dutch cities): walking them credits the named street beside them, and the sidewalks themselves never enter the street count. Tests in Task 1 (`testCountableWays`) and Task 2 (`testSidewalkCreditsStreet`).
- Two streets of the same name in different towns ("Kerkstraat"): two streets, not one. Test in Task 2 (`testSameNameApartAreTwoStreets`).
- A re-match (new version) or a re-matched trip: its old hits go with its old matches, so no stale coverage stays. Test in Task 3 (`testHitsReplacedWithMatches`).
- The owner flips "Count cycling in Streets walked": the tally and the highlighted streets change at once, with no re-match. Test in Task 3 (`testCoveredWaysRespectBike`); the Task 6 review checks it on the phone.

---

### Task 1: Which ways count as streets (Core)

**Files:** Modify `Core/Sources/Core/Streets.swift`; Test `Core/Tests/CoreTests/StreetsTests.swift`.

**Interfaces:**
- Produces: `Way.countable: Bool` (a street for Streets walked), last init parameter `countable: Bool = true`, included in `==`. `OSM.version = 3` (doc comment: 3 = plus street flags), so every stored tile is re-fetched once.
- Rule in `OSM.parse`: `countable` is true for kinds `.foot`, `.cycle`, `.road`, except when any of:
  - `highway` ∈ motorway, motorway_link, trunk_link, service, construction, proposed, platform, raceway, bus_guideway, busway, corridor, elevator, escape
  - `motorroad=yes`
  - `footway` ∈ sidewalk, crossing, or `cycleway=crossing`, or `path=crossing`
  - `access` ∈ private, no, or `foot=no`, unless `foot` ∈ yes, designated, permissive

- [ ] **Step 1: Failing test** `testCountableWays`: parse a fixture with a named residential road, a motorway, a `service` road, a `footway=sidewalk`, an `access=private` road with `foot=yes`, a `foot=no` trunk and a railway. Assert `countable` is `[true, false, false, false, true, false, false]` in that order.
- [ ] **Step 2: Run** `swift test --package-path Core --filter StreetsTests`. Expected: FAIL (no `countable`).
- [ ] **Step 3: Implement** the rule as one `static func countable(_ t: [String: String], _ kind: WayKind) -> Bool` beside `kind(_:)`.
- [ ] **Step 4: Run** the Core tests. Expected: all PASS.
- [ ] **Step 5: Commit** `Streets: OSM ways learn whether they count as streets; tiles re-fetched once`.

### Task 2: Coverage (Core)

**Files:** Create `Core/Sources/Core/Coverage.swift`; Test `Core/Tests/CoreTests/CoverageTests.swift`.

**Interfaces:**
- Consumes: `RoadGraph` (internal `ways`, `index`, `lens`, `candidates`), `MapMatcher.along(_:_:)`, `Way.slice`, `Way.countable`, `MatchedStretch`, `ModeStretch`.
- Produces:
  - `public struct SegmentHit: Hashable, Sendable { public var wayId: Int64; public var seg: Int; public var bike: Bool }`
  - `public struct CoverageResult: Sendable, Equatable { public var ways: [Int64: Bool] /* covered way → true when covered only with cycling */; public var onFoot: Int; public var withBike: Int; public var total: Int }`
  - `Coverage.version = 1`, `Coverage.segmentLength = 20.0`, `Coverage.reach = 15.0`
  - `Coverage.segments(_ length: Double) -> Int` = `max(1, Int((length / 20).rounded()))`; segment i spans `[i, i+1) · length / n`.
  - `Coverage.hits(_ matches: [MatchedStretch], modes: [ModeStretch], graph: RoadGraph) -> Set<SegmentHit>`
  - `Coverage.streets(ways: [Way], hits: [SegmentHit]) -> CoverageResult`

**`hits`:** for each confident mode stretch of walk, run or bike (`bike = mode == .bike`), and each confident matched stretch overlapping it in time:
1. Clip to the time overlap: the metres along go linearly in time from `fromM` to `toM`. A stretch with `start == end` counts only when inside the mode stretch.
2. Walk the clipped geometry (`way.slice`) every 5 m, vertices included. At each sample, every candidate within `reach` on a countable way hits segment `min(n − 1, Int(along / (len / n)))` of that way.

This is how a sidewalk credits its street, and why a crossing street gets at most its end segment.
- `// shortcut: hit length is linear in time inside a matched stretch, upgrade if speed changes within a stretch show in coverage`
- `// shortcut: a road passed under a bridge within 15 m is hit too, upgrade with layer tags if the owner sees it`

**`streets`:** countable ways only.
- An unnamed way is a street. Named ways with the same name that share a node (transitively) are one street.
- Per street, take the length L, the segment count S (summed over its ways) and the hit length H (the segment length of each hit segment).
- It is covered when `S ≤ 10 ? every segment hit : H ≥ 0.9 · L`.
- Evaluate it twice, foot hits only and all hits: `onFoot` and `withBike` count the streets, `total` counts all streets, and `ways` maps every way of a street covered with all hits to `!coveredOnFoot`.

- [ ] **Step 1: Failing tests.** Synthetic ways use the `way(...)` helper style of `MapMatcherTests`. Stretches are built directly with times on a fixed `start` date.
  - `testSegments`: `segments(5) == 1`, `segments(29) == 1`, `segments(31) == 2`, `segments(1000) == 50`.
  - `testWalkHitsStreet`: a 200 m named road, one walk mode stretch (0.9) and a matched stretch 0–200 m (0.9). All 10 segments are hit, and `streets` gives `onFoot == 1, total == 1`.
  - `testBusPartNeverCounts`: a 400 m road, and a matched stretch 0–400 m over t = 0…400 s. Walk runs 0–100 s, bus 100–400 s. Only segments 0–4 are hit (allow the boundary segment 5).
  - `testUnsureNeverCounts`: a walk with mode confidence 0.3 gives no hits; a matched confidence of 0.3 gives no hits either.
  - `testSidewalkCreditsStreet`: a named road plus an unnamed `countable: false` footway 8 m beside it. The walk is matched to the footway. Every road segment is hit; `total == 1`.
  - `testNinetyPercentRule`: on a 1000 m street (50 segments), 45 hit segments cover it and 44 do not. On a 200 m street (10 segments), 9 hits do not cover it.
  - `testSameNameApartAreTwoStreets`: two "Kerkstraat" ways 5 km apart with no shared node give `total == 2`. Two joined at a node give 1. Walking one of the apart pair gives `onFoot == 1`.
  - `testCyclingCountsOnlyWithBike`: a bike stretch over a 200 m street gives `onFoot == 0`, `withBike == 1`, and `ways[id] == true`.
- [ ] **Step 2: Run** `swift test --package-path Core --filter CoverageTests`. Expected: FAIL (no `Coverage`).
- [ ] **Step 3: Implement** `Coverage.swift` as above.
- [ ] **Step 4: Run** the Core tests. Expected: all PASS.
- [ ] **Step 5: Commit** `Coverage: 20 m segments, hits from confident walking stretches, the CityStrides rule`.

### Task 3: Diary v8

**Files:** Modify `Diary/Sources/Diary/Diary.swift`; Test `Diary/Tests/DiaryTests/DiaryTests.swift`.

**Interfaces:**
- Consumes: `Way.countable`, `SegmentHit`, `CoverageResult`.
- Produces:
  - Migration `v8` (additive; NULL `countable` reads as false, so a pre-v8 way never counts):
    - `ALTER TABLE way ADD COLUMN countable INTEGER;`
    - `CREATE TABLE segmentHit(tripStart REAL, wayId INTEGER, seg INTEGER, bike INTEGER, PRIMARY KEY(tripStart, wayId, seg, bike));`
    - `CREATE TABLE coveredWay(wayId INTEGER PRIMARY KEY, bike INTEGER);`
  - `saveTile` writes `countable`, and the way decoder reads it.
  - `saveMatches(tripStart:_:modes:hits: Set<SegmentHit> = [])` replaces the trip's hits in the same transaction.
  - `segmentHits() -> [SegmentHit]`: distinct rows over all trips.
  - `countableWays() -> [Way]`
  - `saveCoverage(_ r: CoverageResult)`: one transaction that replaces all `coveredWay` rows and sets meta `streetsWalked` to `"\(onFoot) \(withBike) \(total)"`.
  - `coveredWays(minLat:maxLat:minLon:maxLon:bike: Bool) -> [Way]`: a join on the way's box; with `bike: false`, rows with `bike = 1` are left out.
  - `streetsWalked(bike: Bool) -> (covered: Int, total: Int)?`: nil before the first coverage run.

- [ ] **Step 1: Failing tests:**
  - `testCountableStored`: one countable and one non-countable way are saved; `countableWays()` returns one.
  - `testHitsReplacedWithMatches`: save trip T with 3 hits, then again with 1 hit. `segmentHits().count == 1`.
  - `testCoveredWaysRespectBike`: save a coverage with way 1 → false and way 2 → true. `coveredWays(bike: false)` gives [1], `bike: true` gives [1, 2], and `streetsWalked(bike:)` returns the matching counts.
  - `testV7DiaryMigrates`: a diary is opened, closed and reopened; its points and matches stay.
- [ ] **Step 2: Implement.** CI green (Diary tests run on CI only). Commit `Diary v8: street flags, segment hits per trip, covered ways`.

### Task 4: Hits and coverage in the street run (app)

**Files:** Modify `LifePath/Streets/StreetService.swift`.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: the `streets` event gains ` walked=onFoot/total`, so the owner's health report shows it working.

- [ ] **Step 1: Implement:**
  - The version string becomes `"\(MapMatcher.version).\(TravelModes.version).\(Coverage.version)"`. History is re-matched once, which computes hits for all past trips.
  - Per trip: `let matches = MapMatcher.match(...)`, then `saveMatches(tripStart:, matches, modes:, hits: Coverage.hits(matches, modes: modes, graph: graph))`.
  - After the trip loop, when `matched > 0 || tiles > 0`: `try diary.saveCoverage(Coverage.streets(ways: diary.countableWays(), hits: diary.segmentHits()))`. Cancellation is checked before it.
  - `// shortcut: coverage is recomputed over every downloaded street after each run that matched or fetched, upgrade to per-tile if the run time or memory shows it`
- [ ] **Step 2:** CI build green. Commit `Street run stores segment hits and recomputes Streets walked`.

### Task 5: Streets on the map, the tally and the cycling setting (app)

**Files:** Modify `LifePath/Map/MapScreen.swift`, `LifePath/Map/TrackMapView.swift`, `LifePath/Recorder/AppSettings.swift`, `LifePath/Features/Settings/SettingsView.swift`.

**Interfaces:**
- Consumes: `diary.coveredWays(...)`, `diary.streetsWalked(bike:)`.
- Produces:
  - `MapOptions.streets = false`, and `Query.streets`, `Query.bike` (read from `UserDefaults` key `countCycling` in `reload()`).
  - `MapData.covered: [(key: String, coords: [(lat: Double, lon: Double)])]`, keyed `"\(wayId)-\(tolerance)"`, and `MapData.walked: (covered: Int, total: Int)?`.
  - `final class StreetLine: MKPolyline {}` in `TrackMapView.swift`.
  - `AppSettings.countCycling` (`@AppStorage("countCycling") = false`).

- [ ] **Step 1: Implement:**
  - **Loader:** when `q.streets`, `load` reads the covered ways in the box and simplifies each with `Simplify.douglasPeucker` at `q.tolerance`. Zoomed out shows less detail, never fewer streets. It also reads `walked`.
  - **Overlays:** `TrackMapView` adds each covered way as a `StreetLine` overlay, key `"w\(key)"`, level `.aboveRoads`, so trip lines draw on top. The renderer is an `MKPolylineRenderer` with stroke `.systemCyan` at alpha 0.8 and line width 6 (a placeholder until the design stage).
  - **Toggle:** a "Streets" toggle in the Heat/Recorded row (accessibility label "Streets walked", hint "Highlights the streets you have walked").
  - **Caption:** while the toggle is on, one caption under the row reads "Streets walked: 42 of 1,310 (3.2%)". With cycling counted it reads "Streets walked or cycled: …". Before the first coverage run it reads "Streets walked: no street maps yet". Numbers use the locale's grouping, and the percent has one decimal.
  - **Settings:** a new section after the mobile-data toggle, `Toggle("Count cycling in Streets walked", isOn: settings.$countCycling)`. Footer: "On: streets you cycled count too, like on CityStrides. Off: only walking and running count. Car, bus, tram, train and boat never count."
- [ ] **Step 2:** CI build green. Commit `Map: Streets toggle highlights walked streets with a tally; setting to count cycling`.

### Task 6: Review and release

- [ ] Whole-branch ponytail review against the spec bullet "Coverage", the Global Constraints and the Review Focus. Check on the phone, through the `streets` event, that the tally appears after the one-time re-fetch and re-match, and that the cycling toggle changes it at once.
- [ ] One fix wave.
- [ ] Write `docs/decisions/stage-3c.md`. It records the decisions below, so the owner can be asked later:
  - Running counts as walking.
  - Hits within 15 m of the matched path, so a separately mapped sidewalk credits its street.
  - What does not count as a street: motorways, driveways and service roads, sidewalks and crossings, private ways.
  - Unnamed paths each count as one street (spec).
  - Same-name streets join only where they touch.
  - Tiles re-fetched once.
  - The map caption stands in for the Stats section until stage 4.
  - The highlight colour.
- [ ] Release: if v0.4.0 (stages 3a and 3b) has not shipped, this joins it as one release. Otherwise it ships as 0.4.1. The build number is one above the last released build. Merge to `main` and tag the next preview.
