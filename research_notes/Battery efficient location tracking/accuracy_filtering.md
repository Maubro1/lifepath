# Accurate, Clean Phone GPS Tracks: Filtering, Smoothing, Outliers, Stationary Handling, Fusion, Map Matching, Simplification

Context: private iOS 26 app on iPhone 15 Pro, walks drawn within ~8 m of the true path, battery-conscious.

## Kalman filtering for phone GPS (models, horizontalAccuracy as R, process noise, implementations, gains)

### Takeaway
The proven, simplest on-device pattern is LocoKit's 1-D-per-axis "random walk" Kalman filter: measurement variance = horizontalAccuracy², process noise grows as Δt·q² with q ≈ 4 m/s for coordinates, followed by a weighted moving-average smoothing pass. Full constant-velocity / accelerometer-fused filters exist (Mad Location Manager, KalmanKit, transistorsoft) but none of the open-source projects publishes quantitative accuracy gains.

### Cited Findings
- LocoKit's `KalmanFilter` (ported from a Stack Overflow answer) is a scalar filter: on first fix `variance = accuracy²`; on each new fix `variance += Δt · q²`, gain `k = variance / (variance + accuracy²)`, `variance = (1 − k)·variance`, and new value = `old + k·(new − old)`, applied separately to latitude and longitude. Fixes with timestamps not newer than the last are dropped; fixes failing `hasUsableCoordinate` (horizontalAccuracy < 0 or invalid coordinate) are dropped — [LocoKit KalmanFilter.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/KalmanFilter.swift); [KalmanCoordinates.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/KalmanCoordinates.swift); [CLLocationTools.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/Helpers/CLLocationTools.swift)
- LocoKit parameters: `KalmanCoordinates(qMetresPerSecond: 4)`, `KalmanAltitude(qMetresPerSecond: 3)`; `worstAllowedLocationAccuracy = 300` m (Kalman variance reset to this on reset); `maximumSampleAge = 60` s; low-trust fixes get their accuracy inflated by `100 m × (1 − trustFactor)` before entering the filter (a per-location "trust" learned from past data) — [LocoKit ActivityBrain.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/ActivityBrain.swift)
- LocoKit pipeline: pass 1 Kalman filter to remove noise; pass 2 "dynamically sized, weighted moving average" to smooth paths. In a tuk-tuk trip with raw accuracy 30–100 m in an urban canyon, moving/stationary detection was "achieved to an accuracy of 5 to 10 metres" (author's claim, not an independent benchmark) — [LocoKit LocationFilteringExamples.md](https://github.com/sobri909/LocoKit/blob/master/LocationFilteringExamples.md)
- LocoKit weights points by accuracy when averaging: `weight = 1 − horizontalAccuracy / (worstAccuracyInRange + 1)`; stationary-classified samples get 3× weight in weighted centres — [CLLocationTools.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/Helpers/CLLocationTools.swift); [LocomotionSample.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/LocomotionSample.swift)
- Other Swift implementations: a "Kalman Filter for CLLocation" gist using horizontalAccuracy as measurement uncertainty (variance initialised as accuracy²); KalmanKit (SPM, 6-D lat/lon/alt state, tunable sensor and acceleration noise, iOS 14+); HCKalmanFilter (CocoaPods, CLLocation in → smoothed CLLocation out) — [gist](https://gist.github.com/8762152832c5fdbadd323ef03406053f); [KalmanKit](https://github.forks.workers.dev/Stof83/KalmanKit); [HCKalmanFilter](https://cocoapods.org/pods/HCKalmanFilter)
- Go `regnull/kalman` geo filter: process noise expressed as expected distance and speed change per second; each observation carries horizontal accuracy in metres — [pkg.go.dev regnull/kalman](https://pkg.go.dev/github.com/regnull/kalman)
- Mad Location Manager (Android) fuses GPS + accelerometer in a Kalman filter; "acceleration deviation" sets process noise (lower = trust accelerometer more); needs linear acceleration (gravity removed) and orientation (rotation-vector sensor); adds a GeoHash filter that accepts a point only after a GeoHash cell is hit ≥ N times. Claims: reduces route errors, excludes sharp jumps, removes extra distance while stationary — no quantitative figures published — [maddevsio/mad-location-manager](https://github.com/maddevsio/mad-location-manager)
- transistorsoft Background Geolocation `LocationFilter`: `useKalman: true` default with `kalmanProfile` (aggressive / default / conservative); `policy` PassThrough / Adjust (default) / Conservative; burst averaging `rollingWindow 5`, `burstWindow 10 s`, `maxBurstDistance 300 m`; separate odometer Kalman (`odometerUseKalmanFilter: true`) that leaves recorded points unchanged — [transistorsoft LocationFilter docs](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/LocationFilter.html)

### Inferences
- LocoKit's filter has no velocity state, so it lags around corners in proportion to how small q is relative to accuracy. With q = 4 m/s and 1 Hz GPS at 5 m accuracy, after 1 s variance grows by 16 m² vs R = 25 m², so k ≈ 0.4–0.6 — light smoothing that preserves corners at walking speed (~1.4 m/s). A per-activity q (e.g. ~2–4 m/s walking, higher for cycling/vehicle) is a natural extension; no source gives tested per-activity values.
- For an 8 m target with iPhone 15 Pro GPS outdoors (raw ~3–8 m), a light Kalman + accuracy gating is likely sufficient; heavy smoothing risks cutting corners more than it removes noise.

### Gaps
- `villoren/KalmanLocationManager` could not be found in search results; OwnTracks' own filter parameters were not found.
- No source reports measured before/after error (e.g. RMSE vs ground truth) for any of these open-source phone filters.

## Outlier rejection (accuracy thresholds, speed/teleport checks, stale/cached fixes)

### Takeaway
Standard gates: drop horizontalAccuracy < 0, drop fixes older than a few seconds to 60 s, drop accuracy worse than a threshold (100 m for tracking in transistorsoft; 20 m for distance; 300 m hard cap in LocoKit), and drop fixes implying impossible speed (60 m/s default in transistorsoft; 50 m/s in Newson–Krumm).

### Cited Findings
- Negative `horizontalAccuracy` = invalid coordinate; CoreLocation delivers a cached last-known fix at startup, so apps compare `timestamp` age to a cutoff — examples use 5, 10, 15, 60 s; a Home Assistant implementation treats >600 s as invalid and prefers ≤30 s; Chromium rejects negative age (future timestamps) — [search summary of SO/Chromium/HA sources](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/3856582/get-rid-of-cached-data-in-didupdatetolocation); [Chromium CLLocation+OmniboxGeolocation](https://chromium.googlesource.com/chromium/src/+/7452ac6/ios/chrome/browser/geolocation/CLLocation+OmniboxGeolocation.mm); [Home Assistant iOS OneShotLocation](https://git.sudo.is/home-assistant/iOS/src/branch/master/Sources/Shared/Location/CLLocationManager+OneShotLocation.swift)
- Reported case of old locations delivered with refreshed timestamps — so combine timestamp and accuracy/position checks — [SO: old locations with new timestamps](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/8041693/location-manager-giving-old-locations-with-new-timestamps)
- transistorsoft defaults: `trackingAccuracyThreshold 100 m`; `maxImpliedSpeed 60 m/s` (~216 km/h); `odometerAccuracyThreshold` 20 m in property text but 100 in the table (docs inconsistent) — [transistorsoft LocationFilter](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/LocationFilter.html)
- LocoKit: worst allowed accuracy 300 m; max sample age 60 s; rejects non-increasing timestamps — [ActivityBrain.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/ActivityBrain.swift); [KalmanCoordinates.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/KalmanCoordinates.swift)
- Newson–Krumm break conditions (useful as teleport checks): no road within 200 m; route distance minus great-circle distance ≥ 2000 m; implied speed > 50 m/s. They remove points around a break until healed, up to 180 s, else split the trip — [Newson & Krumm 2009 PDF](https://microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf)
- Home Assistant's OwnTracks integration offers `max_gps_accuracy` to drop fixes that can be kilometres off — [HA OwnTracks](https://home-assistant.io/components/device_tracker.owntracks/)
- Mad Location Manager's GeoHash filter rejects isolated jumps by requiring repeated hits in the same cell — [mad-location-manager](https://github.com/maddevsio/mad-location-manager)

### Inferences
- For walking with an 8 m target, a practical gate set: accuracy < 0 → drop; age > ~10 s → drop; accuracy > ~20–25 m → drop from the drawn path (keep for visit detection); implied speed vs previous accepted point > ~7–10 m/s while CoreMotion says walking → drop. Walking-specific speed thresholds are my extrapolation, not sourced.

### Gaps
- No published empirical tuning of age/accuracy thresholds specifically for walking tracks on recent iPhones.

## Stationary handling (drift scribbles, CoreMotion freeze, visit clustering)

### Takeaway
Use motion activity to switch states: when CoreMotion/`CLLocationUpdate.isStationary` says still, stop appending points (or collapse them to an accuracy-weighted centre) and drop to low accuracy; LocoKit sleeps after 180 s stationary with 60 s wakeup checks; transistorsoft uses a stop timer plus a stationary geofence (iOS needs ~200 m to exit).

### Cited Findings
- transistorsoft toggles moving/stationary via `CMMotionActivityManager` on iOS; a `still` activity starts a `stopTimeout` timer; on expiry it enters stationary, creating a `stationaryRadius` geofence; "Even if you configure a stationaryRadius: 25, iOS will still require the device to move ~200 meters"; disabling motion permission increases battery use — [transistorsoft Philosophy of Operation](https://www.github.com/transistorsoft/flutter_background_geolocation/wiki/Philosophy-of-Operation); [GeoConfig](https://transistorsoft.github.io/capacitor-background-geolocation/latest/interfaces/GeoConfig.html)
- LocoKit: `sleepAfterStationaryDuration = 180` s; `sleepCycleDuration = 60` s wakeups that briefly use GPS-level accuracy; desired accuracy in visits capped at `kCLLocationAccuracyHundredMeters`; desired accuracy changes rate-limited (increase every 60 s, decrease every 120 s) — [LocomotionManager.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/LocomotionManager.swift)
- LocoKit moving-state detection: slowest detectable moving speed ~3 km/h outdoors; most indoor movement classified stationary; stationary radius bounded at 65 m ("small enough for slow walking to be detected"); requires 10–60 samples depending on Kalman accuracy and speed — [MovingState.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/MovingState.swift); [ActivityBrain.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/ActivityBrain.swift)
- LocoKit clusters stationary samples into "visits" (indoor points more likely stationary) — [LocationFilteringExamples.md](https://github.com/sobri909/LocoKit/blob/master/LocationFilteringExamples.md)
- iOS 17+ `CLLocationUpdate.liveUpdates(_:)` yields updates with `isStationary`; WWDC23 session 10180 describes automatic pause/resume when stationary — [Apple CLLocationUpdate](https://developer.apple.com/documentation/corelocation/cllocationupdate.md); [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180); a developer reports isStationary flipping true→false right after launch, threshold undocumented — [Apple forum 750531](https://developer.apple.com/forums/thread/750531)
- Mad Location Manager claims to remove extra distance accumulated while stationary — [mad-location-manager](https://github.com/maddevsio/mad-location-manager)

### Inferences
- Simplest scribble fix: while stationary (CoreMotion `stationary` or `isStationary`), don't add points; on resume, start a new segment from the first good fix. Store the stop as one visit point (accuracy-weighted mean).

### Gaps
- Apple's exact `isStationary` threshold/latency is undocumented.

## Wi-Fi/cell-only vs GPS accuracy; when iOS uses GPS for NearestTenMeters vs HundredMeters

### Takeaway
Modern measured data is sparse. Old iPhone data: A-GPS ~8 m, Wi-Fi median 74 m, cell median ~600 m. Wi-Fi/cell positioning cannot meet an 8 m walking target; GPS-tier accuracy (`kCLLocationAccuracyNearestTenMeters` or better) is needed while drawing walks. Apple does not document which radio each tier uses.

### Cited Findings
- 2009 iPhone 3G study (Zandbergen): A-GPS median ~8 m; Wi-Fi median 74 m (n=58); cellular median ~600 m — [Zandbergen TGIS 2009](https://www.scribd.com/document/154262133/Zandbergen-TGIS-2009); [Esri UC abstract](https://proceedings.esri.com/library/userconf/proc09/uc/abstracts/a1870.html)
- 2019 PLOS ONE: iPhone 6 urban, average horizontal accuracy 7–13 m (overall, not Wi-Fi-only) — [PLOS ONE via RePEc](https://econpapers.repec.org/RePEc:plo:pone00:0219890)
- Wi-Fi positioning generally: Place Lab median 15–40 m in calibrated areas; UCSD study median errors consistently > 5 m — [UCSD wifi-lcn11](https://cseweb.ucsd.edu/~snoeren/papers/wifi-lcn11.pdf)
- Community (not Apple) claims: HundredMeters is "mainly wifi and cellTower", NearestTenMeters is the GPS tier — [SO: decoding CLLocationAccuracy](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/3411629/decoding-the-cllocationaccuracy-const-s); Apple's docs list HundredMeters as default for macOS/watchOS/tvOS — [Apple desiredAccuracy](https://developer.apple.com/tutorials/data/documentation/corelocation/cllocationmanager/desiredaccuracy.md)
- Dual-frequency: iPhone 14 Pro and Apple Watch Ultra (2022) support dual-frequency GNSS; single-frequency positions within several metres but struggles in urban canyons; L5 available on ~17 GPS satellites, full coverage targeted 2027 — [ABI Research](https://www.abiresearch.com/market-research/insight/7781281-dual-frequency-gnss-gaining-momentum-in-hi); smartphone L1+L5 with 3D-mapping aiding ~10 m average in urban canyons — [NAVI/ION 2021](https://navi.ion.org/content/68/4/727); [PolyU](https://ira.lib.polyu.edu.hk/handle/10397/92730?mode=full)
- Newson–Krumm HMM matching stays robust to noise up to ~50 m std dev at longer sampling intervals, which suggests coarse fixes can still identify *roads* even when they can't draw a precise *path* — [Newson & Krumm 2009](https://microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf)

### Inferences
- iPhone 15 Pro is in the dual-frequency Pro line (inference from 14 Pro support); open-sky walking accuracy should be a few metres, urban canyons ~10 m+.
- Battery strategy: GPS tier only while CoreMotion says walking; HundredMeters/visit monitoring while stationary (LocoKit pattern).

### Gaps
- No reliable recent (2020+) measured Wi-Fi-only or cell-only accuracy for iPhones, nor Apple documentation of radio selection per accuracy tier. No independent urban-walking benchmark for iPhone 15 Pro.

## Sensor fusion with CoreMotion (PDR) to fill gaps — worth it?

### Takeaway
Smartphone PDR reaches ~1.4–4% of distance walked when step length and heading are calibrated; heading drift (gyro bias, magnetometer) dominates. Over a 100 m gap that's ~2–4 m error, so short gaps can be bridged; longer gaps exceed 8 m. Open-source fusion libraries publish no measured gains.

### Cited Findings
- Calibrated smartphone PDR: step-length error < 2% of distance; 750 m walk mean error 1.83 m, 90th percentile 4.1 m (with anchor calibration) — [sciforum 11302](https://sciforum.net/paper/11302)
- Posture-aware handheld PDR: 1.4–2.0% of distance — [PMC6210328](https://pmc.ncbi.nlm.nih.gov/articles/PMC6210328); 1.79–3.86% — [Springer chapter](https://springerlink.bibliotecabuap.elogim.com/content/pdf/10.1007/978-3-642-45025-9_21.pdf); 2,100 m urban route max error ~40 m (~2%) — [IEEE JSEN via ResearchGate](https://researchgate.net/profile/Hemin-Zhang-2/publication/273392025_A_Handheld_Inertial_Pedestrian_Navigation_System_With_Accurate_Step_Modes_and_Device_Poses_Recognition/links/569ba66008aeeea985a572c8/A-Handheld-Inertial-Pedestrian-Navigation-System-With-Accurate-Step-Modes-and-Device-Poses-Recognition.pdf)
- Heading: mean error 4.72° (pitch-based method); pocket system 80% probability heading error < 4°, drift mainly from gyro bias — [academia.edu](https://www.academia.edu/93413514/An_Indoor_Position_Estimation_Algorithm_Using_Smartphone_IMU_Sensor_Data); [IEEE Access 2019](https://doaj.org/article/2361c5eac88d495780c8c7836fc31c65)
- Mad Location Manager notes accelerometer is precise short-term but integration error accumulates; needs gravity-free acceleration plus orientation — [mad-location-manager](https://github.com/maddevsio/mad-location-manager)
- LocoKit records CMPedometer step frequency (stepHz) as a classifier feature rather than for dead reckoning — [LocomotionSample.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/LocomotionSample.swift)

### Inferences
- A 4° heading error alone gives ~7 m lateral error after 100 m (tan 4° × 100), so PDR gap filling to an 8 m tolerance is good for roughly ≤100 m gaps. Cheaper alternative: just connect the gap with a straight line or a map-matched route between the endpoints.
- Using CoreMotion for *activity gating* (when to turn GPS on/off) delivers most of the battery benefit; full PDR fusion adds complexity with uncertain gain.

### Gaps
- No sourced battery cost for continuous CMPedometer/IMU fusion vs GPS on iPhone 15 Pro; no Apple-specific PDR accuracy study.

## Map matching / street coverage ("which streets have I walked")

### Takeaway
Newson–Krumm HMM (Gaussian emission σ≈4.07 m, exponential transition on |great-circle − route distance|, Viterbi) is the reference algorithm, with Valhalla/Meili and OSRM as open servers. Coverage apps use simpler rules: CityStrides counts an OSM node when any GPS point is within 25 m, and a street is complete at 90% of nodes (100% for ≤10 nodes). A simple on-device approach: buffer the cleaned track and mark OSM nodes/segments inside.

### Cited Findings
- Newson & Krumm: emission p = Gaussian of point-to-road distance, σz estimated by MAD `σ = 1.4826·median|z − x|` = 4.07 m on their data; road candidates beyond 200 m get zero probability; transition p = exponential in |great-circle distance − route distance| with β = median/ln 2; preprocessing removes points within 2σz of the previous kept point (7,531 → 4,605 points); breaks handled by removing points up to 180 s then splitting. Result: perfect match on 80 km 1 Hz drive; only 0.11% route error even at 30 s sampling; robust to noise up to ~50 m std dev at longer sampling periods but more noise-sensitive at 1 s sampling ("frequent, noisy points tend to pull the route rather violently") — [Newson & Krumm 2009](https://microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf)
- Open Traffic/Mapzen adopted σz = 4.07 and β = 3 as defaults; grid search found other optima (e.g. σ 10, β 5.5) depending on noise and sample rate — [Mapzen data-driven map matching](https://mapzen.com/blog/data-driven-map-matching/); [notebook](https://nbviewer.jupyter.org/github/opentraffic/reporter-quality-testing-rig/blob/master/notebooks/map_matching_part_II.ipynb)
- Valhalla `trace_route`/`trace_attributes`: `trace_options.search_radius`, `gps_accuracy`, `breakage_distance`; raise `turn_penalty_factor` (example 500) to smooth pedestrian traces; sample config shows pedestrian search_radius 50, turn_penalty_factor 100, default gps_accuracy 5.0 — [Valhalla API reference](https://valhalla.github.io/valhalla/api/map-matching/api-reference); [Transit.land map matching](https://www.transit.land/documentation/routing-platform/map-matching); [config gist](https://gist.github.com/bboure/768019d380ae422b20619e3104d43ace); pedestrian mismatch issue — [Valhalla discussion 3224](https://github.com/valhalla/valhalla/discussions/3224)
- CityStrides: node counts if a GPS point is within 25 m; street complete at 90% of nodes; streets with ≤10 nodes need 100%; supporter "Hard Mode" requires 100%; 90% chosen to absorb GPS jitter — [CityStrides: what defines a completed street](https://community.citystrides.com/t/what-defines-a-completed-street/17355); [Ground rules](https://community.citystrides.com/t/ground-rules/23528/2)
- Wandrer: tracks partially-traveled ranges per road (e.g. 0–40% traveled → 41–100% untraveled); recommends 1 Hz recording and no smart recording for better matching; chose an activity editor over perfecting matching (bike-lane-beside-road cases) — [Wandrer untraveled roads](https://news.wandrer.earth/2026/01/30/wandrer-untraveled-roads.html); [Wandrer FAQ](https://wandrer.earth/faq); [Activity editor](https://news.wandrer.earth/2025/08/14/activity-editor-is-available.html); matching is algorithmically expensive, free tier used a cheaper method — [DC Rainmaker](https://dcrainmaker.com/2020/12/reviews-wandrer-tracks.html)
- Buffer-and-dissolve coverage (search-and-rescue tool) avoids double counting — [ASRC coverage tool](https://www.archive.asrc.net/ASRC-Operations/2012-08-30-Coverage-Tool-Ferguson.pdf)

### Inferences
- On-device, a CityStrides-style rule (OSM nodes within ~15–25 m of any accepted point, 90% node threshold) is cheap with a spatial index and avoids a full HMM. The 25 m radius is generous relative to an 8 m drawing target; parallel streets < 25 m apart may get false credit.
- For drawing, don't snap the displayed track to roads by default (walkers use paths/parks); use matching only for coverage stats.

### Gaps
- Wandrer's actual distance tolerance is not published. No sourced comparison of OSRM vs Valhalla accuracy for pedestrian traces.

## Track simplification for storage/rendering (Douglas-Peucker, Visvalingam, spacing)

### Takeaway
Douglas-Peucker with a metric tolerance guarantees max deviation and gives the best compression in a GPS trajectory benchmark; Visvalingam yields smoother, less angular shapes but worse compression. Tolerances must be in metres (project coordinates first), not degrees.

### Cited Findings
- tracklib: tolerance is in coordinate units (so not metres for raw lat/lon); Visvalingam output "less angular" than Douglas-Peucker; Visvalingam tolerance means typical max deviation from straight line, not interchangeable with DP's — [tracklib simplification](https://tracklib.readthedocs.io/en/latest/api/algo/simplification.html); [howto](https://tracklib.readthedocs.io/en/latest/howto/SIMP_Simplification.html)
- MDPI study on GPS trajectories: Douglas-Peucker best compression ratio but slower and higher error than TD-TR; Visvalingam worst compression — [MDPI IJGI 12/10/399](https://mdpi.com/2220-9964/12/10/399/xml)
- Douglas-Peucker is error-bounded, fitting when tolerance is set in metres — [MDPI IJGI](https://mdpi.com/2220-9964/12/10/399/xml)
- Newson–Krumm's 2σ (~8 m) minimum-spacing preprocessing cut 1 Hz points by ~39% with no loss in matching accuracy — [Newson & Krumm 2009](https://microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf)

### Inferences
- Store the full filtered points (or simplify with DP at ~1–2 m) and simplify for rendering at ~3–5 m metric tolerance; this stays well inside an 8 m budget and keeps corners because DP retains the farthest-deviating vertex. Visvalingam is preferable only for zoomed-out aesthetic rendering.
- A minimum spacing of ~5–8 m (≈2σ) during recording also removes stationary jitter points cheaply.

### Gaps
- No source gives measured compression ratios at specific metre tolerances for walking tracks.
