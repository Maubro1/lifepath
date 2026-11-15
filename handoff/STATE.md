# Project state

Last updated: 2026-11-15 (update this line and the sections below whenever the handoff is refreshed).

## Released (installable from GitHub Releases, all pre-releases)

| Version | What it adds |
|---|---|
| v0.0.1 / v0.0.2 | Stage 0: proved the €0 route (GitHub Actions builds an unsigned IPA; SideStore installs and refreshes it; data survives updates; updates don't use SideStore app IDs). |
| v0.1.0-preview.1 / .2 | Stage 1: the recorder. IMM Kalman filter with Doppler, motion engine (moving/settling/still, wander backoff, fidget-proof wakes, tunnels, indoor fallback), deep-sleep automatic mix (thermal fair only counts off the charger), diary, status box, health report, onboarding, SideStore reminder. |
| v0.2.0-preview.1 | Stage 2a: map tab (lines by date or speed, time filters, satellite, heat map, rest dots, locate-me), offline RTS trip smoothing (open or charging only). |
| v0.2.1-preview.1 | Life-long map: per-trip level-of-detail line cache; every trip shown at every zoom; chunked reads instead of any cap; heat and rest dots from all points. |

The owner runs these on their iPhone and reports that recording works well.

## In progress: stage 2b, learned places

Plan: `docs/superpowers/plans/2026-11-15-stage-2b-places.md`. Ledger: `ledger-current-stage.md` (copy of `.superpowers/sdd/2026-11-15-stage-2b-places/progress.md`). Active branch: **`places`** (pushed to GitHub).

| Task | Status at last update |
|---|---|
| 1. Places core (time-density shapes, density-peak pin, learning, merging) | Done, reviewed, merged into `places`. |
| 2. Diary v4 (place, placeCell, visit, meta tables) | Done, reviewed (data-safe upgrade), merged into `places`. |
| 3. Learning service (folds finished rests into places while open or charging) | An implementer committed `ec7f602` on `places`; check CI and the ledger; it still needs its task review. |
| 4b. Still points need confirmed presence (no assumed location without signal) | An implementer was building it on branch `places-t4b` (from `4ca923a`). Check whether that branch exists on GitHub and what it contains; if incomplete, redo from the plan's Task 4b. |
| 1b. Pin rules (points, hiding after 6 months) | Being built on branch `places-t1b`. |
| 4. Resting at a known place (engine uses visible pins) | Not started; after 1b. |
| 5. Places on the map (pins, outlines, rename) | Not started; after 3 and 1b. |
| 6. Final review and release v0.3.0-preview.1 | Later. |

## Owner decision on places (made 2026-11-15)

One kind of place, shown as a pin: 4 points per different day + 1 point per hour; the pin appears at 100 points. A pin hides after 6 months in a row without a real visit (≥ 5 h, or ≥ half the median of that place's recent visits) and returns on one real visit. Nothing is deleted; past map periods show the pins of that time. No invisible places. Task 1b (Core) implements this; Task 4 (calm resting) uses visible pins.

## Stages after 2b (from the spec)

3. Streets: OSM download (automatic, owner confirmed), HMM/Viterbi map matching onto roads/rail/ferry, travel-mode classification (walk, run, bike, car, bus, tram, train, boat), Streets walked coverage (on foot only), unnamed places get street names.
4. Timeline + Stats + steps (CMPedometer days copied into the diary).
5. Export / backup / import / restore prompt (GPX, GeoJSON, KML, `.lifepath` backup; import must clear the trip-line cache).
6. Design: visual direction with the owner (they want many design questions at this stage), restyle all screens, rest dots clearly different from pins, onboarding copy (humanizer pass).

## Known follow-ups and deferred minors

See `docs/decisions/*.md` (every ruling and deferred minor per stage) and the ledger. Notable: Recorded-line mode at "All" reads all history (correct but unmeasured on the phone); still-dot cells in degrees vs heat's Mercator cells; first trip-line build is chunked monthly.

## Things only the phone can show (ask the owner for health reports)

Battery per day, warmth, wake counts per hour, spot checks per hour, gaps and their reasons, whether the 8-steps fidget threshold and the 6-week/6-month pin rules feel right.
