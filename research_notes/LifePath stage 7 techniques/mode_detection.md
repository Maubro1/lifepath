# Transport mode detection from GPS + motion sensors (on-device, iOS)

Research status: web search was rate-limited after the first few queries and most PMC/arXiv/GitHub-docs fetches failed (cookie wall, 404, 500). Only items with a URL below were actually read this session. Everything else is under "Unverified background" and in Gaps/Inferences and must be treated as memory, not evidence.

## Which features carry the most information (speed percentiles, accel, stops, heading, accuracy, CoreMotion, pedometer, barometer)

### Takeaway
Speed-distribution features (mean, max, SD, percentiles) are the cheap workhorse and separate walk/bike/motorised well, but speed alone cannot separate bus/car/tram/train (slow walk, congested car and bus overlap). Fusing GPS with accelerometer, or GPS with transit-network context, is what lifts accuracy from ~55-80% to ~90%+.

### Cited Findings
- A practitioner random forest (40 trees) used trip length, mean/max/SD of speed and 25th/50th/75th speed percentiles; ~80% balanced accuracy; acceleration was tried and dropped because it did not improve validation accuracy. Small, imbalanced data; blog post, not peer reviewed. — [Oskarsson blog](https://joeloskarsson.github.io/blog/2019/transport-mode)
- Speed ambiguity: 7 km/h can be a brisk walk, or a car/bus in congestion; car average speed in congestion is as slow as walking (GPS-only studies, via search summary). — [Urbancic et al. and others](https://aile3.ijs.si/dunja/SiKDD2016/Papers/Urbancic_TransportationMode.pdf) (second-hand)
- Roy et al. 2020 (Vancouver / St. John's, 4071 trips, modes bike/walk/bus/car/SkyTrain, SVM-RBF, 37 features at 1-min resolution): GPS features = distance, speed, net displacement, height, relative turning angle (mean, SD, IQR, skewness, kurtosis, max); accelerometer features = vector magnitude, peak count, dominant FFT frequency, signal power. Accuracy 90.9% fused; single source 55.5%-79.4% (accelerometer-only lowest). Caveats: wrist-worn accelerometer, not phone; stops/congestion removed from trips first; user-labelled trips. — [Roy et al., Findings 2020](https://findingspress.org/article/14520.pdf)
- Urbancic et al. (Ljubljana, ~20 h, car 57%/bus 32%/train 11%): accelerometer-only, 5 s windows, 100 Hz, gravity removed, features = mean, variance, skewness, 5th and 95th percentile per axis plus the same on positive and negative parts (60 features), SVMs. Cars ~90% correct, buses 57%, trains 67%; buses mostly confused with cars; one-vs-one pairs all above 0.8 accuracy/F1; car vs train best separated. Small dataset, one city, no trams/metro. — [Urbancic et al. 2016](https://aile3.ijs.si/dunja/SiKDD2016/Papers/Urbancic_TransportationMode.pdf)
- Patent text: users move the phone more on a bus, while phones stay still in a car; also describes an 18-bin speed histogram feature. Patent, weak evidence. — [US 10072932](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10072932)
- Apple CMMotionActivity exposes booleans stationary, walking, running, cycling, automotive, unknown plus confidence (low/medium/high); history queryable for roughly 7 days; needs NSMotionUsageDescription. The fetched page body was empty, so this is recall of Apple's docs, not verified text. — [Apple docs](https://developer.apple.com/documentation/coremotion/cmmotionactivity)

### Inferences
- Use speed percentiles (P50, P85/P95) rather than max (GPS spikes) or mean (dwell dilutes it); source evidence for P85/P95 specifically is thin, but percentile features recur in all cited work and max is outlier-prone.
- CoreMotion automotive/cycling/walking is nearly free (motion coprocessor) and should be the first-pass prior; GPS speed then refines motorised sub-mode.
- Acceleration adds little to GPS speed for walk/bike/motorised (blog finding) but helps phone-in-car vs phone-on-bus style discrimination (Urbancic, patent); at 100 Hz it costs battery, so prefer CoreMotion activity and pedometer cadence over raw accelerometer in LifePath.

### Gaps
- No verified source on barometer, heading-change-rate importance, or pedometer cadence for mode detection.
- No Geolife / MTL Trajet / SHL challenge report was read.
- No feature-importance ranking (P85 vs mean) found.

## GPS degradation as evidence (Faraday effect, tunnels, underground)

### Takeaway
GPS loss is used qualitatively (tunnel entry/exit, underground implies rail), and papers note vehicles and underground shield the receiver; I found no published quantified per-vehicle attenuation or benchmarked fix-loss mode feature.

### Cited Findings
- A patent for a navigation device detects tunnel entry/exit from GPS signal loss and recovery, and combines it with known tunnel/station locations and speed to infer train. — [US 8983766](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8983766)
- Urbancic et al. state phone GPS is often shielded underground, inside stations, and when the user is not near a window in a vehicle, causing loss of positioning. — [Urbancic et al. 2016](https://aile3.ijs.si/dunja/SiKDD2016/Papers/Urbancic_TransportationMode.pdf)
- SubwayPS: no GPS underground; accelerometer + gyroscope positioning along a known subway line given origin and destination reaches "reasonable, not perfect" accuracy. — [Stockx, Hecht, Schoening](https://export.arxiv.org/pdf/1904.01675)
- u-blox vendor case study: dead-reckoning divergence under 30 m after more than 2.5 km without GNSS in rail tunnel tests (vendor, dedicated hardware). — [u-blox](https://content.u-blox.com/sites/default/files/documents/u-blox-case-study-railway-positioning-in-tunnels.pdf)
- A GNSS-independent magnetometer approach reports 95% (98% with averaging filter) accuracy for transport modes and states; details not read. — [DLR](https://elib.dlr.de/216554)

### Inferences
- Rule for LifePath: a gap in fixes (or horizontalAccuracy jumping to hundreds of metres) between two points both near mapped metro/rail entrances, with plausible rail speed implied across the gap, is strong evidence for metro/train; a gap with no station at either end is tunnel/indoor, weaker.
- Treat degraded accuracy as a soft prior for enclosed vehicles, never a hard rule; no source quantifies it.

### Gaps
- No dB attenuation per vehicle type found. No paper found using horizontalAccuracy distribution as a classifier feature.

## Splitting a trip into single-mode segments

### Takeaway
Walk-based segmentation (change points at walking intervals) is the classic approach (Zheng et al., Geolife); I could not retrieve a source this session, so details are from memory.

### Cited Findings
- Roy et al. removed stops and congestion before classifying and used fixed feature windows (3/5/7/10 s). — [Roy et al.](https://findingspress.org/article/14520.pdf)
- LocoKit models the timeline as Visits (stationary) and Paths (movement between visits), with near-real-time stationary/moving detection; its README does not explain how mode changes within a path are found. — [LocoKit README](https://github.com/sobri909/LocoKit)

### Inferences
- Practical on-device recipe: (1) cut at stationary dwell (CoreMotion stationary or low speed beyond ~1-2 min); (2) inside a moving span, cut where CoreMotion/speed says walking for more than ~30-60 s (walking = transfer between modes); (3) classify each piece; (4) merge neighbours with the same mode. Thresholds are my design suggestions, not published values.

### Gaps
- Zheng et al. Geolife segmentation, MTL Trajet, and HMM-smoothing papers not fetched.

## Per-mode-pair accuracy and evidence that closes the gap

### Takeaway
Bus vs car is hardest in every source read; transit-network proximity gives the biggest published gain.

### Cited Findings
- Stenneth et al. 2011: GPS + GIS (bus stops, rail lines, real-time bus locations) reached over 93.5% for car, bus, aboveground train, walk, bike, stationary; +17% over GPS-only, +9% over GPS with GIS models. Only the abstract was seen (via search summary); real-time bus location data is unavailable to a private offline app. — [Stenneth et al. SIGSPATIAL 2011](https://typeset.io/pdf/transportation-mode-detection-using-mobile-phones-and-gis-2o9lv4ngro.pdf)
- Urbancic: bus is the weakest class, mostly mistaken for car (57% recall vs ~90% for car, accelerometer-only). — [Urbancic et al.](https://aile3.ijs.si/dunja/SiKDD2016/Papers/Urbancic_TransportationMode.pdf)
- A PLOS One study found Wi-Fi features improved bus, train and driving detection over GPS alone (search summary only). — [PMC7332005](https://pmc.ncbi.nlm.nih.gov/articles/PMC7332005)
- GPS-heavy methods in one review stayed below 86% accuracy, mainly due to GNSS interference (search summary only). — [ETH collection](https://research-collection.ethz.ch/bitstream/20.500.11850/394810/2/ab1481.pdf)

### Inferences
- For a private offline diary, replace live bus data with static stop/line geometry (e.g. GTFS shapes): dwell at a mapped stop, stop-go pattern at stop spacing, and route-match to a bus/tram line versus road-only geometry is the practical bus-vs-car discriminator. Without it, store bus vs car as a probability and fall back to "motorised".
- Rail-bound modes (tram, metro, train) are best identified by geometry: track matching, smooth speed profile, low heading change rate, station dwell.

### Gaps
- No verified confusion matrices for walk/run/bike, tram vs bus, or boat. Boat: nothing found (inference: water-polygon matching is the strong cue).

## LocoKit: what it does exactly

### Takeaway
LocoKit (Swift, open source) uses a machine-learned, location-specific classifier fed by Core Motion data and filtered location; the exact feature list was not retrievable.

### Cited Findings
- README: ML activity-type detection; `ActivityTypeClassifier` is created for a coordinate (geographically specific); `classify(sample)` returns ranked results; claims to distinguish car, train, bus, motorcycle, airplane, boat plus stationary/walking/running/cycling; pedometer, accelerometer and Core Motion activity recording are on by default and said to improve detection; location is filtered/smoothed (rawLocation vs filteredLocation); recording auto-stops/restarts to save battery. — [LocoKit README](https://github.com/sobri909/LocoKit)

### Inferences
- The model is trained (not reproducible by rules alone). The LifePath rule/HMM approach is the lean analogue: CoreMotion flags + speed percentiles + stationary/moving state + map context.

### Gaps
- Docs/ActivityTypeClassifierExamples.md and LocationFilteringExamples.md returned 404 at the tried URL; actual features unverified. Read the repo source directly.

## Unverified background (memory only; do not cite without checking)
- Google Timeline and Moves use phone-side classes like CMMotionActivity (still, walking, running, bike, in-vehicle); finer bus/train/subway split comes from server-side transit data.
- Geolife work (Zheng 2008-2010): walk-based change-point segmentation; heading change rate, stop rate, velocity change rate with decision trees; roughly 70-85% accuracy over walk/bike/bus/car/train. Heading change and stop rate are the classic bus-vs-car cues.
- SHL challenge 2018-2020 winners used deep nets or gradient boosting on IMU for 8 classes; trained models required.
