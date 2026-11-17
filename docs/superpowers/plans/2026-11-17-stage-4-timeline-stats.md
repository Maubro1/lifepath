# Stage 4: Timeline, Stats and Steps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Timeline tab (days newest first, each a card with a little drawing of the day's route, distance, moving time and steps) and the Stats tab (Where you went, On foot, Streets walked), with daily steps, distance and stairs copied from CMPedometer into the diary for good.

**Architecture:** Core gets `Days.tally`, which credits each trip's point-to-point distance and time to the local day of the earlier point. Distance follows the smoothed line where there is one, and "walked" counts only pairs inside a confident walk or run stretch. A new `DayService` runs at the end of the existing open-or-charging chain (smoothing → places → streets → days). It copies the last 7 days of pedometer data, then recomputes the per-day summaries from a cursor: yesterday, or further back when the street run re-matched older trips. The first build reads history a month at a time. Diary v9 adds `day` (a recomputable cache) and `daySteps` (permanent, because iOS keeps only 7 days). The screens read only these small tables, plus each visible card's own trip lines, so scrolling never reads full history.

**Tech Stack:** Swift 6; Core (Foundation only, local and CI tests), Diary (GRDB, CI), app (SwiftUI, CoreMotion, CI build).

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md`: Principles; "In plain words"; "Diary" (`daySteps`); "Screens" (Timeline, Stats, Settings "step counting", pull to refresh); "Stages" item 4. Settings notes: `handoff/robustness-audit.md` ("step counting (a status row pointing to iOS Motion & Fitness instead of a toggle)"). Builds on `docs/superpowers/plans/2026-11-17-stage-3b-travel-modes.md` (modes) and `2026-11-17-stage-3c-streets-walked.md` (tally).

**Decisions made here (owner can revisit at stage 6):**
- The route drawing is the day's trip lines drawn as a plain line, with no map underneath. The spec names `MKMapSnapshotter`, but that would fetch Apple map tiles for every day card, warm the phone and need a disk cache. A line drawn from the cached trip lines costs nothing off screen and sends nothing anywhere. A map background can come back at stage 6 if the owner wants it.
- A trip that crosses midnight is split at midnight, with each part counted on its own day.
- "Distance walked" counts walking and running stretches the classifier is sure of, measured along the GPS line. It is the same rule Streets walked uses. Unsure stretches and rides never count. The pedometer's own distance is stored but not shown, so it is not lost after 7 days.
- Streets walked shows the overall tally. The spec's "per area" split needs an area model the diary does not have yet, so it is deferred. The map caption stays.
- The Timeline lists days that have any recorded point. A day with steps but no recording is counted in Stats and not listed on the Timeline.

## Global Constraints

- Top priority: accuracy, battery efficiency and a cool phone, together. Summaries are computed only in `DayService.run`, which runs at the end of `SmoothingService.execute` (app open or charging) and on pull to refresh (app open). The pedometer copy is at most 7 history queries per run. No live sensor is added. The screens do no work off screen.
- Life-long: every recorded day has a row, and every day is reachable by scrolling. Years of history stay fast. A full rebuild reads points a month at a time, and only on a version change. After that, each run recomputes from yesterday (or from the street cursor). The Timeline reads all `day` rows in one query (a few thousand small rows), plus trip lines for visible cards only, by a `start` range.
- Honest: gaps stay gaps. No steps are invented: a day without pedometer data shows no steps, never 0. Unsure mode stretches never count as walked. Stored step values are never lowered by a later, partial query.
- Stored points are never modified. Migration v9 is additive. `day` is a recomputable cache, versioned by meta `daysVersion` = `"\(Days.version).\(smoothingVersion).\(matcherVersion)"` (the latter two read from meta). `daySteps` is permanent, like `activity`.
- Distances by mode use 3b's travel modes: walked means modes `.walk` or `.run` with `confidence ≥ TravelModes.confident`. Vehicles, bike and unsure stretches never count as walked. Stretches are identified by timestamps, never by point indices.
- Days are local calendar days, keyed `"yyyy-MM-dd"` (POSIX formatter, `Calendar.current` at compute time). `// shortcut: days are keyed in the time zone current at compute time, so a trip abroad may shift by the offset, upgrade if the owner travels across zones and sees it`.
- Nothing may prompt for permission: pedometer reads are guarded by `CMPedometer.authorizationStatus() == .authorized`.
- Plain system styling (List, Section, LabeledContent). Stage 6 restyles. Every control has an accessibility label.
- Ponytail: smallest complete change. Mark known limits with `// shortcut: <limit>, <when to upgrade>`. Synthetic fixtures only (the repo is public).
- Subagents never run `scripts/ci-wait.sh` (GitHub's anonymous API allows 60 requests an hour). They push and report the sha.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A walk from 23:50 to 00:10: 10 min of moving time and its distance on each day, with nothing counted twice or lost. Test in Task 1 (`testTripOverMidnightSplits`).
- A day at home (still points only, plus pottering that never became a trip): listed and counted as a tracked day, with 0 distance and 0 moving time. Test in Task 1 (`testHomeDayHasNoMovingTime`).
- A walk to the bus and the bus ride: walked counts only the walk. A walk stretch below the confidence threshold counts as distance but not as walked. Test in Task 1 (`testWalkedOnlyInsideConfidentWalkOrRun`).
- Step counting off, a day older than iOS's 7 days, or a later query that returns fewer steps (iOS already dropped part of the day): the card shows no steps rather than 0, and a stored count never drops. Tests in Task 2 (`testStepsNeverLowered`, `testDaysJoinSteps`).
- A street re-match of trips from last month (new tiles or a new matcher version): those days' walked distance is recomputed, while untouched days are left alone. Tests in Task 2 (`testSaveDaysReplacesFromDay`); Task 3 sets the cursor from the street cursor, and the review checks it through the `days` event.

---

### Task 1: Day tally (Core)

**Files:** Create `Core/Sources/Core/Days.swift`; Test `Core/Tests/CoreTests/DaysTests.swift`.

**Interfaces:**
- Consumes: `Trip` (`Trips.split`), `FilteredPoint`, `ModeStretch`, `TravelModes.confident`, `Geo.distance`.
- Produces:
  - `public struct DaySummary: Sendable, Equatable { public var day: String; public var distance: Double; public var movingTime: TimeInterval; public var walked: Double; public var points: Int }`, with a public memberwise init.
  - `public struct DaySteps: Sendable, Equatable { public var day: String; public var steps: Int; public var distance: Double?; public var floorsUp: Int? }`, with a public memberwise init.
  - `public struct LifeStats: Sendable, Equatable { public var distance: Double; public var walked: Double; public var days: Int; public var points: Int; public var steps: Int?; public var floorsUp: Int?; public var stepsSince: String? }`, with a public memberwise init.
  - `Days.version = 1`
  - `Days.key(_ t: Date, _ calendar: Calendar) -> String`, giving `"yyyy-MM-dd"` in the calendar's time zone.
  - `Days.tally(points: [FilteredPoint], trips: [Trip], modes: [ModeStretch], smoothed: [Date: (lat: Double, lon: Double)], from: Date, calendar: Calendar, into days: inout [String: DaySummary])`

**Rules for `tally`** (only points and pairs whose first point has `t ≥ from` count):
- Every point in `points` adds 1 to `points` of its day. This is what makes a home day a tracked day.
- **Moving time:** each consecutive pair (a, b) in a trip's points adds `b.t − a.t` to the day of `a`.
- **Distance:** each consecutive pair of precise points (kind ≠ `.rough`; rough points are skipped, as `Trips.split` does) adds the distance between them to the day of `a`. Each point's position is `smoothed[t]` when present, else its `lat`/`lon`.
- **Walked:** the same pair distance is added to `walked` when a and b both fall inside one stretch with mode `.walk` or `.run` and `confidence ≥ TravelModes.confident` (`start ≤ t ≤ end`).
- `// shortcut: a pair straddling midnight counts wholly on the earlier day (one fix interval at most), upgrade if a day's total looks off`

- [ ] **Step 1: Failing tests.** Use `Calendar(identifier: .gregorian)` with time zone `Europe/Amsterdam` and points on a straight line every 10 s, built directly or with the `Synthetic.swift` helpers.
  - `testKey`: 2026-11-17 23:30 local → `"2026-11-17"`; 00:30 → `"2026-11-18"`. A DST day (2026-03-29) keys correctly.
  - `testHomeDayHasNoMovingTime`: 24 h of `.still` points every 5 min and no trips. One day, `points == 288`, `distance == 0`, `movingTime == 0`.
  - `testTripDistanceAndTime`: a 1,000 m walk over 720 s (73 moving points) with no modes. `distance` is 1000 ± 1, `movingTime == 720`, `walked == 0`.
  - `testWalkedOnlyInsideConfidentWalkOrRun`: the same walk with modes walk 0–300 s (0.9) and bus 300–720 s (0.9). `walked` ≈ the distance of the first 300 s (± 15 m). With the walk at 0.3, `walked == 0`. A run stretch at 0.9 counts.
  - `testTripOverMidnightSplits`: a trip from 23:50 to 00:10. Day 1 has `movingTime == 600` and day 2 has 600; the distances sum to the trip's distance.
  - `testFromSkipsEarlierDays`: with `from` = the second day's start, the first day gets no row and no credit.
  - `testRoughSkippedInDistance`: precise A, then rough R 1 km away, then precise B 50 m from A. `distance` is 50 ± 0.5 and the moving time counts both intervals.
  - `testSmoothedPositionsUsed`: a zig-zag recorded line with a straight `smoothed` map gives the straight distance.
- [ ] **Step 2: Run** `swift test --package-path Core --filter DaysTests`. Expected: FAIL (no `Days`).
- [ ] **Step 3: Implement** `Days.swift` as above.
- [ ] **Step 4: Run** the Core tests. Expected: all PASS.
- [ ] **Step 5: Commit** `Days: per-day distance, moving time, walked distance and point count`.

### Task 2: Diary v9

**Files:** Modify `Diary/Sources/Diary/Diary.swift`; Test `Diary/Tests/DiaryTests/DiaryTests.swift`.

**Interfaces:**
- Consumes: `DaySummary`, `DaySteps`, `LifeStats`.
- Produces:
  - Migration `v9`. It is additive. `day` is a recomputable cache; `daySteps` is permanent because CoreMotion keeps only 7 days.
    ```
    CREATE TABLE day(day TEXT PRIMARY KEY, distance REAL, movingTime REAL, walked REAL, points INTEGER);
    CREATE TABLE daySteps(day TEXT PRIMARY KEY, steps INTEGER, distance REAL, floorsUp INTEGER);
    ```
  - `saveDays(_ days: [DaySummary], from day: String)`: one transaction that deletes rows with `day >= from`, then inserts `days`.
  - `days() -> [(summary: DaySummary, steps: Int?)]`: newest first, `day LEFT JOIN daySteps`.
  - `saveSteps(_ s: [DaySteps])`: upserts and never lowers a value. A NULL never replaces a number: `steps = MAX(steps, excluded.steps)`, and `distance`/`floorsUp` = `COALESCE(MAX(old, new), old, new)`.
  - `lifeStats() -> LifeStats`:
    - From `day`: `SUM(distance)`, `SUM(walked)`, `COUNT(*)`, `SUM(points)`.
    - From `daySteps`: `SUM(steps)`, `SUM(floorsUp)`, `MIN(day)`. These are nil when the table is empty.
  - `tripLines(from: Date, to: Date) -> [TripLine]`: trips overlapping the range, read by the `start` primary key (`start >= from − 86400 AND start < to AND end >= from`). This lets an old day's card avoid scanning every newer trip. `// shortcut: a trip longer than a day before its card's day is missed in the drawing, upgrade if one exists`

- [ ] **Step 1: Failing tests:**
  - `testSaveDaysReplacesFromDay`: save days 01, 02 and 03, then `saveDays([02'], from: "2026-11-02")`. `days()` gives 02' then 01; day 03 is gone, and 01 is untouched.
  - `testDaysJoinSteps`: days 01 and 02, with steps only for 02. `steps` is `[02: n, 01: nil]`.
  - `testStepsNeverLowered`: save 5,000 steps with distance 3,000, then 4,000 with distance nil. The row reads back 5,000 and 3,000. Saving 6,000 then reads 6,000.
  - `testLifeStats`: sums over two days and two step rows; `stepsSince` is the earliest step day. On an empty diary, `steps == nil`, `days == 0`.
  - `testTripLinesByDay`: trips at day −3, day −1 23:50–00:10 and day 0 noon. Querying day 0 returns the last two.
  - `testV8DiaryMigrates`: a diary is opened, closed and reopened; its points and matches stay.
- [ ] **Step 2: Implement.** CI green (Diary tests run on CI only). Commit `Diary v9: day summaries and daily steps`.

### Task 3: DayService (app)

**Files:**
- Create `LifePath/Timeline/DayService.swift`
- Modify `LifePath/Recorder/MotionService.swift`
- Modify `LifePath/Map/SmoothingService.swift` (one call)

**Interfaces:**
- Consumes: `Days`, the Task 2 diary methods, `Trips.split(chunk:carry:)`, `diary.modes(from:to:)`, `diary.smoothed(from:to:)`, and meta `smoothingVersion`, `matcherVersion`, `streetsUntil`.
- Produces:
  - `MotionService.daySteps(now: Date, calendar: Calendar) async -> [DaySteps]`, a `nonisolated static` method. It covers today and the 6 days before, each queried with `queryPedometerData(from: startOfDay, to: min(next day, now))`. A day whose query fails is left out. It returns `[]` unless `CMPedometer.isStepCountingAvailable()` and `CMPedometer.authorizationStatus() == .authorized`. `distance` comes from `data.distance`, and `floorsUp` from `data.floorsAscended` (nil when the iPhone does not report it).
  - `MotionService.stepCounting: String`, a `nonisolated static` property:
    - "On"
    - "Off" (denied or restricted)
    - "Not set up" (not determined)
    - "Not available" (no step counting)
  - `DayService.run(_ diary: Diary) async`
  - `DayService.changed: Notification.Name`, posted on the main actor after a run that saved.
  - The event `days` with detail `from=yyyy-MM-dd days=N steps=M`, or `failed`.

- [ ] **Step 1: Implement `DayService.run`:**
  - **Steps:** `try diary.saveSteps(await MotionService.daySteps(now: Date(), calendar: .current))`.
  - **Version:** `"\(Days.version).\(meta smoothingVersion ?? "").\(meta matcherVersion ?? "")"`. When it differs from meta `daysVersion`, `from = .distantPast`.
  - **Cursor:** otherwise `from` = the start of the earlier of yesterday and the day of meta `daysStreets` (the street cursor this service saw at the end of its last run; trips from there on may have been re-matched since).
  - **Read:** like `SmoothingService.run`, read points from `from − 1 day` (context for the trip split; `tally` credits only `t ≥ from`) to now, a month at a time, carrying the open trip with `Trips.split(chunk:carry:)`. For each batch of trips:
    - `modes` is `diary.modes(from: first.start, to: last.end).values.flatMap { $0 }`.
    - `smoothed` is `diary.smoothed(from: first.start, to: last.end)` as a dictionary.
    - The points passed are the chunk; finish with `split(carry)` and `points: []`.
    - `Task.checkCancellation()` runs per chunk.
  - **Save:** `saveDays(Array(days.values), from: Days.key(from, .current))`, then set meta `daysStreets` to the current `streetsUntil` and `daysVersion` to the version.
  - `// shortcut: a cancelled full rebuild starts over next time, upgrade to a resumable cursor if the log shows it never finishing`
  - **Serialization:** runs never overlap. A `@MainActor static var running: Task<Void, Never>?` makes a second caller await the running one and return.
  - **Logging:** log `days` and flush, as `StreetService.run` does.
- [ ] **Step 2: Call it.** `SmoothingService.execute` calls `await DayService.run(diary)` after `StreetService.run(diary)`.
- [ ] **Step 3:** CI build green. Commit `DayService: copy daily steps, keep per-day summaries`.

### Task 4: Timeline tab (app)

**Files:**
- Create `LifePath/Timeline/TimelineScreen.swift`
- Modify `LifePath/LifePathApp.swift` (tabs)

**Interfaces:**
- Consumes: `diary.days()`, `diary.tripLines(from:to:)`, `DayService.run`, `DayService.changed`.
- Produces:
  - `struct TimelineScreen: View`
  - Tabs in this order: `Tab("Map", systemImage: "map")`, `Tab("Timeline", systemImage: "calendar")`, `Tab("Stats", systemImage: "chart.bar")`, `Tab("Settings", systemImage: "gear")`. The Stats tab is added in Task 5.

- [ ] **Step 1: Implement:**
  - **Screen:** a `NavigationStack` with title "Timeline". A `List` holds one row per day from `diary.days()`, read off the main actor. It reloads on appear, on `DayService.changed`, and on `.refreshable` (which awaits `DayService.run(diary)` first). It does nothing while off screen.
  - **Empty state:** "No days yet. Days appear here once LifePath has recorded."
  - **Day card, in one row:**
    1. The route drawing.
    2. The date, as `Date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())`.
    3. The distance, as `Measurement(value:unit: .meters).formatted(.measurement(width: .abbreviated, usage: .road))`.
    4. The moving time, as `Duration.seconds(...).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))`.
    5. The steps, as "8,412 steps", only when non-nil.
    - A day with no distance and no moving time shows "No trips" instead of items 3 and 4.
    - The row has one combined accessibility label, for example "Monday 17 November 2026, 12.4 km, 1 hr 12 min moving, 8,412 steps".
  - **Route drawing:** 56 × 56 pt. In `.task(id: day)` the row reads `tripLines(from: dayStart, to: nextDayStart)` and draws each line's coords as a `Path` in `.primary` at width 1.5. The projection is equirectangular, with lon scaled by cos(mid-lat), fitted with 4 pt inset and the aspect kept. A day with lines that span under 1 m draws a dot. A day with no lines leaves the square empty. Lines are held in the row's `@State` only.
- [ ] **Step 2:** CI build green. Commit `Timeline tab: days newest first with route drawing, distance, moving time and steps`.

### Task 5: Stats tab and step-counting status (app)

**Files:**
- Create `LifePath/Stats/StatsScreen.swift`
- Modify `LifePath/LifePathApp.swift` (Stats tab)
- Modify `LifePath/Features/Settings/SettingsView.swift` (status row)

**Interfaces:**
- Consumes: `diary.lifeStats()`, `diary.streetsWalked(bike:)`, `UserDefaults` `countCycling`, `MotionService.stepCounting`, `DayService`.
- Produces: `struct StatsScreen: View`.

- [ ] **Step 1: Implement the Stats screen:**
  - **Screen:** a `NavigationStack` with title "Stats" and a `List`. Loading follows the Timeline's pattern (off the main actor; on appear, on `DayService.changed` and on refresh).
  - **"Where you went":** `LabeledContent` rows "Distance" (the road measurement format), "Days tracked" and "Points stored" (grouped numbers).
  - **"On foot":**
    - "Steps" and "Flights of stairs": each shows "—" when nil.
    - "Distance walked".
    - Footer: "Steps and stairs counted since <stepsSince as date>. Distance walked counts walking and running only, never rides." Without steps, the footer instead reads "Step counting is off. Turn on Motion & Fitness for LifePath in iOS Settings."
  - **"Streets walked":** one row in the map caption's wording ("42 of 1,310 (3.2%)", titled "Streets walked or cycled" with `countCycling` on). Before the first coverage run it shows "No street maps yet". Reuse the formatting by moving `MapScreen.tally`'s body into a `static func tallyText(_ w: (covered: Int, total: Int)?, bike: Bool) -> String` on `MapScreen` and calling it from both screens.
- [ ] **Step 2: Implement the Settings status row:**
  - In the Status section: `LabeledContent("Step counting", value: MotionService.stepCounting)`.
  - When the value is "Off" or "Not set up": a button "Open iOS Settings" (accessibility hint "Turn on Motion & Fitness for LifePath") that opens `UIApplication.openSettingsURLString`.
- [ ] **Step 3:** CI build green. Commit `Stats tab (where you went, on foot, streets walked) and step-counting status`.

### Task 6: Review and release

- [ ] Whole-branch ponytail review against the spec ("Screens": Timeline, Stats; "Diary": `daySteps`), the Global Constraints and the Review Focus. Check on the phone:
  - The first `days` event (a full build) and a later one (`from` = yesterday).
  - Thermal state while the first build runs.
  - That a home day shows "No trips".
  - That today's steps match the iPhone's own count to within the pedometer's lag.
- [ ] One fix wave.
- [ ] Write `docs/decisions/stage-4.md`. It records the five "Decisions made here" above, the midnight shortcut and the time-zone shortcut. Add the open questions to `handoff/STATE.md`:
  - Route drawing without a map.
  - Walked distance from GPS rather than the pedometer.
  - Streets walked per area deferred.
  - Days with steps but no recording are not listed.
- [ ] Release: in `project.yml`, `MARKETING_VERSION: 0.6.0` and `CURRENT_PROJECT_VERSION: 11`. Merge to `main` and tag `v0.6.0-preview.1`.
