# Transport mode detection, second pass: Geolife rules, SHL, LocoKit source, GPS degradation, speed thresholds

Scope: fills gaps left by mode_detection.md. Items verified this session were read from the PDF/source text (Zheng 2008 and 2008-WWW PDFs, LocoKit raw Swift, Dawarich docs, SHL review, arXiv 2404.15323, arXiv 2007.14329). Items marked "search summary" were only seen in a search snippet. Items marked "unverified" are memory.

## Geolife (Zheng et al.): features, walk-based segmentation, accuracies

### Takeaway
Geolife's recipe is: cut each trip at walk segments (a stop-and-go transfer almost always sits between two modes), classify each segment with a decision tree on traffic-robust features (stop rate, heading change rate, velocity change rate plus top velocities/accelerations), then smooth with transition probabilities. Accuracy was 71-73% on walk/bike/bus/car, rising to ~76-77% with post-processing; speed-only features were the weakest alone. Useful as rules, not as a headline accuracy.

### Cited Findings
- Segmentation (4 steps): (1) flag each point as "possible walk point" if speed < Vt AND acceleration < at; (2) merge segments shorter than a length threshold into the backward neighbour; (3) segments longer than a threshold are "Certain"; runs of consecutive short "Uncertain" segments beyond a count are merged into one non-walk segment; (4) the start and end of every Walk Segment are change points. Rationale: people must stop and go when changing mode, so walk segments bracket mode changes. — [Zheng et al. UbiComp 2008](https://microsoft.com/en-us/research/wp-content/uploads/2016/02/Ubicomp270-yuzheng.pdf)
- Walk-point thresholds: grid searched velocity in [1,3] m/s and acceleration in [0.2,1.0] m/s2 with step 0.2; chose v = 1.8 m/s (6.5 km/h) and a = 0.6 m/s2 as the loose upper bound giving acceptable recall with best precision. Cars stuck in traffic also produce "walk points", hence the Uncertain-segment merge. — [Zheng et al. WWW 2008 (p247)](https://archives.iw3c2.org/www2008/papers/pdf/p247-zhengA.pdf)
- Heading Change Rate (HCR) = number of points whose heading change exceeds Hc, divided by segment distance. Best Hc = 19 degrees (single-feature search). Car/bus follow roads so heading cannot change as freely as a walker or cyclist, regardless of traffic. — [Zheng et al. 2008](https://microsoft.com/en-us/research/wp-content/uploads/2016/02/Ubicomp270-yuzheng.pdf)
- Stop Rate (SR) = points with speed < Vs per unit distance. Best Vs = 3.4 m/s (12.2 km/h). Ordering reported: SR(walk) > SR(bus) > SR(driving). Bus stops more than a car because of bus stops and passengers, besides traffic lights. — same paper
- Velocity Change Rate (VCR): point counts when |v2 - v1| / v1 exceeds Vr, per unit distance. Best Vr = 0.26 (26% change). — same paper
- Feature table explored: Dist, MaxV1..3 (top-3 velocities), MaxA1..3 (top-3 accelerations), AV (average velocity), EV (expected velocity), DV (variance of velocity), HCR, SR, VCR. Feature sets: "Basic" = MaxV1-3, MaxA1-3, AV, EV, DV, Dist; "Enhanced" (best) = HCR, VCR, SR, MaxV1, MaxV2, MaxA1, MaxA2, AV, EV, DV. Adding MaxV3 dropped accuracy (correlated with MaxV1). — same paper
- Single-feature accuracy (by segment AS / by distance AD, no post-processing): SR 0.35/0.561, HCR 0.34/0.561, AV 0.39/0.547, VCR 0.34/0.526, EV 0.40/0.523, Dist 0.30/0.499, MaxV1 0.29/0.257, MaxV2 0.32/0.344, MaxV3 0.33/0.365, DV 0.27/0.357, MaxA1 0.26/0.208. Top velocity and top acceleration were the weakest single features (they depend on traffic). — same paper
- Combined: SR+HCR+VCR 0.532/0.667; Basic 0.562/0.648; Enhanced 0.583/0.728 (AS/AD). Overall 72.8% by distance with change-point + decision tree; "eight percent" gain over earlier features and "four percent" more from graph post-processing (reaching ~76-77%). Classes: walk, bike, bus, car (driving). — same paper
- Earlier journal version (WWW 2008): >71% on 65 users over 10 months (search summary); decision tree outperformed SVM, Bayesian net and CRF; change-point segmentation outperformed uniform 120 s or uniform-length segmentation. — [Zheng et al. WWW 2008](https://archives.iw3c2.org/www2008/papers/pdf/p247-zhengA.pdf), [search summary of journal version](https://scholars.cityu.edu.hk/en/publications/understanding-transportation-modes-based-on-gps-data-for-web-appl/)
- Post-processing: if a segment's max posterior probability exceeds T1 = 0.6 it is accepted (>90% correct above 0.6) and used to revise neighbours; below T2 = 0.36 the inference is wrong >60% of the time. Transition matrix (Table 1): car, bus and bike are followed by walk 95-98% of the time (Car 95.4%, Bus 95.2%, Bike 98.3%). — [Zheng et al. WWW 2008](https://archives.iw3c2.org/www2008/papers/pdf/p247-zhengA.pdf) (row/column reading of the table is from text extraction; treat the Walk-> row as unclear)
- Data: 2 s sampling, 18 cities, 30,000+ km; trajectories cut into trips at gaps > 20 min; change point correct if within 150 m of truth; change-point recall ~0.79, precision only ~0.28 (many spurious change points). — [Zheng et al. 2008](https://microsoft.com/en-us/research/wp-content/uploads/2016/02/Ubicomp270-yuzheng.pdf)

### Inferences
- Directly portable as rules for LifePath: walk-point gate at speed < 1.8 m/s and |accel| < 0.6 m/s2; stop = speed < 3.4 m/s (counts per km); heading change = turns > 19 degrees per km; speed jump > 26% between consecutive fixes per km. All were tuned at 2 s GPS on 4 modes only, so they must be re-tuned for iOS 1 Hz and for tram/metro/train (not in Geolife's labels for these papers).
- Decision order suggestion: tree on SR/HCR/VCR for road modes; rail modes need track geometry (HCR near zero, VCR smooth) which these features also encode: expect low HCR and low VCR for train/metro, but this was not tested in these papers.
- Top-speed features are weak for a reason: congestion makes car and bus top speed vary; use percentiles over the segment (P85/P95) over max, and treat them as a coarse gate rather than the discriminator.

### Gaps
- Exact Vt/at definition for step 1 matches the 1.8 / 0.6 pair per the WWW 2008 parameter search, but segment-length thresholds for steps 2-3 were not read.
- No tram, metro or train class in these Geolife papers; the 2010 TIST "Understanding transportation modes... for web applications" and "Learning transportation mode from raw GPS data" were not retrievable as text (the first fetch returned a wrong PDF).
- The transition-matrix text was garbled by extraction.

## SHL challenge: what works, and how it relates to GPS-only

### Takeaway
SHL 2018-2020 used motion and pressure sensors only; GPS was explicitly excluded. Bus-vs-car and train-vs-subway are the persistent confusions. For location data, a 2024 paper reached ~88-93% on 8 classes from speed/acceleration/movability windows plus an HMM, with the HMM adding ~4.5 points.

### Cited Findings
- SHL 2018-2020 review: challenges used 100 Hz motion and pressure only; GPS was recorded at 1 Hz in the full dataset but not used; the review states it "is not concerned with GPS-based recognition". Walk/run/bike are easier than car/bus/train/subway; bus and car are confused with each other, train and subway are confused with each other; some vehicle windows are mistaken for Still. — [Wang et al., Frontiers 2021](https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2021.713719/full)
- Winners (F1): 2018 93.9% (Gjoreski, ensemble of classical ML and DL, smoothed by an HMM); 2019 78.4% (Janko, two-stage random forest); 2020 88.5% (Zhu, 1D DenseNet CNN). The 2018 winner's HMM smoothing is the relevant lesson for a tiny HMM. Top-10 average F1 about 86.9% (2018), ~66% (2019), 69.5% (2020). — same review (one figure inconsistent within the paper: 2018 appears as 93.4%, 2020 as 88.9% in the conclusion)
- Hardest class by year: 2018 train, then subway, then car; 2019 car, then train, subway; 2020 subway. — same review
- SHL 2021 targeted radio/GPS-reception/location/WiFi/cell scans. A Latvian university news item credits Dmitry Balabka with first place using Google AutoML Tables (single non-academic source). A ConvTransformer entry on location data reported F1 0.6838 on validation. — [TSI news](https://tsi.lv/?p=33981), [AMiner entry](https://aminer.org/pub/6155a17891e011ec64a8a2fe/an-ensemble-of-convtransformer-networks-for-the-sussex-huawei-locomotion-transportation-shl) (search summaries only)
- Location-only paper, 8 classes (still, walk, run, bike, car, bus, train, subway): inputs per one-minute window are speed and acceleration derived from Haversine distance over consecutive fixes, plus mean and SD of speed, mean and SD of speed derivative, and "movability" (net displacement / total path length). Leave-one-subject-out: accuracy 88.1%, F1 86.7% without HMM; accuracy 92.6%, F1 90.8% with HMM. No per-class numbers, no road/rail network features. Subway has the lowest location weight in the fusion (0.19 location vs 0.81 acceleration), i.e. location is least informative underground. — [arXiv 2404.15323](https://arxiv.org/html/2404.15323v1)
- The same paper's introduction says location is cited as helping separate car from bus and train from subway (prior work), while accelerometer-only models confuse those pairs. — [arXiv 2404.15323](https://arxiv.org/html/2404.15323v1)

### Inferences
- The one-minute window with speed mean/SD, acceleration mean/SD and movability is a cheap, implementable feature set; "movability" (straightness) is a good separator for rail (high) vs walking/cycling (lower).
- An HMM/smoothing layer on top of per-window classes is worth ~4-5 F1 points in two independent results (SHL 2018 winner; arXiv 2404.15323).
- Subway/metro being poorly observed by location is consistent with GPS loss underground; on iOS the loss itself (no fixes) is the signal, not speed.

### Gaps
- No 2021-2023 location-only per-class table (car vs bus, train vs subway) retrieved; SHL 2021/2023 summary papers not opened.
- The 2024 paper's datasets are SHL data; its HMM transition design was not read.

## LocoKit: actual inputs and scoring (from source)

### Takeaway
LocoKit's classifier consumes a per-sample feature vector built from filtered locations, CoreMotion activity, pedometer cadence and device-motion acceleration, evaluated against region-specific server-downloaded ML models (100 km x 100 km tiles, with parent-tile fallback). The model data is not on GitHub, so rules cannot be copied; the feature list is the useful part.

### Cited Findings
- ActivityBrainSample exposes: speed (m/s, from filtered locations distance/duration), kmh, course and courseVariance (circular statistic over filtered location bearings), radius (accuracy-weighted spread of locations around centre), altitude, horizontal and vertical accuracy (negative accuracy locations are dropped; worst allowed accuracy used as fallback), stepHz (pedometer cadence, or steps/duration), coreMotionActivityType, xyAcceleration and zAcceleration (userAcceleration in reference frame from device motion samples), timeOfDay, and coordinate (to choose the regional model). Also a movingState (moving/stationary/uncertain) and a Kalman filter on location. — [LocoKit ActivityBrainSample.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Base/ActivityBrainSample.swift)
- Types supported: base = stationary, walking, running, cycling (global, accurate everywhere); extended = car, train, bus, motorcycle, boat, airplane, tram, horseback, scooter, skateboarding, tractor, skiing, inline skating, metro, tuk-tuk, songthaew (regional data required). Core Motion "automotive" is deliberately replaced by the extended types. — [ActivityTypeClassifier.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Timelines/ActivityTypes/ActivityTypeClassifier.swift)
- Scoring: classifier returns ranked results with probability scores; each classifier has completenessScore and accuracyScore; coverage = completeness x accuracy (0-1). The docs advise falling back to generic "transport/automotive/unknown" when the best match is low (example: cycling at 0.001 means "terrible match"), i.e. use a probability floor rather than always naming a mode. Classifier tries parent (coarser-tile) models when its own completeness < 1. — same file and [MLClassifier.swift](https://raw.githubusercontent.com/sobri909/LocoKit/master/LocoKit/Timelines/ActivityTypes/MLClassifier.swift)

### Inferences
- LocoKit confirms the practical sensor set for iOS: CoreMotion activity + pedometer cadence + location speed/course variance/accuracy; none of it needs training on-device if you accept simpler rules.
- Horizontal accuracy is kept as a sample attribute and used to weight locations (radius calculation), not as a mode feature per se in the source I read.
- Copy its "fall back to generic motorised when confidence is low" behaviour.

### Gaps
- The raw model features per bin (how courseVariance, speed etc. are histogrammed) live in MLModel/Cache files not read; the class-conditional distributions are server-side and unavailable.

## GPS degradation inside vehicles (quantified evidence)

### Takeaway
No source gives a clean "smartphone C/N0 drop per vehicle type" number. What exists: ordinary window glass costs ~1-4 dB at GPS L1, metal-coated glazing ~20 dB or more, phones in vehicles track at low and irregular C/N0, and a threshold-based "attenuating environment" detector works from max C/N0 < 30 dB-Hz over 100 s (receiver-specific). iOS exposes neither C/N0 nor satellite counts, so the usable feature is fix gaps and horizontalAccuracy.

### Cited Findings
- Window glass at GPS L1: ~1-4 dB for ordinary architectural glass (Stone 1997); ~20 dB for a double-glazed unit with metallic shielding (Asp 2012); ~24.4 dB at L1 for tinted shopping-mall glass (Kjaergaard 2010). These are building figures quoted in a search summary of GNSS attenuation papers. — [arXiv 2007.14329 context, search summary](https://arxiv.org/pdf/2007.14329)
- In a railway-station booth (tinted glass, metal roof), most satellites had C/N0 15-20 dB-Hz vs. above 20 dB-Hz in an open parking lot; a receiver by a high-speed-train window failed to track satellites on a real journey; the proposed detector flags an "attenuating environment" when the maximum C/N0 over any satellite stays < 30 dB-Hz during a 100 s measurement window after a 100 s start-up (initialisation and thresholds stated to be receiver-model specific). Alternative criteria: average C/N0 below threshold, or number of satellites below threshold. — [Detection of attenuating environments, arXiv 2007.14329 (read, text extracted)](https://arxiv.org/pdf/2007.14329)
- Smartphone (Xiaomi Mi 8) in a car on the dashboard: low and irregular C/N0 with high multipath; processing used a 20 dB-Hz C/N0 mask (search summary). — [Satellite Navigation 2020/2021 articles](https://dx.doi.org/10.1186/s43020-020-00013-z)
- Rail rolling-stock study (UK DfT): vehicle penetration loss 3-28 dB across four carriage types (window seats 3-7 dB; others 6-10 dB worse; metallised/energy-saving glazing adds 20-30 dB). This is for mobile-network frequencies, NOT GNSS; GNSS L1 1575 MHz is in a similar range but no GNSS figure was given. — [UK DfT rolling stock RF attenuation](https://assets.publishing.service.gov.uk/media/618d299cd3bf7f055b29332f/mobile-connectivity-in-rolling-stock-radio-frequency-attenuation-characteristics.pdf) (read from extracted text)
- Mode-feature use: urban/underground shielding named as cause of loss of positioning in Urbancic et al. (already in notes 1). The SHL location-only fusion gives subway the lowest location weight (above). — [arXiv 2404.15323](https://arxiv.org/html/2404.15323v1)

### Inferences
- Magnitudes: ordinary car windscreen ~ a few dB, so cars keep fixes; modern trains/trams with metallised or laminated glass and metal roof can drop 15-28 dB, which brings a phone near its tracking limit; expect degraded accuracy (tens to hundreds of metres, frequent gaps) in rail vehicles not seated at a window. This is an inference from the sources, not a measurement on iPhones.
- Practical feature: fraction of time with fixes missing or horizontalAccuracy > ~50-65 m within a segment, plus gap length; combined with matching to rail geometry. Use as a soft prior (rail-like) with an upper-bound check that speed implied across the gap is plausible.

### Gaps
- No peer-reviewed dB figure for phone inside bus, tram or metro carriage; no study using horizontalAccuracy distribution as a mode feature; iPhone Core Location does not expose C/N0.

## Practical top-speed thresholds and stop-dwell patterns

### Takeaway
There is no validated published per-mode P85/P95 cutoff table. Published rules are coarse: walking up to ~7 km/h, cycling to ~45 km/h, train above ~80 km/h, with heavy overlap among bus/car/tram; Huss et al. found the 95th-percentile speed (with acceleration) was the best speed feature but could only separate "motorised" reliably, not bus/car/train.

### Cited Findings
- Dawarich open-source rules (km/h): stationary 0-1, walking 1-7, running 7-20, cycling 7-45, driving 15-220, bus 10-100, train 30-350 with a "train minimum" of 80, boat 1-80. Acceleration tie-breaks: running vs cycling 0.25 m/s2, cycling vs driving 0.4 m/s2. Segments need >= 60 s and >= 2 points; new segment after a 180 s gap. Self-declared limitations: cycling vs running overlap 7-20; fast highway driving may be labelled train; most buses are labelled driving because stop patterns are unused. — [Dawarich docs](https://dawarich.app/docs/features/transportation-modes/)
- Huss et al. 2014 (GPS speed patterns, adults): used the 95th percentile of speed among several metrics; best agreement from combining it with acceleration and deceleration; modes reliably classified when used for > 1 minute; train/bus/car pooled as one motorised class (kappa 0.95); tram/subway not separated. — [Huss et al. 2014 (search summary)](https://ij-healthgeographics.biomedcentral.com/articles/10.1186/1476-072X-13-40/tables/1)
- Austrian rule-based paper: stops are the only places where mode changes are allowed; stop = speed below 1.6 km/h on first pass, plus second pass treating slow points within 5 m as stops. — [Austriaca paper (search summary)](https://austriaca.at/0xc1aa5576_0x003a2033.pdf)
- Other quoted defaults (search summary): rest period <2 km/h; a slow-point rule of 1.88 m/s with acceleration 0.4 m/s2 (ITSC12 paper). — [ITSC 2012](https://www.cs.uic.edu/~jalowibd/uploads/ITSC12.pdf)
- Stop pattern: Geolife says stop rate SR(walk) > SR(bus) > SR(car); bus stops at bus stops and traffic lights, cars at lights. — [Zheng et al. 2008](https://microsoft.com/en-us/research/wp-content/uploads/2016/02/Ubicomp270-yuzheng.pdf)

### Inferences
- A defensible starting ladder, to calibrate on LifePath's own labelled days: P95 < ~8 km/h walk; ~8-35 km/h with high straightness and low SR bike; P95 > 35 km/h motorised; P95 > ~80 km/h with smooth profile (low VCR, low HCR) train/rail or motorway car (rail geometry decides); bus/tram/metro need stop dwell + route geometry. These are my synthesis from the Dawarich and Geolife numbers, not published rules.
- Dwell durations at stops (bus 20-60 s every 300-500 m; train at stations) were NOT found in a sourced paper this pass; treat as unverified design values.

### Gaps
- No sourced dwell-time statistics at bus/tram/metro stops; no published per-mode P85/P95 table; PMC article for Huss unreadable (cookie wall), so numbers rely on search summary.
- Tram vs bus vs metro on GPS speed alone: nothing sourced; likely only separable by geometry/GTFS.
