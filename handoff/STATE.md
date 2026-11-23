# Project state

Last updated: 2026-11-23 (update this line and the sections below whenever the handoff is refreshed).

## Released (installable from GitHub Releases, all pre-releases)

| Version | What it adds |
|---|---|
| v0.0.1 / v0.0.2 | Stage 0: proved the €0 route (GitHub Actions builds an unsigned IPA; SideStore installs and refreshes it; data survives updates; updates don't use SideStore app IDs). |
| v0.1.0-preview.1 / .2 | Stage 1: the recorder. IMM Kalman filter with Doppler, motion engine (moving/settling/still, wander backoff, fidget-proof wakes, tunnels, indoor fallback), deep-sleep automatic mix (thermal fair only counts off the charger), diary, status box, health report, onboarding, SideStore reminder. |
| v0.2.0-preview.1 | Stage 2a: map tab (lines by date or speed, time filters, satellite, heat map, rest dots, locate-me), offline RTS trip smoothing (open or charging only). |
| v0.2.1-preview.1 | Life-long map: per-trip level-of-detail line cache; every trip shown at every zoom; chunked reads instead of any cap; heat and rest dots from all points. |
| v0.9.8-preview.1 | The top-speed choice (under / from 40 km/h) applies to lines, Fog and Heat; its toggles are always in the layers panel. Owner data: no trip between 29.8 and 50.8 km/h top speed in 8 days, so 40 sits in the gap. |
| v0.9.7-preview.1 | No spikes from lone rough fixes: trip lines draw rough fixes at their smoothed position (a "2 km" fix on 21 Nov drew a 700 m spike in a tram ride). Trip-line cache v5. |
| v0.9.6-preview.1 | Street matching works again (a transit stretch and the matcher's own both saved as seq 0 made every run fail from 19 Nov; the week since is matched on the next open/charge); pottering is no trip (a run between two rests at one spot that never leaves it: 129 of the owner's 224 trips, mostly night wake-ups at home); top speed falls back to positions when iOS gives no Doppler; age colours mustard to navy in Oklab with an age bar; fog clears closed pockets narrower than a walk's band; rest dots removed; speed toggles flip instead of greying out. Trip-line cache v4. |
| v0.9.5-preview.1 | Accuracy round 1 (report `reports/LifePath tracking accuracy.md`): tests use phone-like drifting error (new bars live 6.0 m, smoothed 5.8 m, corner 11.5 m); iOS speed/course accuracy can only widen the Doppler noise; a 65 m Wi-Fi fix counts as rough; keep-alive asks for the recorder's activity type; health report shows iOS speed/direction accuracy and walks against their matched street. Layers panel: under "By speed", show trips with top speed under 40 km/h and/or 40 km/h and over (top speed = fastest held for 15 s; per trip); trip-line cache rebuilt once (v3). Backup of v0.9.4: tag `backup/before-accuracy-2026-11-23` and `handoff/private/backups/`. |
| v0.9.4-preview.1 | Lines no longer vanish while panning: the map margin (for the Apple logo) was re-set on every update because iOS reports it with the safe area added, which re-laid out, reloaded and redrew the map nonstop; All-time line ages start at the diary's first trip, so a pan no longer re-keys every line. |
| v0.9.3-preview.1 | Rides anchored to where you stood before and after (platform waits up to 90 min), single rides through the same check; crash on rides from a line's first stop fixed; walks next to rides keep their street snap; lines by speed again (log scale, km/h legend, no modes). |
| v0.9.2-preview.1 | Train rides linked across signal gaps and station stops (one ride, snapped station to station, rail only); Streets mode shows only the tracked lines; Apple logo above the panel; list values under their titles. |
| v0.9.1-preview.1 | Compass icon (heat glow, night and paper), day facts as a 2 x 2 grid, short durations, day keys in local time, Fog and Heat without trip lines, fainter single heat passes, deeper light fog, Save a backup fixed. |
| v0.9.0-preview.1 | Stage 7: short stops without gaps, lines that keep their shape, see-through warm fog, cumulative line heat, travel modes internal, transit snapped to OSM routes, full-screen map with glass controls, delete chosen days. |
| v0.8.0-preview.1 | Stage 6 design: two tabs (Map, You); Streets or Fog map that fills up; progress per city and neighbourhood (OSM borders); flicker-free map layers; the owner's study-page look (palette, Bricolage), appearance switch; day pages with map pictures and the day as a story. |
| v0.7.2-preview.1 | Bus rides no longer read as boat rides (rough fixes, narrow boat speed prior, missing streets). |
| v0.7.1-preview.1 | Map matching does one route search per starting point instead of one per pair (same results, about 8× less work while matching). |
| v0.7.0-preview.1 | Stage 5: Export tracks (GPX, GeoJSON, KML), Save a backup, Restore from a backup (preview, adds only, keeps a copy first, also on the first-launch page), Last backup row. |
| v0.6.0-preview.1 | Stage 4: Timeline tab (a card per day: route, distance, moving time, steps), Stats tab (where you went, on foot, Streets walked), steps kept permanently. |
| v0.5.0-preview.1 | Stages 3b + 3c: travel mode per stretch (walk, run, bike, car, bus, tram, train, boat) with a Mode colouring; trains match rail only, bikes cycle paths; Streets walked toggle and tally (20 m segments, 90% rule). |
| v0.4.0-preview.1 | Stage 3a: OpenStreetMap streets, rail and ferry downloaded along trips (only a map rectangle leaves the phone), HMM map matching, walks drawn on the street taken and train rides on the railway. |
| v0.3.1-preview.1 | Tracking under pressure: train positions kept (rough), better walking and vehicle lines, home pottering no longer keeps GPS on, battery-saving mode in trains, live steady map with dashed rough stretches. |
| v0.3.0-preview.1 | Stage 2b: learned places as pins (time-density shapes, dynamic hiding, pins per period, outlines, rename), calm resting at pins, confirmed presence for still points, Save a backup, "Not saving since" status, resume after first unlock, clearer settings, walking steps keep a resumed walk awake. |

The owner runs these on their iPhone and reports that recording works well.

## Now: v0.9.8-preview.1 released (owner said release without waiting for screenshots; fix and re-release if the checks find issues)

Accuracy round 1 and the top-speed filter shipped. Next from the report, in its order: measure first (the health report now gives iOS's speed/direction accuracy and the walks' offset from their street with a fade time; feed the measured fade time into `Drift.phone`), then the `.fitness` vs `.other` walk experiment (needs the owner's test walks), walker-tuned map matching (beta by spacing, off-network option), drift states in the smoother. Speed filter follow-ups: per stretch instead of per trip (a walk to the station currently counts with the train), and speed pedelecs (32-45 km/h) straddle the 40 km/h line. Known: km during a signal gap are not counted in the day's distance.

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

## Stage 7 requests (owner, 18 Nov 2026, after v0.8.0)
1. Travel modes are internal only: no mode colours in lines or stats. Classify from the trip's top speed (not the average) and signal; cars, buses and trains are Faraday cages (poor GPS is evidence).
2. Rounded corners. Build a way to render the app's screens off the phone so the look can be inspected; every change gets a visual check. UX first: walk the user's steps, cut what is not needed, add what is missing; native iOS, not generic.
3. Trains: a line that keeps crossing or following one railway and starts and ends at stations is a train; snap it to the railway. Same idea for tram, bus and metro. Stations worldwide, not only the Netherlands.
4. Stops are detected too quickly: standing still a few minutes must not pause tracking or leave gaps.
5. Fog must not be opaque; fog lags when panning; lines keep changing shape; simplify lines less (efficient, researched techniques).
6. Heat map: follow the shape of the lines with natural gradients, no blocks.
7. Rethink the map screen: what to show, where, and how it looks.
Research each; use proven techniques; show initiative.
