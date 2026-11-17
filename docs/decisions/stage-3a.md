# Stage 3a decisions

Decisions taken on the owner's behalf while building streets and map matching, with what each costs if wrong.

- Ruling: OpenStreetMap ways (streets, foot and cycle ways, rail, tram, ferry) come from Overpass in ~2 km tiles along each trip's path, one request at a time, only the tile rectangle in a POST body, ephemeral session, backoff 60 s doubling to 30 min remembered across launches; no network means skip quietly — cost if wrong: streets arrive later
- Ruling: a tile that keeps failing blocks matching of later trips until it succeeds (shortcut comment) — cost if wrong: no matching for a while after a server problem
- Ruling: HMM/Viterbi matcher per the spec; walkers may use roads where no footpath fits; one-way rules ignored on foot; one-point jumps onto a crossing way dropped — cost if wrong: a walk may sit on the road beside a footpath
- Ruling: rough points match only rail, tram and ferry above 15 m/s; until stage 3b's travel modes, rough-only stretches under 25 m/s median speed stay unconfident (drawn as recorded), so a fast car in struggle mode never sticks to a railway — cost if wrong: some slower train stretches stay dashed until 3b
- Ruling: matched stretches are identified by the times of their first and last point (not indices), so the map applies them to whatever part of a trip is loaded — cost if wrong: none
- Ruling: a new matcher version re-matches all trips once, resuming from a cursor; matches are a recomputable cache — cost if wrong: none
- Ruling: zoomed-out cached lines are not matched (the cache holds smoothed lines) — cost if wrong: street-exact lines only when zoomed in

## Deferred minor findings

- Final review: one route search per candidate pair (up to 64 per step); one search per source to all targets would be ~8× cheaper
- Matching runs only while the app is open or charging; the first run downloads and matches all history and can take a while
- Not verified on the phone: Overpass downloads, matching quality on real streets and railways
