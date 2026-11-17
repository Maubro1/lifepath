# Project state

Last updated: 2026-11-16 (update this line and the sections below whenever the handoff is refreshed).

## Released (installable from GitHub Releases, all pre-releases)

| Version | What it adds |
|---|---|
| v0.0.1 / v0.0.2 | Stage 0: proved the €0 route (GitHub Actions builds an unsigned IPA; SideStore installs and refreshes it; data survives updates; updates don't use SideStore app IDs). |
| v0.1.0-preview.1 / .2 | Stage 1: the recorder. IMM Kalman filter with Doppler, motion engine (moving/settling/still, wander backoff, fidget-proof wakes, tunnels, indoor fallback), deep-sleep automatic mix (thermal fair only counts off the charger), diary, status box, health report, onboarding, SideStore reminder. |
| v0.2.0-preview.1 | Stage 2a: map tab (lines by date or speed, time filters, satellite, heat map, rest dots, locate-me), offline RTS trip smoothing (open or charging only). |
| v0.2.1-preview.1 | Life-long map: per-trip level-of-detail line cache; every trip shown at every zoom; chunked reads instead of any cap; heat and rest dots from all points. |
| v0.7.1-preview.1 | Map matching does one route search per starting point instead of one per pair (same results, about 8× less work while matching). |
| v0.7.0-preview.1 | Stage 5: Export tracks (GPX, GeoJSON, KML), Save a backup, Restore from a backup (preview, adds only, keeps a copy first, also on the first-launch page), Last backup row. |
| v0.6.0-preview.1 | Stage 4: Timeline tab (a card per day: route, distance, moving time, steps), Stats tab (where you went, on foot, Streets walked), steps kept permanently. |
| v0.5.0-preview.1 | Stages 3b + 3c: travel mode per stretch (walk, run, bike, car, bus, tram, train, boat) with a Mode colouring; trains match rail only, bikes cycle paths; Streets walked toggle and tally (20 m segments, 90% rule). |
| v0.4.0-preview.1 | Stage 3a: OpenStreetMap streets, rail and ferry downloaded along trips (only a map rectangle leaves the phone), HMM map matching, walks drawn on the street taken and train rides on the railway. |
| v0.3.1-preview.1 | Tracking under pressure: train positions kept (rough), better walking and vehicle lines, home pottering no longer keeps GPS on, battery-saving mode in trains, live steady map with dashed rough stretches. |
| v0.3.0-preview.1 | Stage 2b: learned places as pins (time-density shapes, dynamic hiding, pins per period, outlines, rename), calm resting at pins, confirmed presence for still points, Save a backup, "Not saving since" status, resume after first unlock, clearer settings, walking steps keep a resumed walk awake. |

The owner runs these on their iPhone and reports that recording works well.

## Next: stage 6, design (together with the owner)

Stages 0–5 are built, reviewed and released (latest v0.7.0-preview.1; decisions in `docs/decisions/`). Stage 6 is done with the owner: visual direction (they want many design questions here), restyle all screens, rest dots clearly different from pins, mode colours, timeline route drawing (plain line now; a map snapshot is possible), onboarding copy (humanizer pass), settings polish. Use the `impeccable` plugin. Start by asking the owner the questions below plus the design questions, and by collecting their health reports on v0.7.0.

## Questions for the owner (collected overnight, 2026-11-17)

None of these block work; each has a default already built.

1. Travel mode: when you walk to a train, the switch point on the map can be up to 30 s late. Fine, or should it be sharper?
2. Travel mode: stretches LifePath isn't sure about are drawn grey. OK, or would you rather see them in the date colour?
3. Streets walked: running counts as walking; a walk within 15 m of a street (e.g. on a separately mapped sidewalk) counts for that street; motorways, service roads, sidewalks and private roads don't count as streets. Agree?
4. Streets walked: the tally (e.g. "312 of 1,840 streets") sits under the map controls until the Stats screen arrives in stage 4. OK?
5. Privacy check: LifePath now keeps your motion activity (walking, cycling, in a vehicle) in the diary for good, because iOS forgets it after 7 days. It never leaves the phone. OK?
6. Restore: restoring a backup into a diary that already has places keeps this phone's places and drops the backup's place names (a fresh install keeps everything). OK, or should names be carried over where places overlap?
7. Export (GPX, GeoJSON, KML): train stretches with only rough positions are left out, so the exported line breaks there. OK, or include them marked as approximate where the format allows?

## Owner decision on places (made 2026-11-15)

One kind of place, shown as a pin: 4 points per different day + 1 point per hour; the pin appears at 100 points. A real visit lasts at least 5 h, or at least half the median of that place's last 20 visits. Hiding is dynamic: hideAfterDays = min(730, max(180, 3 × typical gap) + 30 × min(6, years known)). A stay is a run of consecutive days touched by a real visit; a gap runs from the end of one stay to the start of the next; the typical gap is the lower median of the last 8 gaps; years known counts whole years from the first visit to the last real visit. In the owner's words: a pin stays at least 6 months after the last real visit, or three times the usual gap between stays if that is longer, plus one month per year the place has been in their life (up to 6), at most 2 years. One real visit brings it back. Nothing is deleted; past map periods show the pins of that time. No invisible places, no fading, no manual "moved away" button for now. Worked examples (all in the tests): home 8 yrs → 360 days, former home after 5 yrs → 330, school 4 yrs → 300, gym → 240, parents monthly → 360, grandparents 3×/yr → 450, holiday home yearly → 730, café → 270, internship → 180.

## Owner priority (2026-11-16): top three

Accuracy, efficiency (battery) and keeping the phone cool are the top priorities, equal to each other and above everything else. Every design and review checks them first. See the Principles section of the spec.

## Owner priority (2026-11-15)

The app and its data must survive crashes, updates and iOS kills, and the app must be well adjustable, with clear setting names and short descriptions where needed. Every review checks this.

## Stages after 2b (from the spec)

3. Streets: OSM download (automatic, owner confirmed), HMM/Viterbi map matching onto roads/rail/ferry, travel-mode classification (walk, run, bike, car, bus, tram, train, boat), Streets walked coverage (on foot only), unnamed places get street names.
4. Timeline + Stats + steps (CMPedometer days copied into the diary).
5. Export / backup / import / restore prompt (GPX, GeoJSON, KML, `.lifepath` backup; import must clear the trip-line cache).
6. Design: visual direction with the owner (they want many design questions at this stage), restyle all screens, rest dots clearly different from pins, onboarding copy (humanizer pass).

## Known follow-ups and deferred minors

See `docs/decisions/*.md` (every ruling and deferred minor per stage) and the ledger. Notable: Recorded-line mode at "All" reads all history (correct but unmeasured on the phone); still-dot cells in degrees vs heat's Mercator cells; first trip-line build is chunked monthly.

## Things only the phone can show (ask the owner for health reports)

First health reports (v0.2.1, evening of 14 Nov to 01:43 on 15 Nov): thermal nominal throughout, GPS on 0.5 h in an evening, resting 82–100% in quiet hours, spot checks every 5 min through the night, 94% of moving points within 20 m, fidget wakes returned to rest within a minute. The only two gaps (15 and 19 min) each ended at the launch of a newly installed version: a SideStore update stops the app until the owner opens it (robustness-audit item 5). Deep sleep on v0.2.1 stopped spot checks entirely; the code on `places` keeps one every 15 min.


Battery per day, warmth, wake counts per hour, spot checks per hour, gaps and their reasons, whether the 8-steps fidget threshold and the pin rules (100 points, dynamic hiding) feel right, and whether the deep-sleep keep-alive with 15-minute spot checks stays cool and battery-light overnight.
