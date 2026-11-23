# Per-trip "top speed" filter (under / over 40 km/h): soundness, statistic, threshold

Scope: whether "mean of the top 10% of a trip's points by speed" is a sound way to split LifePath trips at **40 km/h**. The owner's correction says the line is 40 km/h, not 40 mph. The goal is to separate walking and cycling (including e-bikes) from motorised modes (tram, bus, car, train). The notes also cover which statistic, unit and noise handling work best on-device. Labels: **measured** = a source measured it; **inferred** = my reasoning from sources plus the data facts in the brief.

## 1. Which speed features are most robust in the transport-mode detection literature?

### Takeaway
High percentiles of speed (85th–95th) are the usual robust choice. One measured comparison of seven speed metrics found the 95th percentile (together with acceleration and deceleration) best. Speed separates walk / bike / motorised well (kappa 0.73, and 0.95 with the motorised modes merged). The raw maximum and top-N speeds (Zheng's "top three velocities") are standard, but papers filter outliers before computing them. Several sources warn that speed-only thresholds are crude where mode speed ranges overlap. I found no study that injects GPS noise and compares max, top-N and percentile features head to head.

### Cited Findings
- **Measured:** Huss et al. 2014 (Int. J. Health Geographics 13:40; the brief's "Brondeel 2015" seems to be a mis-citation, since this paper matches) had 12 commuters walk, cycle or use motorised transport with GPS. They compared **seven speed metrics**. The best result came from the **95th percentile of speed, acceleration and deceleration (kappa 0.73)**. With all motorised modes merged into one class, **kappa = 0.95**. Mode was classified reliably **when used for longer than one minute**. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483); [Utrecht University record](https://research-portal.uu.nl/en/publications/using-gps-derived-speed-patterns-for-recognition-of-transport-mod/) (full text blocked by cookies; figures from the abstract and snippets; the kappa for each metric, max included, was not visible)
- Zheng et al. (GeoLife, 2008) segment trajectories and extract mean and variance of velocity, expectation of velocity, and **the top three velocities and accelerations** per segment. The 2010 version adds heading change rate, stop rate and velocity change rate. — [Dabiri & Heaslip, arXiv 1804.02386](https://arxiv.org/pdf/1804.02386); [Zheng et al. 2010](https://www.microsoft.com/en-us/research/?p=158113)
- Standard preprocessing drops points with non-monotonic timestamps, and points whose speed or acceleration exceeds a threshold. — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- A review of GPS mode studies: early speed-threshold methods reached about **72–75%** accuracy (small samples). A plain threshold cannot tell a traffic-light slowdown from the traveller's own pace. — [ETRR 2020, s12544-020-00462-2](https://etrr.springeropen.com/articles/10.1186/s12544-020-00462-2)
- Statistics Netherlands (CBS, 2025) notes that GPS-only features separate similar modes poorly, and adds OpenStreetMap features to a rule-based classifier. A 2026 ML follow-up suggests fully automated classification may not be feasible and proposes semi-automated prompts. — [CBS 2025 rule-based](https://www.cbs.nl/-/media/_pdf/2025/34/transport-mode-prediction-rule-based.pdf); [CBS 2026 ML discussion paper](https://www.cbs.nl/-/media/_pdf/2026/05/discussion_paper___transport_mode_prediction_ml.pdf) (from search snippets; I could not extract the PDF text)
- Stenneth et al. 2011: >93.5% accuracy (car, bus, train, walk, bike, stationary) using GPS plus GIS (bus positions, rail lines, stops), 17% better than GPS alone. A later review calls it "not uncontested". — [Stenneth et al.](https://www.cs.uic.edu/~jalowibd/uploads/ITSC12.pdf); [arXiv 2305.19428](https://arxiv.org/abs/2305.19428v2)
- A telematics patent uses order statistics and a "robust range" (95th minus 5th percentile) instead of extremes. — [USPTO 9900747](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9900747)
- An open-source location-timeline app ships bicycle defaults of an **8–25 km/h average and a 35 km/h peak** (to allow for downhills and e-bikes). Anything faster falls through to car. Because the ranges overlap, the app checks bike before car. — [GeoPulse docs](https://tess1o.github.io/geopulse/docs/user-guide/timeline/travel_classification)

### Inferences
- The owner's 40 km/h split targets the human-powered versus motorised boundary. This is the boundary where speed features do best (kappa 0.95 in Huss et al., with motorised merged). Choosing that boundary is right. Speed alone still mislabels the overlap zone: slow city motorised travel and fast e-bikes (see Q3). (inferred)
- "Mean of the top 10%" is a trimmed upper-tail statistic. With many points it behaves like p95. With few points it degrades into top-1 or top-2, which is no more robust than max (Q2). (inferred)

### Gaps
- The per-metric kappa of Huss et al. (max versus p95) could not be read.
- I found no controlled noise-injection comparison of max, top-N, p85/p95 and mean-of-top-x%.
- The CBS thresholds and confusion tables could not be read (no PDF text extraction available).

## 2. Is "mean of the top 10% of points" sensitive to sampling and short trips? Time-weighted or sustained-speed instead?

### Takeaway
Yes, on both counts. With LifePath's mixed distance/time sampling, a point-based top 10% covers a different share of *time* at different speeds. On 10–30-point trips it shrinks to the top 1–3 points, so one spike decides the class. Use a **time-based sustained top speed** on the RTS-smoothed track instead: the highest distance/time average over any **~15 s** window, per stretch. For a 40 km/h line, 15 s is long enough to dilute a 1 s spike below 40 and short enough to catch a car or bus that reaches 50 km/h between traffic lights. A time-weighted p95 of smoothed speed is a near-equivalent. Both are one O(n) pass.

### Cited Findings
- Reliable classification once a mode lasts **>1 minute**. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483)
- Dutch commuter averages: **17.6 km/h** bike, **21.0 km/h** pedelec, **28.8 km/h** speed pedelec. — [SWOV](https://www.swov.nl/en/fact/pedelecs-7-how-fast-do-pedelec-and-speed-pedelec-riders-cycle)

### Inferences
- **Sampling bias (inferred):** below ~36 km/h a point arrives every 10 m, so points per minute grow with speed (walking 5 km/h ≈ 8/min; cycling 20 km/h ≈ 33/min). Above that, the rate is fixed at ~60/min. Trains with rough fixes (speed −1) contribute few or no ranked points. The top 10% of points therefore covers a different amount of time in every trip. Weighting each point by its Δt (time to the next point), or using distance/time windows, removes this.
- **Short-trip fragility (inferred, arithmetic):** a 20-point bike trip gives top 10% = 2 points. One 87 km/h spike plus a true 25 km/h peak averages to **56 km/h**, so this bike trip is classed motorised at a 40 km/h line. For a 10-point trip the value is just max speed. A point-based top-x% is unusable at 40 km/h without despiking.
- **Window length for a 40 km/h line (inferred, arithmetic):**
  - Spike dilution: a 1 s spike of 87 km/h in a cycling window at 20 km/h raises the window mean by 67/n. That gives **≈ 22 km/h at n = 30 s, ≈ 24.5 at 15 s, ≈ 26.7 at 10 s**. Even two spikes in 10 s give ≈ 33 km/h. Windows of 10–15 s keep bikes under 40 even with despiking missed.
  - Capturing short motorised peaks: a city car or bus reaches 45–50 km/h between lights for perhaps 10–20 s. A 30 s window averages that run with its acceleration and braking and can land below 40. A 10–15 s window keeps it above 40. So for this threshold, **~15 s is the better window** (the 30–60 s windows suit a higher threshold such as 64 km/h).
  - The window works on distance along the smoothed track ÷ elapsed time. That makes it independent of point count, and the app's end-to-end speeds for rough train stretches slot in as-is (trains run far above 40, so the rough-stretch averaging risk that mattered at 64 km/h is minor at 40).
- **Stretches shorter than the window (inferred):** use the whole-stretch average speed, or inherit the neighbour's class. Never use a top-N value.

### Gaps
- No source measured how top-x% statistics behave under distance- versus time-based sampling. The above is arithmetic.
- No source measured how long city cars, buses or trams hold their peak speed between stops. The 10–20 s value is an estimate and should be checked against LifePath's own tracks.

## 3. Typical top speeds by mode, and does 40 km/h sit in a natural gap?

### Takeaway
**Partly.** For walking, ordinary bikes and 25 km/h pedelecs (real tops ~30–35 km/h), 40 km/h leaves a sound margin. For motorised travel on 50 km/h roads, trains, regional buses and motorways, top speeds are well above 40. But 40 km/h is **not** in a clean gap on either side. **Speed pedelecs** cruise at 32–38 km/h with a p95 ≈ 40 and a cap of 45, so 40 cuts straight through their distribution. And **short city trips by car, bus or tram can stay under 40**: about 70% of urban road length in NL is now 30 km/h (80% in Amsterdam since Dec 2023), and tram operating speeds are ~20–25 km/h. A speed filter at 40 is fine if it is named "top speed under / over 40 km/h". As a walk-and-bike versus motorised *mode* filter it will misplace slow city motorised trips, and any speed-pedelec rides.

### Cited Findings
- **Bicycles (measured):** speed pedelec cruising speed **32–37 km/h**, "far below the maximum of 45 km/h". Mean on 50 km/h roads **31.8 km/h**, on bike paths **28.5 km/h**. Pedelec (assist cap 25 km/h) average ≈ **21 km/h**; conventional bike ≈ **17.6 km/h**. — [SWOV](https://www.swov.nl/en/fact/pedelecs-7-how-fast-do-pedelec-and-speed-pedelec-riders-cycle). NL/BE speed pedelec average travel speed **29–37 km/h**. — [ZIV/Mobycon](https://www.ziv-zweirad.de/en/ziv-publishes-first-comparative-study-on-speed-pedelec-usage/). Flanders: mean cruising speed **38.2 km/h (men) / 33.5 km/h (women)**; commuting **95th percentile ≈ 40 km/h**. — [KU Leuven](https://lirias.kuleuven.be/retrieve/660891)
- **City speed limits (measured/official):** Amsterdam raised the share of 30 km/h road length inside the built-up area **from 70% to 80% on 8 Dec 2023**. Nationally, about **70% of urban road length** is 30 km/h, varying strongly by municipality. — [Gemeenteblad 2023-226118](https://zoek.officielebekendmakingen.nl/gmb-2023-226118.pdf); [Sweco whitepaper 2024](https://www.sweco.nl/wp-content/uploads/sites/5/2024/01/Whitepaper-In-een-lagere-versnelling.pdf); [NOS](https://nos.nl/l/2522327)
- **Tram:** the standard maximum on the HTM (The Hague) tram network is **50 km/h**. Up to **100 km/h** is allowed on part of RandstadRail. — [Local regulation](https://lokaleregelgeving.overheid.nl/CVDR602799/1); [bgr-2017-515](https://zoek.officielebekendmakingen.nl/bgr-2017-515.pdf). RandstadRail vehicles: **80 km/h**. — [scbist specs](https://scbist.com/scb/foreign-railways/projects/randstadrail/specs.html). Operating speed (including stops) of the Scheveningen–Delft tram line: **19.4 km/h**, with a target of ~25 km/h. — [CVS 2018 paper](https://cvs-congres.nl/e2/site/cvs/custom/site/upload/file/cvs_2018/id_162_ramon_peters_sneller_van_scheveningen_naar_delft_tramlijn.pdf). In GVB's study of a city-wide 30 km/h limit in Amsterdam, travel-time loss for buses was expected to be minimal. — [Kamerstuk bijlage](https://zoek.officielebekendmakingen.nl/blg-1125709.pdf) (from snippet)
- **Bus:** buses are registered for **80 km/h**; with RDW "T100" approval, **100 km/h** on motorways. — [business.gov.nl](https://business.gov.nl/regulation/tempo-100-approval)
- **Car:** motorways **100 km/h 06:00–19:00**, up to **130 km/h** otherwise. Some motorways allow 130 all day since April 2025. — [Rijkswaterstaat](https://www.rijkswaterstaat.nl/wegen/wetten-regels-en-vergunningen/verkeerswetten/maximumsnelheid); [Rijksoverheid 2025-04-14](https://www.rijksoverheid.nl/actueel/nieuws/2025/04/14/vanaf-nu-hele-dag-130-kilometer-per-uur-op-aantal-snelwegen). Urban 50 / rural 80 default: [Wikipedia (listing only)](https://www.wikipedia.org/wiki/Speed_limits_in_the_Netherlands)
- **Train:** most lines **130–140 km/h**, some 160 km/h with ERTMS. SNG Sprinter 160 km/h; ICNG 200 km/h. — [NOS](https://nos.nl/l/2227785); [NS annual report 2024](https://nsannualreport.nl/annual-report-2024/about-ns/our-trains)

### Inferences
- **Lower side (inferred):** walking (<~7 km/h, running <~20), conventional bikes and 25 km/h pedelecs have sustained tops of roughly 25–35 km/h (consistent with GeoPulse's 35 km/h bike peak). 40 km/h leaves a 5–15 km/h margin, provided spikes are removed (Q2, Q5). Fast road cyclists and long descents can exceed 40, but are rare in NL.
- **Speed pedelecs (inferred from measured distributions):** with cruising speeds of 32–38 km/h and a p95 ≈ 40, a sustained-15 s top speed will land on both sides of 40 from ride to ride. **No threshold between 35 and 45 separates speed pedelecs from city motorised traffic.** If the owner rides one, the split is unstable for those rides. Worth one taste/usage question to the owner.
- **Upper side, how often city motorised trips stay under 40 (inferred; no measured frequency found):**
  - **Car:** a trip on any free-flowing 50 km/h arterial (gebiedsontsluitingsweg) or faster road will top 40. Trips that stay inside 30 km/h zones, or move in congestion, will not. Short neighbourhood drives (a few km in a 30 km/h city like Amsterdam) can plausibly stay under 40 for the whole trip.
  - **Tram:** limit 50 km/h, but stops every few hundred metres and an operating speed of ~20 km/h. On long gaps between stops it reaches 40–50 for perhaps 10–20 s; on a short inner-city ride (1–3 stops) it may not. RandstadRail/sneltram sections will always top 40.
  - **City bus:** similar to the tram. Lines on 50 km/h arterials will top 40, inner-city legs in 30 zones or bus lanes with close stops may not. Regional buses (80 km/h) always top 40.
  - **Train/metro:** always above 40 on any leg longer than one stop.
- **Net (inferred):** errors go one way. Slow urban motorised stretches fall into "under 40". Bikes very rarely fall into "over 40" once despiked, apart from speed pedelecs. For the owner's goal this means the "under 40" layer gets some city tram, bus and car trips, while "40 and over" stays nearly clean. Whether that is acceptable is a taste call.
- **Better alternative for the stated goal (inferred):** the goal ("walk/bike vs motorised") is a mode question. The app's internal HMM already labels stretches. Grouping its labels into *human-powered* versus *vehicle*, with the 40 km/h sustained speed only as a tie-breaker or fallback, would place slow city trams, buses and cars correctly without showing the detailed labels. If the filter must stay purely speed-based, name it honestly ("top speed under 40 km/h / 40 km/h and over") so a slow tram ride under 40 does not look like a bug.
- **Threshold choice if speed-only (inferred):** 40 km/h is a reasonable single value. Lower (e.g. 35) moves more speed-pedelec and fast-bike rides into "over" while catching a few more slow city motorised trips. Higher (45) does the reverse. Between 35 and 45 there is no value without overlap, so 40 is a fair middle.

### Gaps
- I found no measured distribution of achieved top speeds of Dutch city car, bus or tram trips (the share of short trips that stay under 40). LifePath's own history (stretches with HMM labels) could measure this directly offline.
- I found no published commercial or average speeds for GVB/RET/HTM buses, apart from the one tram line quoted.
- I opened no source for walking or running speeds; those values are inferred.

## 4. Per-trip or per-stretch?

### Takeaway
Per-stretch, and more so at 40 km/h than at 64. Almost every public-transport trip contains a walk leg, and many contain bike legs. A per-trip top speed inherits the fastest leg, so the walk to the tram stop or station is drawn in the "40 and over" layer. The literature works per segment or per epoch. Reuse the existing HMM stretch boundaries (not their labels) and give each stretch its own sustained top speed.

### Cited Findings
- Zheng et al. segment first (at walk/change points), then classify each segment as an independent instance. — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- Huss et al. classify per time epoch; reliability needs a mode to last >1 min. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483)
- Recent work treats change-point detection and segment classification as one joint task (unit = single-mode segment). — [arXiv 2312.04821](https://arxiv.org/pdf/2312.04821)

### Inferences
- **Per-trip failure cases (inferred):** (a) walk + train in one trip: the walk is shown as "40 and over". (b) Bike to a station + train: the bike leg is shown as "40 and over". (c) A short bike trip with an undespiked spike flips the whole trip.
- **Cheap per-stretch version (inferred):** use the HMM stretch boundaries. Merge stretches shorter than ~60 s into a neighbour (Huss's 1 min floor). Compute the sustained-15 s top speed per stretch and draw by that value. If a trip list also needs a class: a trip is "40 and over" if any stretch is, but the map draws per stretch.

### Gaps
- No source compares per-trip with per-segment filtering for map display; this is an application-level judgement.

## 5. Best practice for cleaning GPS speed before taking maxima

### Takeaway
Clean in layers. (1) Drop invalid points (speed < 0) and points with poor horizontal accuracy from any Doppler ranking. (2) Reject physically impossible jumps with an acceleration gate. (3) Remove single-sample spikes with a median-of-3/5. Better still, (4) take the top speed as distance/time over a ~15 s window on the RTS-smoothed track, so remaining spikes are diluted below the 40 km/h line.

### Cited Findings
- Discard points whose speed or acceleration exceeds a threshold, and points with non-monotonic timestamps. — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- **Measured:** smartphone (Android) Doppler velocity shows **many outliers** (horizontal error >1 m/s RMS with a common method), traced to receiver-clock jumps. Better estimation gives <1 cm/s. — [GPS Solutions 2023](https://bvbvf1.bib-bvb.de/vufind/PrimoRecord/cdi_proquest_journals_2795861485)
- **Measured:** velocity accuracy differs a lot between phone models (cm/s versus dm/s, static). — [ISPRS 2022](https://isprs-archives.copernicus.org/articles/XLVI-3-W1-2022/89/2022/)
- **Informal, Apple Watch:** position-derived speed spikes far more than Doppler speed. An accuracy-estimate threshold alone removed some spikes and missed others. — [Logiqx](https://logiqx.github.io/gps-details/devices/apple/watches/wingfoil-230722-1407Z)

### Inferences
- **Acceleration gate (inferred):** the bike spike in the brief (~20 → 87 km/h in 1 s) means ≈ 18.6 m/s², impossible for any land vehicle in normal use. A gate of ~4–5 m/s² between consecutive valid speeds rejects it and never cuts real motorised acceleration.
- **Median-of-3/5 (inferred):** removes isolated 1-sample spikes almost for free (5 points ≈ 50 m on a walk, 5 s at 1 Hz).
- **Accuracy rejection (inferred):** leave fixes with horizontal accuracy > ~50 m out of the Doppler ranking. Such stretches contribute only through smoothed-track distance/time (the app's existing end-to-end speed).
- **Recommended pipeline for LifePath (inferred):** per HMM stretch (≥60 s), take the sustained top speed = max over 15 s windows of smoothed-track distance ÷ time, and classify against 40 km/h. Use the gate and median only if a point-based statistic is kept. If the owner's "mean of top 10%" is kept, make it time-weighted (top 10% of moving time, each point weighted by its Δt), apply it after despiking, and require ≥30 s of moving time. Optional: let the hidden HMM vehicle/human-powered grouping override speed for stretches whose sustained top speed is close to the line (e.g. 32–45 km/h).
- **Lightweight (inferred):** one O(n) two-pointer pass per stretch, cacheable. Fits on-device background processing.

### Gaps
- I found no published spike rate for iPhone CoreLocation Doppler speed under real motion.
- I found no validated acceleration-gate values for mode-detection preprocessing; 4–5 m/s² is inferred from physics.
