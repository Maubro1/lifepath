# Stage 6 Design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild LifePath around a map that fills up (Streets or Fog), with progress per city and neighbourhood, a You tab, and the owner's study-page look, drawn without flicker.

**Architecture:** Pure logic (palette, borders, progress, fog widths, day story) lives in Core with Windows unit tests. The Diary gains additive tables for areas, area progress and street covered dates. The app replaces the four tabs with Map and You; the map draws fog, streets and lines through three long-lived `MKOverlay` renderers that invalidate only changed rects.

**Tech Stack:** Swift 6, SwiftUI, MapKit (`MKMapView` via `UIViewRepresentable`), GRDB, XCTest, XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-17-stage-6-design.md`

## Global Constraints

- Colours: exact light/dark hex pairs from spec section 1; dynamic `UIColor { trait in ... }`, never inverted.
- Corner radius of LifePath's own cards and buttons: 3 pt. System sheets, switches, keyboards stay native.
- Fog clearing half-widths: walk/run/bike 15 m; car/bus/tram 6 m; train/boat 0 along the line, 25 m circle at the stop where boarded and left; visit 25 m circle; feather 4 m; on-screen minimum band 2 pt.
- Your lines: satsuma by default; date ramp mustard (newest) → satsuma → cherry (oldest), full alpha, never grey.
- Motion: number roll, 0.5 s one-time fade-in of new fog/streets on map open, soft spring; Reduce Motion → plain fade; no looping animation.
- Only a tile rectangle ever leaves the phone; place naming uses downloaded streets only.
- Diary migrations are additive; never index by point position, only by timestamps or ids.
- Accessibility: Dynamic Type (Bricolage via `relativeTo:`), 44 pt targets, labels for every colour coding.
- Core tests: `pwsh -NoProfile -File scripts/test-core.ps1`. App and Diary: CI only (one `scripts/ci-wait.sh` waiter at a time).

## Review Focus

1. A street that crosses a neighbourhood border: counted once, in the area holding its midpoint; totals per city still add up.
2. A city with no neighbourhood boundaries in OSM: the city is its own single neighbourhood; nothing crashes or shows 0 of 0.
3. Border download fails or a relation is huge: street matching and coverage still run; progress shows the city as "no border yet".
4. Switching Light/Dark while the map is open: fog colour and line colours redraw for the new appearance with no stale tiles.
5. A live trip growing while the map is visible: only its rect redraws; other lines and fog never blink.

---

### Task 1: Palette in Core with contrast tests

**Files:**
- Create: `Core/Sources/Core/Palette.swift`
- Test: `Core/Tests/CoreTests/PaletteTests.swift`

**Interfaces:**
- Produces: `public struct Hex { let light: UInt32; let dark: UInt32 }`; `public enum Palette` with `page, card, inset, text, muted, satsuma, cherry, mustard: Hex`; `static func mode(_ m: TravelMode) -> Hex`; `static let unsure: Hex`; `static func dateRamp(_ f: Double) -> (light: UInt32, dark: UInt32)` (f 0 newest … 1 oldest, mustard → satsuma → cherry, linear in sRGB); `static func contrast(_ a: UInt32, _ b: UInt32) -> Double` (WCAG ratio).

- [ ] **Step 1: Failing tests:** `testTextContrast` (text on page, card, inset ≥ 7 in both appearances; muted ≥ 4.5), `testLinesVisibleOnFogAndMap` (every mode colour, satsuma and `dateRamp(0/0.5/1)` ≥ 3 against `page` in its own appearance), `testRampEnds` (`dateRamp(0)` == mustard, `dateRamp(1)` == cherry).
- [ ] **Step 2:** Run Core tests, expect compile failure.
- [ ] **Step 3:** Implement with the spec's hex values. If a mode colour misses 3:1 on the page, deepen (light) or brighten (dark) that colour minimally and note the change in `docs/decisions/stage-6.md`.
- [ ] **Step 4:** Run Core tests, expect PASS.
- [ ] **Step 5:** Commit `Palette with contrast tests`.

### Task 2: Look, appearance switch, two tabs, Settings sections

**Files:**
- Create: `LifePath/Design/Theme.swift` (`extension UIColor { convenience init(_ h: Hex) }`, `extension Color { static let page, card, inset, ink, muted, satsuma }`, `struct Card<Content>: View` (filled `card`, 3 pt radius), `extension Font { static func display(_ size: CGFloat, relativeTo: Font.TextStyle) -> Font }`)
- Create: `LifePath/Fonts/BricolageGrotesque.ttf` (OFL, from the google/fonts repository, with `OFL.txt`), add to `project.yml` resources and `UIAppFonts`
- Modify: `LifePath/LifePathApp.swift:30-34` (tabs: `Map` (systemImage `map`), `You` (systemImage `person.crop.circle`); `.preferredColorScheme` from `@AppStorage("appearance")` values `system|light|dark`; tint `satsuma`)
- Modify: `LifePath/Features/Settings/SettingsView.swift` (navigation title "Settings"; sections Recording, Appearance, Street maps, Your data, Help; backup row shows a satsuma dot when never saved or older than 30 days; Diagnostics sub-page holding Recorded line toggle and Points stored)
- Modify: `LifePath/Map/TrackMapView.swift:10-24` (`TravelMode.color` → `UIColor(Palette.mode(self))`)

- [ ] **Step 1:** Download the font file only after the owner has approved the download (filename, source, size); commit it with `OFL.txt`.
- [ ] **Step 2:** Implement the files above; `StatsScreen` and `TimelineScreen` stay compiling but unreferenced until Task 8 deletes them.
- [ ] **Step 3:** Push; CI build green.
- [ ] **Step 4:** Commit `Look: palette, Bricolage, appearance switch, Settings sections`.

### Task 3: Borders from OSM

**Files:**
- Create: `Core/Sources/Core/Areas.swift`
- Modify: `Core/Sources/Core/Streets.swift` (`OSM.query` adds `rel["boundary"="administrative"]["admin_level"~"^(8|9|10|11)$"]` and `rel["boundary"="place"]` and `way["place"~"^(suburb|quarter|neighbourhood)$"]` in the bbox, `out geom`; `OSM.parse` returns areas too; `OSM.version = 4`)
- Modify: `Diary/Sources/Diary/Diary.swift` (migration: `CREATE TABLE area(id INTEGER PRIMARY KEY, level INTEGER, name TEXT, minLat REAL, maxLat REAL, minLon REAL, maxLon REAL, rings BLOB)`; `saveTile` stores areas; `areas(minLat:maxLat:minLon:maxLon:) -> [Area]`)
- Test: `Core/Tests/CoreTests/AreasTests.swift`

**Interfaces:**
- Produces: `public struct Area: Sendable, Equatable { id: Int64; level: Int; name: String; rings: [[(lat: Double, lon: Double)]] /* outer rings */; holes: [[(lat: Double, lon: Double)]] }`, `level` 8 = city, 9…11 or place boundary = neighbourhood (place boundaries and `place=` ways get level 12); `Area.contains(lat:lon:) -> Bool` (even-odd over rings minus holes); `public enum Areas { static func assemble(_ members: [(role: String, coords: [(lat: Double, lon: Double)])]) -> (outer: [[...]], inner: [[...]]) ; static func locate(lat: Double, lon: Double, in areas: [Area]) -> (city: Area?, neighbourhood: Area?) }`. `locate` picks the smallest-area city (level 8) and the smallest-area containing area with level > 8 that lies inside that city; with none, neighbourhood = city.

- [ ] **Step 1: Failing tests:** `testAssembleOutOfOrderReversedWays` (four ways, two reversed, shuffled → one closed outer ring), `testHoleExcluded`, `testLocatePicksSmallest` (city + two nested neighbourhoods → the inner one), `testNoNeighbourhoodFallsBackToCity`, `testParseRelationWithGeom` (fixture JSON with one relation, two outer way members → one `Area`, level 8, name).
- [ ] **Step 2:** Run, expect failure.
- [ ] **Step 3:** Implement. `assemble` joins member ways end-to-end by matching endpoints (reversing as needed), drops chains that never close. Unclosed relations are skipped, not fatal.
- [ ] **Step 4:** Run Core tests, PASS. Push; CI (Diary tests) green.
- [ ] **Step 5:** Commit `Borders: areas from OSM relations`.

### Task 4: Progress per place and street covered dates

**Files:**
- Modify: `Core/Sources/Core/Coverage.swift` (`version = 2`)
- Modify: `Diary/Sources/Diary/Diary.swift` (`segmentHitsDated() -> [(hit: SegmentHit, tripStart: Date)]`; tables `areaProgress(areaId INTEGER, bike INTEGER, covered INTEGER, total INTEGER, PRIMARY KEY(areaId, bike))`, `streetCovered(key TEXT PRIMARY KEY, at REAL, bike INTEGER)`; `saveProgress(_:)`, `areaProgress(bike:) -> [AreaProgress]`, `newStreets(from:to:bike:) -> Int`)
- Modify: `LifePath/Streets/StreetService.swift:105-112` (after `Coverage.streets`, compute and save progress)
- Test: `Core/Tests/CoreTests/CoverageTests.swift`

**Interfaces:**
- Consumes: `Area`, `Areas.locate` (Task 3).
- Produces: `public struct AreaProgress: Sendable, Equatable { areaId: Int64; covered: Int; total: Int }`; `Coverage.progress(ways: [Way], hits: [(hit: SegmentHit, tripStart: Date)], areas: [Area], bike: Bool) -> (areas: [AreaProgress], covered: [String: Date])`, where the key is the street key (lowest way id of the joined street, as a string) and the date is the `tripStart` whose hits first brought the street over the existing rule. A street belongs to the city and neighbourhood holding the midpoint of its longest way.

- [ ] **Step 1: Failing tests:** `testStreetCountedInMidpointArea` (street crossing a border counts once), `testCityTotalsAddUp` (sum over a city's neighbourhoods == city), `testCoveredDateIsTripThatCompletedIt` (hits over three trips, rule met on the second → its date), `testBikeOnlyExcludedOnFoot`.
- [ ] **Step 2:** Run, expect failure.
- [ ] **Step 3:** Implement by reusing the union-find and rule inside `Coverage.streets` (extract the street grouping into one private function both use); process hits sorted by `tripStart`.
- [ ] **Step 4:** Core PASS; CI green.
- [ ] **Step 5:** Commit `Progress per city and neighbourhood, street covered dates`.

### Task 5: Fog strokes and day story in Core

**Files:**
- Create: `Core/Sources/Core/Fog.swift`, `Core/Sources/Core/DayStory.swift`
- Test: `Core/Tests/CoreTests/FogTests.swift`, `Core/Tests/CoreTests/DayStoryTests.swift`

**Interfaces:**
- Produces: `public struct FogStroke: Sendable { coords: [(lat: Double, lon: Double)]; halfWidth: Double }` (one coord = circle); `Fog.strokes(line: TripLine, modes: [ModeStretch], visits: [Visit], places: [Place]) -> [FogStroke]` using the Global Constraints widths, unsure stretches at 6 m; `public enum StoryItem: Sendable, Equatable { case stay(name: String, placeId: Int64?, start: Date, end: Date), trip(mode: TravelMode?, start: Date, end: Date, distance: Double) }`; `DayStory.build(day: Date, visits: [Visit], places: [Place], modes: [ModeStretch], lines: [TripLine], nearestStreet: (Double, Double) -> String?) -> [StoryItem]`. Unnamed stays: `"near \(street)"`, else `"A place"`.

- [ ] **Step 1: Failing tests:** `testWalkIs15mCarIs6m`, `testTrainClearsOnlyEnds` (two 25 m circles, no band), `testVisitIsCircle`, `testStoryOrderAndNaming` (stay, walk, bus, stay; unnamed stay uses the street closure), `testStayCrossingMidnightClipped`.
- [ ] **Step 2:** Run, expect failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Core PASS.
- [ ] **Step 5:** Commit `Fog strokes and day story`.

### Task 6: Overlay renderers without flicker

**Files:**
- Create: `LifePath/Map/Layers.swift` (`final class LayerOverlay: NSObject, MKOverlay` covering `MKMapRect.world`; `final class LayerRenderer: MKOverlayRenderer`; `protocol LayerData: Sendable { func draw(in rect: MKMapRect, zoomScale: MKZoomScale, context: CGContext, dark: Bool) }`; `FogData`, `StreetsData`, `LinesData` each holding an immutable snapshot and a grid index of item rects at 1/1024 world width)
- Modify: `LifePath/Map/TrackMapView.swift` (replace per-trip `TrackLine` and `StreetLine` overlay diffing with three `LayerOverlay`s added once; `update(_:)` swaps the renderer's data under a lock and calls `setNeedsDisplay(_:)` for the union of rects of items that were added, removed or changed; on `traitCollectionDidChange` of the user interface style call `setNeedsDisplay()` on all three)
- Delete: `LifePath/Map/TrackLine.swift`, `LifePath/Map/StreetLine.swift` once unused

**Interfaces:**
- Consumes: `Fog.strokes` (Task 5), `Palette` (Task 1), covered ways and countable ways from Diary.
- Produces: `TrackMapView(data:mode:lines:colour:satellite:onRegion:onPlace:)` with `mode: MapMode` (`.streets`, `.fog`) and `lines: LineColour`.

Drawing rules: Fog fills the rect with `page`, then draws strokes with `.clear` blend, line width `max(2 * halfWidth in map points, 2 pt / zoomScale)`, a 4 m feather by drawing the same strokes once more with `.destinationOut` at half alpha 4 m wider. Streets: unwalked countable ways 1 pt `muted` at 35% alpha; walked ways a 6 pt satsuma stroke at 25% alpha under a 2.5 pt solid one. Below zoomScale where a 20 m segment is under 1 pt, Streets draws neighbourhood polygons filled with satsuma at `0.15 + 0.6 * percent` alpha instead, cross-faded over the next zoom step. Lines: 3 pt with a 1 pt `ink` edge in Streets mode.

- [ ] **Step 1:** Implement; build on CI.
- [ ] **Step 2:** Verify on the phone (owner): pan, zoom, appearance switch, a live walk; no blinking. Record findings in `docs/decisions/stage-6.md`.
- [ ] **Step 3:** Commit `Map layers drawn in tiles without flicker`.

### Task 7: Map tab controls

**Files:**
- Modify: `LifePath/Map/MapScreen.swift` (remove the `controls` panel; add `PlaceChip`, `RightColumn` (layers, `MKUserTrackingButton`, `MKCompassButton` stacked with 8 pt gaps, 44 pt each), `BottomCard` (segmented `Streets | Fog` bound to `@AppStorage("mapMode")`, period `Menu` Today/Week/Month/Year/All/Custom/Off, today row "3,2 km · 4.120 steps · +2 new streets"))
- Create: `LifePath/Map/PlaceCard.swift` (sheet: city percent in `Font.display(56, relativeTo: .largeTitle)`, neighbourhood rows with bars sorted by percent; tap flies the map)
- Create: `LifePath/Map/LayersSheet.swift` (colour by Mode/Date/Speed with legend chips that filter, off at 45% opacity; Standard/Satellite; Heat)
- Modify: `LifePath/Map/TrackMapView.swift:45-60` (set `map.showsCompass = false`; the column owns locate and compass; place pins become small square markers in `ink` with a `card` edge, names shown from city zoom inward)

**Interfaces:**
- Consumes: `Diary.areaProgress(bike:)`, `Diary.areas(...)`, `Diary.newStreets(from:to:bike:)`, `Areas.locate` for the map centre (debounced 0.3 s).

- [ ] **Step 1:** Implement; VoiceOver labels per spec section 6; numbers use `.contentTransition(.numericText())`; new strokes fade in once over 0.5 s on appear (skip with Reduce Motion).
- [ ] **Step 2:** CI green; owner checks on the phone.
- [ ] **Step 3:** Commit `Map tab: place chip, layers, Streets and Fog, today`.

### Task 8: You tab and day page

**Files:**
- Create: `LifePath/You/YouScreen.swift` (status pill, facts strip, places list, year strip of 52 weeks, mode bar with legend, days under month headers)
- Create: `LifePath/You/DayPage.swift` (map picture, facts strip, story list from `DayStory.build`; tapping the map sets the Map tab's period to that day and switches tab)
- Create: `LifePath/You/DaySnapshot.swift` (`MKMapSnapshotter` 64×64 pt per day and appearance, cached as PNG in Caches keyed by day, appearance and the day's last trip end; muted base, lines in satsuma)
- Delete: `LifePath/Timeline/TimelineScreen.swift`, `LifePath/Stats/StatsScreen.swift` (keep `DayService`, `Format`)
- Modify: `Diary/Sources/Diary/Diary.swift` (`distanceByMode(from:to:) -> [TravelMode: Double]`, `weeklyWalked(year:) -> [Double]` (52 values))

**Interfaces:**
- Consumes: `DayStory`, `Palette`, `Diary.newStreets`, `Diary.areaProgress`.

- [ ] **Step 1:** Diary tests for `distanceByMode` and `weeklyWalked` (CI).
- [ ] **Step 2:** Implement screens; relative dates "Today", "Yesterday", else `Mon 16 Nov`.
- [ ] **Step 3:** CI green; owner checks on the phone in light and dark at default and largest text size.
- [ ] **Step 4:** Commit `You tab and day page`.

### Task 9: Review and release

- [ ] **Step 1:** `ponytail-review` of the stage branch against the spec; fix Critical and Important items.
- [ ] **Step 2:** `docs/decisions/stage-6.md` complete; `handoff/STATE.md` updated.
- [ ] **Step 3:** Version 0.8.0 (15) in `project.yml`; tag `v0.8.0-preview.1`; one CI waiter; release has `LifePath.ipa`.
