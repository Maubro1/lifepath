# How fitness and navigation apps on iPhone get accurate GPS tracks with reasonable battery use

Scope: Strava, Komoot, Garmin Connect, Runkeeper, Nike Run Club, AllTrails, Apple Workout/Fitness, Google/Apple Maps, plus Gaia GPS where it fills gaps. Research date: Nov 2026. Older sources are flagged.

Overall caveat: none of these companies publishes its exact CLLocationManager settings. Most of what follows comes from Apple guidance, company support pages, a few engineering posts, and user reports. Treat any statement about a specific app's settings as unknown unless it is cited.

## 1. CLLocationManager configuration used by these apps

### Takeaway
No app in scope documents its exact `desiredAccuracy`, `distanceFilter`, `activityType` or `pausesLocationUpdatesAutomatically` values, and I found no credible reverse-engineering of them. What is documented is Apple's own guidance: set `activityType = .fitness` (or a navigation type), use the lowest accuracy you need, and let the system pause when stationary. Since iOS 17 the same is available through `CLLocationUpdate.liveUpdates(.fitness)` plus `CLBackgroundActivitySession`, which pauses and resumes automatically.

### Cited Findings
- Apple's energy guide (last updated 2016-09-13, **old**) says: set `desiredAccuracy` to the lowest precision needed. Higher accuracy powers up more hardware. Avoid `kCLLocationAccuracyBest` and `NearestTenMeters` unless you really need a few metres. The default for standard updates is `kCLLocationAccuracyBest`. — [Apple Energy Efficiency Guide: Location Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Same guide: set `activityType` (for example `CLActivityTypeFitness`) so Core Location can choose the best time for updates. Set `pausesLocationUpdatesAutomatically = YES` so the system can pause background updates when the user is not moving. Enable `allowsBackgroundLocationUpdates` only while you need it. Call `stopUpdatingLocation` when finished, even with auto-pause on. If accuracy is not improving, stop and retry later. — [Apple Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- The same 2016 guide recommends deferred updates (`allowDeferredLocationUpdatesUntilTraveled:timeout:`) to batch GPS fixes in the background. (From memory, not re-verified here: Apple deprecated deferred updates around iOS 13, so this part should not be relied on for iOS 26.) — [Apple Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- WWDC23 "Discover streamlined location updates" adds `CLLocationUpdate.liveUpdates(_:)` (an AsyncSequence) with `LiveConfiguration` cases `default`, `automotiveNavigation`, `otherNavigation`, `fitness` and `airborne`. These match the existing `CLActivityType` values, so an app keeps the same behaviour when it migrates. — [WWDC Notes 10180](https://wwdcnotes.com/documentation/wwdc23-10180-discover-streamlined-location-updates/); [Apple video](https://developer.apple.com/videos/play/wwdc2023/10180)
- With `liveUpdates`, the system pauses automatically when the device has been stationary long enough. The pause update has a non-nil location and `isStationary == true`. Updates resume without app action when the device moves. Apple presents this as a power saving ("We can be power efficient here by pausing the updates"). No numbers are given. — [WWDC Notes 10180](https://wwdcnotes.com/documentation/wwdc23-10180-discover-streamlined-location-updates/)
- `CLBackgroundActivitySession` shows the blue location indicator and keeps the app receiving updates in the background. Requirements: `UIBackgroundModes` must include `location`, and the app must keep a strong reference (deallocating the session invalidates it). A new session can only be started in the foreground. After the app is terminated, it can rejoin an existing session on a background launch, so it should recreate the session immediately. — [WWDC Notes 10180](https://wwdcnotes.com/documentation/wwdc23-10180-discover-streamlined-location-updates/)
- A developer asked on Apple's forums which `LiveConfiguration` uses the least battery and noted the docs "don't say much at all about the modes". A third-party skill site rates `.fitness` as "High" battery use, but that is unofficial and unverified. — [WWDC search summary / Apple dev forums tag](https://origin-devforums.apple.com/forums/tags/wwdc2023-10180); [Axiom core-location ref (unofficial)](https://playbooks.com/skills/charleswiltgen/axiom/axiom-core-location-ref)
- Strava's iOS GPS troubleshooting page describes Strava as GPS-only. It says Google Maps, Waze and Apple Maps "can seem accurate" because they also use cell signals, which can hide a GPS problem that Strava's track exposes. It also warns that battery/task-killer apps can switch off GPS or close Strava. The page names no CLLocationManager settings. — [Strava support: GPS troubleshooting on iOS (Czech)](https://support.strava.com/cs/articles/15402040-reseni-potizi-s-gps-v-systemu-ios)
- Strava's 2014 engineering post on auto-pause (**old**; I saw it only as a search snippet because the page returned 403) says the phone app auto-paused if it had no location update with positive speed for more than 10 s. The new runner auto-pause resumed only when the athlete was running, not walking. — [Strava Engineering: Improving Auto-Pause for Everyone](https://medium.com/strava-engineering/improving-auto-pause-for-everyone-13f253c66f9e)
- Gaia GPS (Outside) is the closest well-documented analogue. A 2023 user write-up found that the drain came from the on-screen compass (heading updates), not from GPS recording. Hiding the compass fixed it. — [Michael Tsai, "Reducing Gaia GPS Battery Drain" (2023)](https://mjtsai.com/blog/2023/05/02/reducing-gaia-gps-battery-drain)

### Inferences
- Fitness apps almost certainly run `startUpdatingLocation` at high accuracy (Best, or BestForNavigation for navigation) with `activityType = .fitness`, a small or no `distanceFilter`, and background location mode for the whole session. Their 1 Hz tracks and per-second pace displays would not be possible otherwise. This is an inference; no source confirms the exact values.
- In-app auto-pause (Strava, Garmin, NRC) is the app's own logic based on speed and time between fixes, as Strava's 2014 post describes. It is not Core Location's `pausesLocationUpdatesAutomatically`. With the classic API, a Core Location pause stays in effect until the app restarts updates, which a recording app must avoid. The iOS 17+ `liveUpdates` API removes that problem by resuming automatically.
- Settings that cost power without adding to the track (heading/compass, a live map on screen, live segments or beacon over cellular) are a large share of drain. Leaving them out matters as much as the GPS settings.

### Gaps
- No published or reverse-engineered `desiredAccuracy`/`distanceFilter` values for Strava, Komoot, Runkeeper, NRC or AllTrails. I found no komoot engineering post on iOS location.
- Garmin Connect mostly syncs watch data. I did not verify whether or how it records with phone GPS.
- Apple Workout on iPhone (iOS 17+ supports phone-only workouts) and Apple Maps use private frameworks. Their settings are not public.

## 2. Battery cost per hour of active GPS recording on modern iPhones

### Takeaway
I found no controlled, published per-hour test of Strava or Komoot on an iPhone 13–16. The usable figures are about 2–5 %/h for screen-off GPS recording on modern iPhones (Gaia GPS tests, one iPhone 16 background-tracking test) and about 10–15 %/h as a vendor rule of thumb. Navigation with the screen on is much higher. The screen, cellular radio, cold and weak signal drive drain more than the GPS chip itself.

### Cited Findings
- Strava support gives only a general guideline: modern phones can record more than 5 hours of activity. That implies under about 20 %/h, but it is not a measured rate. — [Strava support: Garmin and Strava](https://support.strava.com/hc/en-us/articles/216917177-Garmin-and-Strava)
- Strava support says Strava Beacon and Live Segments need cellular data. Users turn them off to save battery. — [Strava support](https://support.strava.com/hc/articles/216917177); [Bike Forums tips thread](https://www.bikeforums.net/road-cycling/840672-strava-tips-maximize-iphone-life-printthread.html)
- AllTrails support says tracking apps typically use 10–15 % of the battery per hour. Its tips: airplane mode when there is no signal (GPS still works), lock the screen when the Navigate view isn't needed, close other apps. — [AllTrails support: saving battery while recording](https://support.alltrails.com/hc/en-us/articles/360019244951-Saving-battery-while-using-Navigate-to-record-an-activity)
- Gaia GPS: reported at about 2–5 %/h, about 2 %/h in the current version, and about 5 %/h in "Tracking mode" by its own tests. A separate iPhone 15 Pro test with Gaia went from 100 % to 58 % on a 6-hour day hike (about 7 %/h, screen use not stated). I saw these figures in an extended-search summary that did not tie each number to a single page. The candidate sources are [Adventure Alan](https://www.adventurealan.com/iphone-gps-map-backpacking/) and [Outdoor Tech Lab](https://www.outdoortechlab.com/gps-vs-smartphone-hiking-test/). Verify before quoting.
- HeyPolo (Sept 2026) tested two identical iPhone 16s, one with its background location app installed and one without, logging each 10 % drop. Results: under 1 point per day extra while sitting still for a week; about 1.9x total drain on a 600 km, 3-day road trip; 1.4x over 6 days of commutes. The author's "gut feeling" is about 2 %/h extra while travelling. Each test ran once, on one model. The vendor ran the test on its own product. — [HeyPolo blog](https://heypolo.com/blog/how-does-location-sharing-affect-your-battery)
- An IEEE Access study cited in search results found GPS apps used 13 % of battery on average with good signal and up to 38 % with weak signal. I did not see the original paper, so test duration and conditions are unknown. — via search summary; original not located
- One MacRumors user reported Google Maps navigation at about 1 % per minute on an iPhone, and Apple Maps at less than half that. This is anecdotal. — via search summary (thread URL not captured)
- Older anecdotes (**iOS 11 era, old**): an iPhone 6s died after about 3.5 h of Strava recording. A cyclist had 33 % left after a 3 h 40 min ride. — [Apple Discussions](https://discussions.apple.com/thread/8109838?page=1); [CycleChat](https://www.cyclechat.net/threads/iphone-strava.161344/)
- The screen matters more than the GPS mode. Background tracking with the screen off gives about double the screen-on runtime. Checking the phone every 15 minutes burns almost as much as leaving the screen on. These are qualitative claims, not measured. — [Backpacking Mastery](https://backpackingmastery.com/basics/hiking-gps-vs-phone-gps-battery-and-accuracy-test.html)
- A Broadcom L1/L5 receiver (BCM4778, 7 nm) is quoted at about 4 mW for L1 only and about 6 mW for L1+L5. The 2017 BCM47755 claimed more than 50 % lower power than the previous generation. — [Broadcom press release](https://investors.broadcom.com/news-releases/news-release-details/broadcom-introduces-worlds-lowest-power-l1l5-gnss-receiver); [GPS World](https://www.gpsworld.com/broadcom-launches-dual-frequency-gnss-receiver-for-mass-market/)

### Inferences
- A GNSS receiver drawing single-digit mW is a tiny share of an iPhone's roughly 13 Wh battery: about 0.05 %/h at 6 mW. The observed 2–7 %/h for screen-off recording therefore comes mostly from the application processor waking for each fix, app code, cellular and Wi-Fi radios, and sensor fusion. Keeping the app idle between fixes and avoiding network calls during recording are the real levers. This is my calculation from the cited chip figures. Apple's actual GNSS chip and its power draw are not public.
- A realistic target for a screen-off walk/ride/drive recorder on an iPhone 15 Pro is about 2–5 %/h, based on the Gaia and HeyPolo numbers. That is about 1 % or less per hour once auto-pause stops GPS while stationary.

### Gaps
- No controlled Strava, Komoot, NRC or Runkeeper per-hour test on iPhone 13–16 was found. No Reddit thread with iPhone 15 Pro numbers turned up.
- No figure for how much `.fitness` vs `.automotiveNavigation` vs `.otherNavigation` changes power.

## 3. Post-processing: smoothing, outlier removal, auto-pause, map matching, elevation

### Takeaway
Clean tracks come mostly from post-processing, not from raw GPS. Common steps: drop low-quality or jumpy points, smooth the path (Apple Workout visibly rounds corners), remove stationary or slow segments for moving time (Strava does this server-side), and replace GPS altitude with a terrain model or barometer. Navigation apps (Apple/Google Maps) additionally snap to roads and fuse cell and Wi-Fi data, which is why they "look" more accurate.

### Cited Findings
- Strava corrects GPS-derived elevation server-side by looking up each point in elevation databases (basemap). Barometric elevation from a device file is used as recorded. Strava applies smoothing and thresholds; per its engineering team, the climb threshold is about 2 m. — [Strava: Elevation FAQs](https://support.strava.com/hc/en-us/articles/115001294564-Elevation-on-Strava-FAQs)
- Strava's server finds stretches below a speed threshold lasting more than 15 s and removes them from moving time (2014 post, **old**, seen as a snippet only). — [Strava Engineering: auto-pause](https://medium.com/strava-engineering/improving-auto-pause-for-everyone-13f253c66f9e)
- Strava's Global Heatmap pipeline filters out low-velocity points, such as after an activity stops moving, on the server. — [Strava Engineering: Global Heatmap](https://medium.com/strava-engineering/the-global-heatmap-now-6x-hotter-23fc01d301de)
- Strava notes that after a signal dropout the points before and after the gap are joined with a straight line, and that zigzag jumps inflate distance. This implies there is no aggressive gap-filling or map matching on recorded activities. — [Strava support iOS GPS](https://support.strava.com/cs/articles/15402040-reseni-potizi-s-gps-v-systemu-ios)
- Apple Workout app (Watch Ultra 3, Sept 2025): compared with the raw GNSS data, the Workout app's track is smoothed and appears to check each position against the next and drop inaccurate ones. Sharp 90° turns come out rounded. The tester's view is that distance and pace are barely affected. This is based on one run. — [the5krunner](https://the5krunner.com/2025/09/20/apple-watch-ultra-3-raw-data-accuracy-is-it-better-than-in-the-workout-app/)
- Gaia GPS says its algorithm filters inaccurate points, applies a smoothing filter, then averages the GPS points. Users note this smoothing underestimates very bumpy tracks. — [Gaia GPS help: Why GPS track recording can be inaccurate](https://gaiagpshelp.zendesk.com/hc/en-us/articles/216162057-Why-GPS-Track-Recording-Can-Be-Inaccurate); [search summary of Gaia community posts](https://help.gaiagps.com/hc/fr/community/posts/360048800354-Differing-elevation-gain-loss-in-Gaia-vs-TrainingPeaks-using-same-GPX-file)
- Komoot: user and forum reports blame elevation discrepancies on komoot's DEM. Phone-recorded komoot distance and elevation often come out higher than a bike computer's. I found no official komoot description of its smoothing. — [Suunto forum](https://forum.suunto.com/post/191830); [Pedelecs forum](https://www.pedelecs.co.uk/topic/36539-komoot-inconsistency/)
- A worked open example of Kalman smoothing Strava streams (2022) is a useful reference for an on-device implementation. — [Cleaning Strava data with Kalman smoothers](https://ybarmaz.github.io/blog/posts/2022-11-05-Cleaning-Strava-data-with-Kalman-smoothers.html)
- Elevation from noisy GPS: adding up every climb inflates the total, so thresholding or smoothing is needed. — [geo-activity-playground notes](https://martin-ueding.github.io/geo-activity-playground/elevation-gain-from-noisy-data)

### Inferences
- Recording apps keep raw-ish 1 Hz points on device, apply light filtering on device (accuracy gate, speed and jump gate, auto-pause), and do heavier corrections (DEM elevation, moving-time stats, heatmap filtering) on the server. A private app can do all of this on device: filter on `horizontalAccuracy`, reject impossible speeds, run a Kalman/RTS smoother after the session, threshold elevation, and use the iPhone barometer (`CMAltimeter`) for altitude instead of GPS.
- Map matching (snapping to roads) is a navigation-app technique (Apple/Google Maps). Fitness apps generally do not snap recorded activities, which is why Strava tracks still show drift through tunnels or urban canyons. For drives, light road snapping would make tracks look cleaner. For walks, it can be wrong on paths.

### Gaps
- No primary documentation of Runkeeper, NRC, AllTrails or komoot track-filtering algorithms.
- Apple Maps and Google Maps internals (snapping and sensor fusion) are not documented publicly.

## 4. Session-only recording vs an all-day tracker

### Takeaway
Every app in scope records only between a user-pressed Start and Stop. High-accuracy, 1 Hz, background-mode GPS is affordable for 1–5 hours but not for 16+ hours a day. None of Strava, Komoot, AllTrails, NRC or Runkeeper offers an always-on mode. The all-day "timeline" products (Google Maps Timeline, and Moves/Arc-style apps) use a different, opportunistic strategy and accept coarser tracks.

### Cited Findings
- Strava support's recording guidance assumes a single activity of about 5+ hours, not continuous logging. — [Strava support](https://support.strava.com/hc/en-us/articles/216917177-Garmin-and-Strava)
- AllTrails and komoot App Store listings warn that continued background GPS can dramatically decrease battery life. Komoot's listing says it "may use your location even when it isn't open". — [AllTrails App Store](https://apps.apple.com/app/id405075943); [komoot App Store](https://apps.apple.com/us/app/komoot-cycle-run-walk-mtb/id447374873)
- Google moved Maps Timeline (Location History) to on-device storage during 2024. Timeline became phone-specific, web Timeline ended on 1 Dec 2024, encrypted cloud backup became optional, and some migrated users later reported missing days (Mar 2025). — [9to5Google Dec 2023](https://9to5google.com/2023/12/12/google-location-history-timeline-device/); [9to5Google Dec 2024](https://9to5google.com/2024/12/11/google-maps-on-device-timeline/); [9to5Google Mar 2025](https://9to5google.com/2025/03/07/google-maps-timeline-missing/)
- The iPhone 16 always-on background location test (HeyPolo) showed under 1 point per day extra while stationary and about 2 %/h while travelling. Background tracking is cheap mostly because it is idle while the user is stationary. — [HeyPolo](https://heypolo.com/blog/how-does-location-sharing-affect-your-battery)
- `liveUpdates` auto-pauses on stationary and auto-resumes on movement. That makes the iOS 17+ API suited to long-running sessions. — [WWDC Notes 10180](https://wwdcnotes.com/documentation/wwdc23-10180-discover-streamlined-location-updates/)

### Inferences
- An all-day tracker should use two tiers. While still or in a known place, use a low-power mode (visits, significant-change or region monitoring, stationary pause). Once movement is detected (CoreMotion activity, or `isStationary` turning false), escalate to fitness-style high accuracy, then drop back. This copies what fitness apps do inside a session (their auto-pause) but applies it to the whole day.
- Users tolerate a heavy "while recording" cost in Strava because sessions are short and chosen by the user. The same settings left on all day would cost roughly 2–7 %/h × 16 h, which is unacceptable. Most of the day is stationary, so stationary-pause behaviour decides all-day battery life.
- Activity-specific accuracy is a reasonable choice. Drives tolerate a coarser `distanceFilter` (tens of metres) and benefit from road snapping. Walks need tighter spacing.

### Gaps
- I found no evidence that Strava or komoot ever shipped an always-on mode, so there is no "how did it fare" data. Moves (acquired by Facebook in 2014 and shut down in 2018, from memory) and Arc are outside this note's sources.

## 5. iPhone 15 Pro dual-frequency GPS (L1 + L5)

### Takeaway
The iPhone 14 Pro, 15 Pro and later Pro models have "precision dual-frequency GPS" (L1+L5). In theory L5 helps against multipath in cities. Real-world phone tests are scarce and mixed: an AppleVis test on the 14 Pro found no meaningful navigation gain. Chip data suggests dual-band adds only about 2 mW. I found no evidence that apps can turn L5 on or off. iOS handles it.

### Cited Findings
- Apple specs: iPhone 15 has GPS, GLONASS, Galileo, QZSS and BeiDou. iPhone 15 Pro has "Precision dual-frequency GPS" (GPS, GLONASS, Galileo, QZSS, BeiDou, NavIC). — [search summary of Apple spec page via Lefixea](https://www.lefixea.com/article/iphone12pro_iphone15pro_difference1); [Wikipedia iPhone 15 Pro](https://en.wikipedia.org/wiki/IPhone_15_Pro)
- An AppleVis real-world test (14 Pro vs single-band iPhone, 2022) concluded: don't buy a 14 Pro expecting apps like Soundscape to be more accurate. — [AppleVis](https://applevis.com/comment/140158) (page returned 403; conclusion seen via search snippet)
- At launch, the iPhone 14 Pro Max had dual-frequency GPS problems, which Apple fixed in the iOS 16.1 beta. — [PhoneArena](https://www.phonearena.com/news/apple-iphone-14-pro-max-gps-issues-ios-16.1-update_id142690)
- A Mapillary forum thread (June 2026) found no one with measured iPhone dual-frequency accuracy results. One member argued that more constellations help more than dual frequency, and suggested checking HDOP/VDOP. — [Mapillary forum](https://forum.mapillary.com/t/have-iphones-with-dual-frequency-gps-improved-accuracy/10423)
- On watches with the same idea (Apple Watch Ultra, L1+L5), reviewers report excellent accuracy overall. One review found it let down exactly where dual frequency should help (tall buildings, valleys). Another found it noticeably better than a Forerunner 965 at following paths. — [the5krunner (Ultra 2, 2023)](https://the5krunner.com/2023/09/27/is-apple-watch-ultra-2-accurate/); [Wareable](https://www.wareable.com/apple/apple-watch-ultra-2-ultra-running-test); [DC Rainmaker NYC gauntlet, Jan 2024](https://dcrainmaker.com/2024/01/apple-garmin-gauntlet.html)
- Dual-band phones vs dedicated GPS units: about the same on open ridgelines. Phones wander more under dense canopy and in canyons. — [Backpacking Mastery (undated, not lab-tested)](https://backpackingmastery.com/basics/hiking-gps-vs-phone-gps-battery-and-accuracy-test.html)
- Power: a Broadcom L1/L5 receiver is quoted at about 4 mW L1-only vs about 6 mW L1+L5. — [Broadcom](https://investors.broadcom.com/news-releases/news-release-details/broadcom-introduces-worlds-lowest-power-l1l5-gnss-receiver)
- Mobile GPS accuracy depends heavily on environment, per DXOMARK's smartphone GPS testing. — [DXOMARK](https://www.dxomark.com/gps-on-your-smartphone-why-youre-not-always-there-when-it-says-youre-there/)

### Inferences
- For the app's design, L5 is a free upgrade that iOS uses whenever the receiver is active at high accuracy. It probably reduces urban multipath jumps somewhat but does not remove them, so the outlier filtering in section 3 is still needed. The extra receiver power (about 2 mW, if Apple's chip is similar to Broadcom's) is negligible compared with CPU and radio wake-ups.
- `horizontalAccuracy` values on the 15 Pro will often read lower (better) than on non-Pro phones. Accuracy gates should be tuned on the target device.

### Gaps
- Apple does not disclose the 15 Pro's GNSS chip vendor or its power draw. I found no DC Rainmaker or other controlled iPhone 15 Pro vs iPhone 15 GPS accuracy test, and no measurement of whether L5 changes iPhone battery drain.
