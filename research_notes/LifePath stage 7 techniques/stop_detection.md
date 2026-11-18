# Stop/stay detection and battery-saving pause logic for continuous iOS background tracking

## 1. Stay-point detection thresholds in literature and shipping apps

### Takeaway
Literature uses radius 20-200 m with dwell 20 s to 20 min; 200 m / 20 min is the classic (Li/Zheng) setting, and Lachesis-style algorithms add a max-gap parameter. Shipping-app internals (Arc/LocoKit, Google Timeline, Moves) are not published numerically; only qualitative behaviour was found.

### Cited Findings
- Li et al. 2008 algorithm: compare a point with its successors; once a successor is farther than the distance threshold, measure the time span first-to-last; if above the time threshold, it is a stay point. Commonly cited parameters (Zheng et al.): 200 m and 20 min. I could not confirm Li's own numbers (a "30 min" figure I was given was not found; sources say 20 min) — [arXiv 1904.09357](https://arxiv.org/pdf/1904.09357), [arXiv 1701.06276](https://arxiv.org/pdf/1701.06276)
- Literature range: time threshold from 50 s to 20 min, distance threshold from 20 m to 200 m — [Stay-point Identification as Curve Extrema](https://arxiv.org/pdf/1701.06276)
- Hariharan & Toyama (Project Lachesis, GIScience 2004): a stay is two or more locations exceeding a minimum stay duration within a maximum roaming distance; destinations then built by clustering stays with a scaling factor — [US patent 7,868,786](https://patentimages.storage.googleapis.com/63/86/f0/bd074ad1ddde2c/US7868786.pdf), [Microsoft Research](https://www.microsoft.com/en-us/research/?p=1114854)
- NOMAD library implements `lachesis` with `dur_min` (min stay, minutes), `dt_max` (max gap between consecutive pings in a stay, must exceed dur_min), `delta_roam` (max roaming distance, m). Also `ta_dbscan` (dist_thresh, min_pts, time_thresh), `st_hdbscan`, `grid_based` (H3/S2 cell). Defaults not stated on the page — [NOMAD docs](https://nomad.readthedocs.io/en/latest/stop_detection.html)
- Two-phase common structure: filter non-stationary points, then cluster stationary ones — [Infostop, arXiv 2003.14370](https://ar5iv.arxiv.org/html/2003.14370)
- LocoKit (Arc): `useLowPowerSleepModeWhileStationary` on by default; a delay before sleep once stationary; while asleep it wakes periodically to check for movement, each wake briefly at GPS accuracy; "near real time stationary/moving detection". No numeric delays published in README/search results — [LocoKit README](https://github.com/sobri909/LocoKit), [LocomotionManager docs (via search)](https://arc-web.herokuapp.com/locokit/docs/Classes/LocomotionManager.html) (page itself returned 503 on fetch)
- Arc App store listing: all day recording with GPS off in low power sleep mode for the rest of the day; Arc Mini takes over if iOS terminates Arc — [App Store](https://apps.apple.com/us/app/arc-timeline-trips-places/id1063151918)

### Inferences
- A max-gap parameter (Lachesis dt_max) is the literature's answer to gaps: a stay must tolerate pauses, so a resume after a gap should not be a new trip start unless displacement exceeds the roam radius.
- For a "never gap on short waits" goal, dwell for declaring a stop should be well above signal-wait durations (traffic light 1-2 min, platform up to ~5-10 min); a dwell of 5+ min before reducing GPS, and a separate longer dwell for committing a "place visit", fits the literature range.

### Gaps
- No numeric thresholds found for Arc/LocoKit sleep delay or wake interval, Google Timeline, or Moves. Indoor noise handling in these apps was not documented in sources found. Check LocoKit source (LocomotionManager.swift, BackgroundLocationMonitoring.md) directly.

## 2. iOS specifics (API behaviour, latency, gap problems)

### Takeaway
`pausesLocationUpdatesAutomatically` is the main gap source: Apple says a pause ends updates until the app restarts them (and in-use apps may not get relaunched). Safest: set it false and control power yourself via accuracy/distanceFilter. On iOS 17+, `CLLocationUpdate.liveUpdates()` has built-in stationary pause that stops deliveries until movement and resumes automatically; Apple advises not to stop it. Region monitoring/SLC are coarse (minutes, hundreds of metres) and safety nets only.

### Cited Findings
- Apple doc: with pauses on, the manager powers down hardware "when location data is unlikely to change"; after a pause "it's your responsibility to restart"; for in-use authorization a pause ends location access until the app launches again. Apple suggests instead disabling the property and dropping accuracy to `kCLLocationAccuracyThreeKilometers` in the background to stay power-friendly — [Apple docs](https://developer.apple.com/tutorials/data/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically.md)
- A third-party library changed its default activityType to `other` after gaps appeared in courier/fleet tracks; `automotiveNavigation` gives more aggressive pausing — [react-native-background-location migration](https://gabriel-sisjr.github.io/react-native-background-location/docs/migration/v0-17-0) (secondary)
- Forum report (anecdotal, unverified OS claim) of 74 s and 138 s delivery gaps even with pauses off and BestForNavigation; deliveries resumed on SLC or foreground — [Apple forums 844579](https://origin-devforums.apple.com/forums/thread/844579) (per search snippet; fetch failed)
- `CLLocationUpdate.liveUpdates()` (WWDC23 10180): AsyncSequence; once device still long enough, automatic pause; updates resume when device moves, no user interaction; property is `isStationary`, renamed `stationary` on iOS 18+ — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180), [forum 810433](https://developer.apple.com/forums/thread/810433)
- Apple engineer: when `stationary` is set you stop getting updates until the device moves; no need to stop updates; if app terminated while updates are stopped it never launches again when moving. Old API combo (GPS + SLC + region monitoring) gives more control but recovery after termination is "clunky, causing possible location update misses" — [forum 810433](https://developer.apple.com/forums/thread/810433)
- Stationary flag semantics undocumented: one report that `isStationary` flips true to false almost immediately after start; no Apple answer — [forum 750531](https://developer.apple.com/forums/thread/750531)
- `.automotiveNavigation` liveUpdates reported to deliver updates when lightly touching a stationary phone — [forum 758704](https://developer.apple.com/forums/thread/758704) (search snippet only)
- CLMonitor / region monitoring (Apple engineer, 2024): about one CLMonitor update per 1-2 minutes "always been the case"; "always said to expect 1 update every 3-5 minutes"; regions with radius smaller than the horizontalAccuracy of significant-location updates may miss entry/exit events; mostly same on iOS 18 as old API — [forum 757363](https://developer.apple.com/forums/thread/757363)
- CLServiceSession can only be started in foreground per WWDC24 10212 as quoted by a forum user (not Apple engineer) — same thread
- SLC (secondary, old): fires at about 500 m movement or cell change, at least 5 min between notifications; Apple energy guide quoted as wake at least every 15 min — [O'Reilly excerpt](https://www.oreilly.com/library/view/ios-components-and/9780133086898/ch02lev2sec5.html), [HA docs mirror](https://git.jeena.net/jeena/home-assistant.github.io/src/commit/02c8010ea78d6007fbb1ac234c02e9ccffcf4e23/source/_ecosystem/ios/location.markdown). Dependent on cell-tower density; needs cellular radio — [Stack Overflow mirror](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/22563432/ios-significant-location-monitoring-only-monitors-wifi)
- Legacy region monitoring, 2014 SO answer: ~200 m practical minimum radius, ~30 s to fire on entry, a couple of minutes to fire on exit — [SO mirror](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/a/23931552) (old, not CLMonitor-specific)
- iOS 26 flag: unanswered forum report that force-quit apps are no longer relaunched by SLC or region monitoring on iOS 26.4.2 (worked iOS 18 and earlier); CLBackgroundActivitySession shows the blue indicator; unresolved, unconfirmed by Apple — [forum 826964](https://developer.apple.com/forums/thread/826964)
- CMMotionActivityManager: WWDC14 said latency about 5-10 s, walking from pocket in ~3-5 s, treat activity as context over ~30 s — [WWDC14 612 index](https://nonstrict.eu/wwdcindex/wwdc2014/612/). Forum: iOS 16.4 beta reports of delays of several minutes to detect walking and false stationary on some devices; in background it behaves like the historical API and mostly reports on change — [forum 725416](https://developer.apple.com/forums/thread/725416). No current official latency figure found.
- Background CoreMotion needs the app awake: Apple DTS says motion apps rely on Core Location, HKWorkoutSession or audio; user report on iOS 26.5.2 that device-motion callbacks stop within seconds of backgrounding without a Core Location session (99.5% delivered with location on vs 0.16% off) — [forum 841001](https://developer.apple.com/forums/thread/841001)

### Inferences
- Wake-up from a stationary pause on a continuously running session (liveUpdates or startUpdatingLocation with pauses off) is bounded by Core Location's own motion detection; no measured number found. Region exit and SLC are minutes late and hundreds of metres coarse, so unsuitable as the primary resume trigger when the goal is "no gap in first minutes".
- Combining the Apple guidance: keep one location session alive permanently (never stop it, never rely on pause), vary accuracy, and treat SLC/region exit only as a relaunch safety net after termination.
- The iOS 26 force-quit relaunch report is unconfirmed; do not design around SLC relaunch after force-quit as guaranteed.
- CMPedometer / CMMotionActivity updates are only reliable while the app is awake; they are a cheap secondary signal, not a wake-up mechanism.

### Gaps
- No measured wake-up latencies from Apple for liveUpdates stationary resume, CLMonitor exit (metres/minutes), or CMMotionActivity on iOS 26. CMPedometer event latency: not found. Apple's own CLMonitor minimum radius: not found (only a third-party "about 100 m" claim). Needs on-device measurement.

## 3. Best practice for "settling" before declaring a stop

### Takeaway
Sources agree on the pattern (delay before sleep, periodic wake checks, hybrid with motion), but no source gives validated numbers. Use a two-stage approach: stay at reduced rate for minutes before any pause, and never fully stop the session.

### Cited Findings
- LocoKit: delay before entering sleep after becoming stationary; periodic wake with brief GPS-accuracy check; wake exits sleep when movement detected — [LocoKit README/docs](https://github.com/sobri909/LocoKit)
- Apple: lowering to 3 km accuracy in background keeps the session alive at low power — [Apple docs](https://developer.apple.com/tutorials/data/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically.md)
- Apple engineer advises against stopping updates while stationary and relying on system pause/resume — [forum 810433](https://developer.apple.com/forums/thread/810433)
- Suggestion from forum answer (not Apple): combine stationary flag with speed, horizontalAccuracy, short time window and consecutive updates — [forum 750531](https://developer.apple.com/forums/thread/750531) (answer text was generated by the fetch tool's summary, not the thread; treat as generic advice)
- Wi-Fi/indoor behaviour: legacy region/SLC is aided by Wi-Fi and other apps' location use — [SO mirror](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/22563432/ios-significant-location-monitoring-only-monitors-wifi) (secondary)

### Inferences
- Proposed state machine (my design, not sourced): MOVING (full accuracy) -> SETTLING (candidate stop; keep full or reduced-but-live GPS for N min, N roughly 3-5 min so traffic lights/platforms never trigger it; exit on displacement beyond ~30-50 m or speed above walking threshold or motion activity walking/automotive) -> STATIONARY (low-power: distanceFilter ~ 50-100 m / coarser accuracy, session alive, motion activity + pedometer as wake hints) -> back to MOVING on any trigger. Known places (home) can shorten SETTLING; street corners/stops/platforms should lengthen it.
- Indoor noise: require stay radius larger than typical indoor horizontalAccuracy (tens of metres), discard fixes with poor accuracy from displacement tests; use median of recent fixes as stay centre.

### Gaps
- No source gave tested N-minute values or indoor jitter statistics for iOS. Validate on device.

## 4. Gap filling after resume

### Takeaway
No authoritative source found on backfilling; only generic literature idea (Lachesis dt_max, stay continuation). Practical options are derived.

### Cited Findings
- Lachesis-style algorithms treat a stay as contiguous pings within roam distance with a max gap, so a gap inside a stay is bridged by the stay, not a new segment — [NOMAD docs](https://nomad.readthedocs.io/en/latest/stop_detection.html)
- LocoKit records pedometer, accelerometer and CoreMotion activity events by default alongside locations (usable as movement evidence during sleep) — [LocoKit README](https://github.com/sobri909/LocoKit)

### Inferences
- Backfill departure: when the first moving fix arrives, set the departure time to the earlier of (last stationary fix time + stay dwell) and the first motion-activity/pedometer change event after the last stay fix (CMMotionActivityManager and CMPedometer can query history via queryActivityStarting/queryPedometerData, as I recall from API knowledge; not verified here), and anchor the departure position at the stay centre; interpolate along the straight line (or snapped route) between stay centre and first fix, flagged as inferred. Step counts divided by average stride give a distance estimate for the unmeasured stretch.
- Never use pause/stop for traffic-light-length waits; the failure mode in all sources is a lost resume, not a slow one.

### Gaps
- No sourced measurements of how many metres/minutes are lost after resume with each API. History query APIs for CMMotionActivity/CMPedometer not verified in this session.

## Overall caveat
Many sources are forum posts, secondary mirrors, or search snippets (several Apple pages returned 404/502/503). Apple's forum threads are the best available primary evidence for iOS 17-26 behavior. API-change flags: `isStationary` renamed `stationary` (iOS 18); CLMonitor/CLServiceSession (iOS 17/18) with foreground-start constraint; unconfirmed iOS 26 force-quit relaunch regression.
