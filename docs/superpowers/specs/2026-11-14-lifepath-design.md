# LifePath design spec

Date: 2026-11-14 · Status: approved by owner 2026-11-14

## In plain words (for the owner)

LifePath records where you go, all day, in the background, and turns it into a map, a day-by-day timeline, lifetime stats and a tally of streets you've walked. It lives only on your iPhone 15 Pro (iOS 26). It costs €0: the code sits in a public GitHub repository (code only, never your data), GitHub's free Mac machines build the app, and SideStore installs it on your phone with a free Apple ID. The one chore: once a week you open SideStore and tap "Refresh All", or the app stops opening until you do. LifePath reminds you a day before.

It's built in seven stages. Each stage ends with something you can install and try. Design questions (colours, layout, feel) come to you at the design stage, with mockups.

Changes from the original brief, forced by iOS:
- Backups must be saved to a folder outside the app (iOS deletes the app's own folder when the app is deleted). On a fresh install the app offers to restore and opens a file picker; it can't search your phone by itself.
- To show which street you were on, LifePath downloads street maps for areas you visit, automatically (can be switched off). Each download sends only a map rectangle (not your track) to OpenStreetMap's free Overpass service. Nothing else ever leaves the phone.
- Your recorded line is never changed. On the map, trips are shown snapped to the streets you most likely took; a toggle shows the raw recorded line, and spots where the match is unsure show the recorded line instead of a guess.
- Steps and stairs come from the motion chip (CoreMotion), not Apple Health.

## Principles (every decision is checked against these)

Every design choice, shortcut, limit and ruling is measured against these before it's made. When a shortcut would break one, it's the wrong shortcut.

1. **Life-long and complete.** LifePath is a map of a whole life. Nothing recorded is ever hidden by a limit: performance comes from showing less *detail* (simplified lines, coarser cells) when zoomed out, never from showing fewer *trips or places*. Time filters exist to choose a period, not to make the app cope.
2. **Honest.** Nothing is invented: unknown stretches stay gaps, guesses are marked as guesses, stored points are never modified.
3. **Precise.** The street actually taken, the place actually visited.
4. **Private.** Everything stays on the phone; the only network use is street-map downloads, which send a map rectangle and nothing else.
5. **Free.** €0 to build, install and run.
6. **Out of the way.** Install once, then forget it; no chores beyond the weekly SideStore refresh.
7. **Cool and light.** No warmth, little battery; heavy work only while open or charging.
8. **Smart but lightweight.** The strongest proven method that stays cheap to run.
9. **Smallest complete code** (ponytail): no speculative features, never cutting what protects data.

## Where LifePath aims past existing apps

Existing diary apps are the floor: LifePath borrows their proven battery mechanics and is held to stricter, checkable bars. The bars are realistic about what a phone can do, and the work pushes as hard as possible on every one of them.

- **Departures caught fast, cheaply.** Arc checks for departure with GPS every 6–60 s. LifePath uses the motion chip (steps, activity) as the first signal and GPS spot checks only as a backup with a 5-minute cap. Bars: fewer than 15 GPS spot checks per hour of rest, and the trip's start *time* dated within 30 s of the first step, from CoreMotion/pedometer history. After deep sleep, the stretch walked before the relaunch (about 200 m) has no GPS points; it is shown as a gap, never invented.
- **Accuracy proven, not claimed.** No app in this category publishes accuracy measurements. LifePath's CI measures the filter on every change. Bars: median ≤ 8 m on ordinary walks (open streets); among tall buildings and under dense trees raw GPS can be off by 15–20 m and filtering can only partly fix that. No corner cut by more than 10 m in the test fixtures.
- **The right street, outdoors.** Trips on foot, bike or car show the street actually taken, also where raw GPS wanders 15–20 m between buildings. Bar: ≥ 95% of walked distance on the correct street in canyon-noise fixtures; in real use, unsure stretches are shown as recorded, never guessed.
- **Stops and trips right.** In the CI test fixtures: zero false stops at red lights and zero false trips from a phone lying still. In real use the target is "very rare", and every case the health report reveals becomes a new fixture.
- **No silent gaps.** Every gap over 15 minutes in the diary has a recorded reason (permission, swipe-away, signing expiry, iOS relaunch delay), shown in the health report and the status box.
- **Cool phone.** LifePath should leave the phone as cool as if it weren't running. Heat comes from repeated waking and processing, so at rest the app does no work beyond the keep-alive and spot-check callbacks, each of which only compares timestamps or one distance; while moving, per-fix work is a few arithmetic steps and nothing renders in the background. Heavy work (map matching, history rebuilds) runs only while the app is open or the phone is charging. Bar: with LifePath the only active app, the thermal state stays nominal at rest and on walks, shown per hour in the health report next to wake counts. A warm phone is not proof of a LifePath problem: the thermal state is the whole phone's (charging, sunlight, games, navigation, other background apps). The health report therefore also logs charging on/off and when LifePath was open on screen, so warm hours can be put next to what LifePath was doing: warm while charging with GPS off and no wakes points elsewhere; warm with GPS on for hours or dozens of wakes points at LifePath.
- **Battery visible.** The health report shows hours of GPS-on time per day and wake counts, so a battery problem points at a cause.
- **Map that stays fast.** The map opens instantly at any history size and costs nothing when off screen.
- **Yours outright.** No account, no subscription, open export formats, merge-safe backups.

## Constraints

- €0. Windows 11 only, no Mac. Target: one iPhone 15 Pro on iOS 26.6.x. Never on the App Store.
- Fully private: no account, no server, no analytics, no network except OpenStreetMap street downloads (automatic around visited areas by default, switchable off; manual downloads always available).
- Battery first while still, recording first when unsure.

## Toolchain

- Swift 6 + SwiftUI, deployment target iOS 26.0.
- Project generated by **XcodeGen** from `project.yml` (no hand-edited `.xcodeproj`, which is git-ignored).
- **GitHub Actions** (public repo, `macos-latest`, free): on every push run Core tests; on tags build an unsigned IPA (`xcodebuild archive CODE_SIGNING_ALLOWED=NO`, zip `Payload/`) and attach it to a GitHub Release.
- **Install:** user opens the Release on the iPhone, downloads the IPA, installs via SideStore (free Apple ID, LocalDevVPN). AltServer on Windows is the fallback. Bundle ID fixed at `app.lifepath.LifePath` so re-signs and updates keep data.
- Git identity is a neutral noreply address; `.gitignore` blocks `*.lifepath`, `*.gpx`, `*.geojson`, `*.kml` outside test fixtures. Test fixtures are synthetic, never the owner's real tracks.
- One third-party dependency: **GRDB** (SQLite). Everything else is Apple frameworks.

## Architecture

```
LifePath/                iOS app target
  Recorder/              CoreLocation + CoreMotion glue, state machine driver
  Diary/                 GRDB database, migrations, queries
  Features/Map|Timeline|Stats|Settings|Onboarding
  Export/                GPX, GeoJSON, KML, backup, import/merge
  Health/                status box + health report writer
Core/                    Swift package, no UIKit/CoreLocation imports
  Filter                 outlier rejection + Kalman smoothing
  MotionState            moving / settling / still decisions
  Trips                  gap splitting, distance, moving time
  Heat                   time-weighted grid
  Streets                OSM segment matching + coverage
project.yml, .github/workflows/
```

Core takes plain value types (`Sample { t, lat, lon, hAcc, speed, course, source }`) and returns decisions and cleaned points. It is fully unit-tested on CI. The app layer stays thin.

## Recording engine

The design follows Arc Timeline's open-source engine (LocoKit2), the best-documented all-day recorder (claimed 24–48 h per charge), adapted to the brief. Research: `reports/Battery efficient location tracking.md`. LocoKit2 itself (MPL-2.0) is not used as a dependency. It brings its own timeline model, database schema, activity classifier and iOS 18+ requirement, has no documented third-party API, and the brief's quality levels, step wake, deep sleep and health report all need direct control of the engine. Its settings and decision logic are reimplemented in Core and credited in the README.

### Location managers (never mix roles on one manager)

- **Recording manager**: runs only while Moving/Settling. Quality level's accuracy, `distanceFilter` from the save-spacing setting, `pausesLocationUpdatesAutomatically = false`, `activityType` `.fitness` or `.automotiveNavigation` from motion activity.
- **Keep-alive manager**: runs always. `desiredAccuracy = 999` (just under 1000 m), **no distance filter**; its readings serve only to confirm presence while Still. Since iOS 16.4, iOS suspends apps that combine low accuracy with a distance filter; this configuration is the one Apple's DTS engineer gave as compliant. Held together with `CLServiceSession(.always)`.
- **Safety-net manager**: significant-location-change + visit monitoring, relaunch only. Plus `CLMonitor` 200 m circle around the pinned point.
- Blue location bar setting (default ON) additionally holds a `CLBackgroundActivitySession`, which shows the indicator and is the longest-tested protection against suspension. OFF relies on the service session alone, which Arc only adopted in Sept 2026 and still marks experimental.

### States

- **Moving**: recording manager on.
- **Settling**: still recording. Stop is declared when the filtered position stays inside a geofence for 2 minutes (+4 minutes if automotive or cycling was seen in the last 10 minutes). The fence centre is the accuracy-weighted mean of recent fixes; radius 20–100 m, scaled by their average accuracy.
- **Still**: recording manager off (GPS off). Position pinned to the fence centre. A still-point is written every 5 minutes, but only while presence is confirmed: a location reading (keep-alive, spot check, significant change) consistent with the rest area within the last 30 minutes. Without confirmation (no signal anywhere, location services off, phone off) still-points stop; nothing is assumed. When a reading later confirms the same place and the motion chip's history shows no departure in between (no step burst, no moving activity), the unconfirmed stretch is filled in; otherwise it stays a gap. The heat map counts time only through these still-points, so it stays accurate at pins and through the night. Wake signals:
  1. `CMPedometer` live updates: ≥15 steps since stop → Moving. Works indoors.
  2. `CMMotionActivityManager`: walking/running/cycling/automotive with medium+ confidence → Moving.
  3. Spot check: the recording manager turns on for up to 20 s at growing intervals (30 s at first, doubling to a 5-minute cap the longer you're still). A fix clearly outside the fence → Moving. Catches departures without steps (car from a garage).
  4. Relaunch nets (app terminated by iOS): `CLMonitor` circle, visits, significant change.

  Signals 1–3 work because the keep-alive manager keeps the app running. Fixes indoors get extra tolerance per place (learned drift) so GPS wander at night doesn't fake a departure.
- **Deep sleep** (automatic mix, confirmed by the owner 2026-11-14): light rest is the default; LifePath enters deep sleep by itself when Low Power Mode is on, the battery is below 20%, or the phone is warm in a way LifePath could plausibly help with: thermal state serious or worse, or fair while not charging. A phone warming up on the charger, in the sun or from another app isn't LifePath's doing, and resting deeper then would cost trip starts for almost no cooling, since LifePath already does next to nothing at rest. It returns to light rest when the reasons clear. A setting forces deep sleep always. In deep sleep the low-accuracy keep-alive stays on, so iOS keeps the app running, and a spot check runs at most every 15 minutes (light rest: at most every 5). Presence therefore stays confirmed through the night, and a stretch with no reading at all stays a gap. Departures are caught by the motion chip, the spot checks and the relaunch nets; trip starts are backfilled from CoreMotion history (`queryActivityStarting`, `queryPedometerData`), which also dates every trip start precisely after any wake.

### Ways of moving

The owner walks, runs, wanders, cycles and rides cars, buses, trams, trains and waterbuses. The engine judges confinement in space, never "steps happened", so each case falls out of one rule set:
- **Walking and running:** Moving while fixes leave the fence. Running gets its own filter noise (q = 8 m/s, like cycling) so the line keeps up at 3–5 m/s.
- **Wandering** (a market, a shop, a museum, pottering in the garden): staying inside a small area is a visit, drawn as a place, even while you shuffle around in it. If you wander beyond the fence (a big park), it's a trip and the path is drawn. Each steps-wake inside a visit is checked against the fence: if the fixes stay inside, the engine returns to Still after 60 s and the steps needed for the next wake rise (15 → 50 → 150, reset when you leave). Pottering about can't keep GPS on, while leaving the fence still wakes it at once through fixes, spot checks or the 200 m geofence.
- **Fidgeting** (phone in a pocket while sitting, swivelling in a chair): CoreMotion can briefly report walking and count a few steps. A walking activity only wakes a resting phone when at least 8 new steps back it up within 20 s; vehicle activity and the step threshold still wake on their own.
- **Waiting** (bus stop, platform, pier): a walk that ends in a wait becomes a visit; the vehicle ride after it is a new trip.
- **Vehicles:** stops at lights, bus/tram stops, stations and piers don't end a trip (vehicle rule); tunnels with confident vehicle motion keep it going.

Any doubt (conflicting signals, poor accuracy, missing motion permission) resolves to Moving.

### Battery rules (what made earlier attempts drain)

- GPS (recording manager) is never on while Still, except the short spot checks.
- No map, snapshot or other rendering while in the background. Per-update work is a few arithmetic steps; points are buffered in memory and written to the diary in one transaction every 30 s or on state change.
- No timers except the spot-check timer; no network; no per-fix logging (events only on decisions).
- Never stop the keep-alive manager while the app should be recording.
- Swiping the app away stops relaunching on iOS 26 (forum reports), so onboarding asks not to.

### Quality levels

| Level | desiredAccuracy | Default save spacing | Notes |
|---|---|---|---|
| Saver | `kCLLocationAccuracyKilometer` | 100 m | Wi-Fi/cell only, neighbourhood level |
| Balanced (default) | `kCLLocationAccuracyBest` | 10 m | full GPS while moving; street level |
| Precise | `kCLLocationAccuracyBest` | 5 m | denser points |
| Max | `kCLLocationAccuracyBestForNavigation` | 2 m | |

Easing: when `ProcessInfo.thermalState` ≥ `.serious` or Low Power Mode is on, run one level lower (never below Saver, never stop). Shown in the status box.

Battery targets for Balanced (from the brief, verified on device via the health report, not promised): about 6% per day at home, about 14% on a day with a walk. For reference, Arc claims 24–48 h of recording per charge (roughly 2–4% per hour, unmeasured), and screen-off GPS recording costs about 2–5% per hour while moving. The home-day target relies on GPS being off nearly all day.

### Filtering and smoothing (Core.Filter)

1. Drop: `hAcc < 0`, `hAcc` above the level's ceiling (Balanced 65 m), timestamps older than 10 s at arrival or in the future, duplicates.
2. Drop teleports: implied speed from the last accepted point > 60 m/s after subtracting both accuracies.
3. Smooth: a constant-velocity Kalman filter per axis in metres (state: position and velocity; white-noise-acceleration process model with acceleration noise qa = 1.0 m/s² walking, 2.0 running and cycling, 4.0 in vehicles; measurement variance = `hAcc²`). Modelling velocity removes the lag a position-only filter (LocoKit's design) shows at running and cycling speeds; it costs a few multiplications per fix and uses the same model as the offline smoother. While Still, output is the pinned point.
4. Store both raw and smoothed coordinates for each point.
5. **Trip smoothing (offline, best estimate):** the live filter can only use the past. Once a trip is finished, a constant-velocity Kalman filter (state: position and velocity per axis) runs forward over the trip's raw fixes, then a Rauch–Tung–Striebel pass runs backward, so every point is estimated from the fixes before *and* after it. This is the optimal linear smoother for this model, O(n) with a few dozen multiplications per point. It runs only while the app is open or charging (cool-phone rule), feeds map matching and the map's line, and is cached (`smoothedPoint(t, lat, lon)`, recomputable); stored points stay untouched. Bar: median ≤ 6 m on the same synthetic walks where the live filter must reach ≤ 8 m. Built in stage 2.

Acceptance: on synthetic tracks (straight streets, corners, stops) with 30 m-class noise added, median error of smoothed output ≤ 8 m. Corners are not cut by more than 10 m.

## Bad signal

Bad signal comes in distinct kinds, and each is handled where it does damage:

| Kind | What the phone does | How LifePath copes |
|---|---|---|
| Weak fix (indoors, trees, bag) | large `hAcc` | Kalman weighting by `hAcc²`; accuracy ceiling per level; wake decisions subtract `hAcc` |
| Confident but wrong (multipath between tall buildings) | small `hAcc`, position 20–40 m off, often for many seconds | Robust Kalman: innovation gating with a Huber weight. When a fix's innovation exceeds 2.5σ of `√(P + hAcc²)`, its variance is inflated in proportion, so a lying fix barely moves the line but a real turn still gets through over two or three fixes. Offline, the RTS smoother and HMM map matching use the whole trip, which corrects most of the rest. |
| Source switch (GPS lost → Wi-Fi → cell) | sudden jump with `hAcc` 65–1000 m | Ceiling drops cell fixes; teleport check drops Wi-Fi jumps; Wi-Fi fixes never wake a resting phone unless they clear the fence by their full accuracy |
| Stale or cached fix after a wake | old timestamp | Dropped when older than 10 s or out of order |
| No fix at all (tunnel, deep indoors) | nothing | Vehicle motion keeps a trip alive through tunnels; otherwise the indoor fallback rests GPS after 5 min. On the map a gap stays a gap; only when both ends are confidently matched and the network allows a single plausible route (a train tunnel between two stations) is that route drawn, dashed and labelled as inferred |
| Noisy speed | jumps imply false speeds | Speed only from the phone's Doppler measurement (`CLLocation.speed`), and only when `hAcc ≤ 20 m`; never from distance over time |
| Noise while settling | fixes bounce around a stop | Settling uses filtered points and tolerates up to 10% of fixes outside the fence in the window |
| Bad mobile data | downloads fail | Street downloads queue and retry; nothing else needs a network |

The health report shows, per hour, the median accuracy and how many fixes were dropped for each reason (counted in memory and written with each batch, never logged per fix), so a bad-signal stretch is visible as such and not mistaken for a bug.

## Diary (SQLite via GRDB)

One file in Application Support, `diary.sqlite`, WAL mode, versioned migrations.

- `point(t PRIMARY KEY, lat, lon, rawLat, rawLon, hAcc, speed, kind)` with kind = moving | still. The timestamp key makes import merging trivial.
- `daySteps(day PRIMARY KEY, steps, distance, floorsUp)` copied from CMPedometer on every launch/foreground (last 7 days, upsert).
- `osmWay(id, name, highway, geometry)`, `segment(id, wayId, a, b, lengthM)`, `segmentHit(segmentId PRIMARY KEY, firstT)`, `area(id, bbox, downloadedAt)`.
- `event(t, kind, detail)` for wake reasons, state changes, thermal, permission changes. Rolled to the last 14 days.
- Settings in `UserDefaults`.

## Places (learned automatically)

LifePath remembers the places where you spend time, so it can rest smarter there and show them on the map. Places add memory on top of the motion engine; they never switch departure detection off.

- **Shape first, pin second.** A place is stored as a shape (where you actually spend time) and the pin is derived from it. The shape drives every decision; the pin is only what the map shows.
- **The shape: a time-density grid.** Each place keeps a sparse grid of 5 m cells. Every still point adds its duration to the cells under it, spread by a small Gaussian kernel whose width is the fix's accuracy (a 5 m fix sharpens one spot, a 40 m fix smears thinly over many), weighted by 1/hAcc² so confident fixes count most. Weights decay with a 60-day half-life, so the shape follows you when furniture, habits or even your home change, and an old place fades away. The place is the smallest set of cells holding 90% of its time (the highest-density region), with one-cell holes filled. It can be any shape: a house with its garden, an L-shaped office, a campus. Membership ("am I inside?") is a hash lookup of the fix's cell, widened by its accuracy.
- **The pin: the density peak.** The pin sits on the cell with the most time after smoothing (the mode), the spot where you really spend your time: the sofa, the desk. It isn't the average position, which can fall in the middle of a courtyard or outside an L-shaped building. When two peaks are nearly equal (desk and bed), the pin goes on the one with more time in the last 30 days.
- **Learning:** every finished rest of ≥ 10 minutes is a visit. A visit whose fixes fall mostly inside a known place's shape (widened by 20 m) joins it; otherwise it starts a candidate. A candidate becomes a place (a pin) when it has earned 100 points: 4 points for every different day visited plus 1 point for every hour spent there (home ≈ 6 days, school ≈ 2 weeks, part-time work ≈ a month, gym ≈ 6 weeks, monthly overnight family visits ≈ 5 months, a regular café ≈ 8 months, a one-off bench or festival never). A pin is hidden from the map after 6 months in a row without a real visit, and one real visit brings it back at once; a real visit lasts at least 5 hours, or at least half as long as the median of that place's recent visits. Hidden pins are never deleted: a map period that includes their visits shows them. There is one kind of place (no invisible tier); shapes that touch merge. A home is a few hundred cells, updated once per rest: cheap.
- **On the map:** the pin, plus the shape drawn as a soft outline (contour of the cell set, smoothed) when zoomed in. iOS geofences are circles only, so the 200 m departure geofence is centred on the pin with a radius covering the whole shape plus margin.
- **Resting at a known place:** the rest fence is the place's shape, so the dot sits on the same spot (the pin) every night and normal indoor GPS wander inside the shape no longer looks like leaving (the per-place drift item the recording engine deferred). Still points use the pin. The spot-check cap rises from 5 to 15 minutes after 30 minutes at a known place; steps, motion, the 200 m geofence and fixes clearly outside the place still wake LifePath at once.
- **Pottering at a known place:** at home, at work or in a garden you wander and do random things, which is exactly what scribbles a track. Inside a known place, movement that stays within the place's shape is part of the visit: the steps needed to wake start at 50 instead of 15, a steps wake returns to rest after 60 s as soon as fixes show you're still inside, and no trip line is drawn inside the place. Leaving is still caught at once by fixes outside the shape (allowing for their accuracy), the 200 m geofence or vehicle motion.
- **Map and timeline:** places appear as pins sized by time spent, with total time and visit count. The timeline reads "At Home 22:10–08:05" for a rest at a named place. Pins can be renamed (Home, Work, …); unnamed ones show the street from the downloaded street data. Stats gain "Where you spend your time".
- **Storage:** `place(id, pinLat, pinLon, totalSeconds, visits, name)`, `placeCell(placeId, cell, weight, updatedAt)` and `visit(start, end, placeId)`; both recomputable from stored points.

## Screens

Tabs: **Map · Timeline · Stats · Settings**. Visual direction is decided with the owner at stage 6 (impeccable skill, mockups). Stages 2–5 use plain system styling that the design stage then restyles.

- **Map**: `MKMapView` wrapped for SwiftUI (custom overlays need it). Track polylines coloured by date (gradient) or speed (walk/bike/drive bands). Time filter: today, week, month, year, all, custom. Standard / satellite. Heat overlay from Core.Heat (seconds spent per ~25 m cell, so a night asleep counts once per hour of presence, not per point). Moving trips are drawn along their matched streets by default (Core.Streets matcher); a "Recorded line" toggle shows the stored track; low-confidence stretches always show the recorded line, styled differently. Streets toggle draws covered segments. Locate-me button. Trips split on gaps > 10 min or jumps > 500 m. Polylines simplified per zoom (Douglas–Peucker, tolerance in metres, 3–5 m at street zoom) and loaded per visible region. The map renders only while on screen.
- **Timeline**: days newest first; card = route thumbnail (`MKMapSnapshotter`, cached on disk), distance, moving time (moving points only), steps.
- **Stats**: Where you went (lifetime distance, days tracked, points stored); On foot (steps, walked distance, floors); Streets walked (% of downloaded streets covered, per area).
- **Settings**: status box on top (healthy / resting / problem, last point, last check-in, signing expiry, hints for changed permissions or app swiped away), quality level, save spacing, smoothing strength, blue location bar toggle, deep sleep, step counting, export, import, health report.
- **Onboarding**: what it does → location While Using → Always → please don't swipe it away → optional motion & fitness → start.
- Pull to refresh on every main screen.

## Streets: map matching and coverage (Core.Streets)

Phone GPS between tall buildings or under trees can be 15–20 m off; filtering alone can't put such a track on the right street. Sequence-based map matching can, because it uses the whole path, not one point at a time.

- **Street data:** OSM `highway` ways plus `railway=rail|tram|light_rail|subway` and `route=ferry` from Overpass (the owner travels by tram, train, bus and waterbus as well as on foot, bike and car). Automatic: after a trip ends (on Wi-Fi or mobile, user setting), tiles of ~2 km covering the trip that aren't stored yet are fetched once. Manual "Download streets here" stays. Setting "Download street maps automatically" (default on, confirmed by the owner 2026-11-14) with a privacy note that each request sends a map rectangle.
- **Matcher:** Hidden Markov Model with Viterbi decoding (Newson & Krumm 2009). Candidates: road positions within max(30 m, 2 × hAcc). Emission: Gaussian on distance, σ from the fix's accuracy (floor 4 m). Transition: exponential on |route distance − straight distance|, β ≈ 3 m, using the shortest path along the network between candidates. Heading and speed shape candidates (walking speeds allow footpaths and both directions; vehicle speeds favour drivable ways and one-way rules). Points closer than 2σ to the previous used point are thinned.
- **Confidence:** each matched stretch gets a score from the winning path's probability margin over the runner-up and the share of points within 2σ. Below threshold, or where no road is within reach (parks, fields, indoors), the stretch is marked unmatched and the map shows the recorded line there.
- **Storage:** stored points are never modified. Matches live in `matchedStretch(tripStart, seq, wayId, fromM, toM, confidence)`, recomputable at any time.
- **Travel mode per stretch:** each trip is split into stretches classified as walking, cycling, car, bus, tram, train or boat, by a second small HMM/Viterbi pass over per-stretch features: CoreMotion activity, speed profile, stop pattern (buses and trams stop every 300–800 m, trains every few km), and which network the matcher fits best (rail ways vs roads; a road-following vehicle that halts at mapped bus stops is a bus). Rail stretches are matched to rail ways, never snapped to a parallel road; boat stretches (waterbus, ferry) match `route=ferry` lines, and open water with no mapped route shows the recorded line, which GPS keeps accurate under open sky; tunnels with no fixes stay a gap between matched ends. The map colours trips by mode as well as by date or speed.
- **Coverage:** ways split into ~20 m segments; a segment is hit when a confident matched stretch classified as walking (cycling optional, setting) runs along it; vehicle stretches never count. A street (all segments of a named way, or the way if unnamed) is covered at ≥ 90% of its length hit (100% for 10 or fewer segments), the CityStrides rule.
- Matching (and history re-matching after a new download) runs only while the app is open or the phone is charging, never in the background on battery. Street downloads after a trip are a single small request and may happen in the background.

## Export, backup, import

- GPX, GeoJSON, KML for all or a date range; backup is a `.lifepath` file made with `VACUUM INTO` (complete diary).
- Saved via the system file exporter, so the owner picks the folder (outside the app's folder for survival).
- Import: file picker → preview (point count, date range) → merge with `INSERT OR IGNORE` on all tables. Never deletes.
- Fresh install with an empty diary: one-time "Restore from a backup?" prompt.

## Health report

One tap writes `LifePath-health-YYYY-MM-DD.txt` (last 3 days) via the file exporter: per hour, % resting, wake count by reason, worst thermal state, accuracy histogram, point counts, gaps > 15 min with the last event before each, current settings and permissions. Written as plain text for pasting into an AI.

## Signing expiry reminder

The app reads `ExpirationDate` from its own `embedded.mobileprovision` and schedules a local notification 24 h before (local notifications need no paid account). Shown in the status box.

## Testing

- Core: test-driven, unit tests on CI for every push. Synthetic track generators with seeded noise for filter accuracy, stop detection (red lights must not count as stops, sofa must not count as moving), trip splitting, heat weighting, map matching on a synthetic street grid with canyon-style noise (biased 15–25 m multipath bursts): ≥ 95% of walked distance on the correct street, parallel street and alley not lit, unsure stretches flagged, not guessed.
- App: CI build must pass. On-device checks per stage using the health report. No simulator exists on Windows; screens are verified on the phone and with CI screenshots from the iOS simulator on the Mac runner where useful.

## Stages (each gets its own implementation plan)

0. **Pipeline**: repo, XcodeGen, CI, Release, near-empty app on the phone via SideStore, one refresh done. Proves the €0 route.
1. **Recorder**: Core filter + motion state, recorder, diary, status box, health report, onboarding (plain).
2. **Map**: offline trip smoothing (RTS), tracks, filters, colouring, heat, locate, learned places (pins, and resting at known places).
3. **Streets**: OSM download (manual + automatic), map matching, matched display, Streets walked coverage.
4. **Timeline + Stats + steps**.
5. **Export / backup / import / restore prompt**.
6. **Design**: visual direction with the owner, restyle all screens, settings polish, onboarding copy.

Backup comes before design so the diary can be saved early in real use.

## Risks

- Missing the weekly SideStore refresh stops recording until refreshed (data is safe). Mitigated by the reminder.
- SideStore/Apple signing changes could break installs. Fallback: AltServer on Windows.
- Background behaviour can only be proven on the device; stage 1 runs several real days before stage 2 starts.
- Battery figures are targets, measured via the health report.
