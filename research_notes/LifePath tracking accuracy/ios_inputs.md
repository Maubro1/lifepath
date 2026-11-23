# iOS / CoreLocation inputs: what the device delivers and what LifePath could use (as of Nov 2026)

Source quality legend used below: **[Apple doc]** = developer.apple.com documentation; **[Apple DTS/engineer]** = reply by an Apple-badged engineer on the Apple Developer Forums; **[dev]** = developer observation / blog / forum user; **[study]** = measurement paper. Dates are given where the source shows them.

## 1. kCLLocationAccuracyBestForNavigation vs kCLLocationAccuracyBest

### Takeaway
Apple only says BestForNavigation "uses additional sensor data" and costs more power (use while plugged in); it never says which sensors or what changes in the fixes. The one published comparison found no significant accuracy difference. There is no Apple-published measurement.

### Cited Findings
- [Apple doc] BestForNavigation is "The highest possible accuracy that uses additional sensor data to facilitate navigation apps... Because of the extra power requirements, use this level of accuracy only while the device is plugged in." It is available only if `isAuthorizedForPreciseLocation` is true. — [kCLLocationAccuracyBestForNavigation](https://developer.apple.com/documentation/corelocation/kcllocationaccuracybestfornavigation.md)
- [Apple doc] kCLLocationAccuracyBest is described as very high accuracy for when the navigation level is not needed. — [CLLocationAccuracy](https://developer.apple.com/documentation/corelocation/cllocationaccuracy.md)
- [dev] A Flybuy test reported no significant accuracy difference between the two constants and recommended plain Best. — [Flybuy (T. Judkins)](https://www.flybuy.com/?p=2471)
- [dev, old 2012–2014] Stack Overflow anecdote: BestForNavigation is "a battery eater... but not more than 20%" more than Best (personal experience, no method). — [SO archive](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/6371744/will-the-kcllocationaccuracybestfornavigation-setting-in-core-location-improve)
- [dev, unverified] A third-party static-analysis rule claims both constants engage IMU sensor fusion; not backed by Apple. — [Xygeni detector](https://detectors.xygeni.io/xydocs/quality/detectors/swift/swift.avoid_max_location_accuracy.html)
- [Apple DTS/engineer, Aug 2025] "iOS uses fused data from GPS, WiFi, other sources, and corrects based on data from the motion chip." (said generally, not tied to the accuracy constant) — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)

### Inferences
- Since fusion with the motion coprocessor happens in general (per the 2025 DTS reply), BestForNavigation's "additional sensor data" likely means more aggressive/continuous IMU use and possibly a higher internal update rate, but this is not documented. LifePath's choice (Best at Balanced, BestForNavigation only at Max) matches Apple's power guidance.

### Gaps
- No Apple or independent measurement of update rate, power draw, or error difference between the two constants on iPhone 15 Pro / iOS 17–26 was found.

## 2. Does CLActivityType change the positions themselves?

### Takeaway
Yes. Apple DTS states (2024, 2026) that activityType controls how CoreLocation processes raw data before handing it to the app, including correcting ("road binding") to known roads and paths, and that `.fitness` and the navigation types use corrected coordinates while `.other` (default) is the way to get uncorrected data. Developer reports conflict: snapping has been observed even with `.other` and `.otherNavigation`, and settings from one manager/app can leak into others.

### Cited Findings
- [Apple DTS, Argun Tekant, Nov 2024] "`activityType` determines how CoreLocation will handle raw location data before transferring it to the app." Effects: "correcting the location data to known roads (for navigation, and also fitness), expecting unusual movements (airborne)... If the activity type matches the type of movements, the results will be more accurate. If you require uncorrected data as it comes, the choose default"; it also determines auto-pause / "stationary" decisions. — [Forum thread 768991](https://developer.apple.com/forums/thread/768991)
- [Apple DTS, Argun Tekant, Oct 2024] "CoreLocation will correct received/perceived coordinates to known roads and paths based on the `activityType`. `.fitness` is one of the activity types that will use corrected coordinates. If you want no such corrections, you may want to give `.other` a try." And: "Setting it to `.other` will stop following known paths, but you will also lose any corrections made to the location data that reduces jitter." And: it is "not possible to turn off parts, or to force the locations to one source or the other." On multiple managers: "properties for one will override the properties of the other (biased towards the better settings)." — [Forum thread 765927](https://developer.apple.com/forums/thread/765927)
- [dev, Oct 2024, same thread] OP reported `.other` still snapped to roads in outdoor testing; another developer said "It always used to be that 'fitness' was the one mode that did not snap." — [Forum thread 765927](https://developer.apple.com/forums/thread/765927)
- [Apple DTS, Kevin Elliott, Aug 2026, iOS 26.6.1 test] "It's expected that the coordinates returned by different activity types will vary. Notably, road binding is tied to activity type." Also: "CLLocationUpdate's internal implementation isn't entirely isolated, which means the configuration outside of it can modify it's behavior"; to monitor multiple activity types "you should use CLLocationManager." — [Forum thread 843376](https://developer.apple.com/forums/thread/843376)
- [Apple engineer, Aug 2025] For a boat whose fixes jump to the shore: try `CLActivityType.other`; "The wrong locations jumping to the shore sounds like the system is trying to correct to a 'possible' location at the shore." Sep 2025: Apple is "aware of an issue with locations when boats are just slowly drifting." — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)
- [dev, Oct 2025] Same thread: `.otherNavigation` and `.other` both still produced the shore jumps (FB20796539). — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)
- [dev, Aug 2026] 4x4 off-road tracks still snapped to roads with `.otherNavigation` and `.other`; no Apple answer. — [Forum thread 768991](https://developer.apple.com/forums/thread/768991)
- [dev, 2015, old] Jeffrey Friedl: snap-to-road enabled for every type except Other Navigation (AutomotiveNavigation, Fitness, Other all snapped); kicks in around 20 km/h; once any app on the phone requests a snapping type "all apps get the road-snapped data"; caused one-second speed spikes (e.g. 87 km/h, ~130 km/h on a bicycle). — [regex.info blog](https://regex.info/blog/2015-12-03/2651); [OpenRadar 23737784](https://openradar.appspot.com/23737784)
- [Apple doc] `.automotiveNavigation` is for positioning in a car on a road network. — [CLActivityType](https://developer.apple.com/documentation/corelocation/clactivitytype.md)
- [Apple WWDC23] LiveConfiguration members (default, automotiveNavigation, otherNavigation, fitness, airborne) map to the corresponding CLActivityType to "have the same location experience"; the session gives no accuracy/snapping details. — [WWDC23 session 10180](https://developer.apple.com/videos/play/wwdc2023/10180)
- [Apple doc, 2016 archive] activityType also governs when auto-pause is safe (automotiveNavigation pauses only when the user does not move a significant distance over time). — [Location and Maps Programming Guide (2016)](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html)

### Inferences
- LifePath's foot fixes (`.fitness`) are, per Apple, already corrected toward known paths and de-jittered. Its own Kalman filter therefore runs on map-matched, smoothed data (double filtering), and the map-matching can pull a walk onto a nearby path that was not walked.
- Whether `.otherNavigation` (LifePath's vehicle type, including trains and waterbus) snaps is contradictory: Friedl 2015 said no; DTS 2024 names "navigation" types as corrected; users 2025–2026 still see snapping with it. The waterbus case resembles the 2025 boat-to-shore bug.
- Snapping/settings are shared state: LifePath's 999 m keep-alive manager, any CLLocationUpdate stream, and other apps (e.g. Maps navigation, fitness apps) can change what LifePath receives. Per DTS, the merge is "biased towards the better settings".
- Snapping above ~20 km/h (2015 observation) means speed/course may jump when a fix is re-bound to another road, which would violate the filter's fixed 0.7 m/s Doppler sigma.

### Gaps
- No Apple statement on whether `.airborne` or `.otherNavigation` snap on iOS 26, nor whether trains get rail binding. No measured comparison of error per activityType on modern iOS.

## 3. Does distanceFilter discard intermediate fixes and change GPS duty cycle?

### Takeaway
Apple documents distanceFilter only as a delivery gate measured from the previously delivered location; undelivered fixes are not exposed to the app. Apple's efficiency guidance says larger values let the system turn radios off more often, but a developer test claims it does not reduce GPS use. No Apple statement says intermediate fixes are buffered or made available.

### Cited Findings
- [Apple doc] distanceFilter: "The minimum distance in meters the device must move horizontally before an update event is generated... measures this relative to the previously delivered location. Specify the value kCLDistanceFilterNone to receive notifications for all movements." Default is kCLDistanceFilterNone. — [distanceFilter](https://developer.apple.com/documentation/corelocation/cllocationmanager/distancefilter.md)
- [Apple doc, via search summary; page body could not be fetched] Apple's efficiency article advises setting distanceFilter to the largest value that gives the needed information, saying higher values let the system turn off radio hardware more frequently. — [Accessing the device's location efficiently](https://developer.apple.com/documentation/xcode/accessing-the-device-s-location-efficiently.md)
- [dev] Mizutori: the distance filter sits higher in the stack than the GPS driver, so it does not reduce how often iOS reads the GPS chip and saves no GPS power; also "distanceFilter is not very accurate". Author admits it is not well documented. — [Medium: Tracking highly accurate location in iOS vol 3](https://medium.com/@mizutori/tracking-highly-accurate-location-in-ios-vol-3-7cd827a84e4d)
- [study] University of Alberta thesis: tuning desiredAccuracy and distanceFilter together saved up to 26.91% energy in real apps; notes Apple's brief documentation does not let developers predict energy effects. — [UAlberta ERA thesis](https://era.library.ualberta.ca/items/cff6f4a8-342e-4f79-a4a5-979d0d094107/download/75028129-f125-4b83-ad38-d63bc2cb77b8)
- [Apple doc, 2016 archive] distanceFilter is configured together with desired accuracy as "the distance that must be traveled before reporting a new location". — [Location and Maps Programming Guide (2016)](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html)

### Inferences
- Because the gate is relative to the last *delivered* fix, any fix inside the 10 m / 5 m / 2 m radius never reaches the app: the filter loses those position and Doppler-speed measurements. At walking speed (~1.4 m/s) a 10 m filter means roughly one fix per ~7 s instead of ~1 Hz, i.e. ~85% of measurements dropped; in vehicles the loss is small. The gate also uses the noisy fix, so stationary jitter larger than the filter still passes.
- With desiredAccuracy = Best, GNSS likely stays on regardless of a small distanceFilter (consistent with Mizutori), so the battery saving of 10 m vs none is probably small; the 26.91% saving in the thesis combined accuracy and filter changes. kCLDistanceFilterNone plus in-app thinning before storage would give the Kalman filter all measurements; cost is more delegate wake-ups (CPU), not GNSS time.

### Gaps
- No Apple statement on whether distanceFilter changes the GNSS duty cycle at Best accuracy; no power measurement isolating distanceFilter at Best on a modern iPhone.

## 4. Statistical meaning of horizontalAccuracy, speedAccuracy, courseAccuracy

### Takeaway
An Apple engineer (Jun 2022) defined horizontalAccuracy as a 2-D RMS error, sqrt(σE² + σN²), containing the truth about 63–68% of the time; 1.73x gives ~95%, 2.15x ~99%, "under ideal circumstances". So the per-axis 1-sigma is about hAcc/√2 when errors are isotropic. Apple documents speedAccuracy (m/s) and courseAccuracy (degrees) as uncertainties with negative = invalid, but gives no confidence level; no calibration study of either was found.

### Cited Findings
- [Apple engineer, Jun 2022] "the horizontalAccuracy field should be interpreted as an estimated two-dimensional root mean square error... if sigma_e and sigma_n are the one-dimensional standard deviations of location errors in the east and north directions... horizontalAccuracy for that location will be reported as sqrt(sigma_e^2 + sigma_n^2)." Circle of radius hAcc contains truth ~63.2% (equal E/N errors) to ~68.3% (very unequal); "1.73 * horizontalAccuracy ... roughly 95%"; "2.15 * horizontalAccuracy ... roughly 99%". "Actual error characteristics may vary considerably in practice." Negative values = invalid; 0 is unexpected. — [Forum thread 699996](https://developer.apple.com/forums/thread/699996)
- [dev, contradicted] Earlier community claim that hAcc is a 95–98% radius (Stack Overflow) is contradicted by the Apple engineer above. — [Forum thread 699996](https://developer.apple.com/forums/thread/699996); [SO archive](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/30673627/location-accuracy-defined-ios)
- [dev] Android documents its accuracy as a 68% radius; Apple docs are silent (the forum reply is the only Apple statement). — [logiqx gpx-ideas](https://logiqx.github.io/gpx-ideas/apis/location.html)
- [Apple engineer, Aug 2025] With a GNSS fix unavailable CoreLocation falls back to Wi-Fi/cell; "For WiFi you will see 65 meters or more... no WiFi based location should be 10 meters." — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)
- [Apple doc] speedAccuracy = uncertainty of speed in m/s; courseAccuracy = uncertainty of course in degrees; negative = invalid. Speed and course are filled in once enough data has been gathered. — [CLLocation](https://developer.apple.com/documentation/corelocation/cllocation.md); [speedAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/speedaccuracy.md); [courseAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/courseaccuracy.md); [Getting heading and course information](https://developer.apple.com/documentation/corelocation/getting-heading-and-course-information.md)
- [dev] Example sample shows speedAccuracy 1.0 and courseAccuracy 0.4 (one illustrative value, not a measurement). — [itnext: CLLocationManager all in one](https://itnext.io/swift-ios-cllocationmanager-all-in-one-b786ffd37e4a)

### Inferences
- LifePath treats hAcc as the per-axis 1-sigma; per Apple's definition the per-axis sigma is hAcc/√2 (≈0.71·hAcc), so the filter's measurement variance is ~2x too large *under ideal conditions*. That may be accidentally helpful, because CoreLocation errors are time-correlated and "vary considerably in practice", but it should be a deliberate choice, not a misreading.
- LifePath's 65 m "rough" cutoff lines up with Apple's statement that Wi-Fi fixes report 65 m or more: >65 m is effectively "not GNSS". Exactly-65 m fixes may also be Wi-Fi.
- speedAccuracy and courseAccuracy are delivered per fix but discarded; using them instead of the fixed 0.7 m/s and 3°/10° sigmas would let the filter down-weight bad Doppler/heading automatically (e.g. at low speed, where course is meaningless). Whether they are on the same RMS basis as hAcc is unknown.

### Gaps
- No empirical calibration of iPhone horizontalAccuracy vs ground truth (coverage %) was found, nor any for speedAccuracy/courseAccuracy. Availability versions (commonly cited: speedAccuracy iOS 10, courseAccuracy iOS 13.4) were not verified in this pass.

## 5. Is CoreLocation output already filtered/smoothed internally?

### Takeaway
Yes, per Apple DTS: fixes are fused from GNSS, Wi-Fi, other sources and corrected with motion-chip data, and (activity-type dependent) bound to roads/paths with jitter reduction. An app filter therefore sees time-correlated, pre-smoothed measurements, not independent raw GNSS fixes; the source cannot be forced or turned off.

### Cited Findings
- [Apple engineer, Aug 2025] "iOS uses fused data from GPS, WiFi, other sources, and corrects based on data from the motion chip." "It is not possible to disable WiFi updates." — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)
- [Apple DTS, Oct 2024] "CoreLocation will use fused data from whatever sources it can get... It is not possible to turn off parts, or to force the locations to one source or the other." `.other` loses "corrections made to the location data that reduces jitter." — [Forum thread 765927](https://developer.apple.com/forums/thread/765927)
- [Apple DTS, Nov 2024] activityType governs how CoreLocation handles raw data before delivery. — [Forum thread 768991](https://developer.apple.com/forums/thread/768991)
- [Apple doc] CLLocationSourceInformation (iOS 15+) exposes only `isSimulatedBySoftware` and `isProducedByAccessory`; it does not say GNSS vs Wi-Fi vs fused. — [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation.md)
- [Apple WWDC23] Warns to be careful filtering the liveUpdates sequence by horizontalAccuracy because execution blocks until a match. — [WWDC23 session 10180](https://developer.apple.com/videos/play/wwdc2023/10180)
- [dev] LocoKit/ArcKit (Arc app) still runs its own two-pass pipeline on CoreLocation output: Kalman filter first, then a dynamically sized weighted moving average; reports 30–100 m fix accuracy in urban canyons. — [LocoKit LocationFilteringExamples.md](https://github.com/sobri909/LocoKit/blob/master/LocationFilteringExamples.md)

### Inferences
- A Kalman filter that assumes white measurement noise on already-smoothed fixes will be overconfident (errors are correlated across consecutive fixes). Common remedies: inflate R, or decimate. LifePath's ~2x variance inflation (section 4) partly compensates.
- The speed/course values are probably also fused/smoothed (not raw Doppler), so the "Doppler" sigma is a modelling assumption, not a raw-sensor property.
- `sourceInformation` is only useful to reject simulated/accessory fixes; it cannot classify Wi-Fi vs GNSS (hAcc ≥ 65 m is the practical proxy).

### Gaps
- Apple does not publish the internal filter's time constants or lag; no study measuring CoreLocation fix autocorrelation was found.

## 6. iPhone 15 Pro dual-frequency GNSS; iOS 17–26 changes and new APIs

### Takeaway
The iPhone 15 Pro has "precision dual-frequency GPS" (L1+L5) per Apple's spec sheet, but no published urban/tree-canopy walking test of the 15 Pro was found; iPhone 14 Pro tests showed only ~1–2 m gains. Apple's "Core Location updates" page lists no new APIs after June 2024 (CLServiceSession, auth-free CLLocationUpdate/CLMonitor, diagnostic properties); iOS 26 forum traffic is mostly regressions (visits, heading, underground), with Apple reporting NYC-subway improvements in Jun 2026.

### Cited Findings
- [dev quoting Apple specs] iPhone 15 Pro: "precision dual-frequency GPS" (GPS, GLONASS, Galileo, QZSS, BeiDou, NavIC); standard iPhone 15 lacks dual-frequency. — [dpreview member comment quoting specs](https://www.dpreview.com/members/1177791893/comments)
- [dev] iPhone 14 Pro (L1+L5) vs iPhone 14 in urban walking: ~1–2 m gains, not meaningful for the navigation app tested. — [AppleVis](https://applevis.com/comment/140158); user report "not much better" — [Apple Community 254360629](https://discussions.apple.com/thread/254360629); [MacRumors on 14 Pro dual-frequency](https://www.macrumors.com/2022/09/10/iphone-14-pro-dual-frequency-gps/)
- [study] L5 measurements improved 3D-map-aided positioning in urban canyons (average errors within ~10 m) thanks to better multipath handling. — [NAVIGATION 68(4):727](https://navi.ion.org/content/68/4/727)
- [study, Android, 2022] Smartphone L5 signals were rarely received and carrier phase often missing in Vienna tests. — [TU Wien thesis (Slateff 2022)](https://repositum.tuwien.at/bitstream/20.500.12708/139226/3/Slateff%20Andreas%20-%202022%20-%20Data%20Quality%20and%20Outdoor%20Positioning%20Accuracy%20of%20Recent...pdf)
- [study, old] iPhone 6 static urban accuracy 7–13 m average (PLOS ONE 2019); earlier: iPhone 3G ~10 m, iPhone 4S ~6.5 m. — [Merry & Bettinger 2019](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6638960/)
- [study, Android, 2026] Environment, more than hardware, is the main driver of smartphone positioning error; dense urban and indoor consistently degrade it. — [arXiv 2601.22406](https://arxiv.org/pdf/2601.22406)
- [study, non-phone] Walking with a dedicated GPS logger: median error 0.7 m open, 2.6 m half-open, 5.2 m urban canyon (3.9 m overall). — [JOSIS article](https://josis.org/index.php/josis/article/download/551/215/2067)
- [Apple doc] Core Location updates page (fetched Nov 2026) has only a June 2024 entry: CLLocationUpdate/CLMonitor without explicit authorization, CLServiceSession, and async diagnostic properties on CLLocationUpdate and CLMonitor events. — [Core Location updates](https://developer.apple.com/documentation/updates/corelocation.md)
- [Apple WWDC23/24] CLLocationUpdate.liveUpdates (iOS 17) with `isStationary` auto-pause/resume; CLServiceSession (iOS 18). — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180); [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- [dev + Apple engineer] iOS 26.1 beta underground positioning on NYC subway worse than iOS 18.6.2 (late/missing station updates on an iPhone 15 Pro Max); Apple, Jun 2026: "we have been working with NYC MTA and have made significant performance improvements to location in that transit network." — [Forum thread 802721](https://developer.apple.com/forums/thread/802721)
- [dev] iOS 26 reports: `didVisit` unreliable (Apple staff called it a possible regression); heading returning travel direction while moving; significant-change/region relaunch failures on 26.4.2. — [Thread 807301](https://developer.apple.com/forums/thread/807301); [Thread 826964](https://developer.apple.com/forums/thread/826964); [Core Location forum tag](https://developer.apple.com/forums/tags/core-location?page=2)

### Inferences
- Do not expect L5 to remove urban-canyon multipath on the 15 Pro; realistic walking error in a city remains several metres to tens of metres, worse under dense canopy and between tall glass buildings (Apple engineer named glass high-rises as a reflection cause in thread 797906).
- Underground/tunnel fixes on iOS 26 are produced by CoreLocation even without GNSS (transit-network-specific work, NYC confirmed); these may look plausible but are model-derived, which matters for LifePath's train logic.
- No new iOS 26 accuracy API exists to adopt; the CLLocationUpdate diagnostics (iOS 18) help explain missing updates, not accuracy.

### Gaps
- No iPhone 15 Pro (or 16/17) ground-truth walking study in cities or under trees was found. No Apple WWDC25 Core Location session or iOS 26 API addition was found (search found none; absence not fully confirmed against WWDC25 session list).

## 7. User-side phone settings affecting accuracy

### Takeaway
Wi-Fi switched on (not necessarily connected) helps because Wi-Fi is a fused input and Apple's crowd-sourced hotspot database is used where GNSS is weak; Apple's own pages say Location Services uses cellular, Wi-Fi, GPS and Bluetooth. Precise Location is required for BestForNavigation. Low Power Mode is not listed by Apple as changing location. No Apple statement on accuracy effects of System Services toggles was found.

### Cited Findings
- [Apple support] Location Services uses "information from cellular, Wi-Fi, Global Positioning System (GPS) networks, and Bluetooth to determine your location"; when GPS is obstructed the device uses Wi-Fi or cellular. With Location Services on, the device periodically sends geo-tagged nearby Wi-Fi hotspots and cell towers to Apple's crowd-sourced database. — [About privacy and Location Services](https://support.apple.com/en-us/102515); [HT203033](https://support.apple.com/en-us/HT203033)
- [dev] Phone gets much better locations with Wi-Fi on even without connecting to any network. — [Life360 explainer](https://www.life360.com/blog/ask-a-user-how-does-wi-fi-improve-my-familys-location-accuracy); Apple Maps prompts to turn on Wi-Fi to improve accuracy — [Forum thread 774204](https://developer.apple.com/forums/thread/774204)
- [press] iOS 18.4+: Settings > Privacy & Security > Location Services > System Services > "Improve Location Accuracy" (on by default); turning it off stops contributing data but does not stop using the database. — [9to5Mac Apr 2025](https://9to5mac.com/2025/04/02/ios-iphone-new-location-services-privacy-toggle/)
- [Apple doc] BestForNavigation requires `isAuthorizedForPreciseLocation` (Precise Location on). — [kCLLocationAccuracyBestForNavigation](https://developer.apple.com/documentation/corelocation/kcllocationaccuracybestfornavigation.md)
- [Apple support] Low Power Mode lists brightness, Auto-Lock, 5G, iCloud Photos, downloads, mail fetch, background app refresh; location/GPS is not listed. — [Use Low Power Mode](https://support.apple.com/101604)
- [Apple support] "Limit precise location from mobile networks" (iPhone Air, 16e, 17e; iPad Pro M5 cellular) only affects data available to carriers, not apps' Location Services. Not available on iPhone 15 Pro. — [Apple support 126101](https://support.apple.com/en-au/126101)
- [Apple engineer, Aug 2025] Wi-Fi location cannot be disabled by the app. — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)

### Inferences
- Owner-side checklist: Wi-Fi on (even unconnected), Bluetooth on, Precise Location on for LifePath, Location Services System Services left on. Low Power Mode probably does not throttle GNSS directly but can affect background app refresh.

### Gaps
- No Apple statement on accuracy impact of "Networking & Wireless", "Compass Calibration" or Bluetooth off; no measurement of Low Power Mode on GNSS rate.

## 8. First fixes after startUpdatingLocation; vehicles, trains, Faraday cage

### Takeaway
Apple (2016 guide) warns the first events may be cached and recommends checking timestamps (its sample drops events older than 15 s), since a rough fix can take several seconds. In GNSS-poor places CoreLocation falls back to Wi-Fi/cell (≥65 m). In tunnels/subways iOS can produce transit-network-aware positions without GNSS.

### Cited Findings
- [Apple doc, 2016 archive] "Because the location manager object sometimes returns cached events, it's recommended that you check the timestamp of any location events you receive. (It can take several seconds to obtain a rough location fix...)" Sample discards events older than 15 s. — [Location and Maps Programming Guide (2016)](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/CoreLocation/CoreLocation.html)
- [Apple doc, 2016 archive] CoreLocation also pauses updates "when it can't obtain a location fix" (when pausesLocationUpdatesAutomatically = YES). — same source
- [Apple engineer, Aug 2025] Without a clear GNSS fix, fallback to Wi-Fi/cell with hAcc ≥ 65 m for Wi-Fi. — [Forum thread 797906](https://developer.apple.com/forums/thread/797906)
- [Apple engineer, Jun 2026] NYC subway location improvements done with the MTA (iOS 26.x). — [Forum thread 802721](https://developer.apple.com/forums/thread/802721)
- [Apple doc] Speed/course are only filled in after enough data is gathered (so first fixes often have speed/course invalid). — [Getting heading and course information](https://developer.apple.com/documentation/corelocation/getting-heading-and-course-information.md)

### Inferences
- LifePath should drop fixes whose timestamp predates the start of the session (or older than ~15 s) and not feed the first rough Wi-Fi fixes to the filter; its 65 m "rough" rule already does the latter.
- In trains (metal body, tinted/coated windows) the fix stream is mostly ≥65 m Wi-Fi/cell or model-derived tunnel positions; this supports LifePath's drop to HundredMeters after 3 min of rough fixes, but the 20 s probe may be too short to reacquire GNSS from cold (no source quantifies time-to-fix on iPhone).

### Gaps
- No modern (iOS 17–26) Apple statement or measurement on time-to-first-good-fix, warm vs cold start, or train-carriage attenuation on iPhone was found. The 2016 guide is old; the current doc pages fetched (distanceFilter, accuracy constants) do not contain the cached-event wording.
