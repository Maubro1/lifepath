# How always-on iOS location diary / lifelogging apps get low-battery continuous tracking

Research date: 2026-11-14. Source code was read from shallow clones of the repos as they stood on that date: LocoKit2 last commit 2026-11-12, LocoKit (v1) last commit 2020-12-07, Overland-iOS last commit 2026-11-12, OwnTracks iOS last commit 2026-10-17. Line references are approximate, for the file versions read then.

Base URLs used below:
- LocoKit2: https://github.com/sobri909/LocoKit2 (MPL-2.0, iOS 17+, Swift 6)
- LocoKit v1 (old, 2020, legacy): https://github.com/sobri909/LocoKit
- Overland: https://github.com/aaronpk/Overland-iOS
- OwnTracks: https://github.com/owntracks/ios

---

## Q1. Arc Timeline / Arc Editor / LocoKit / LocoKit2: moving vs stationary, sleep/wake cycles, CLLocationManager settings per state

### Takeaway
LocoKit2 never fully stops location services. It runs two CLLocationManagers. A "recording" manager (10 m accuracy, distanceFilter 3 m) runs while moving. When the Kalman-filtered location has stayed inside a small self-computed geofence (radius 20–100 m) for 2 minutes, it switches to "sleeping": GPS-level updates stop and a second "sleep" keep-alive manager (desiredAccuracy 999 m, distanceFilter none, no indicator) plus significant-location-change keep the app alive. Wake-up comes from timers, not iOS geofences. Every 6–60 s (set from the learned Place's leaving probability) it turns the precise manager on for up to 30 s, checks whether the fix left the geofence, and either resumes recording or goes back to sleep. In 2026 the default became a "shield regime" built around Apple DTS's rule that keep-alive sessions need desiredAccuracy < 1000 m and no distance filter.

### Cited Findings

**State machine (LocoKit2, current)**
- Recording states are `off`, `recording`, `sleeping`, `deepSleeping` (rawValue 3), `wakeup` and `standby`. `sleepStates = [wakeup, sleeping, deepSleeping]`. In current LocoKit2, `deepSleeping` is only handled as a state and is never entered by LocomotionManager (no `startDeepSleeping` exists). [RecordingState.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Models/RecordingState.swift); [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Recording manager config:** `distanceFilter = 3`, `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`, `pausesLocationUpdatesAutomatically = false`, `showsBackgroundLocationIndicator = true`, `allowsBackgroundLocationUpdates = true`. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Sleep (keep-alive) manager, "shield" regime (default since 2026-09-30):** `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy = 999` (code comment: "just under the magic 1000"), no indicator, `pausesLocationUpdatesAutomatically = false`. It is never stopped while recording is on. Its locations are discarded by the delegate (`guard manager !== parent.sleepLocationManager`), so it is keep-alive only. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Shield regime keep-alive:** at startRecording it creates `CLServiceSession(authorization: .always)` (iOS 18 API) and sets `showsBackgroundLocationIndicator = false` on the recording manager. The comment says this avoids the forced blue indicator that `CLBackgroundActivitySession` brings. It is labelled internally "BIG-617 shield regime (two-manager compliance experiment)", and the comment's hypothesis is that "the sole-df=3-session state is what cued the suspensions". [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Baseline regime (the earlier long-shipped config, still available via `useShieldRegime = false`):** keep-alive is `CLBackgroundActivitySession()`, which forces the indicator. The sleep manager uses `desiredAccuracy = kCLLocationAccuracyThreeKilometers` and `distanceFilter = 3000` with the indicator on, and is stopped during recording. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **startRecording:** `locationManager.startUpdatingLocation()` plus `startMonitoringSignificantLocationChanges()`. Starts Core Motion (accelerometer sampler and CMPedometer step sampler), a fallback timer (`fallbackUpdateDuration = 6` s) and a chain watchdog. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **startSleeping:** stops Core Motion, starts the sleep manager and significant-location-change monitoring, stops the precise manager (`locationManager.stopUpdatingLocation()`) and arms a one-shot wakeup timer of `sleepCycleDuration`. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **startWakeup:** restarts `locationManager.startUpdatingLocation()` and arms a wakeup timeout of `wakeupTimeout = 30` s, which can extend once to 60 s when an "underground" (metro) detector is warming up. In `wakeup`: if the Kalman location is outside the sleep geofence it goes to recording. If raw and Kalman disagree, it keeps gathering until the timeout. If both are inside, it sleeps again immediately. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Sleep decision (SleepModeDetector):** `sleepModeDelay = 2 min`. The geofence is the accuracy-weighted centre of the last ~2 min of Kalman-filtered fixes, with radius = mean horizontalAccuracy clamped to 20–100 m (×2 if there is only one sample). `shouldBeSleeping = durationWithinGeofence >= 2 min`. The state then "freezes" and unfreezes only when a filtered fix lands outside the fence. It re-evaluates every 6 s even when updates stall. [SleepModeDetector.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Samplers/SleepModeDetector.swift)
- **Extra gate:** sleeping only starts when the current timeline item is a Visit whose age ≥ `TimelineItemVisit.minimumKeeperDuration` (`canStartSleeping`). The code comment says age is used "because distanceFilter delays new samples when stationary". [TimelineRecorder.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineRecorder.swift)
- **Moving vs stationary per sample (StationaryStateDetector):** uses a 10 s window and requires mean horizontal accuracy ≤ 50 m. Stationary if the accuracy-weighted mean speed is below ~0.5 m/s with SD below ~0.3 m/s. A "moving" verdict is overridden when ≥ 50% of raw fixes have invalid velocity (speed −1). [StationaryStateDetector.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Samplers/StationaryStateDetector.swift)
- **Adaptive sleep cycle (Arc's "sleeps more deeply at learned places"):** while recording the cycle is 6 s. At a known Place, the cycle comes from `place.leavingProbabilityFor(duration:)`: probability ≥ 0.10 gives 6 s; 0.01–0.10 maps onto 60→6 s on a cube-root curve; < 1% gives 60 s. Fallback with no place: 6 s for the first 2 min, linear 6→30 s up to 60 min, then capped at 30 s ("matches Arc Timeline"). [TimelineRecorder.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineRecorder.swift)
- **Developer confirmation (forum, 3 Oct 2024):** "Sleep cycles are dynamic, from about 6 to 60 seconds, based on the current Place model and typical leaving times." Arc Recorder lacks Places, so it uses about 6–30 s based on time since arrival. During sleep the app does nothing and wakes briefly for a single location check. "When Arc / LocoKit are in sleep mode there aren't any calculations." [Big Paua forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- **Why not iOS geofences:** the developer (3 Oct 2024) says iOS's built-in geofencing suspends the app and typically fires only after about 100 m of movement, too slow for Arc. [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- **Stale-fix handling:** in recording, if the last raw fix is more than 60 s old, it does stop/start on the manager, throttled to once per 60 s. In wakeup it uses a 70 s staleness threshold with backoff 60 s → 2 m → 5 m → 10 m while restarts produce nothing ("bad-signal bedroom marathons"). The code comment says the old 60 s threshold caused "~1,000 redundant full-accuracy spin-ups/day". [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Robustness:** a 60 s repeating watchdog re-arms the sleep/wake timer chain if it has stalled > 180 s. The comment describes field cases where a MainActor Task hop never ran and "recording silently dies until relaunch". `locationManagerDidPauseLocationUpdates` is logged as an error ("iOS paused despite pausesLocationUpdatesAutomatically=false") and triggers startSleeping. Out-of-order or cached fixes (timestamp ≤ last) are discarded. CLLocationManagers must be created on the main thread or delegate callbacks are silently lost. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Standby (two apps, Arc Timeline and Arc Recorder, sharing an App Group):** the non-active recorder runs only the sleep manager plus significant location change, with `standbyCycleDuration = 120` s checks to see whether it should take over. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift); [Arc Timeline Recorder App Store](https://apps.apple.com/us/app/-/id6499296846)
- **"Trust factor" / drift inflation:** indoor drift can falsely wake the app at night. LocoKit2 inflates the accuracy of raw fixes using a per-place drift profile before the Kalman filter, so drift stays inside the geofence. The developer (Jul 2023) says correcting drifting segments teaches Arc a trust factor that keeps it asleep longer. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift); [forum thread 518](https://support.bigpaua.com/t/can-i-pause-arc-overnight-to-save-battery/518)

**LocoKit v1 (2020, legacy, flagged as old)**
- It used a single manager. Sleep was reached by setting `desiredAccuracy = Double.greatestFiniteMagnitude` and `distanceFilter = CLLocationDistanceMax` (not stopping). Defaults: `sleepAfterStationaryDuration = 180` s, `sleepCycleDuration = 60` s, `fallbackUpdateCycle = 30` s. While recording, `dynamicallyAdjustDesiredAccuracy` stepped among 100 m / 10 m / Best / BestForNavigation according to achieved accuracy, falling back to 100 m when stationary with ≥ 65 m achieved accuracy. [LocoKit LocomotionManager.swift](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift)
- v1 "deep sleep": `startDeepSleeping(until:)` requires ≥ 15 min (`miminumDeepSleepDuration = 60*15`). It stops updating location and Core Motion, starts `startMonitoringVisits()` plus `startMonitoringSignificantLocationChanges()` as "safety nets", and requests a server silent push to wake at the given time (`LocoKitService.requestWakeup`). It requires Background App Refresh. [LocoKit LocomotionManager.swift](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift)
- The v1 sleep approach (accuracy set to greatestFiniteMagnitude plus a huge distanceFilter while keeping updates on) is exactly the low-accuracy/distance-filter pattern Apple said, from iOS 16.4, can get apps suspended. See Q4. [Apple forum 726945](https://developer.apple.com/forums/thread/726945)

### Inferences
- Arc's core trick is "duty-cycled GPS inside a never-suspended process". The process stays alive cheaply (low-accuracy session plus significant change). Precise fixes are bursty: at most about 30 s of GPS every 6–60 s while stationary. Wake latency at home is up to 60 s, versus about 100–200 m of movement for an iOS region exit.
- The 2026 shift to `CLServiceSession` plus a 999 m / no-distance-filter companion manager suggests that on iOS 18–26 even Arc was being suspended with the older config. Hiding the blue indicator required the DTS-compliant configuration.
- The 6–60 s adaptive cycle depends on a learned per-place leaving-time model. Without one, a 30 s cap is the developer's default.

### Gaps
- No public LocoKit2 blog post or doc describes the shield regime. It is known only from code comments (BIG-617, dated 2026-09-30). I could not locate the DTS message that the comments cite.
- I did not determine whether Arc Editor (the current app name) differs from the LocoKit2 defaults. The bigpaua.com page only mentions "Arc Timeline 4".
- `TimelineItemVisit.minimumKeeperDuration` was not looked up.

---

## Q2. How OwnTracks, Overland, Life Cycle, Rove, Gyroscope, Moves, Google Maps Timeline and transistorsoft handle it

### Takeaway
Apart from Arc, the field uses simpler, coarser strategies:
- **Region exit (~200 m) as the wake mechanism:** transistorsoft, and Overland's optional "Resume with Geofence".
- **Significant-change plus visits only:** OwnTracks "significant" mode, Overland's battery preset, Life Cycle.
- **Continuous GPS:** OwnTracks "move", Overland "high resolution".

### Cited Findings

**OwnTracks (iOS)**
- Four modes: Quiet, Manual, Significant, Move. Every mode sets `pausesLocationUpdatesAutomatically = NO` and `allowsBackgroundLocationUpdates = TRUE`. [LocationManager.m](https://github.com/owntracks/ios/blob/master/OwnTracks/OwnTracks/LocationManager.m)
- **Move:** `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy = kCLLocationAccuracyBest`, startUpdatingLocation, and SLC and visits stopped. Publishing is filtered in software by `minDist` and `minTime` (a repeating NSTimer). [LocationManager.m](https://github.com/owntracks/ios/blob/master/OwnTracks/OwnTracks/LocationManager.m)
- **Significant:** stopUpdatingLocation, then `startMonitoringSignificantLocationChanges` plus `startMonitoringVisits`. [LocationManager.m](https://github.com/owntracks/ios/blob/master/OwnTracks/OwnTracks/LocationManager.m)
- Booklet: Significant mode reports moves of at least 500 m in 5 min, at most once every 5 min, and is described as battery-optimal. Move mode publishes every `locatorDisplacement` (default 100 m) or `locatorInterval` (default 300 s), with battery "comparable to navigation or tracker apps". Region monitoring is independent of the mode. [OwnTracks booklet: location](https://owntracks.org/booklet/features/location/)
- OwnTracks does not use stationary detection, duty cycling or CLBackgroundActivitySession in its LocationManager. [LocationManager.m](https://github.com/owntracks/ios/blob/master/OwnTracks/OwnTracks/LocationManager.m)

**Overland (aaronpk)**
- Tracking modes: off, standard, significant, both (standard plus SLC). Desired accuracy is user-set (nav/best/10m/100m/1km/3km), with separate trip settings for accuracy, activity type, pause and indicator. `startMonitoringVisits` is always on when tracking. [GLManager.m](https://github.com/aaronpk/Overland-iOS/blob/main/GPSLogger/GLManager.m)
- **"Resume with Geofence":** when iOS pauses updates (`locationManagerDidPauseLocationUpdates`) or Auto-Stop fires, it creates a `CLCircularRegion` at the last location with radius 100/200/500/1000/2000 m, exit-only, and on `didExitRegion` re-enables tracking. [GLManager.m](https://github.com/aaronpk/Overland-iOS/blob/main/GPSLogger/GLManager.m)
- **Auto-Stop (new, 2026):** if the phone stays within a user radius (up to 500 m, off by default) for N seconds (default 120 s; 600 s during a trip, "so stopping at a red light doesn't end the trip"), counting only fixes with accuracy ≤ 200 m, it calls stopUpdatingLocation, starts SLC as a backup and sets the exit geofence. It resumes when an SLC fix lands outside the radius. [AutoStop.swift](https://github.com/aaronpk/Overland-iOS/blob/main/GPSLogger/AutoStop.swift); [GLManager.m](https://github.com/aaronpk/Overland-iOS/blob/main/GPSLogger/GLManager.m)
- Docs: iOS auto-pause triggered about 10 min after stopping in initial testing, and resuming "may not happen immediately". A ≥ 50 m auto-stop radius is recommended because GPS drifts when still. SLC is usually reported only after about 500 m of movement. Visit tracking records an update after about 3 min at a new place. Min Distance and Min Time filters have "no noticeable battery effect" because iOS has already delivered the data. [Overland settings](https://overland.p3k.app/settings)
- Presets. High-res: pause off, geofence off, Standard, Other, Best ("a lot of battery", up to 1 point/s). Battery-saving: pause on, geofence 500 m, Significant, Other, 100 m ("much less battery"). Significant only "uses almost no battery". [Overland settings](https://overland.p3k.app/settings)

**transistorsoft background-geolocation (RN/Flutter/Capacitor, closed-source iOS core)**
- Two states. **Moving:** location on, recording every `distanceFilter` m, with elastic distanceFilter scaling by speed (`disableElasticity` default false). **Stationary:** location services off, app suspended ("There is no code running at all"), and a stationary geofence of `stationaryRadius` around the last position. [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation); [GeoConfig docs](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html)
- Motion: CMMotionActivityManager (still/on_foot/running/on_bicycle/in_vehicle). A `still` reading while moving starts the `stopTimeout` timer (default 5 min). On expiry it goes stationary; motion cancels the timer. [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation); [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html)
- Waking from stationary: on iOS the geofence exit typically needs ~200 m of movement even with `stationaryRadius: 25`. The enforced minimum radius is 25. [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html); [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation)
- `preventSuspend` (iOS, default false) keeps the app alive while stationary, so motion can be detected after "a few meters" instead of ~200 m, and enables `heartbeatInterval`. Docs warn of a "large and noticeable impact on battery consumption", "not suitable for continuous 24/7 operation". With the device unplugged and the screen off, iOS throttles heartbeats about 2 min after backgrounding. [AppConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/AppConfig.html); [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation)
- `disableStopDetection: true` on iOS makes location turn off after "exactly 15 minutes" of no motion (iOS's own auto-pause). `pausesLocationUpdatesAutomatically: false` has "severe battery-drain implications". `useSignificantChangesOnly` records roughly every 500–1000 m. Only `DESIRED_ACCURACY_HIGH` uses GPS. [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html)
- After iOS 16.4, transistorsoft changed its `showsBackgroundLocationIndicator` default to true (Capacitor 4.12.0, 2023-05-04), calling 16.4 "a major change to location-services" (as reported by Capawesome). [Capawesome blog](https://capawesome.io/blog/why-ios-stops-background-location-updates/)

**Life Cycle (Northcube / Sleep Cycle AB)**
- "Life Cycle does not use the GPS in the background, but instead relies on cell tower and Wi-Fi locations". It claims "less than 1% of your battery per day". Wi-Fi must be enabled. Latest version 3.2.7 (27 Jan 2025). [App Store listing](https://apps.apple.com/gb/app/id1064955217)
- User complaints: places sometimes take days to appear or don't appear; issues after iOS updates. [search summary of App Store reviews](https://apps.apple.com/app/id1064955217) (review quotes not individually verified)

**Moves (ProtoGeo, historical 2013–2018, discontinued; flagged as old)**
- Moves 2.0 (Nov 2013) added a battery-saving mode and M7 support, claiming up to 40% better battery life on typical use, on all iPhones. [The Next Web, 2013](https://thenextweb.com/apps/2013/11/14/moves-iphone-hits-2-0-new-look-battery-saving-mode-m7-coprocessor-support/)
- One anecdotal report: running Moves cost about 2 h 15 min of battery life per day; it was listed as the top battery drainer. [KnowYourMobile](https://www.knowyourmobile.com/applications/10-apps-that-are-killing-your-iphone-s-battery-life) (undated anecdote)

**Rove (historical 2013–2014; flagged as old, status unknown)**
- Adjusts sampling frequency by movement. Full M7 / Core Motion integration in late 2013, "optimized to minimize battery drain when the user is stationary". [AppAdvice 2013](https://appadvice.com/appnn/2013/11/automatic-life-logging-app-rove-gets-full-m7-integration-and-other-improvements)
- Rove 2.0 (Mar 2014) claimed up to 30% lower battery consumption on average. [The Next Web 2014](https://thenextweb.com/news/roves-stylish-location-diary-app-now-lets-save-specific-memories-lifelog)

**Gyroscope**
- The App Store listing contains only the standard background-location battery warning; the developer said location tracking was "fixed" in v2.9. No technical or battery details are published. [App Store](https://apps.apple.com/ch/app/gyroscope/id1104085053?l=en-GB)

**Google Maps Timeline**
- Moved from cloud to on-device storage by the end of 2024, with optional encrypted backup. [Google support](https://support.google.com/maps/answer/14169818); [9to5Google](https://9to5google.com/2024/12/11/google-maps-on-device-timeline/)
- I found no published description of the iOS collection technique or a battery figure. A user on the Arc forum (Aug–Sep 2024) saw Google Maps at 2–5% in the iOS battery list versus Arc at 20–31% on the same days (relative shares, see Q3). [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)

### Inferences
- Only Arc/LocoKit pursues high-detail stationary/moving segmentation with a quick wake. Everyone else accepts either ~200–500 m wake latency (geofence/SLC) or the cost of full continuous GPS.
- Life Cycle's under-1% figure is plausibly from SLC plus visits only (no GPS). That is the floor for a "place diary" with poor path detail.

### Gaps
- No technical details were found for Gyroscope, Google Timeline (iOS), or current Rove. Moves and Rove information is 2013–2014.
- transistorsoft's iOS core is closed-source, so the exact CLLocationManager settings in stationary state could not be verified beyond the docs.

---

## Q3. Reported daily battery percentages and user complaints

### Takeaway
Arc reports about 24–48 h of continuous recording per charge. Users report roughly 5–30% per day attributed to Arc, and occasional bad overnight drains, mostly from indoor drift causing false wakes. Life Cycle claims under 1% per day using SLC plus Wi-Fi/cell only. The iOS Battery screen percentages are relative shares between apps and are often misread.

### Cited Findings
- Arc developer: "can record continuously for at least 24 hours on a single battery charge, and up to 48+ hours on some iPhone models" (29 Aug 2024). Sleep mode runs roughly 24–48 h per charge (3 Oct 2024). [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- Arc developer: the Settings → Battery percentage is a share of the day's app energy, not a share of the charge. A 50% share on a day that used 50% of the battery is about 25% of a full charge. [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- User k4869 (iPhone 14 Pro, Aug 2024): Arc Timeline Recorder was the top app at 20% over ten days. User dayorbyte: Arc about 20% vs Google Maps 2% over 24 h, later 31% vs 5%. [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- The developer says the UI is the big cost: the map view uses as much battery in a minute as an hour or more of sleep mode. Arc's own Low Power Mode changes only the UI; background housekeeping runs only while plugged in. [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- The developer suspected Arc Recorder used more energy in standby because it lacked dynamic accuracy requests (Sep 2024, iOS 18). [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- Overnight (iPhone SE 2, Jul 2023): Arc running overnight left about 68% by morning, versus about 95% with Arc swiped closed or recording off. Earlier it once dropped to about 25%. That is roughly 27 points of overnight drain attributable to Arc on an old device. [forum thread 518](https://support.bigpaua.com/t/can-i-pause-arc-overnight-to-save-battery/518)
- Developer on swipe-closing: likely a placebo that can drain faster. A swiped-closed app restarts after an unpredictable delay ("perhaps in 15 minutes, or perhaps several hours later"). When unplugged and stationary, iOS doesn't relaunch Arc after swipe-close, and scheduled background tasks don't run. [forum thread 518](https://support.bigpaua.com/t/can-i-pause-arc-overnight-to-save-battery/518)
- Further figures appeared only in a search-engine summary that I did not verify on the source pages: about 17% overnight (developer estimate), 18% per 24 h on an iPhone 11, 5–7% per day with iOS Low Power Mode, and an iOS battery view showing "51%" during sleep. The likely sources are [High battery consumption](https://support.bigpaua.com/t/high-battery-consumption/64), [iOS 17 / iPhone 15 battery woes](https://support.bigpaua.com/t/ios-17-iphone-15-battery-woes/576?page=2) and [Arc Low power mode vs full interface](https://support.bigpaua.com/t/arc-low-power-mode-vs-arc-full-interface/182). Treat these as unverified.
- Arc App Store and site: "Recording your whole day takes some energy, and more detail takes more." Arc favours accurate paths over saving power. [bigpaua.com/arcapp](https://www.bigpaua.com/arcapp/)
- Life Cycle: under 1% per day (vendor claim). [App Store](https://apps.apple.com/gb/app/id1064955217)
- Overland: qualitative only ("almost no battery" for SLC only, "a lot of battery" for high-res). [Overland settings](https://overland.p3k.app/settings)
- OwnTracks: qualitative only (Move mode is comparable to navigation apps). [OwnTracks booklet](https://owntracks.org/booklet/features/location/)
- transistorsoft: no quantified figures; qualitative warnings only. [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation)

### Inferences
- A realistic target for an Arc-class recorder on an iPhone 15 Pro is roughly 5–15% per day in the background on a mostly-stationary day. This is extrapolated from the developer's 24–48 h claim and the user reports. Overnight false wakes and the foreground map are the main risks.

### Gaps
- No controlled, instrumented battery measurements (mAh, Xcode Energy Log) were found for any of these apps.
- No iPhone 15 Pro / iOS 26 specific battery reports were found.

---

## Q4. Recurring techniques, and what doesn't work or is deprecated

### Takeaway
Recurring techniques:
- Detect stationarity, then drop GPS. Detection is by GPS-speed or geofence dwell (Arc: 2 min) or by CMMotionActivity "still" (transistorsoft: 5 min).
- Keep a cheap wake path: a self-run timer duty cycle inside a kept-alive process (Arc), a region exit (~100–200 m, transistorsoft and Overland), or SLC (~500 m / 5 min) plus visits (OwnTracks, Overland, Life Cycle).
- Always set `pausesLocationUpdatesAutomatically = false` and manage stopping yourself.

Known pitfalls: since iOS 16.4, Apple suspends background apps that combine startUpdatingLocation plus SLC with low accuracy and a distance filter. iOS's own auto-pause is slow (about 10–15 min) and unreliable to resume. Region exits are coarse.

### Cited Findings
- **Apple's iOS 16.4 rule (Apple engineer, Mar 2023, accepted answer):** apps calling both startUpdatingLocation() and startMonitoringSignificantLocationChanges() "may get suspended in the background if they are specifying low accuracy and distance filtering". For continuous background updates: `allowsBackgroundLocationUpdates = true`, `distanceFilter` unset or `kCLDistanceFilterNone`, and `desiredAccuracy` of `kCLLocationAccuracyHundredMeters` or better ("If you're using numeric values, it must be set to less than 1000 meters"). Alternatively set `showsBackgroundLocationIndicator = true`. For accuracy of 1 km or coarser, use SLC alone. [Apple Developer Forums 726945](https://developer.apple.com/forums/thread/726945)
- Community reports in that thread say the indicator alone did not always fix it, that leaving distanceFilter unset behaved differently from explicitly setting kCLDistanceFilterNone (Jul 2023), and that the problem persists on iOS 17+ (Mar 2025). [Apple forum 726945](https://developer.apple.com/forums/thread/726945); [Apple forum 776698](https://developer.apple.com/forums/thread/776698)
- LocoKit2's 999 m / kCLDistanceFilterNone sleep manager directly implements the "< 1000 m numeric" rule (code comment: "the DTS-prescribed compliant session"). [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **CLBackgroundActivitySession** (iOS 17) and **CLServiceSession** (iOS 18) are the modern ways to declare background location sessions. A session must be recreated after a background relaunch (WWDC23). LocoKit2 used CLBackgroundActivitySession (forces the indicator) and moved to `CLServiceSession(authorization: .always)` plus a compliant sleep manager in 2026. [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/); [twocentstudios Core Location tips](https://twocentstudios.com/2024/12/02/core-location-modern-api-tips/); [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **iOS auto-pause is slow and unreliable:** Overland measured a pause about 10 min after stopping, with resumption "may not happen immediately". transistorsoft notes iOS turns location off after "exactly 15 minutes" of no motion. LocoKit2 treats an iOS pause as an error. [Overland settings](https://overland.p3k.app/settings); [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html); [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Region exit latency:** about 200 m (transistorsoft) and about 100 m (Arc developer), and the app is suspended in between. [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation); [forum thread 799](https://support.bigpaua.com/t/arc-timeline-recorder-still-drawing-quite-a-power-from-the-battery/799)
- **SLC latency:** about 500 m / 5 min (OwnTracks), about 500 m (Overland), 500–1000 m (transistorsoft). [OwnTracks booklet](https://owntracks.org/booklet/features/location/); [Overland settings](https://overland.p3k.app/settings); [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html)
- **Visits** (`startMonitoringVisits`) are used as a supplement by OwnTracks, Overland (about 3 min arrival) and LocoKit v1 deep sleep, never as the primary recorder. [LocationManager.m](https://github.com/owntracks/ios/blob/master/OwnTracks/OwnTracks/LocationManager.m); [Overland settings](https://overland.p3k.app/settings); [LocoKit v1](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift)
- **Keeping a process alive costs power:** transistorsoft `preventSuspend` has a "large and noticeable impact" and is not for 24/7 use. Heartbeats are throttled by iOS about 2 min after backgrounding when unplugged with the screen off. [AppConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/AppConfig.html)
- **Software min-time / min-distance filters save nothing:** iOS has already delivered the fixes. [Overland settings](https://overland.p3k.app/settings)
- **Core Motion is stopped during sleep** in LocoKit2 (accelerometer and pedometer). Motion is used for classification while recording, not as the wake trigger. transistorsoft instead uses CMMotionActivity as the primary moving/still signal. [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift); [Philosophy of Operation](https://github.com/transistorsoft/react-native-background-geolocation/wiki/Philosophy-of-Operation)
- **Deprecated or legacy approaches:**
  - LocoKit v1's silent-push "deep sleep" is gone in LocoKit2.
  - LocoKit v1's "accuracy = greatestFiniteMagnitude plus distanceFilter max" sleep falls under the post-16.4 suspension pattern.
  - Deferred location updates (`allowDeferredLocationUpdates`) appear in none of the current codebases I read (grep found no use). Apple deprecated them in iOS 13 (not verified with a source in this session).
  - [LocoKit v1](https://github.com/sobri909/LocoKit/blob/master/LocoKit/Base/LocomotionManager.swift); [LocoKit2](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- **Practical gotchas from LocoKit2 field logs:**
  - iOS re-delivers cached or stale fixes, so discard fixes timestamped at or before the last one.
  - Restart the manager when the newest fix is more than 60–70 s old, with backoff.
  - Run a timer-chain watchdog.
  - Create CLLocationManager on the main thread.
  - Indoor drift causes false wakes, so inflate accuracy at known places.
  - Sources: [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)

### Inferences
- For a private iOS 26 app: copy LocoKit2's two-manager design.
  - Recording: 10 m accuracy with a small distanceFilter, indicator on or a CLServiceSession.
  - Keep-alive: 999 m accuracy, kCLDistanceFilterNone, never stopped, plus SLC as a relaunch path.
  - Timer-driven wakeups of about 30 s at the cadence a place model allows.
  - A 2 min dwell inside a 20–100 m accuracy-scaled fence to enter sleep.
  - This beats the region-exit (~200 m) or SLC (~500 m) designs on detail, at a cost of roughly 24–48 h per charge by Arc's own claim.
- As a private app (not App Store reviewed), it can also keep the blue indicator on, which Apple says by itself avoids the 16.4 suspension.

### Gaps
- No Apple documentation was found that formally specifies the CLServiceSession plus 999 m "shield" behaviour; it rests on LocoKit2 code comments citing DTS.
- I did not check iOS 26-specific changes to background location policy.
- The deprecation status of `allowDeferredLocationUpdates` was not source-verified in this session.
