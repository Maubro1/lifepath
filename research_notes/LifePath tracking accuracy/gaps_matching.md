# Filling trip gaps and tuning HMM map matching for sparse pedestrian and transit tracks

Scope note: about 24 tool calls. LocoKit2 facts come from reading its source (shallow clone of `main`, last commit 21 Nov 2026). The Newson & Krumm PDF could not be turned into text (binary PDF, no extractor on this machine; the mirror returned nothing), so the paper's own sensitivity numbers are **not verified** here, only as quoted by Valhalla and Open Traffic.

## How do all-day trackers (Arc/LocoKit2, Google Timeline, Gyroscope, Moves, Life Cycle, Overland, OwnTracks) handle trip starts and signal gaps?

### Takeaway
LocoKit2 (the engine behind Arc Timeline) does no route inference. It joins neighbouring timeline items directly when the gap is 15 min or less and inserts an explicit "data gap" item when it is longer. Trip starts are fixed by moving boundary samples between visit and trip ("edge stealing"), not by drawing a line back to the place. No source found shows any consumer tracker inferring a walked route through a gap. Google Timeline's straight lines are a known symptom of missing data, not a designed feature.

### Cited Findings
- LocoKit2 `edgeHealingThreshold = 15 minutes`. When the time gap between an item and its nearest neighbour is ≤ 15 min the two are linked directly (previousItemId/nextItemId). A longer gap gets an explicit data-gap item made of two `LocomotionSample.dataGap` samples at the gap's start and end. The nearest-neighbour search window is 24 h — [LocoKit2 TimelineProcessor+EdgeHealing.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+EdgeHealing.swift); [TimelineProcessor+DataGaps.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+DataGaps.swift)
- A data-gap item is a trip-type item with no coordinates in between. Nothing interpolates or routes across it — [TimelineProcessor+DataGaps.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+DataGaps.swift)
- Trip start and end boundaries ("edge cleansing") work like this: for a Visit–Trip edge, the trip's edge sample and the one after it move into the visit if both lie inside the visit radius. The test uses mean + 2 SD for stationary-classified samples and mean + 1 SD for moving ones. If that fails, the visit's edge sample can move to the trip, but only if the next visit sample is ≤ 2 min away and the trip edge is outside the visit's 1-SD radius. At most 30 samples move per item per pass. Edges are skipped when the items are > 10 min apart or not within "mergeable distance". The code says stationary edge samples are "genuine visit time (correct arrival/departure)" — [TimelineProcessor+EdgeCleansing.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+EdgeCleansing.swift)
- For Trip–Trip edges (mode changes), a boundary sample moves to the neighbouring trip only when its activity type matches that trip and both edge speeds sit on the same side of `maximumModeShiftSpeed` — [same file](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+EdgeCleansing.swift)
- LocoKit2 has an `UndergroundDetector` (BIG-150, dated 2026-05-24). It spots the "GPS fallback to cell-tower triangulation" regime, mostly underground trains, from consecutive invalid-velocity fixes plus a rolling-average hAcc above 500 m, held for a 30 s warm-up. It then reshapes the raw fixes so the Kalman filter follows the movement instead of staying anchored at the origin. Its parameters were calibrated on one Bangkok MRT trip with a Python harness, so this is a single-trip calibration, not a measured accuracy — [UndergroundDetector.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Samplers/UndergroundDetector.swift)
- LocoKit2 learns a per-place `DriftProfile`: the largest and mean drift distance from the place centroid, and mean drift per 45° sector (8 sectors). It uses this to inflate the accuracy of indoor-drift fixes ("drift germinations", described as 14–126 s long with low hAcc of about 15 m) — [DriftProfile.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Models/DriftProfile.swift); [UndergroundDetector.swift comments](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Samplers/UndergroundDetector.swift)
- LocoKit2 recording: the sleep cycle defaults to 30 s (`sleepCycleDuration = 30`). Sleep mode keeps a "coarse 3 km" location manager plus significant-location-change monitoring running as a keep-alive, and wakeups start CoreMotion (accelerometer and steps samplers) — [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
- Google Timeline: straight-line routes between distant points are listed as a symptom of missing location data, usually because Maps had foreground-only location permission. Missed indoor visits are tied to Wi-Fi/Bluetooth scanning being turned off. This is a third-party troubleshooting guide, not Google documentation — [Digitash](https://digitash.com/google/maps/fix-google-maps-timeline-not-working-history-missing/)
- Transit-data convention: in GTFS, a gap in route position data may be drawn as a straight line — [TfNSW open data forum](https://opendataforum.transport.nsw.gov.au/t/public-transport-timetables-for-realtime-v2/5415)

### Inferences
- LocoKit2's file list (Sources/LocoKit2) has no road-network or map-matching module. So Arc's trip line is the filtered sample path, and a missed walk at a trip start is "fixed" only by re-assigning samples, never by adding geometry. LifePath snapping the first fix back to the place along the OSM foot network would go further than Arc does.
- LocoKit2 uses a 2-SD visit radius for stationary samples and a 1-SD radius for moving ones. That is a cheap, proven way to choose which boundary fixes belong to the visit. LifePath could use the same rule to decide whether the first GPS fix is still "at the place".

### Gaps
- No primary documentation found on gap handling for Gyroscope, Moves (defunct), Life Cycle, Overland or OwnTracks. Overland and OwnTracks are raw loggers and, as far as their design suggests, draw nothing between points. That is unverified.
- No Arc Timeline forum post was found on missing trip-start walks. The search returned only unrelated transit forums.
- How LocoKit2's StepsMonitor output is used in timeline processing was not checked.

## Route inference and gap filling between sparse points, including pedometer distance

### Takeaway
The literature reconstructs routes between sparse points with shortest or most-likely paths, history-based route inference (HRIS), and uncertainty-aware variants (InferTra). Bayesian K-best-path inference uses spatio-temporal constraints. **No work was found that uses step count or pedometer distance to choose among candidate outdoor paths.** Step-based distance shows up only in indoor PDR plus map-matching work.

### Cited Findings
- HRIS (Microsoft Research) is aimed at low-sampling-rate trajectories, where consecutive points can be "several minutes or even hours" apart. It derives travel patterns from historical data and feeds them into route inference — [MSR: Reducing Uncertainty of Low-Sampling-Rate Trajectories](https://www.microsoft.com/en-us/research/?p=162006)
- InferTra argues that maximum-likelihood route prediction degrades under high uncertainty. It returns an edge-weighted "uncertain trajectory" instead of one route, and notes that "the most likely region may not necessarily be part of the most likely trajectory" — [arXiv 1603.07641](https://arxiv.org/pdf/1603.07641)
- RICK (KDD 2012) builds popular routes from uncertain trajectories through collective knowledge — [MSR KDD12 PopularRoutes](https://microsoft.com/en-us/research/wp-content/uploads/2016/02/KDD12-PopularRoutes.pdf)
- Bayesian path inference treats the problem as finding the K most probable candidate paths under spatio-temporal (elapsed-time) constraints, using segment frequencies to cope with sparsity — [Bayesian Path Inference Using Sparse GPS Samples With Spatio-Temporal Constraints](https://bvbvf1.bib-bvb.de/vufind/PrimoRecord/cdi_proquest_journals_2700416392)
- Ozdemir (2018, Transportation) uses a hybrid HMM to find the most likely path between matched GPS points instead of assuming the shortest path — [IDEAS/RePEc](https://ideas.repec.org/a/kap/transp/v45y2018i1d10.1007_s11116-016-9734-2.html)
- Pedestrian trajectory reconstruction in a city: map matching first, then reconstruction with InferTra and shortest-path search, with a report on how sampling gaps affect quality — [CEUR-WS Vol-2029 paper15](https://ceur-ws.org/Vol-2029/paper15.pdf)
- Valhalla Meili limits the routing search between two fixes to 5 × the straight-line distance (`max_route_distance_factor = 5`) and 5 × the elapsed time (`max_route_time_factor = 5`). Fixes more than 2000 m apart (`breakage_distance`) are not connected — [Valhalla Meili configuration](https://valhalla.github.io/valhalla/contributing/architecture/meili/configuration/)
- Indoor PDR work combines step-length × heading dead reckoning with map matching (projecting onto passageways, or CRF matching of activity sequences to landmarks) — [ScienceDirect S0263224122016141](https://www.sciencedirect.com/science/article/abs/pii/S0263224122016141); [arXiv 2109.11706](https://arxiv.org/html/2109.11706.pdf)

### Inferences
- For the trip-start gap (known place → first fix, 30 s–3 min, tens to 250 m), the case is better posed than in the literature. Both endpoints are known (the place centroid or exit and the first fix), the time is known (CoreMotion departure date), and the distance is known (pedometer distance in 30 s buckets). Taking the K shortest foot paths on OSM and picking the one whose length best matches the pedometer distance, rejecting any where length / elapsed time exceeds walking pace, is an untested but cheap extension of the K-best-path idea. Stride-length error in pedometer distance (not measured here) sets how well it can tell paths apart. For short gaps the shortest path will usually win anyway.
- Showing the inferred segment differently (dashed or faded) matches InferTra's point that inferred geometry is uncertain, and keeps "measured vs inferred" honest.
- For tunnel or train gaps, the transit route relation between stations already acts as the "inferred path". Counting its length for distance is defensible, and it differs from what Arc does (an explicit gap or a reshaped cell-fallback track).

### Gaps
- No published use of pedometer or step-count distance as a likelihood term for outdoor path choice. No published accuracy for iPhone pedometer distance over 50–250 m walks was found in this pass.

## Sensitivity of Newson–Krumm matching to beta and sigma; recommended values across engines

### Takeaway
LifePath's current values (σ = max(4 m, hAcc), β = 3 m) match the Newson–Krumm-derived defaults Valhalla uses (σz 4.07, β 3). GraphHopper uses σ = 10 m and β = 2, and FMM's CLI defaults are much looser (gps_error 50, radius 300, k 8). Published values come from car traces. No measured pedestrian optimum was found.

### Cited Findings
- Valhalla Meili defaults: `sigma_z` 4.07, `beta` 3 ("empirical"), `search_radius` 50 m, `max_search_radius` 100 m, `interpolation_distance` 10 m (a later fix closer than this is interpolated, not matched), `breakage_distance` 2000 m, `max_route_distance_factor` 5, `max_route_time_factor` 5, `turn_penalty_factor` 0. Each mode node (pedestrian, bicycle, …) can override these, but the docs list no pedestrian-specific defaults — [Valhalla Meili configuration](https://valhalla.github.io/valhalla/contributing/architecture/meili/configuration/). An earlier search snippet said sigma_z defaults to 10. The current official page says 4.07.
- σz = 4.07 traces to Newson & Krumm, who derived it from the median absolute deviation of their dataset. β is the scale of an exponential distribution over |great-circle distance − route distance| between consecutive fixes. Open Traffic "adopted a β of 3 as our default" — [Open Traffic notebook (raw)](https://raw.githubusercontent.com/opentraffic/reporter-quality-testing-rig/master/notebooks/map_matching_part_II.ipynb)
- Open Traffic ran a grid sweep of σz and β over 0.5–10 (20 values each), noise 0–100 m, sampling every 1/5/10/20/30 s, on 200 San Francisco (car) routes, using N&K's distance-based error metric. In the one score row readable at σz = 0.5, β = 0.5, noise 0, the error was 0.0 at 1/5/10 s and about 0.22 at 20 and 30 s. The per-condition optima were not readable — [Open Traffic notebook (raw)](https://raw.githubusercontent.com/opentraffic/reporter-quality-testing-rig/master/notebooks/map_matching_part_II.ipynb)
- GraphHopper source defaults: `measurementErrorSigma = 10.0` m, `transitionProbabilityBeta = 2.0`, `uTurnCost = 40.0`. The candidate search box starts at 2σ (20 m) and grows by 20 m up to 50 times, stopping at the first hit. Intermediate fixes within 2σ of the last kept fix are dropped, but their distance is added to the next kept fix's linear distance. The transition is routed vs linear distance with no time term — [GraphHopper MapMatching.java](https://raw.githubusercontent.com/graphhopper/graphhopper/master/map-matching/src/main/java/com/graphhopper/matching/MapMatching.java). A DeepWiki summary claims σ defaults to 50 m, which conflicts with the source — [DeepWiki](https://deepwiki.com/graphhopper/map-matching/2.2-probability-models)
- FMM (Yang & Gidófalvi 2018) CLI defaults: k = 8 candidates, radius 300, gps_error 50, penalty factor 0, in network units. The repo has a tool for exploring k, radius and gps_error — [FMM paper](https://people.kth.se/%7Ecyang/bib/fmm.pdf); [FMM GitHub](https://github.com/cyang-kth/fmm)
- Barefoot: no authoritative σ/λ guidance. A user with about 250 m noise at one fix per minute tried σ = 200, max distance 700, and got no validated answer — [Barefoot issue #127](https://www.github.com/bmwcarit/barefoot/issues/127)
- The best transition parameter λ depends on measurement noise σ and the mean spacing between samples. The authors suggest cross-validating σ — [Multi-track Map Matching, arXiv 1209.2759](https://arxiv.org/pdf/1209.2759)
- For pedestrian traces, Transitland/Valhalla docs suggest raising the turn penalty (e.g. to 500) to smooth them. One community config uses pedestrian `search_radius` 25 and `turn_penalty_factor` 100 — [Transitland map-matching docs](https://www.transit.land/documentation/routing-platform/map-matching); [community gist](https://gist.github.com/bboure/768019d380ae422b20619e3104d43ace)
- Low sampling is the hard regime. Accuracy "falls down sharply when sampling frequency decreases", and one paper defines low rate as > 120 s — [arXiv 1409.0797](https://arxiv.org/pdf/1409.0797); [arXiv 1603.07376](https://arxiv.org/pdf/1603.07376)

### Inferences
- β is in metres of "detour per step", so it should grow with spacing between fixes. At 5–30 s walking (7–40 m per step), β = 3 m is strict and favours straight-ish paths. That suits the grid streets cars use but penalises real pedestrian detours (crossings, path bends). Following the Multi-track result, scaling β with step distance (e.g. β ≈ 0.1–0.2 × straight distance, floor 3 m) is a reasonable, untested change. LifePath's existing 50 m β for rough fixes already points this way.
- Using σ = max(4 m, hAcc) per fix is stricter and better-motivated than any engine's single σ. Note that iOS hAcc is roughly a 68% radius, not an SD per axis. Thinning at 2σ copies N&K, GraphHopper and Meili (interpolation_distance 10 m). GraphHopper's trick of carrying dropped distance forward into the next transition costs little and keeps distance totals exact.
- Since none of the defaults were tuned on pedestrians, the only trustworthy tuning is a small sweep on LifePath's own recorded walks with known routes. That is a lean, one-off check.

### Gaps
- Newson & Krumm's own figures (route mismatch fraction vs sampling period, β sensitivity) could not be extracted. No measured σ/β optimum for pedestrians or for 5–30 s sampling was found.

## Pedestrian-specific matching (sidewalks, squares, parks, area:highway) and off-network walking

### Takeaway
Pedestrian HMM papers report gains from better initialisation and from handling open-field "HMM breaks". The bigger issue is OSM coverage: OSM sidewalks are accurate but often missing (72% of Street View sidewalk points had no OSM sidewalk in one study). Off-network walking has to be allowed explicitly, not forced onto the nearest way.

### Cited Findings
- An enhanced pedestrian HMM tackles large localisation error at the start and HMM breaks in open-field crossings. It uses a heuristic for initial state probabilities from a short GPS warm-up and reports "significantly higher" accuracy than the state of the art (claimed; dataset-specific) — [ResearchGate 380145567](https://www.researchgate.net/publication/380145567_An_Enhanced_Hidden_Markov_Model_for_Map-Matching_in_Pedestrian_Navigation)
- A practical pedestrian HMM reports > 10% absolute accuracy gain over widely used HMMs and better selection of the first road segment (claimed) — [IEEE 10049007](https://ieeexplore.ieee.org/document/10049007/)
- SaferCross uses HMM sidewalk matching over a set of preceding locations, not one, because pedestrians move slowly — [arXiv 1805.00442](https://arxiv.org/pdf/1805.00442)
- OSM sidewalks (Maryland): high accuracy, few false positives, low completeness. OSM missed sidewalks at 72% of points where Street View showed them — [CDC PCD 2026](https://www.cdc.gov/pcd/issues/2026/26_0255.htm); [AHA abstract P2120](https://www.ahajournals.org/doi/10.1161/cir.151.suppl_1.P2120)
- A crowdsourced pedestrian network built from map-matched trajectories had a median matching deviation of about 5 m — [ResearchGate 264920147](https://www.researchgate.net/publication/264920147_Crowdsourced_Pedestrian_Map_Construction_for_Short-Term_City-Scale_Events)

### Inferences
- Pedestrian areas (`highway=pedestrian` + `area=yes`, `area:highway`, squares, parks without paths) can be handled by adding an "off-network" candidate per fix: the raw fix itself, with emission from hAcc and a fixed penalty. When no way candidate beats it, the line stays raw and is not dragged to a street edge. This is the usual remedy for open-field breaks. Measured gains are not available.
- With incomplete sidewalk data, matching walks to the street centreline (`highway=residential`, etc.) with a foot profile is the expected fallback. Side-of-street error (5–15 m) is then a mapping limit, not a matcher error.

### Gaps
- No measured accuracy found for HMM matching on OSM pedestrian areas, plazas or parks. No engine documents explicit area handling.

## Heading/speed-aware emission or transition terms (Doppler course)

### Takeaway
Heading terms are common in online HMM matchers (e.g. ITSC 2012), but **no source found isolates a measured gain from a heading term**, least of all for pedestrians or sparse sampling.

### Cited Findings
- An ITSC 2012 online HMM builds emission and transition probabilities from GPS position, speed, inferred heading and topology. No accuracy figure isolating heading was reported in the material seen. Its experiments use high-rate vehicle data — [MIT, map_matching_itsc2012](https://web.mit.edu/jaillet/www/general/map_matching_itsc2012-final.pdf)
- Plain Newson–Krumm emission uses only position distance, which is why heading is often proposed as an add-on. A review says HMM's independence assumption ignores the effect of points far apart — [arXiv 1409.0797](https://arxiv.org/pdf/1409.0797)
- Valhalla supports a turn penalty (`turn_penalty_factor`) but has no heading term in its default config — [Valhalla Meili configuration](https://valhalla.github.io/valhalla/contributing/architecture/meili/configuration/)
- GraphHopper's direction handling is limited to a U-turn cost (40) between opposite-direction candidates at the same snap — [GraphHopper MapMatching.java](https://raw.githubusercontent.com/graphhopper/graphhopper/master/map-matching/src/main/java/com/graphhopper/matching/MapMatching.java)

### Inferences
- Doppler course is reliable only above roughly walking-to-jogging speed. At walking pace iOS often reports course −1 or large courseAccuracy. Any heading term should therefore be gated on speed and courseAccuracy, which makes it most useful for bike, car and tram, and least for walking.
- For pedestrians, a U-turn or turn penalty (GraphHopper/Valhalla style) is the cheaper way to stop zig-zag between parallel footways.

### Gaps
- No measured gain from Doppler-heading emission terms was found. No iPhone courseAccuracy data at walking speed was found in this pass.

## Stop/visit position accuracy: how trackers place a visit

### Takeaway
LocoKit2 places a visit at the inverse-variance (1/hAcc²) weighted centroid of its samples, computed on the unit sphere. The radius is a weighted mean ± SD, bounded to 10–150 m. Indoor drift is handled by a learned per-place drift profile, not by snapping to a building. No measured accuracy figure was found.

### Cited Findings
- `weightedCenter()`: weight = 1 / (horizontalAccuracy²), averaged as 3-D unit vectors (lat/lon → x, y, z). A single usable sample is returned as-is — [LocoKit2 LocomotionSample+Array.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Models/LocomotionSample+Array.swift); [CoreLocation+LocoKit.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Extensions/CoreLocation+LocoKit.swift)
- Visit radius: weighted radius (mean, SD) from the centre, mean bounded to 10–150 m (`minRadius` 10, `maxRadius` 150), SD capped at 150. `contains(location, sd:)` tests distance ≤ mean + sd × SD, clamped to 10–150 m — [TimelineItemVisit.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Models/TimelineItem/TimelineItemVisit.swift)
- The code notes that moving samples are kept at 1 SD "so low-hAcc edge samples can't drag the visit centre" — [TimelineProcessor+EdgeCleansing.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/TimelineProcessor+EdgeCleansing.swift)
- Per-place DriftProfile records drift magnitude and direction in 8 × 45° sectors from the place centroid — [DriftProfile.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Models/DriftProfile.swift)

### Inferences
- With 1/hAcc² weighting, a few good fixes taken before entering or after leaving a building dominate a long run of Wi-Fi-biased indoor fixes (65 m hAcc weighs about 1/40 of a 10 m fix). That is the cheapest bias fix. Snapping a visit to the OSM building polygon that holds the weighted centre (or the nearest one within the radius) is a further, offline step. No tracker was found doing it, and no measured accuracy exists.

### Gaps
- No published accuracy (metres) for visit placement by any consumer tracker. No dwell-cluster accuracy study was found in this pass.

## Reducing departure-detection latency cheaply on iOS

### Takeaway
No controlled measurement of iOS region-exit latency exists in what was found. Developer reports range from about 20 s to 3–5 min. Radii ≤ 50–100 m are the most common source of trouble. CLMonitor on iOS 18 has reported reliability regressions. LifePath's pedometer wake plus CoreMotion back-dating is likely already faster than geofence exit. The remaining gap is better closed geometrically (above) than by chasing latency.

### Cited Findings
- iOS reports a crossing only after the device is a minimum distance past the boundary and stays there about 20 s. Typical exit latency is "3 to 5 minutes on average" (developer guide, anecdotal) — [Capawesome](https://capawesome.io/blog/why-are-your-geofences-not-triggering-on-ios/); [Capgo](https://capgo.app/blog/capacitor-geofences-not-triggering-ios/)
- Callbacks can arrive up to about 20 s late (developer anecdote) — [Medium: Seamless Device Location Monitoring](https://medium.com/programming-passion/seamless-device-location-monitoring-in-ios-part-1-96375b31dbb5)
- Exit events may not fire right after leaving — [Radar: limitations of iOS geofencing](https://radar.com/blog/limitations-of-ios-geofencing)
- An Apple Developer Forums reply says regions ≤ 50 m are the most common cause of problems. Other guides recommend ≥ 100–200 m — [Apple Developer Forums 768373](https://developer.apple.com/forums/thread/768373); [Capawesome](https://capawesome.io/blog/why-are-your-geofences-not-triggering-on-ios/)
- CLMonitor on iOS 18: developers report unreliable entry/exit compared with iOS 17. Starting a CLServiceSession reportedly helped one developer (disputed). In the simulator, a move under 500 m never triggered a transition — [Apple Developer Forums 766956](https://developer.apple.com/forums/thread/766956); [Woosmap PR #43](https://github.com/Woosmap/geofencing-core-ios-sdk/pull/43)
- LocoKit2 keeps a coarse 3 km location manager and significant-location-change monitoring running in sleep, with a 30 s sleep cycle, instead of relying on geofences — [LocomotionManager.swift](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)

### Inferences
- LifePath's 200 m+ geofence is at the reliable end. Shrinking it below about 100 m would likely add missed or late exits rather than cut latency. The 15/50-step pedometer wake responds within steps, so the trip-start gap mostly comes from time-to-first-good-fix after GPS turns on, not from detection. Filling that gap from the place to the first fix along the foot network is therefore the higher-yield fix.

### Gaps
- No measured iOS geofence exit-latency distribution, no measured Wi-Fi-change departure trigger (iOS gives apps no public Wi-Fi-change background event), and no measured GPS time-to-first-fix after a cold start from the pedometer wake on iPhone 15 Pro were found.
