# Tracking under pressure (v0.3.1)

Design for the owner's tracking reports of 16 November 2026 and the map-drawing complaints, checked against the top priority: accuracy, battery efficiency and a cool phone, together.

## The evidence

| Report | What the data shows | Root cause |
|---|---|---|
| Gaps while walking (Neude, 16 Nov 17:30–17:41) | Three steps wakes, each followed 60 s later by `wake wander-return` | The wander rule judged "still pottering" from GPS alone; between buildings a resumed walk barely moves the fixes. Each false return also raised the wake threshold 15 → 50 → 150. Fixed in v0.3.0 (steps at walking pace block wander-return and settling). |
| Home keeps tracking | Indoor fixes jump 30–50 m while standing | One noisy fix outside the rest fence counts as leaving and resets the threshold; settling then needs two calm minutes that indoor fixes rarely give. |
| Train: no line, 1 km circle | 374 fixes dropped for accuracy in one hour; the owner saw the circle centred on the true position | iOS overstates `horizontalAccuracy` in coated-window trains; LifePath drops everything above 65 m, and keeps GPS on the whole ride for nothing. |
| Zigzag along the Oudegracht | Line swings 30–40 m across the canal | Urban-canyon multipath with small reported `hAcc`; the smoother cannot see the error. |
| Bus spike | Short out-and-back excursion | A burst of bad fixes passed the vehicle model, which allows sharp manoeuvres. |
| Line appears late, jumps, flickers | Map reloads only on pan, settings or finished smoothing; every reload replaces every overlay; detail changes with every zoom step | No live drawing; no overlay diffing; continuous detail levels. |

The common thread: LifePath trusts iOS's accuracy number, which is wrong in both directions (too pessimistic in trains, too optimistic between buildings), while sensors that are already running (step counter, motion activity, Doppler speed) go unused.

## Principle: cross-check, then trust what fits

Each decision uses the evidence that is reliable in that situation, preferring sensors that are already on over switching GPS on. Nothing recorded is deleted for looking unreliable; it is judged when drawing.

## 1. Keep every fix, judge it afterwards

- `TrackFilter` keeps fixes of any accuracy. A fix above the quality's accuracy ceiling is stored as a new point kind `rough` (raw position, its `hAcc`, no Doppler speed) and does not enter the live Kalman state, so it can never pull the precise line. Still dropped: invalid (`hAcc < 0`), stale, future, out of order, and physically impossible jumps.
- Rough fixes are stored at most one per 10 s (they come in bursts and carry little detail).
- `Trips` treats rough points as part of the trip, so a train ride is one trip with its rough stretch inside it.
- The smoother weighs a rough stretch by its consistency, not by `hAcc`: the effective error is the robust spread of the stretch's second differences (for near-constant motion, `√(var/6)`), at least 20 m and at most the reported `hAcc`. A smooth train-speed path of 1 km-"accuracy" fixes therefore gets the weight it deserves.
- The map draws rough stretches as a thinner dashed line in the trip's colour, so precision is never overstated. Stage 3 matches them onto the rail network (the CTrack result: 156 m median error raw, 45 m after network matching).

## 2. Pottering or leaving

After a steps or walking wake, the decision uses three numbers: **walked** W (pedometer distance since the wake), **drift** D (distance from the rest centre to the median position of the last 20 s of fixes) and **noise** N (median `hAcc` of those fixes).

- **Leaving:** D exceeds the rest area (fence radius, or the place's shape) by more than N + 15 m in two consecutive 10 s windows, with D growing. Any position-based wake (geofence, significant change, spot check outside) stays an immediate departure.
- **Pottering:** W ≥ 40 m while D ≤ N + 10 m: back to Still, GPS off.
- **Walking without drift** (canyon): stay awake while steps keep walking pace (v0.3.0 rule); D or the stopping of the steps decides.
- The 15 → 50 → 150 backoff stays, and resets after 30 min of rest as well as on leaving.

At a visible pin (home), a steps wake first runs on the keep-alive readings that are already on (Wi-Fi/cell, no GPS): GPS starts only when a keep-alive reading lies outside the place shape (allowing its accuracy), the geofence fires, or steps keep walking pace for 3 minutes. Cost: leaving home starts GPS when the Wi-Fi reading moves, typically within 30–60 s; the first tens of metres can stay a gap (the trip's start time is still dated from step history).

## 3. Saving effort in vehicles

- Vehicles use `CLActivityType.otherNavigation` (no road-network assumption), since the owner rides trains, trams and waterbuses as much as cars. Cost if wrong: slightly less smooth car lines, visible in the health report's accuracy table.
- **Struggle mode:** while moving with vehicle activity, three minutes in which every fix is rough switch GPS to `kCLLocationAccuracyHundredMeters` with a 50 m distance filter; every 5 minutes a 20 s probe at full accuracy checks whether GPS is back (a fix ≤ 65 m ends struggle mode). Rough fixes keep being stored throughout. Logged as `struggle on/off`.

## 4. A better drawn line (offline, open or charging)

- **Walking pace from the step counter:** when smoothing a walking trip (median speed < 2.5 m/s) within CoreMotion's 7-day history, the smoother queries pedometer distance in 30 s buckets and uses that pace as a speed measurement along the filter's own heading wherever a fix has no valid Doppler (σ 0.3 m/s). A zigzag the steps cannot explain is pulled straight. Older trips keep their current smoothing. Stage 3 snaps walks to the street.
- **Spike removal:** a run of at most 3 fixes within 30 s whose out-and-back implies a speed above the plausible maximum for the trip (4 m/s walking, 15 m/s cycling, otherwise 3 × the trip's median speed) and whose neighbours line up within their accuracy is weighted as negligible. Stored points are never modified.
- A smoothing version number makes existing trips re-smooth once.

## 5. A steady map

- **Live drawing:** while the map is on screen, a flush that wrote points posts a notification and the map reloads at most every 15 s. Nothing runs while the map is off screen.
- **Redraw only the differences:** each overlay carries a key (trip start and detail level; heat by data generation); an update adds missing keys and removes stale ones, and unchanged lines stay on the map.
- **Fixed detail steps:** the simplification tolerance snaps to powers of two (3, 6, 12, 24 m …), so zooming within a step changes nothing.

## 6. Proof on the phone

The health report gains, per hour: rough fixes stored, struggle minutes, pottering returns and leaving decisions. These show whether the changes work without the owner sharing tracks.

## Testing (synthetic fixtures, Core)

- Train: straight 30 m/s, fixes every 2 s with `hAcc` 700–1500 m but true error ≤ 40 m → rough points stored; smoothed line within 60 m of truth; struggle mode after 3 min; a probe every 5 min.
- Canyon walk: 1.3 m/s with biased 25–35 m bursts and a pedometer track → smoothed path length within 15% of the pedometer distance; mean error below the current smoother's.
- Bus spike: 10 m/s route with a 3-fix 150 m excursion → smoothed deviation ≤ 20 m.
- Home pottering: 5 min of random-direction steps with indoor noise 30–50 m → back to Still, GPS on ≤ 2 min in total.
- Neude: walk, 3 min pause, walk on with fixes nearly static → no gap (already in v0.3.0).
- Existing tests keep passing; accuracy bars from the spec stay.

## Out of scope here

Map matching onto streets and rail (stage 3), travel-mode classification (stage 3), restyling (stage 6).
