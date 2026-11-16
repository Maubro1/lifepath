# Stage 2b decisions

Every decision taken on the owner's behalf while building stage 2b (learned places, robustness), with what it costs if wrong. Taken from the build ledger and the final review.

- Ruling (owner): one kind of place, a pin at 100 points (4 per visit day + 1 per hour); a real visit lasts ≥ 5 h or ≥ half the place's median recent stay; dynamic hiding min(730, max(180, 3 × typical gap) + 30 × min(6, years known)) days; nothing deleted; past map periods show the pins of that time — cost if wrong: retune the numbers
- Ruling (owner): still points (and so heat) need confirmed presence within 30 min; unconfirmed stretches are filled only when a later reading confirms the place and CoreMotion shows no departure — cost if wrong: some honest gaps in heat
- Ruling (owner): calm resting applies to visible pins only — cost if wrong: Task 4 scope
- Ruling: PlaceShape carries a precomputed region, so a wake fix costs at most 21 × 21 set lookups — cost if wrong: none
- Ruling: Diary v5 stores realDays and recentDurations as text columns rather than rebuilding them from visits; no released build had places — cost if wrong: none
- Ruling: pins for a past period use isVisible(at: period end), counting only real visits up to that date; hideAfterDays and isCandidate use the whole history (shortcut comment) — cost if wrong: an old period shows a pin slightly early or late
- Ruling: place outlines are one MKMultiPolygon of 5 m cell squares (smaller code than merging polygons) — cost if wrong: more vertices at street zoom
- Ruling: the stored place name always wins over a learning run's copy (set, changed or cleared); a merge no longer carries an unnamed survivor the loser's name — cost if wrong: rename a merged place once more
- Ruling: places decay lazily when touched (exact, because pin and region depend only on weight ratios); a run rewrites only changed places — cost if wrong: none
- Ruling: the places cursor is rewound after a backfill older than it; a concurrent run can win the race (shortcut comment) — cost if wrong: a fill missed until the next rewind
- Ruling: "Save a backup" copies through a reader connection and hands the file to the system file mover; restore waits for stage 5 — cost if wrong: none
- Ruling: deep sleep no longer exempts the "no location check for over an hour" status; a low battery forces deep sleep only off the charger — cost if wrong: a false warning during a very long deep sleep
- Ruling (owner report, Neude walk): steps at walking pace (≥ 35 per 30 s, for up to 3 min after a wake) block wander-return and settling; after 3 min positions decide alone, so busy pottering cannot hold GPS on — cost if wrong: up to 3 min extra GPS during vigorous pottering
- Ruling: the full redesign for trains, urban canyons and home pottering goes to v0.3.1 (spec 2026-11-16-tracking-under-pressure) — cost if wrong: those reports stay open one more version

## Deferred minor findings

- Final review: still points at a known place sit on the pin, so learning cannot move a pin within the same building (spec rule; revisit if pins look stuck)
- Final review: the departure geofence stays the 200 m circle around the rest position, not the pin plus the shape's extent (large places like a campus may wake GPS inside the place); v0.3.1 Task 3
- Final review: Root creates a CLLocationManager per init (harmless)
- Final review: after the no-fix fallback the first still point sits at the fence, not the pin (shortcut comment)
- A rename during a running places pass shows the old name on the map until the next pass (the diary keeps the new one)
- Task 1: pin tie set includes neighbours of the peak; pin candidates not restricted to region
- Task 2: no test for empty visitDays, shrinking cells or orphan placeCell rows; no index on visit.end
