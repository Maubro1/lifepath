# Robustness and settings audit (branch `places` at d428145)

A read-only audit, run because the owner asked that the app and its data survive crashes, updates and iOS kills, and that every setting has a clear name and description. Nothing was built or run for it; items marked "unverified" rest on knowledge of iOS and GRDB.

## What already holds up

The app never deletes or recreates the diary; a failed open is only logged (Recorder.swift:271). File protection is "until first unlock". No App Group; the bundle ID is fixed. Points use INSERT OR IGNORE on `t`, so retries can't duplicate them. GRDB runs each migration in its own transaction. Smoothing, trip-line and places caches each save per trip or chunk in one transaction with the cursor taken from the data, so a crash leaves a clean prefix. The recording path has no `try!` or `fatalError`; its force unwraps can't fail as written.

## Critical (fix before v0.3.0-preview.1)

1. **No backup exists yet.** The whole diary is one file in the app container; deleting/reinstalling the app or a changed SideStore bundle-ID suffix loses everything. Fix: a minimal "Save a backup" button now (VACUUM INTO a temp file, then the system file exporter, about 20 lines); restore waits for stage 5. Tell the owner never to delete the app.
2. **Failed writes are invisible** (Recorder.swift:277-296). With a corrupt diary, full disk or failed open, `diary` stays nil, points pile up in memory, and the status box still says "Tracking" because it reads memory (:118, :166). Fix: make `flushFailedAt` observable, show "Not saving since HH:mm" in the status box, and add `diary: open / failed <error>` to the health report (:308).
3. **Places forget `realDays` and `recentDurations` on reload** (Diary.swift:185-242 doesn't store Places.swift:15-16). Task 1c: additive migration v5 or rebuild both from the `visit` table.

## Important

4. **Locked after a reboot** (Diary.swift:54, Recorder.swift:64): nothing can be written until the first unlock; a kill in that window loses the buffer and skips the relaunch backfill. Fix: on `protectedDataDidBecomeAvailableNotification`, flush and redo the relaunch backfill. No unprotected side file (privacy).
5. **A SideStore refresh or update terminates the app**, and iOS may not relaunch it (unverified). Fix: reminder text (SigningReminder.swift:310), status hint (TrackingStatus.swift:26) and docs/install.md say "…then open LifePath once".
6. **Settings read before first unlock may come back as defaults** (unverified). LifePathApp.swift:305 still starts recording via the permission fallback, but Root (:321) could show onboarding again. Fix: Root uses the same test as :305 (`onboarded || authorization != .notDetermined`).
7. **A dead recorder in deep sleep goes unnoticed**: TrackingStatus.swift:21 skips the "no check-in for an hour" check in deep sleep, though deep sleep keeps the keep-alive on. Fix: drop `!deepSleep` from that check. The spec also wants automatic easing and the deep-sleep reason in the status box.
8. **Backfill can land behind the cache cursors** (Recorder.swift:176, :188; Diary.swift:137; PlaceService.swift:119): a fill added after an overnight places run may never become a visit. Fix: after a fill older than the cursor, move `placesProcessedUntil` back to the fill's start.

## Minor

9. A background and a foreground smoothing run can overlap (SmoothingService.swift:69-97); a place rename (task 5) could be overwritten. Fix: one shared `running` guard.
10. On background-task expiry, cancellation is checked only between trips/visits; a first-build month read could overrun the grace time.
11. A crash loses up to 30 s of buffered points (PointBuffer.swift:341), as the spec allows.
12. Downgrading to an older IPA works while migrations stay additive and rows are read by column name (unverified for GRDB 7). Never rename or drop columns.
13. Renaming a `Quality` case resets the setting (AppSettings.swift:5). Keep raw values forever.
14. The signing reminder is re-scheduled only when the app opens.

## Settings

| Now (file:line) | Key / default | Proposed name: description |
|---|---|---|
| AppSettings.swift:5, SettingsView.swift:264 | `quality` / balanced | **Recording detail** (Battery saver / Balanced / Precise / Maximum): "How closely trips are traced while you move. Higher uses more battery. Drops a step by itself when the phone is hot or in Low Power Mode." |
| :6, :267 | `showsIndicator` / on | **Show blue location bar**: "Helps keep iOS from pausing LifePath. Off hides the bar, but recording may stop more often." |
| :7, :268 | `deepSleep` / off | **Always rest deeply**: "LifePath already rests deeply by itself when the battery is low, the phone is warm or Low Power Mode is on. On: checks every 15 min instead of 5, so the start of a trip may be missed." |
| SettingsView.swift:273 | (button) | **Save health report**: "A text file of the last 3 days, for troubleshooting." |
| Status box (:258-260) | (rows) | **Last location check**; **SideStore refresh due**. |

The quality section's footer only describes deep sleep; each setting needs its own description.

Spec settings that don't exist yet: save spacing (fold into Recording detail, each level already sets it), smoothing strength (the smoother has no knob; drop unless the owner wants it), step counting (a status row pointing to iOS Motion & Fitness instead of a toggle). Stage 3 adds "Download street maps automatically" (on: "Sends only a map rectangle to OpenStreetMap, never your track"), "Use mobile data for map downloads" (on), "Count cycling in Streets walked" (off). Stage 5 adds "Save a backup", "Restore from a backup", "Export tracks (GPX, GeoJSON, KML)". Map tab choices reset on every launch (minor).
