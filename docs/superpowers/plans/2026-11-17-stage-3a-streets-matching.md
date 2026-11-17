# Stage 3a: Streets and Map Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download OpenStreetMap streets, rail and ferry lines around the owner's trips and show each trip on the way actually taken: walks on the right street between tall buildings, train rides (rough fixes) on the railway.

**Architecture:** Core gets a pure OSM parser, a road graph with a segment grid, and a Hidden Markov Model map matcher (Newson & Krumm 2009, Viterbi). The diary stores ways, fetched tiles and matched stretches in additive migration v6. An app `StreetService` fetches ~2 km tiles from Overpass one request at a time after trips end and runs the matcher only while the app is open or the phone is charging. The map draws matched geometry for confident stretches and the smoothed or recorded line elsewhere.

**Tech Stack:** Swift 6; Core (Foundation only, local + CI tests), Diary (GRDB, CI), app (SwiftUI/MapKit/URLSession, CI build).

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md` section "Streets: map matching and coverage" (plus Principles and "Bad signal"); `docs/superpowers/specs/2026-11-16-tracking-under-pressure-design.md` section 1 (rough stretches go to rail matching here). Travel-mode classification (3b) and Streets walked coverage (3c) are later plans.

## Global Constraints

- Top priority: accuracy, battery efficiency and a cool phone, together. Matching runs only while open or charging; a download is one small request after a trip.
- Privacy: each Overpass request sends only a bounding box. Ephemeral `URLSession`, no cookies, User-Agent `LifePath/<version> (personal location diary)`, nothing else leaves the phone.
- Overpass etiquette: one request at a time; on HTTP 429 or 504 stop and wait ≥ 60 s, then doubling up to 30 min; `[timeout:60]`; endpoint `https://overpass-api.de/api/interpreter`.
- Stored points are never modified; migrations additive; matches are a recomputable cache with a `matcherVersion` in `meta`.
- Unsure stretches are shown as recorded, never guessed (spec "The right street, outdoors").
- Ponytail: smallest complete change; `// shortcut: <limit>, <when to upgrade>`; synthetic fixtures only (public repo).
- Subagents never run `scripts/ci-wait.sh` (GitHub's anonymous API: 60 requests/hour); they push and report the sha.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A walk between tall buildings with 25–35 m multipath bursts: ≥ 95% of distance on the correct street; the parallel street and the alley never chosen.
- A 30 min train ride of rough fixes (hAcc 700–1500 m, true error ≤ 300 m) beside a parallel motorway: matched to the rail line, never the road.
- A walk through a park with no mapped path: unmatched, recorded line shown.
- Overpass down or rate-limiting for a day: no retry storm, no battery drain, matching waits; a tile never half-stored.
- A trip crossing a tile edge: matched across both tiles as one stretch.

---

### Task 1: OSM ways and the road graph (Core)

**Files:** Create `Core/Sources/Core/Streets.swift`; Test `Core/Tests/CoreTests/StreetsTests.swift`.

**Interfaces:**
- Produces: `public enum WayKind: String { case foot, road, rail, tram, ferry }`; `public struct Way: Sendable, Equatable { id: Int64; kind: WayKind; name: String?; oneway: Bool; nodes: [Int64]; coords: [(lat: Double, lon: Double)] }` (Equatable written by hand for the tuple array); `OSM.parse(_ data: Data) throws -> [Way]` for Overpass JSON with `out body geom`; `OSM.query(minLat:minLon:maxLat:maxLon:) -> String`; `public struct RoadGraph` built by `RoadGraph(ways: [Way])` with `candidates(lat:lon:radius:) -> [Candidate]` (segment grid with 25 m cells) and `routeDistance(from: Candidate, to: Candidate, limit: Double) -> Double?` (Dijkstra over shared OSM node ids, cut off at `limit`); `public struct Candidate { wayId: Int64; segment: Int; t: Double /* 0...1 along segment */; lat, lon: Double; distance: Double }`; `Tile` key = `(x: Int(floor(lon / 0.03)), y: Int(floor(lat / 0.018)))` and `Tile.bounds`.
- Kind mapping: `highway=footway|path|pedestrian|steps|cycleway|track|living_street` → foot; other `highway` → road; `railway=rail|light_rail|subway` → rail; `railway=tram` → tram; `route=ferry` → ferry. `oneway` only for road (`oneway=yes|1|true`, or `junction=roundabout`).

- [ ] Failing tests: `testParseOverpassJSON` (fixture JSON with a footway, a residential road with oneway, a rail line, a ferry: kinds, names, node ids and coordinates), `testCandidatesWithinRadius` (synthetic 3 × 3 grid of 100 m blocks: a point 10 m from one street gets exactly that street within 20 m), `testRouteDistanceFollowsNetwork` (two points on parallel streets 30 m apart → route via the corner ≈ 230 m, not 30), `testRouteRespectsLimit` (nil past the limit), `testTileKeyAndBounds`.
- [ ] Implement; commit.

### Task 2: HMM map matcher (Core)

**Files:** Create `Core/Sources/Core/MapMatcher.swift`; Test `Core/Tests/CoreTests/MapMatcherTests.swift`.

**Interfaces:**
- Consumes: Task 1's `RoadGraph`, `Candidate`, `WayKind`.
- Produces: `public struct MatchedStretch: Sendable, Equatable { seq: Int; wayId: Int64; fromM: Double; toM: Double; confidence: Double; first: Int; last: Int /* point indices */ }`; `MapMatcher.match(_ points: [FilteredPoint], graph: RoadGraph) -> [MatchedStretch]`; `MapMatcher.version = 1`; `MapMatcher.confident = 0.6`.

- [ ] Failing tests (synthetic street grid and noise, seeded): `testCanyonWalkOnCorrectStreet` (≥ 95% of walked distance on the true street with 25–35 m biased bursts), `testParallelStreetAndAlleyNotChosen`, `testRoughTrainMatchesRailNotMotorway` (rail and motorway 150 m apart, rough fixes hAcc 1000, true error ≤ 300 m → every stretch on rail), `testParkWalkUnmatched` (no way within reach → no stretch or confidence < `confident`), `testStillPointsSkipped`.
- [ ] Implement per spec: candidates within max(30 m, 2 × hAcc) for precise points, within min(hAcc, 1500 m) for rough points (rough points only consider rail/tram/ferry when the stretch's straight-line speed exceeds 15 m/s); emission Gaussian σ = max(4 m, hAcc) (rough: σ = min(hAcc, 300 m)); transition exp(−|route − straight| / β), β = 3 m for precise pairs and β = 50 m when either point is rough; route search limit = 2 × straight + 200 m; points closer than 2σ to the previous used point thinned; foot ways only at walking speeds (< 2.5 m/s median over ±30 s), road ways never at walking speed unless no foot way is within reach; a break (no transition possible) starts a new chain. Confidence per stretch = share of points within 2σ × probability margin over the runner-up path, 0...1.
- [ ] Core tests pass; commit.

### Task 3: Diary v6 (streets, tiles, matches)

**Files:** Modify `Diary/Sources/Diary/Diary.swift`; Test `Diary/Tests/DiaryTests/DiaryTests.swift`.

**Interfaces:**
- Consumes: Task 1's `Way`, `Tile`; Task 2's `MatchedStretch`.
- Produces: migration `v6` creating `way(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, oneway INTEGER, nodes BLOB, coords BLOB, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL)` with an index on `(minLat, maxLat)`, `tile(x INTEGER, y INTEGER, fetchedAt REAL, PRIMARY KEY(x, y))`, `matchedStretch(tripStart REAL, seq INTEGER, wayId INTEGER, fromM REAL, toM REAL, confidence REAL, first INTEGER, last INTEGER, PRIMARY KEY(tripStart, seq))`; `saveTile(_ tile: Tile, ways: [Way])` (one transaction: ways upserted, tile row last); `hasTile(_:) -> Bool`; `ways(minLat:maxLat:minLon:maxLon:) -> [Way]`; `saveMatches(tripStart: Date, _ stretches: [MatchedStretch])` (replaces that trip's rows in one transaction); `matches(tripStart: Date) -> [MatchedStretch]`. Coordinates and node ids packed as little-endian Float64/Int64 blobs.

- [ ] Failing tests: `testTileSavedAtomicallyWithWays`, `testWaysInBox`, `testMatchesReplacePerTrip`; implement; CI green; commit.

### Task 4: StreetService (download and matching)

**Files:** Create `LifePath/Streets/StreetService.swift`; Modify `LifePath/Map/SmoothingService.swift` (call after a run), `LifePath/Recorder/AppSettings.swift`, `LifePath/Features/Settings/SettingsView.swift`.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: settings `downloadStreets` (default on) "Download street maps automatically" — "Fetches the streets around your trips from OpenStreetMap. Each request sends only a map rectangle, never your track."; `streetsOnCellular` (default on) "Use mobile data for map downloads". `StreetService.run(_ diary: Diary) async` : for trips smoothed since `meta streetsUntil`, fetch the missing tiles covering each trip's bounding box (one at a time, backoff per Global Constraints, `URLSession` with `allowsCellularAccess` from the setting, `waitsForConnectivity`), then match each trip whose tiles are all present and save its stretches; re-match all trips when `meta matcherVersion` differs. Runs at the end of each smoothing run (open or charging only). Health report: event `streets tiles=N matched=M` per run.

- [ ] Implement; CI build green; commit.

### Task 5: Matched lines on the map

**Files:** Modify `LifePath/Map/MapScreen.swift`, `TrackMapView.swift`.

- [ ] In `MapLoader.load`, for each trip with stored matches, replace the coordinates of points `first...last` of each confident stretch (`confidence ≥ MapMatcher.confident`) by the matched way geometry between `fromM` and `toM` (keep the trip's colouring by date or speed); unconfident or unmatched parts keep the current line; rough stretches matched to rail draw solid. The "Recorded line" toggle still shows the recorded line everywhere. Keys stay stable (Task 5 of v0.3.1). CI build green; commit.

### Task 6: Review and release v0.4.0-preview.1

- [ ] Whole-branch ponytail review against the spec and Review Focus; one fix wave; `docs/decisions/stage-3a.md`; version 0.4.0, build 9; merge to `main`; tag `v0.4.0-preview.1`.
