# Per-trip "top speed" filter (under / over 64 km/h): soundness, statistic, threshold

Scope: whether "mean of the top 10% of a trip's points by speed" is a sound way to split LifePath trips into slow and fast travel, and what statistic, unit and threshold work best on-device. Labels: **measured** = a source measured it; **inferred** = my reasoning from sources plus the data facts in the brief.

## 1. Which speed features are most robust in the transport-mode detection literature?

### Takeaway
High percentiles of speed (85th–95th) are the usual robust choice. One measured comparison of seven speed metrics found the 95th percentile best. The raw maximum and top-N speeds (Zheng's "top three velocities") are standard features, but a single bad fix can drive them, so papers filter outliers before computing them. I found no study that injects GPS noise and compares max, top-N and percentile features head to head.

### Cited Findings
- **Measured:** Huss et al. 2014 (Int. J. Health Geographics 13:40; the brief's "Brondeel 2015" seems to be a mis-citation, since this is the paper that matches) had 12 commuters walk, cycle or use motorized transport with GPS loggers. They compared **seven speed metrics**. The best result came from the **95th percentile of speed, acceleration and deceleration (kappa 0.73)**. With all motorized modes merged into one class, **kappa rose to 0.95**. Mode was classified reliably **whenever a mode was used for longer than one minute**. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483); [Utrecht University record](https://research-portal.uu.nl/en/publications/using-gps-derived-speed-patterns-for-recognition-of-transport-mod/) (full text blocked by cookies; figures come from the abstract and search snippets, so the kappa for each of the seven metrics, including max, is not shown here)
- Zheng et al. (GeoLife, 2008) cut trajectories into segments and extracted features per segment: mean and variance of velocity, expectation of velocity, and **the top three velocities and accelerations**. Decision trees and similar classifiers were trained on these. The 2010 version added heading change rate, stop rate and velocity change rate. Those three became the stronger "advanced" features. — [Dabiri & Heaslip, arXiv 1804.02386 (summarising Zheng)](https://arxiv.org/pdf/1804.02386); [Zheng et al. 2010, Microsoft Research](https://www.microsoft.com/en-us/research/?p=158113)
- A standard preprocessing step drops points with non-monotonic timestamps, and **"The GPS point whose speed or acceleration exceeds certain threshold is identified as outlier and discarded."** — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- Stenneth et al. 2011 report >93.5% accuracy for car, bus, aboveground train, walk, bike and stationary when GPS is combined with GIS data (real-time bus locations, rail lines, bus stops). That is 17% better than GPS alone. A later review calls this accuracy "impressively high – albeit not uncontested". — [Stenneth et al. (UIC)](https://www.cs.uic.edu/~jalowibd/uploads/ITSC12.pdf); [arXiv 2305.19428](https://arxiv.org/abs/2305.19428v2)
- A telematics patent uses order statistics and a "robust range" (95th minus 5th percentile) instead of max−min. It notes that an extremely high GPS speed can mean a plane or high-speed train, but in the same breath shows that a single bad reading can produce such a value. — [USPTO 9900747](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9900747)
- A 2026 preprint infers mode from **speed alone**, using a Transformer on dense smartphone GPS. This shows the speed profile carries most of the signal. — [arXiv 2603.00340](https://arxiv.org/html/2603.00340v2)

### Inferences
- The 0.73 → 0.95 jump in Huss et al. is directly relevant. Speed separates **human-powered from motorized** very well, and separates motorized modes from each other much less well. The owner's filter puts the line *inside* the motorized group (city car/bus/tram versus highway car/train). That is exactly where speed features are weakest. (inferred)
- "Mean of the top 10%" is a trimmed upper-tail statistic. It sits between max/top-N (fragile) and p90/p95 (robust). With enough points it behaves close to p95. With few points it degrades into top-1 or top-2, which is no more robust than max (see Q2). (inferred)

### Gaps
- I could not read the per-metric kappa table of Huss et al. (cookie and redirect walls), so the measured gap between max and p95 in that study is unknown here.
- I found no controlled study that injects GPS speed noise and compares max, top-N, p85/p95 and mean-of-top-x%.

## 2. Is "mean of the top 10% of points" sensitive to sampling and short trips? Time-weighted or sustained-speed instead?

### Takeaway
Yes, on both counts. With LifePath's mixed distance/time sampling, a point-based top 10% covers a different share of *time* at different speeds. On a 10–30-point trip it shrinks to the top 1–3 points, so a single 1-second spike can decide the class. A **time-based "sustained top speed"** avoids both problems: the highest distance/time average over any ≥30 s window, computed on the RTS-smoothed track, or equivalently a time-weighted p90. It is cheap to compute (one O(n) sliding window).

### Cited Findings
- Classification became reliable once a mode lasted **more than one minute**. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483)
- Measured cycling speeds (Dutch commuters, n=46): **17.6 km/h** conventional bike, **21.0 km/h** pedelec, **28.8 km/h** speed pedelec (averages). — [SWOV fact sheet: Pedelecs](https://www.swov.nl/en/fact/pedelecs-7-how-fast-do-pedelec-and-speed-pedelec-riders-cycle)

### Inferences
- **Sampling bias (inferred, worked through):** below ~36 km/h a point arrives every 10 m, so the points per minute grow with speed (walking 5 km/h ≈ 8 points/min; cycling 20 km/h ≈ 33 points/min). Above that, the rate is fixed at ~60 points/min. In a walk+bike trip the bike points therefore outnumber the walk points far more than its share of time would suggest. In a walk+train trip, the train contributes a lot (1 Hz) or very little (rough fixes with speed −1, which drop out of a Doppler ranking). The "top 10% of points" thus means a different amount of time in each trip. Weighting each point by its duration (time to the next point) removes this.
- **Short-trip fragility (inferred, arithmetic):** for a 20-point bike trip, top 10% = 2 points. One spike at 87 km/h plus a true peak of 25 km/h gives (87+25)/2 = **56 km/h**, just under 64. Two spikes push it over. For a 10-point trip, top 10% = 1 point, which is plain max speed. The measure is only as robust as the despiking in front of it.
- **Sustained window dilutes spikes (inferred, arithmetic):** a 30 s window at 20 km/h containing a single 1 s spike at 87 km/h averages to 20 + (87−20)/30 ≈ **22 km/h**. A real train or motorway stretch holds its speed for minutes, so its 30–60 s sustained value barely drops below its peak. This is why "highest speed held for 30–60 s" fits a slow/fast split better than any point percentile. Computing it as **distance along the smoothed track ÷ elapsed time** also makes it independent of point count, so distance- and time-sampled stretches are treated the same, and the app's end-to-end speed for rough stretches drops in naturally.
- **Window length (inferred):** 30 s matches the existing HMM window and Huss et al.'s ~1 min reliability floor. Stretches shorter than the window should use their whole-stretch average speed, or inherit the class of a neighbouring stretch. They should not get a top-N value.
- **Caveat for rough train stretches (inferred):** if a sprinter leg is covered only by rough fixes and its end-to-end speed spans a station stop, the averaged speed can drop well below the train's real top speed (stop spacing of a few km gives a lot of acceleration and dwell time). Where valid fixes exist they will set the maximum. Where they don't, a Sprinter trip could fall into "slow". A cheap fallback is to let the hidden HMM "train" label force "fast" (the label stays internal; it only feeds the filter).

### Gaps
- No source measured how mean-of-top-x% behaves under distance- versus time-based sampling. The analysis above is arithmetic, not measured.
- No source measured 30 s or 60 s sustained-speed features for mode detection specifically.

## 3. Typical top speeds by mode in NL/Europe: where is the natural gap, and does 64 km/h sit in it?

### Takeaway
The natural, wide gap lies between **human-powered modes (≤ ~45 km/h even for speed pedelecs)** and motorized modes. 64 km/h sits safely above every bicycle class. *Within* motorized travel there is no gap. 64 km/h sits roughly halfway between the 50 km/h urban and 80 km/h rural speed regimes, so it splits **cars and regional buses by road type** and **trams by right-of-way** (city tram slow, RandstadRail-type light rail fast). That matches the owner's wording ("city driving" slow), but the filter is a *speed-regime* filter, not a mode filter, and should be named that way.

### Cited Findings
- **Bicycles (measured):** speed pedelec cruising speed is **32–37 km/h** depending on location, "far below the maximum of 45 km/h". On 50 km/h roads the mean was **31.8 km/h**, on bike paths **28.5 km/h**. — [SWOV](https://www.swov.nl/en/fact/pedelecs-7-how-fast-do-pedelec-and-speed-pedelec-riders-cycle). Average travel speed in NL/BE is **29–37 km/h**. — [ZIV/Mobycon](https://www.ziv-zweirad.de/en/ziv-publishes-first-comparative-study-on-speed-pedelec-usage/). Flanders: mean cruising speed **38.2 km/h (men) / 33.5 km/h (women)**, commuting **95th percentile ≈ 40 km/h**. — [KU Leuven](https://lirias.kuleuven.be/retrieve/660891)
- **Regular pedelec:** assist is capped at 25 km/h. Average ≈ **21 km/h**. — [SWOV](https://www.swov.nl/en/fact/pedelecs-7-how-fast-do-pedelec-and-speed-pedelec-riders-cycle)
- **Tram:** the standard maximum on the HTM (The Hague) tram network is **50 km/h**. Up to **100 km/h** is allowed on the RandstadRail section between Leidschenveen and the metro line E boundary. — [Local regulation (overheid.nl)](https://lokaleregelgeving.overheid.nl/CVDR602799/1); [bgr-2017-515](https://zoek.officielebekendmakingen.nl/bgr-2017-515.pdf). RandstadRail vehicles: maximum line speed **80 km/h**. — [scbist RandstadRail specs](https://scbist.com/scb/foreign-railways/projects/randstadrail/specs.html); [HTM](https://www.htm.nl/en/about-us/our-transport/randstadrail-white/blue-trams)
- **Bus:** a bus registered for **80 km/h** can get RDW approval to drive **100 km/h** (a "T100" coach). Articulated buses do not qualify. — [business.gov.nl Tempo 100](https://business.gov.nl/regulation/tempo-100-approval); [Stb. 2005, 235](https://zoek.officielebekendmakingen.nl/stb-2005-235.pdf)
- **Car:** on most motorways the limit is **100 km/h from 06:00 to 19:00** and up to **130 km/h** outside those hours. Since April 2025 some motorways allow 130 km/h all day. — [Rijkswaterstaat](https://www.rijkswaterstaat.nl/wegen/wetten-regels-en-vergunningen/verkeerswetten/maximumsnelheid); [Rijksoverheid news 2025-04-14](https://www.rijksoverheid.nl/actueel/nieuws/2025/04/14/vanaf-nu-hele-dag-130-kilometer-per-uur-op-aantal-snelwegen). Default urban 50 km/h and rural 80 km/h: [Speed limits in the Netherlands (Wikipedia; listing only, not opened)](https://www.wikipedia.org/wiki/Speed_limits_in_the_Netherlands)
- **Train:** most Dutch lines run at **130–140 km/h**. Some stretches (e.g. Utrecht–Amsterdam, Lelystad–Zwolle) allow **160 km/h** with ERTMS. The Sprinter New Generation tops out at **160 km/h**. The ICNG reaches **200 km/h** (HSL). New double-deckers are specified for 160 km/h. — [NOS](https://nos.nl/l/2227785); [webwoordenboek](https://webwoordenboek.nl/kenniscentrum/hoe-hard-rijden-de-treinen-in-nederland); [NS annual report 2024](https://nsannualreport.nl/annual-report-2024/about-ns/our-trains); [Wikipedia SNG](https://www.wikipedia.com/wiki/NS_SNG)

### Inferences
- **Bikes versus 64 (inferred):** the highest measured bicycle tail (speed pedelec p95 ≈ 40 km/h, assist cap 45) sits ~20 km/h below 64. Bikes only cross 64 through spikes. With despiking or a sustained window, the bike/fast error rate should be close to zero. Long downhills are rare in NL.
- **City tram versus 64 (inferred):** a 50 km/h network gives sustained top speeds of ~45–55 km/h, a ~10 km/h margin. RandstadRail/light-rail sections (80–100 km/h) will read as **fast**. That is correct for a speed filter, but surprising if the user thinks "tram = slow".
- **Bus (inferred):** city buses (50 km/h roads) → slow. Regional buses on 80 km/h roads and T100 coaches on motorways → **fast**. So "bus" is split by route type, as the owner asked.
- **Car (inferred):** urban-only drives → slow, unless an urban arterial with a higher limit or speeding pushes the sustained speed above 64. Any drive that uses an 80 km/h road for ≥30 s → **fast**, even with no motorway. The owner's "city driving vs highway" maps onto "only 50-roads vs any 80+ road", not "motorway or not". A threshold of ~90 km/h would isolate motorway and train from 80-roads, but would also move many Sprinter legs and RandstadRail into "slow". 64 is the better single split.
- **Train (inferred):** nearly all heavy-rail trips sustain >100 km/h for minutes, so they read as fast, except for the rough-fix averaging risk noted in Q2.
- **Natural-gap summary (inferred):** walk (<~7 km/h, running <~20) | bike 15–45 | *gap* | motorized 30–200 with no gap. 64 km/h ≈ 40 mph is a sensible mid-point of the 50/80 regimes and well clear of bikes. Showing it as "64 km/h" (km/h in NL) is more honest than "40 mph".

### Gaps
- I found no source for the top speed of the Amsterdam metro or Rotterdam metro, or for urban 70 km/h arterials in NL.
- I found no measured distribution of *achieved* top speeds of Dutch city drives or city buses (how often they exceed 64 km/h). That would need the app's own data.
- I opened no source for walking speeds. The values above are common knowledge and inferred.

## 4. Per-trip or per-stretch?

### Takeaway
Per-stretch (per travel-mode segment) is better. The literature works per segment or per epoch, not per door-to-door trip. A per-trip value inherits the fastest leg, so the walk to the station is drawn in the "fast" layer and a long cycle ride with a short motorway leg in a friend's car becomes entirely "fast". Use the existing HMM stretch boundaries (not the hidden labels) and give each stretch its own sustained top speed. The map then shows or hides stretches.

### Cited Findings
- Zheng et al. first split a trajectory into segments (at walk points / change points), then extract speed features and classify each segment as an independent instance. — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- Huss et al. classify per time epoch, and reliability depends on a mode lasting more than one minute. — [PMC4320483](https://pmc.ncbi.nlm.nih.gov/articles/PMC4320483)
- Recent work treats change-point detection and segment classification as one joint task. In other words, the unit of analysis is the single-mode segment. — [arXiv 2312.04821](https://arxiv.org/pdf/2312.04821)

### Inferences
- **Per-trip failure cases (inferred):** (a) walk 8 min + train 25 min = one trip (no stop of several minutes in between), so the whole trip, walk included, appears as "fast". (b) Bike to a stop + bus on an 80 km/h road: the bike leg appears as "fast". (c) A long walk with one bad 1-second spike: with only point despiking, the trip could flip.
- **Cheap per-stretch version (inferred):** reuse the existing HMM stretch boundaries. Merge adjacent stretches shorter than ~60 s into a neighbour. Compute the sustained top speed per stretch and draw by that value. The labels stay hidden, and the filter remains a pure speed filter. If a trip-level list is also wanted, a trip is "fast" if any stretch is fast, but the map draws per stretch.

### Gaps
- No source compares per-trip with per-segment speed filtering for map display specifically. This is an application-level judgement.

## 5. Best practice for cleaning GPS speed before taking maxima

### Takeaway
Clean in layers. (1) Drop invalid points (speed < 0) and points with poor horizontal accuracy from the Doppler ranking. (2) Reject physically impossible jumps with an acceleration gate. (3) Remove single-sample spikes with a short median filter. Better still, (4) take the top speed from the RTS-smoothed track over a ≥30 s window, so remaining spikes barely move the result.

### Cited Findings
- Common preprocessing: discard points whose speed or acceleration exceeds a threshold, and points with non-monotonic timestamps. — [arXiv 1804.02386](https://arxiv.org/pdf/1804.02386)
- **Measured:** smartphone Doppler velocity showed **many outliers** in static and shake-table tests (horizontal errors >1 m/s RMS with a common method), caused by irregular receiver-clock behaviour including frequent jumps. Better estimation brought the error below 1 cm/s. — [GPS Solutions 2023 record](https://bvbvf1.bib-bvb.de/vufind/PrimoRecord/cdi_proquest_journals_2795861485)
- **Measured:** velocity accuracy differs a lot between phone models (cm/s versus dm/s in static tests). — [ISPRS Archives 2022](https://isprs-archives.copernicus.org/articles/XLVI-3-W1-2022/89/2022/)
- **Informal, Apple Watch:** speed derived from position differences spikes much more than Doppler speed. A plain accuracy-estimate threshold removed some spikes and missed others. — [Logiqx GPS details](https://logiqx.github.io/gps-details/devices/apple/watches/wingfoil-230722-1407Z)
- Percentile-based "robust" statistics are used instead of extremes, so that single bad readings matter less. — [USPTO 9900747](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9900747)

### Inferences
- **Acceleration gate (inferred):** the brief's bike spike (~20 → 87 km/h in 1 s) means ≈ 18.6 m/s², far beyond any land vehicle in normal use (cars and trains stay well under ~4 m/s²). A gate of roughly 4–5 m/s² between consecutive valid Doppler speeds rejects such spikes and never removes real train or motorway speed, since those build up gradually.
- **Median-of-3/5 (inferred):** this removes isolated 1-sample spikes at almost no cost. At 1 Hz it also flattens nothing real. On a distance-sampled walk, 5 points ≈ 50 m, which is harmless for a top-speed purpose.
- **Accuracy rejection (inferred):** leave fixes with horizontal accuracy > ~50 m out of the Doppler ranking. Their stretches should contribute only through the smoothed-track distance/time, which already happens with the app's end-to-end speed for rough stretches.
- **Order of preference for LifePath (inferred):** sustained (≥30 s) distance/time on the RTS-smoothed track, per stretch, threshold 64 km/h. The acceleration gate plus median filter matter only if a point-based statistic is kept. If the owner's "mean of top 10%" is kept, make it time-weighted (top 10% of moving time, each point weighted by its Δt), apply it after despiking, and use at least 30 s of moving time.
- **Lightweight (inferred):** all of the above runs in one O(n) pass per stretch with a two-pointer window, so it is suitable for on-device computation at import or in the background, and cacheable per stretch.

### Gaps
- I found no published spike rate for iPhone (CoreLocation) Doppler speed under real motion. The GPS Solutions study used Android.
- I found no source that validates specific acceleration-gate values for mode-detection preprocessing. The 4–5 m/s² value is inferred from physics.
