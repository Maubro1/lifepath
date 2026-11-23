# Filtering and smoothing smartphone location fixes (position-only input) for LifePath

Scope: what turns CoreLocation fixes (position + horizontalAccuracy + Doppler speed/course, no raw pseudoranges) into the most accurate track, live and offline. "Needs raw GNSS" marks techniques iOS cannot use. Derived numbers I computed myself are labelled "(my calculation)".

## 1. How time-correlated are smartphone position errors, and what does a white-noise Kalman/RTS do with them?

### Takeaway
Smartphone position errors are strongly time-correlated. Measured 1 Hz error series fit AR(2)/AR(3) models whose dominant pole gives correlation times of roughly 25–65 s, on top of a per-trip quasi-static offset of several metres. No trajectory-only smoother can remove that offset. A smoother that assumes white noise grows overconfident, and a synthetic white-noise test overstates how much smoothing helps. Of all the findings, this one most changes how LifePath's CI bar should be read.

### Cited Findings
- 2025 field test (campus in Japan; RTK u-blox ZED-F9R reference; Motorola edge 40 neo dual-frequency and moto g24 single-frequency phones; 1 Hz; ~1250 fixes each). Each phone's error splits into a quasi-static offset **a = [-6.37, 1.00] m** (edge 40 neo) and **[-1.91, 1.99] m** (g24), plus an AR(2) residual. The 1 Hz AR(2) coefficients are: edge 40 neo x φ1=1.183, φ2=-0.195, σ=0.48 m; y φ1=1.246, φ2=-0.262, σ=0.53 m. g24 x φ1=1.491, φ2=-0.508, σ=0.31 m; y φ1=1.405, φ2=-0.414, σ=0.46 m. The authors note "strongly temporally correlated components remain after accounting for the quasi-static offset." — [Kanzaki, Suto, Sato, arXiv 2609.11142, App. A, Table II](https://arxiv.org/pdf/2609.11142)
- Same paper: a KF–RTS smoother that models position, velocity, a constant bias **and** the exact AR(2) residual still performed about the same as no correction, because "the GNSS trajectory likelihood cannot separately identify a sensor-specific quasi-static bias from a constant translation" of the trajectory. Only outside spatial information (radio measurements, in their case) removed the offset. — [arXiv 2609.11142, Sec. VII and App. B](https://arxiv.org/pdf/2609.11142)
- Same paper: to resample a 1 Hz AR model to a sparser interval (they used 20 s), you must match the autocovariances at the new lags. Reusing the 1 Hz coefficients "would not preserve the temporal correlation." — [arXiv 2609.11142, App. A-B](https://arxiv.org/pdf/2609.11142)
- Rutgers/Toyota study, pedestrian traces in Manhattan (Pixel and Nexus 5, 1 Hz): "the GPS error term of successive samples has high autocorrelation", high for the first several lags. Yule–Walker AR(3) fits give φ1 between 1.15 and 1.71 and Σφ ≈ 0.97–0.98, which is nearly a random walk. Environment (7th Ave skyscrapers vs 9th Ave <8-storey buildings) mattered more than phone model or time of day. — [Rutgers VTC paper, Table II, Fig. 1-4](https://www.winlab.rutgers.edu/~gruteser/papers/VTC_camera_ready.pdf)
- EGU25 study (Allan deviation and autocorrelation of smartphone GNSS observations and residuals): the noise is white noise plus a time-correlated part "similar ... to a Gauss–Markov process." — [EGU25-8500](https://meetingorganizer.copernicus.org/EGU25/EGU25-8500.html)
- First-order Gauss–Markov definition: autocorrelation σ²·e^(−β|τ|) with β = 1/τ_corr. τ_corr is read off as the lag where the autocorrelation falls to σ²/e. (The source applies this to smartphone IMU, not GNSS.) — [UniBw München, ION PLANS 2020](https://www.rz.unibw-muenchen.de/lrt9/lrt-9.2/forschung/ion_plans2020_p6.pdf)
- Two standard fixes for time-correlated measurement noise (Bryson & Henrikson 1968): **state augmentation** with a shaping-filter (Gauss–Markov) state, giving filter dimension n+m, and **measurement differencing**, which keeps dimension n and copes with the singular R that pure augmentation produces. — [Bryson & Henrikson report, NASA NTRS](https://ntrs.nasa.gov/api/citations/19670025416/downloads/19670025416.pdf); [ISPRS Annals II-2 2014](https://isprs-annals.copernicus.org/articles/II-2/61/2014/isprsannals-II-2-61-2014.pdf); [MDPI Sensors 2018](https://mdpi.com/1424-8220/18/11/3678)
- A standard KF that ignores time correlation is "suboptimal". The ISPRS simulation, on image-aided INS rather than GNSS, found that a correctly modelled correlated-noise filter beat the Bryson–Henrikson shaping filter by 13.8% N, 16.1% E and 13.9% heading on average errors, and that its stated standard deviations matched the true errors. The mis-modelled filters produced ratios of true RMS error to stated σ that were not 1. — [ISPRS Annals II-2 2014](https://isprs-annals.copernicus.org/articles/II-2/61/2014/isprsannals-II-2-61-2014.pdf)
- Effective-sample-size argument (GPS patent, from the Selective Availability era): a conventional KF given 10 fixes of σ=30 m predicts ≈10 m error, but if the 10 fixes span 10 s of correlated error, "the error variance ... would be optimistic by roughly a factor of ten." A second patent: a KF handles errors well only if their time constant is "on the order of, or less than, the time between consecutive GPS position measurements." — patent results surfaced via search ([US 5416712](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/5416712); [US 6337657](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6337657)). Which patent carries which quote was not verified in the full text.
- Apple's guidance: horizontalAccuracy is roughly a 2-D RMS error. A circle of that radius holds the true position only about 63–68% of the time, so it is not a 95% radius. — Apple developer forums ([thread 768043](https://developer.apple.com/forums/thread/768043) / [thread 699996](https://developer.apple.com/forums/thread/699996); the search summary did not say which thread holds the statement)

### Inferences
- (my calculation) Dominant AR(2) poles from the 2025 table: edge 40 neo x 0.985 (τ≈66 s), y 0.978 (τ≈45 s); g24 x 0.963 (τ≈26 s), y 0.984 (τ≈62 s). The stationary σ of the edge-40-neo x residual comes out ≈3.5 m, so the "slow" part makes up most of the error, and the quasi-static offset (up to 6.4 m) sits on top of it.
- (my calculation) LifePath gets a walking fix about every 7 s. At τ≈45 s, neighbouring fixes still correlate at ρ≈e^(−7/45)≈0.86, so the 10 m distance filter does **not** decorrelate the errors. Averaging N such fixes cuts variance by N_eff≈N(1−ρ)/(1+ρ)≈0.075·N, about 13× fewer independent samples than a white-noise model assumes. The smoother's covariance will be roughly 3–4× too small in σ, and the gate will reject or down-weight the wrong points.
- The CI suite adds white Gaussian noise at hAcc = 1.5 × per-axis σ. That rewards exactly what correlated real errors defeat: averaging across fixes. Passing ≤6 m smoothed on white noise therefore predicts real-world accuracy poorly. The cheapest and highest-value change is to make the synthetic noise a first-order Gauss–Markov (or AR(2)) process with τ≈30–60 s, plus a per-trip constant offset of 0–6 m. Ideally also make "per-axis σ ≈ hAcc/√2" consistent with Apple's description of hAcc as a 2-D RMS. Expect the medians to get worse. Retune the bar against the new noise; don't retune the filter against white noise.
- Bias-state augmentation (2 extra states, GM with τ≈30–60 s) cannot reduce the common-mode offset. It does three things: it keeps the covariance honest, it stops the smoother turning slow error drift into fake velocity (wiggles, false "movement" at stops), and it lets Doppler velocity, whose errors are independent of the position error, separate drift from real motion. These benefits are reasoned, not measured on phone data.
- Measurement differencing is less attractive here. With fixes 7 s apart and irregular, the differencing coefficient changes every step. Augmentation fits the existing CV state vector more simply.

### Gaps
- No published correlation time for **iPhone CoreLocation** output specifically (Apple's output is already filtered and fused, possibly with Wi-Fi). The figures above come from Android/Pixel/Motorola phones.
- No study found that measures the extra error of a white-noise RTS versus a bias-augmented RTS on real smartphone position fixes.

## 2. Does sampling every ~7 s (distanceFilter 10 m) instead of 1 Hz hurt, and how much does Doppler help?

### Takeaway
Because the errors are correlated (Q1), the 6 extra fixes per 7 s that 1 Hz would add carry little independent position information. What LifePath does lose is Doppler velocity between fixes, and Doppler is the observable with the best published gains. Every reported Doppler gain comes from raw-measurement processing, so the size of the effect for CoreLocation speed/course is unmeasured.

### Cited Findings
- Android smartphones (Xiaomi MI8 and others; car-borne and hand-held tests): Doppler-aided positioning improved position by **37.7% E, 37.1% N, 26.6% U** and velocity by **29.6% E, 39.6% N, 29.4% U**. Android Doppler is available more consistently than carrier phase, and the MI8 shows a constant Doppler-vs-code-rate bias. This uses **raw** Doppler. — [Peng et al., J. Navigation 76(2-3), 2023](https://cambridge.org/core/journals/journal-of-navigation/article/characterisation-and-positionaiding-performance-analysis-of-doppler-observation-from-android-smartphones/B5163AAD5F99C885E4ADB5F27DD93B75)
- Hong Kong urban canyon, Huawei P40 Pro at 1 Hz, pedestrian. Adding a constant-velocity factor tightly coupled with Doppler to FGO cut mean error from 14.97 m to 13.13 m (−12.3%) on campus but made it worse in the dense canyon (16.80→17.50 m, +4.2%). Adding PDR relative motion helped much more (see Q5). **Needs raw** pseudorange/Doppler. — [Wen/Hsu group, arXiv 2212.14264, Tables 2–5](https://arxiv.org/pdf/2212.14264)
- Patent statement: the KF does well only when the error time constant is on the order of, or shorter than, the interval between fixes. — [US 6337657 / US 5416712 search results](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6337657)

### Inferences
- With τ≈25–65 s, 1 Hz versus 1/7 Hz fixes should change *position* accuracy only modestly (N_eff barely grows; see Q1). This is reasoned, not measured.
- Doppler velocity accuracy is largely independent of the multipath that biases position, so velocity samples are what pin the trajectory *shape* between correlated position fixes. LifePath gets one speed/course pair per fix (every ~10 m). Ways to recover more of it without the battery cost of 1 Hz: (a) let distanceFilter drop to `kCLDistanceFilterNone` for short bursts in vehicles, where a 10 m filter already gives ≥1 Hz at speeds above 36 km/h, so the cost there is small; (b) on walks, treat the pedometer pace (already used) as the main speed signal. No measured gains exist for either.
- The Peng et al. numbers come from raw-domain processing whose baseline is epoch-wise code positioning. CoreLocation output is already filtered by Apple (an assumption; Apple does not document this), so the remaining Doppler gain is likely much smaller than 37%.

### Gaps
- No study found that compares smoothing accuracy for 1 Hz versus distance-triggered (~0.15 Hz) phone fixes.
- No published accuracy for iOS `speed`/`course` (Doppler-derived) against a reference.

## 3. Per-fix speedAccuracy / courseAccuracy as velocity noise

### Takeaway
iOS reports per-fix speedAccuracy (m/s) and courseAccuracy (degrees ±, invalid if negative). They are the natural velocity R, but I found no published evaluation of how well they are calibrated.

### Cited Findings
- `courseAccuracy`: if ≥0, the course is ± that many degrees (mod 360); a negative value means the course is invalid. A negative `speed` means the speed is invalid. — [Apple CLLocation.courseAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/courseaccuracy.md); [Apple CLLocation.speed](https://developer.apple.com/documentation/corelocation/cllocation/speed.md); [Apple CLLocation.speedAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/speedaccuracy.md)
- Apple's initializer docs swap the descriptions of the course and speed accuracy parameters (a copy-paste error), so use the property pages. — [Apple CLLocation init doc](https://developer.apple.com/documentation/corelocation/cllocation/init(coordinate:altitude:horizontalaccuracy:verticalaccuracy:course:courseaccuracy:speed:speedaccuracy:timestamp:).md)
- Developer forum advice: check speedAccuracy together with speed, because the true speed can change many times between deliveries. — [Apple forums thread 111052](https://developer.apple.com/forums/thread/111052)

### Inferences
- Suggested, unmeasured design: σ_speed = max(speedAccuracy, floor) with a floor of about 0.3–0.5 m/s, and σ_cross-track = speed × courseAccuracy (in radians), with courseAccuracy floored at about 3°. Fall back to the current fixed 0.7 m/s and 3°/10° when a value is negative. Log both fields and the reference residuals on real trips to check calibration. That needs no ground truth beyond the RTS output on clean stretches, and it would settle whether Apple's values are honest before relying on them.
- Treat Doppler velocity as a measurement independent of the position noise (no shared correlated state). That is the assumption under which it helps against correlated position errors (Q1).

### Gaps
- No quantitative evidence found, for iOS or Android position-domain processing, on whether per-fix speed/course accuracy beats fixed values.

## 4. Better offline smoothers: IMM-RTS, Student-t / VB, factor graphs with robust kernels, turn-rate models

### Takeaway
On phone data, the biggest measured gains come from adding information: PDR relative motion, Doppler, and outside spatial constraints. Changing the smoother family on the same position fixes has produced little or no measured gain. IMM smoothers performed about the same as a single CV smoother in a survey comparison. Robust Student-t/skew-t smoothers are proven in pseudorange-domain GNSS tests at 5–10× KF cost, with no phone-position-domain numbers. LifePath's robust RTS (spike removal and consistency weighting) already covers most of what robust kernels deliver.

### Cited Findings
- Survey of manoeuvring-target methods: in simulation, an IMM fixed-interval smoother "performed similarly overall" to a single constant-velocity smoother but showed larger error spikes at manoeuvre onsets. — [Survey of Manoeuvring Target Tracking Methods, arXiv 1503.07828](https://arxiv.org/pdf/1503.07828)
- The RTS smoother is optimal only for linear models with white Gaussian noise and does not handle abrupt changes. That is the usual reason for switching-model smoothers. An "enhanced fixed-interval smoother" for Markov switching systems did slightly better than the two-filter IMM smoother in simulation (no RTS baseline number given). — [Fusion 2021, White Rose eprint](https://eprints.whiterose.ac.uk/177589/1/Fusion%202021-Enhanced%20Fixed-Interval%20Smoothing.pdf)
- Skew-t VB filter/smoother (Nurminen, Ardeshiri, Piché, Gustafsson): beats the earlier skew-t VB filter in GNSS **pseudorange** tests, and its improved covariance approximation avoids underestimating posterior covariance. — [arXiv 1608.07435](https://arxiv.org/pdf/1608.07435). Simulated pseudorange positioning: better accuracy than low-complexity alternatives at roughly **5–10× KF compute**. — [arXiv 1503.06606](https://web3.arxiv.org/pdf/1503.06606)
- Robust VB Kalman filtering with outlier detection (Li, Medina, Vilà-Valls, Closas): performance gains shown in GNSS examples, RTK under degraded signals included. No figure in the material read. — [NSF PAR 10230626](https://par.nsf.gov/servlets/purl/10230626); [NSF PAR 10120300](https://par.nsf.gov//servlets/purl/10120300)
- Android raw-GNSS study comparing MHE, EKF and RTS: the RTS smoother was best, cutting horizontal error by **76.4% static / 46.5% dynamic versus WLS**. Raw-measurement pipeline; the baseline is unfiltered epoch-wise WLS. — [arXiv 2309.08936](https://ar5iv.labs.arxiv.org/html/2309.08936)
- Factor-graph optimisation with Doppler, PDR and a "soft motion model" (small-acceleration prior), Hong Kong, 1 Hz. On campus, mean error went 14.97 m (FGO) → 13.13 m (+CV) → 11.32 m (+PDR) → 7.97 m (+PDR+CV), up to −46.8%. In the dense canyon: 16.80 → 13.10 m best (−22%). The soft motion model alone gave ≤5% and occasionally hurt (campus PDR+CV+SMM 8.71 m vs PDR+CV 7.97 m). An EKF with PDR was 2.7% better on campus but 27% **worse** in the dense canyon than FGO. **Needs raw** pseudorange/Doppler. — [arXiv 2212.14264, Tables 2–5](https://arxiv.org/pdf/2212.14264)
- LocoKit (the open-source library behind the Arc diary app) uses two passes: a Kalman filter on raw locations, then a dynamically sized, weighted moving average for smoother lines. — [LocoKit LocationFilteringExamples.md](https://github.com/sobri909/LocoKit/blob/master/LocationFilteringExamples.md)

### Inferences
- For LifePath's offline pass, expected gains rank as follows. (1) Model the error correctly: a GM bias state and an honest R (Q1), which costs almost nothing in CPU. (2) Add independent information: per-fix Doppler, pedometer, map (Q2, Q5, Q6). (3) Change the smoother family (IMM-RTS, Student-t VB, FGO): unproven on position-only input and probably small, given that the existing robust RTS already handles spikes.
- An IMM-RTS for vehicles would mainly sharpen corners. The survey result suggests overall error barely changes and onset spikes can get worse. A cheaper fix: since the smoother is offline and segments are known, use a higher q for vehicle segments only, or within a few seconds of a detected heading change.
- Constant-turn-rate (CTRV) models: no phone-specific gain numbers found. With one fix per ~10 m, turn-rate is barely observable between fixes on foot. It may help vehicles in curves when fixes run at ≥1 Hz (an unmeasured claim).
- A sliding-window robust least squares (Huber/Cauchy kernel) over the CV model is mathematically close to an iterated, reweighted RTS. If LifePath ever wants it, an IRLS loop around the existing RTS (2–3 iterations, Huber weights from smoothed residuals) gives most of it without a factor-graph library. Reasoned, not measured.

### Gaps
- No published comparison of IMM-RTS, Student-t VB or FGO against plain CV-RTS on **position-only smartphone fixes**.
- No measured gain found for CTRV versus CV smoothing on phone vehicle tracks.

## 5. Phone motion sensors for pedestrian tracks (pedometer, activity, heading, barometer)

### Takeaway
Adding PDR relative motion to GNSS gave the largest measured gain in the phone literature (−19% to −47% mean error, Hong Kong, raw-GNSS FGO). Phone-in-pocket zero-velocity updates are unreliable, but stop detection (activity "stationary" plus no steps) is a sound zero-velocity prior. No numbers found on the background battery cost of CMDeviceMotion.

### Cited Findings
- Huawei P40 Pro, 1 Hz. Adding a PDR relative-motion factor (accelerometer steps plus heading) to GNSS FGO cut mean error 24.4% on campus (14.97→11.32 m) and 19.4% in the dense canyon (16.80→13.55 m). PDR alone drifted (campus PDR-only mean 21.04 m, RMSE 26.74 m). — [arXiv 2212.14264, Tables 2–6](https://arxiv.org/pdf/2212.14264)
- Reviews of smartphone PDR describe Kalman-based PDR/GPS integration as "reasonably accurate". Step length is the weak point; one paper argues step length predicts better than average walking speed per step. Smartphone EKF systems apply zero-velocity updates when the phone is stationary and barometric altitude correction when available. Zero-velocity updates of the foot-mounted kind (stance phase) are reported as unreliable for hand-held/pocket phones. — search results from [Essex repository PDR paper](https://repository.essex.ac.uk/19569/1/1-s2.0-S1566253517302701-main.pdf), [arXiv 1703.00154](https://arxiv.org/html/1703.00154), [PMC6165578](https://pmc.ncbi.nlm.nih.gov/articles/PMC6165578) (snippet-level only: which quote belongs to which paper was not verified)

### Inferences
- LifePath already uses pedometer pace as a speed measurement. The cheapest next steps, using only background-friendly APIs (CMPedometer, CMMotionActivity): (a) a **zero-velocity pseudo-measurement** (v=0, σ≈0.1 m/s) whenever CMMotionActivity says stationary and the pedometer shows no steps. That stops the smoother turning slow correlated drift into fake motion at stops; (b) a **pedometer distance constraint between consecutive fixes** (CMPedometer distance over [t_k, t_k+1] as a constraint on path length) rather than only 30 s pace. Both are unmeasured but small.
- Full PDR bridging (heading from CMDeviceMotion) is what the 19–47% figures measure. It needs continuous device-motion heading, which is costly in background and suffers from phone-in-pocket orientation ambiguity. Treat it as a later, measured experiment, not a default.

### Gaps
- No source found on the battery cost of CMDeviceMotion (or of a higher CoreLocation rate) running in the background on iPhone.
- No published accuracy for CMPedometer distance or pace against a reference on iPhone 15-class devices.
- No published gain for GPS+pedometer-speed-only fusion (without heading) on phone data.

## 6. Map-aided pedestrian smoothing, and what transfers from the Google Smartphone Decimeter Challenge

### Takeaway
The large map-aided gains (shadow matching, 11.25→2.41 m) **need per-satellite raw signal data** that iOS does not expose. Building-footprint and walkable-area constraints are sound in principle, but I found no position-only smartphone numbers. The GSDC winners relied on raw carrier phase and factor graphs. The position-domain steps that transfer (outlier removal, Kalman smoothing, averaging during stops) gave small gains in a documented mid-table solution.

### Cited Findings
- UCL kinematic shadow matching with a particle filter (smartphone, London built-up area): mean error 11.25 m (conventional GNSS) → **2.41 m** (−78.6%). It uses 3-D building models to predict per-satellite visibility from signal strength, so it **needs raw/per-satellite data**. — [UCL GNSS14-0181](https://discovery-pp.ucl.ac.uk/1421172/1/GNSS14-0181.pdf)
- NATO educational note: the more a building plan constrains motion, the better the accuracy, but an accurate plan is needed in advance. — [NATO STO EN-SET-116](https://www.sto.nato.int/publications/STO%20Educational%20Notes/RTO-EN-SET-116-2011/EN-SET-116(2011)-09.pdf)
- GPS+INS+stereo-camera+map probability particle filter for urban pedestrians. — [PMC3435951](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3435951/). Smartphone map-matching particle filter (non-GNSS, barometer plus digital map), post-processed on desktop. — [PMC6068906](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6068906/). No accuracy numbers were extracted from either.
- GSDC 2021, 18th-place pipeline: outlier correction → Kalman smoothing (lat/lon states, linear interpolation to equal spacing) → phone averaging → snap-to-grid → stop averaging. CV score (presumably metres) went from baseline 5.29 to 5.21 after the Kalman step (≈−1.5%), and to 4.95 after blending. The final private score was 2.841. Snap-to-grid used grids built from **ground truth**, so it does not transfer. — [Speakerdeck, 18th place GSDC](https://speakerdeck.com/kuto5046/18th-place-solution-in-gsdc)
- GSDC allowed forward plus backward (post-processed) solutions over full recorded trajectories. Real deployments are mostly forward-only. — [arXiv 2309.08936](https://ar5iv.labs.arxiv.org/html/2309.08936); [CEUR Vol-4298 paper 7](https://ceur-ws.org/Vol-4298/paper7.pdf)
- Several 2021–2022 GSDC teams failed to build an effective GNSS/INS EKF or saw no significant gain from it. A 2024 entry fused a GNSS/INS EKF with a PPK solution for smoother results. — [NAVIGATION (ION) 73(1), navi.748](https://navi.ion.org/content/navi/73/1/navi.748.full.pdf)
- The 2022 GSDC winner used factor-graph optimisation on raw measurements. — search summary of [GPS World](https://www.gpsworld.com/smart-ways-to-improve-smartphone-location-accuracy/) and related results (the full winner paper was not read)

### Inferences
- What transfers to LifePath from GSDC: outlier removal before smoothing, RTS over the whole trip (both already done), and **averaging during detected stops** (cheap; matches the zero-velocity idea in Q5). Expect single-digit-percent gains, not the decimetre results, which come from raw carrier phase.
- Map aid that works on position-only input and on-device: a soft walkable-area prior, i.e. penalise smoothed points inside OSM building footprints, inflating R toward the nearest walkable edge or adding a pseudo-measurement. This differs from HMM snapping, which forces points onto a graph and breaks in open squares and parks. It is also the only position-only tool that can attack the quasi-static offset Q1 says is otherwise unremovable. It is unmeasured on position-only phone data, so CI must show it lowers error, not just changes it.
- Plain HMM snapping to footpaths is a display step for pedestrians, not an accuracy step, unless the network is dense and complete. LifePath already snaps transit to rails, which suits vehicles.

### Gaps
- No quantitative study found of building-footprint or walkable-area constraints applied to **position-only** smartphone fixes.
- The GSDC 2021/2023 winning write-ups were not retrieved, so their position-domain post-processing gains are unknown.
