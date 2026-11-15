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
| 4. Resting at a known place (engine uses the place shape) | NOT started: waits for the owner's decision below. |
| 5. Places on the map (pins, outlines, rename) | NOT started: waits for the owner's decision below. |
| 6. Final review and release v0.3.0-preview.1 | Later. |

## Open decision for the owner (ask before Tasks 4 and 5)

Proposed after the owner's own idea of visible and invisible places:

- **Invisible places** (used by LifePath itself for calm resting, no GPS for pottering, a fixed dot): form after rests on **2 different days**.
- **Visible pins** (clean map): a place earns **4 points per day visited + 1 point per hour there**; the pin appears at **100 points** (home ≈ 6 days, school ≈ 2 weeks, part-time work ≈ a month, gym ≈ 6 weeks, parents with overnight stay monthly ≈ 5 months, a regular café ≈ 8 months, a one-off bench or festival never).
- **Disappearing**: a pin hides after **6 months in a row without a real visit**; one real visit brings it back at once. A real visit = **at least 5 hours, or at least half as long as your usual visit there** (so a weekly gym visit keeps the gym's pin).
- Nothing is ever deleted: choosing a past period on the map shows the pins of that period.

The owner had agreed earlier that places form over about a week (visits on ≥ 5 different days, first and last ≥ 7 days apart); that rule is what's implemented in Core right now (`Places.learn`, `isCandidate`). If the owner approves the proposal above, change Core so that: `isCandidate == false` after 2 different days (invisible place), and add the points/visibility rules for pins (probably as computed properties on `Place` using its visits; the visit table has the data).

## Stages after 2b (from the spec)

3. Streets: OSM download (automatic, owner confirmed), HMM/Viterbi map matching onto roads/rail/ferry, travel-mode classification (walk, run, bike, car, bus, tram, train, boat), Streets walked coverage (on foot only), unnamed places get street names.
4. Timeline + Stats + steps (CMPedometer days copied into the diary).
5. Export / backup / import / restore prompt (GPX, GeoJSON, KML, `.lifepath` backup; import must clear the trip-line cache).
6. Design: visual direction with the owner (they want many design questions at this stage), restyle all screens, rest dots clearly different from pins, onboarding copy (humanizer pass).

## Known follow-ups and deferred minors

See `docs/decisions/*.md` (every ruling and deferred minor per stage) and the ledger. Notable: Recorded-line mode at "All" reads all history (correct but unmeasured on the phone); still-dot cells in degrees vs heat's Mercator cells; first trip-line build is chunked monthly.

## Things only the phone can show (ask the owner for health reports)

Battery per day, warmth, wake counts per hour, spot checks per hour, gaps and their reasons, whether the 8-steps fidget threshold and the 6-week/6-month pin rules feel right.
