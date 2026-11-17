# Stage 5: Export, Backup, Import and Restore Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner can save a backup, restore one (from Settings, or from a one-time onboarding page on a fresh install), and export trips as GPX, GeoJSON or KML for all history or a date range. A restore can never lose the diary.

**Architecture:** "Save a backup" already exists (`Recorder.backup()` → `Diary.backup(to:)` → system file mover). Restore is a merge, never a replace. The picked file is copied into the app's temporary folder, coordinated so iCloud files download first. The copy is migrated to the current schema (`Diary.backupSummary(at:)`) and previewed. It is then merged with `Diary.merge(backupAt:)`, which ATTACHes it and copies every table in **one transaction**, `INSERT OR IGNORE` by primary key, so the current row always wins. The same transaction marks the derived caches stale. Into an empty diary (a fresh install), the backup's caches and cursors are copied as they are, so nothing needs rebuilding. Into a diary that already has points, the smoothing, matching and day versions are cleared, and the existing open-or-charging chain rebuilds them, with progress shown. Export is pure text building in Core (`Export`), streamed to a temporary file a month of points at a time, and then handed to the file mover.

**Tech Stack:** Swift 6; Core (Foundation only, local and CI tests), Diary (GRDB, CI tests), app (SwiftUI `fileImporter`/`fileMover`, CI build).

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md`: Principles; "In plain words" (backups live outside the app; a fresh install offers a restore through a file picker); "Export, backup, import"; "Where LifePath aims past existing apps" ("Yours outright … open export formats, merge-safe backups"); Constraints (`.gitignore` of `*.lifepath`, `*.gpx`, `*.geojson`, `*.kml`); "Stages" item 5. Settings names: `handoff/robustness-audit.md` ("Stage 5 adds 'Save a backup', 'Restore from a backup', 'Export tracks (GPX, GeoJSON, KML)'"; `Diary.saveTripLines` notes that an import must clear the trip-line cache).

**Decisions made here (owner can revisit at stage 6):**
- **Restore always merges and never replaces.** Nothing in the current diary is deleted or overwritten: where both have a row with the same key, the current one is kept. Before merging into a diary that has points, a copy of it is saved as `before-import.lifepath` in the app's own folder (one copy, replaced at the next import). It guards against a merge bug; a later version can offer "Undo last import" from it if ever needed.
- **Places from a backup are taken only when this diary has no places yet** (the reinstall case). Merging into a diary that already has places keeps its places and names, and the backup's history is learned into them. A backup place's name is then not carried over. `// shortcut` in code.
- **Events (the 14-day diagnostic log) are not imported.**
- **Exports hold trips, not rests or places.** Each trip is one track, using the stored positions (the "Recorded line"), not the smoothed or street-matched estimate. Rough positions (above the accuracy ceiling, such as about 1 km fixes in trains) are left out, and the track breaks where they were, so no straight line is drawn across them. A piece shorter than 2 points is dropped. A period's edges cut trips.
- **The restore picker shows all files**, and the file is checked by reading it. No `.lifepath` file type is declared.
- Settings shows **"Last backup"** (date or "never"), so a missing backup is visible.

## Global Constraints

- Top priority: accuracy, battery efficiency and a cool phone, together. Import, export and the rebuild after an import run only while the app is open; the rebuild resumes in the existing open-or-charging chain if the app is left. No timers, no background work added. Each heavy step shows progress text.
- **Data safety first:**
  - The picked backup file is never modified. All work happens on a private copy in `FileManager.default.temporaryDirectory`, which is deleted afterwards.
  - The merge is one SQLite transaction, with the cache invalidation inside it. A crash or kill at any point leaves either the old diary or the fully merged one, and both are working diaries.
  - Points recorded while the merge runs are held in the Recorder's memory buffer and written right after (`Recorder.holdWrites`).
  - If the kept copy cannot be written (disk full), nothing is merged.
- Migrations stay additive; **no migration in this stage**. Rows are copied by column name, using the current diary's columns, so older backups (migrated first) and newer ones (extra columns ignored) both merge.
- Life-long: export and merge cover all history. Export reads points a month at a time (as `SmoothingService.run` does) and streams them to a file; nothing holds all history in memory.
- Honest: gaps stay gaps in exports (see the rough-point rule). Imported points are never altered.
- Private: files go only where the owner picks, through the system file mover. Nothing leaves the phone. Real backups and exports never enter git: `.gitignore` already blocks `*.lifepath`, `*.gpx`, `*.geojson` and `*.kml`. Test fixtures are synthetic and built in code.
- Plain system styling (List, Section, LabeledContent, ProgressView). Stage 6 restyles. Every control has an accessibility label, and every setting has a footer description.
- Ponytail: smallest complete change. Mark known limits with `// shortcut: <limit>, <when to upgrade>`.
- Subagents never run `scripts/ci-wait.sh` (GitHub's anonymous API allows 60 requests an hour). They push and report the sha.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Release: `MARKETING_VERSION: 0.7.0`, `CURRENT_PROJECT_VERSION: 12`, tag `v0.7.0-preview.1`.

## Review Focus

- **Restoring the same backup twice,** or one that overlaps the current diary: no duplicate points, steps never lowered, and the second merge adds 0. Tests in Task 2 (`testMergeTwiceAddsNothing`, `testMergeKeepsCurrentRows`).
- **A kill or error mid-merge:** the diary is unchanged, and its cache versions are still set. Test in Task 2 (`testFailedMergeChangesNothing`).
- **A backup from an older version** (schema v4, from v0.3.0): it is migrated on the private copy and merges, and the original file stays byte-identical. Test in Task 2 (`testOldBackupMigratesAndMerges`). The review also checks that `ImportService` only ever passes the temporary copy.
- **A train ride with rough fixes inside a trip:** the export breaks the line there, with no straight segment across. Test in Task 1 (`testRoughBreaksSegment`).
- **Restoring from Settings while recording, or while the chain is running:** the chain is stopped first, no run can start until the merge ends, points recorded meanwhile are written afterwards, and a later table added by a migration cannot be silently skipped. Test in Task 2 (`testMergeCoversEveryTable`). The guards are checked in the Task 3 review and on the phone (the `import` and `smooth` events in the health report).

---

### Task 1: Track export formats (Core)

**Files:** Create `Core/Sources/Core/Export.swift`; Test `Core/Tests/CoreTests/ExportTests.swift`.

**Interfaces:**
- Consumes: `Trip`, `FilteredPoint`, `PointKind`.
- Produces:
  - `public enum ExportFormat: String, CaseIterable, Sendable { case gpx, geojson, kml }`, where `rawValue` is the file extension.
  - `Export.segments(_ trip: Trip) -> [[FilteredPoint]]`: the trip's points in order, broken at every run of `.rough` points (which are dropped). Segments with fewer than 2 points are dropped.
  - `Export.head(_ f: ExportFormat) -> String`, `Export.tail(_ f: ExportFormat) -> String`.
  - `Export.trip(_ trip: Trip, _ f: ExportFormat, first: Bool) -> String`. It returns `""` when `segments` is empty. `first` is false when a trip was already written (it adds the GeoJSON comma).

**Exact output** (coordinates `%.7f`; times `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` in UTC; the trip name is its start time in the same format):
- **GPX 1.1:**
  - Head: `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="LifePath" xmlns="http://www.topografix.com/GPX/1/1">\n`
  - Each trip: `<trk><name>…</name>`, then one `<trkseg>` per segment of `<trkpt lat=".." lon=".."><time>..</time></trkpt>`, then `</trk>\n`.
  - Tail: `</gpx>\n`.
- **GeoJSON:**
  - Head: `{"type":"FeatureCollection","features":[\n`
  - Each trip is a Feature with `"geometry":{"type":"MultiLineString","coordinates":[[[lon,lat],…],…]}` and `"properties":{"start":..,"end":..,"coordTimes":[[..],..]}`. The order is **lon, lat**, and `coordTimes` mirrors the segments.
  - Tail: `]}\n`.
- **KML 2.2:**
  - Head: `<?xml …?>\n<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Document><name>LifePath</name>\n`
  - Each trip: `<Placemark><name>…</name><gx:MultiTrack>`, then one `<gx:Track>` per segment with all `<when>` elements first, then all `<gx:coord>lon lat 0</gx:coord>`; closed with `</gx:MultiTrack></Placemark>\n`.
  - Tail: `</Document></kml>\n`.

- [ ] **Step 1: Failing tests.** The trips are built directly from points 10 s apart, with millisecond timestamps.
  - `testRoughBreaksSegment`: kinds m m r r m m. This gives 2 segments of 2 points each, with no rough point in either.
  - `testShortSegmentDropped`: kinds m r m m. This gives 1 segment (the last two); kinds m r m give `[]`, and `trip(...)` returns `""`.
  - `testGPXParsesAndKeepsEveryPoint`: head + 2 trips + tail is parsed with `XMLParser`. It has no error, `trkpt` count == point count, the first `lat`/`lon` attributes equal the first point's values to 1e-7, and the first `time` round-trips to the point's `t` within 1 ms.
  - `testGeoJSONLonLatOrderAndCommas`: 3 trips, where the middle one is all rough (so it writes `""`), are written with the caller's `first` logic. `JSONSerialization` parses the result into 2 features. `coordinates[0][0] == [lon, lat]`, and the `coordTimes` counts match the coordinate counts.
  - `testKMLParsesWhenMatchesCoord`: `XMLParser` parses the result; the `when` count equals the `gx:coord` count, and the first coord reads `"lon lat 0"`.
- [ ] **Step 2: Run** `swift test --package-path Core --filter ExportTests`. Expected: FAIL (no `Export`).
- [ ] **Step 3: Implement** `Export.swift` as above.
- [ ] **Step 4: Run** all Core tests. Expected: PASS.
- [ ] **Step 5: Commit** `Export: GPX, GeoJSON and KML track text, rough fixes left out with the line broken`.

### Task 2: Backup summary and merge (Diary)

**Files:** Modify `Diary/Sources/Diary/Diary.swift`; Test `Diary/Tests/DiaryTests/DiaryTests.swift`.

**Interfaces:**
- Produces:
  - `public struct BackupSummary: Sendable, Equatable { public var points: Int; public var first: Date?; public var last: Date? }`
  - `public struct MergeResult: Sendable, Equatable { public var addedPoints: Int; public var fresh: Bool }`
  - `public static func backupSummary(at path: String) throws -> BackupSummary`. It opens the file with `Diary(path:)`, so **it migrates the file in place: callers pass a private copy** (doc comment). It throws when the file is not a database the migrations accept. The `Diary` is released before it returns.
  - `public func merge(backupAt path: String) throws -> MergeResult`
  - `public static let mergedTables: [String]`: every table that `merge` handles, listed for the coverage test.

**`merge` algorithm** (`pool.writeWithoutTransaction`, because ATTACH is not allowed inside a transaction; `defer` runs `DETACH DATABASE b`; all copying happens in one `db.inTransaction { …; return .commit }`):
1. `fresh` = no row in `main.point`.
2. Copy each table with `INSERT OR IGNORE INTO main."T"(cols) SELECT cols FROM b."T"`. The `cols` are the main diary's column names from `PRAGMA main.table_info("T")`. `addedPoints` = `db.changesCount` after `point`.
   - Always: `point`, `activity`, `way`, `tile`, `stop`.
   - `daySteps`: always, as `INSERT … SELECT … FROM b.daySteps WHERE true ON CONFLICT(day) DO UPDATE SET …`, with the same MAX/COALESCE expressions as `saveSteps`. A stored count is never lowered.
   - `place`, `placeCell`, `visit`: only when `main.place` has no row.
   - The caches `smoothedPoint`, `tripLine`, `matchedStretch`, `modeStretch`, `segmentHit`, `coveredWay`, `day`: only when `fresh`.
   - `event`: never.
3. Meta:
   - When `fresh`: `INSERT OR REPLACE INTO main.meta SELECT key, value FROM b.meta`. The backup's caches and cursors describe exactly its points.
   - Otherwise:
     - `DELETE FROM main.meta WHERE key IN ('smoothingVersion','matcherVersion','daysVersion')`. Smoothing re-smooths and rebuilds every trip line, streets re-match, and days rebuild.
     - Rewind `placesProcessedUntil` (only when it is set and later) to the target. The target is b's `placesProcessedUntil` when the places were copied; otherwise, or when that cursor is missing, it is b's earliest point `t`. Visits already stored are skipped by `Places.settle`, so this cannot count a visit twice.
     - `// shortcut: a backup place's name is not carried into a diary that already has places, upgrade if the owner merges old phones`

- [ ] **Step 1: Failing tests.** Backups are built as a second temp diary, filled through the public API, and then merged.
  - `testSummary`: 3 points at t 100, 200, 300 → `points == 3`, `first == d(100)`, `last == d(300)`. An empty diary gives `points == 0` and both dates nil.
  - `testNotADatabaseThrows`: a file of 1 KB of random bytes → `backupSummary` throws.
  - `testMergeIntoEmptyCopiesEverything`: the backup has points, a smoothed point, a trip line, a place named "Home" with cells and a visit, daySteps, an activity, meta `smoothingVersion` and an event. After the merge into a new diary, all of these read back equal, except that `events` is empty. The result is `MergeResult(addedPoints: n, fresh: true)`.
  - `testMergeKeepsCurrentRows`: the current diary has t 0…9 with lat 1, and the backup has t 5…14 with lat 9. After the merge, t 5…9 still have lat 1, t 10…14 have lat 9, and `addedPoints == 5`.
  - `testMergeMarksCachesStale`: non-fresh. Meta `smoothingVersion`, `matcherVersion` and `daysVersion` are gone, the current diary's `tripLine` rows are still there, and the backup's trip lines are not copied.
  - `testMergePlacesOnlyIntoPlacelessDiary`:
    - (a) The current diary has a place. Its places are unchanged, the backup's place is absent, and `placesProcessedUntil` is rewound to the backup's first point.
    - (b) The current diary has points but no place. The backup's named place and visits are present, and the cursor = min(current, the backup's cursor).
  - `testMergeStepsNeverLowered`: the current day has 5,000 steps and the backup 4,000; another day has backup steps only. The result is 5,000, plus the backup-only day.
  - `testMergeTwiceAddsNothing`: the second merge returns `addedPoints == 0`, and the row counts of every table in `mergedTables` are unchanged.
  - `testFailedMergeChangesNothing`: non-fresh. Run `DROP TABLE daySteps` in the backup through a raw `DatabaseQueue` after creating it, so the merge throws after `point` was copied. The merge throws, the point count is unchanged, and `smoothingVersion` is still set.
  - `testOldBackupMigratesAndMerges`:
    - Build a v4-era file with a raw `DatabaseQueue`: the v1 to v4 SQL, `grdb_migrations` rows `v1` to `v4`, and 2 points.
    - Record its bytes, copy it, and run `backupSummary` and `merge` on the copy. Both points merge, and the original's bytes are unchanged.
  - `testMergeCoversEveryTable`: the tables of a new diary (`sqlite_master`, type `table`), minus `mergedTables`, `event`, `meta`, `grdb_migrations` and `sqlite_sequence`, leave an empty set. A future migration that adds a table fails this test until merge handles it.
- [ ] **Step 2: Implement** as above.
- [ ] **Step 3:** CI green (Diary tests run on CI only). **Commit** `Diary: backup summary and one-transaction merge that never deletes`.

### Task 3: Restore (app)

**Files:**
- Create `LifePath/Export/ImportService.swift`, `LifePath/Export/RestoreButton.swift`
- Modify `LifePath/Recorder/Recorder.swift`, `LifePath/Map/SmoothingService.swift`, `LifePath/Timeline/DayService.swift`, `LifePath/Features/Settings/SettingsView.swift`, `LifePath/Features/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `Diary.backupSummary(at:)`, `Diary.merge(backupAt:)`, `Diary.backup(to:)`, `PlaceService`, `SmoothingService.linesChanged`, `DayService.changed`, `PlaceService.changed`.
- Produces:
  - **Recorder:**
    - `var holdWrites = false`: while true, `flush()` returns at once and the points stay buffered.
    - `func diaryForImport() -> Diary?`: opens the diary if needed, so a restore can run during onboarding before `start()`.
    - `start()` calls `openDiary()` only when `diary == nil`. Because `resume()` already ran on the empty diary, a restored backup's last still point never triggers a relaunch backfill up to now.
  - **SmoothingService:**
    - `@MainActor static func stop() async`: cancels `running`, awaits it, then awaits `DayService.running?.value`.
    - `@MainActor @discardableResult static func start() -> Task<Void, Never>`: starts `execute()` the way `appBecameActive` does, ignoring `ranThisForeground` (which it sets), and returns the task. `appBecameActive` calls it.
    - `execute()` and `DayService.run` return at once while `ImportService.shared.merging`.
  - **ImportService:** `@MainActor @Observable final class ImportService` with `static let shared`, `var merging = false`, and `var phase: Phase`, where `enum Phase { case idle, reading, ready(BackupSummary, URL), merging, rebuilding, done(Int), failed(String) }`. It has `func read(_ picked: URL) async`, `func merge() async` and `func cancel()`.
  - **RestoreButton:** `struct RestoreButton: View { let title: String }`.

- [ ] **Step 1: Implement `ImportService`:**
  - **`read`:** phase `.reading`. Detached:
    - `startAccessingSecurityScopedResource` (stopped in `defer`).
    - `NSFileCoordinator().coordinate(readingItemAt:)`, which downloads an iCloud placeholder first, then copies to `tmp/import-<UUID>.lifepath`.
    - `Diary.backupSummary(at: copy)`.
    - The phase becomes `.ready(summary, copy)` or `.failed("This file isn't a LifePath backup.")`. On failure the copy is deleted.
  - **`merge`:**
    1. `merging = true`, phase `.merging`; then `await SmoothingService.stop()` and `Recorder.shared.holdWrites = true`.
    2. Detached:
       - If the diary has a point, write `Application Support/before-import.lifepath` with `diary.backup(to:)`, after removing the old one. If that fails, phase `.failed("Not enough space to keep a copy of your diary first. Nothing was changed.")`.
       - `diary.merge(backupAt: copy)`.
    3. In a `defer`: delete the copy, set `holdWrites = false`, call `Recorder.shared.flush()` and set `merging = false`.
    4. On success:
       - Set `PlaceService.shared.places = try diary.places()`.
       - Post `SmoothingService.linesChanged`, `DayService.changed` and `PlaceService.changed`.
       - Log `import` with `added=N fresh=true|false`.
       - Set phase `.rebuilding`, `await SmoothingService.start().value`, then phase `.done(n)` with n = `addedPoints`.
    - A merge error gives `.failed("Restore failed: <error>. Your diary is unchanged.")`.
    - The Diary is `Recorder.shared.diaryForImport()`, and nil gives `.failed("The diary can't be opened right now. Unlock the iPhone and try again.")`.
  - **`cancel`:** deletes the copy and sets phase `.idle`.
- [ ] **Step 2: Implement `RestoreButton`:**
  - A `Button(title)` opens `.fileImporter(allowedContentTypes: [.item])`, and the picked URL goes to `read`.
  - A `.sheet` is shown whenever the phase is not `.idle`. It holds a `NavigationStack` with a List:
    - **`.reading`:** `ProgressView("Checking the backup…")`.
    - **`.ready`:** "Points" (grouped), and "From" and "To" as dates. A footer reads "These points are added to your diary. Nothing already in it is removed, and a copy of your diary is kept first." The buttons are "Restore" (disabled when `points == 0`, with the footer then reading "This backup holds no points.") and "Cancel".
    - **`.merging`:** `ProgressView("Adding the backup to your diary…")`.
    - **`.rebuilding`:** `ProgressView("Rebuilding the map, places, streets and days…")`, with the footer "This can take a few minutes for years of history. Keep LifePath open; if you leave, it continues next time." There is a "Done" button that only closes the sheet; the work goes on.
    - **`.done(n)`:** "Restored. <n> points added."
    - **`.failed(msg)`:** shows `msg`.
  - Closing the sheet in `.ready` or `.failed` calls `cancel()`. The sheet cannot be dismissed interactively while `.merging`.
- [ ] **Step 3: Wire it in:**
  - **Settings:** in a section after "Save a backup", put `RestoreButton(title: "Restore from a backup")` with the footer "Adds the points from a backup file (for example after reinstalling LifePath). Nothing in this diary is removed."
  - **Onboarding:** a page after "What LifePath does", titled "Used LifePath before?", with the text "Restore your diary from a backup file in Files or iCloud Drive. You can also do this later in Settings." and `RestoreButton(title: "Restore from a backup")`. The page is shown only when `(try? Recorder.shared.diaryForImport()?.lastPoint()) == nil`, checked once in `onAppear` into `@State`. The tags renumber.
- [ ] **Step 4:** CI build green. **Commit** `Restore from a backup: preview, kept copy, one-transaction merge, rebuild with progress, onboarding offer`.

### Task 4: Export tracks and Last backup (app)

**Files:** Create `LifePath/Export/ExportSheet.swift`; Modify `LifePath/Features/Settings/SettingsView.swift`.

**Interfaces:**
- Consumes: `Export`, `ExportFormat`, `Trips.split(chunk:carry:)`, `diary.points(minLat:maxLat:minLon:maxLon:after:to:limit:)`.
- Produces:
  - `enum ExportService { static func write(_ diary: Diary, _ f: ExportFormat, from: Date, to: Date, progress: @escaping @Sendable (Int) -> Void) throws -> URL? }`
  - `struct ExportSheet: View`.

- [ ] **Step 1: Implement `ExportService.write`:**
  - Create `tmp/<name>.<ext>` and write through a `FileHandle`: the head, then each trip as points are read a month at a time (the loop of `SmoothingService.run`, from `from` to `to`, with the open trip carried across chunks and finished with `Trips.split(carry)`), then the tail.
  - `progress(tripsWritten)` is called once per month.
  - `Task.checkCancellation()` runs per month; on a throw, the file is deleted.
  - It returns nil, with the file deleted, when no trip was written.
  - The name is `LifePath-tracks-<yyyy-MM-dd>` (all history; the export date) or `LifePath-tracks-<from>-to-<to>`, using a POSIX formatter.
- [ ] **Step 2: Implement `ExportSheet`** (presented from Settings):
  - Picker "Format" (GPX / GeoJSON / KML), Toggle "All history" (on), and, when off, DatePickers "From" and "To" (dates only). The range is `startOfDay(from)` to `startOfDay(to) + 1 day`.
  - Button "Export" runs `write` detached, showing `ProgressView("Writing tracks… <n> trips")`, then a `.fileMover` for the URL. When moving is cancelled, the temporary file is deleted (as for the backup).
  - No trips gives the text "No trips in this period."
  - Closing the sheet cancels the task.
  - Footer: "Your trips as a file other apps can open. Positions LifePath was unsure of (about a kilometre off, as in some trains) are left out, so the line breaks there. Rests and places are not included; they are in the backup."
- [ ] **Step 3: Implement the Settings rows:**
  - Button "Export tracks (GPX, GeoJSON, KML)" opens the sheet.
  - `LabeledContent("Last backup", value:)` from `@AppStorage("lastBackup")` (seconds since 1970, 0 = "never"), set when the backup `fileMover` reports `.success`.
- [ ] **Step 4:** CI build green. **Commit** `Export tracks as GPX, GeoJSON or KML for all history or a period; Last backup row`.

### Task 5: Review and release

- [ ] Whole-branch ponytail review against the spec ("Export, backup, import"), the Global Constraints, the Review Focus and the robustness checklist (crash at each step of `merge()`; settings names and footers). Check on the phone (real files stay on the phone, never in git):
  - Save a backup, then restore it into the same diary: 0 added.
  - Export a day as GPX and open it in another app.
  - The `import` and `smooth` events in the health report.
  - Thermal state during the rebuild.
- [ ] One fix wave.
- [ ] Verify the privacy guard: `git check-ignore -v x.lifepath x.gpx x.geojson x.kml` matches all four.
- [ ] Docs:
  - Write `docs/decisions/stage-5.md`. It records the "Decisions made here" and the place-name shortcut.
  - `docs/install.md` step 8: replace "(Restoring a backup … arrives in a later stage.)" with "On first start LifePath offers to restore a backup; pick your `.lifepath` file."
  - Update `handoff/STATE.md`.
- [ ] Release: in `project.yml`, `MARKETING_VERSION: 0.7.0` and `CURRENT_PROJECT_VERSION: 12`. Merge to `main` and tag `v0.7.0-preview.1`.
