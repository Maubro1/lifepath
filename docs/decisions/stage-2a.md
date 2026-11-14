# Stage 2a decisions

Every decision taken on the owner's behalf while building stage 2a (the map), with what it costs if wrong. Copied from the build ledger.

- Ruling: stage 2 split into 2a (map, smoothing, heat) and 2b (learned places) so the owner gets a map sooner — cost if wrong: none
- Task 3: Ruling: heat cell size 40 Web-Mercator metres (≈25 m on the ground at the owner's ~52°N) with a shortcut comment — 25 Mercator m was ~15 m on the ground, finer than the spec's ~25 m — cost if wrong: cell size visibly varies far from 52°N
- Task 2: Ruling: keep the live filter's consistency inflation (R × max(k,1) while gated with Doppler agreeing) in the smoother's forward pass — the brief excluded it, but the 'burst better than live' bar outranks the brief; the backward pass otherwise spreads the burst — cost if wrong: retune once
- Task 3: Ruling: task review done by the controller reading the full 30-line implementation and the cell-size diff (correct grid, time weighting with caps by current kind, defensive sort) instead of a separate reviewer — cost if wrong: caught by the final review
- Task 2: Ruling: stored points never carry hAcc < 0 (TrackFilter drops them), but the smoother weights hAcc < 0 or NaN negligibly anyway (r = 1e4, no Doppler) — one line of defence at a trust boundary — cost if wrong: none
- Ruling: Task 6 runs in a worktree on branch stage-2a-t6 from 0c61d0b while Task 5 is reviewed — cost if wrong: small merge fix
- Task 2: Ruling: two-fix assert bar 0.1 m instead of the reviewer's 1 m — the full smoother moves that fixture 0.41 m; forward-only moves 0.0 m — scoped re-review replaced by the controller reading the 6-line source diff — cost if wrong: none
- Ruling: Task 6's task review is folded into the whole-branch final review (most capable model, with Task 6 as an explicit focus) — saves one review cycle before the owner's first map — cost if wrong: findings arrive in one larger fix wave
- Final: Ruling: 2(c) — "All"/"Year" at city zoom show the newest 200 000 points with the "Zoom in" banner; fine for the owner's weeks of data; zoom-based thinning (sampling older points per screen cell) is deferred to a later stage — cost if wrong: "All" shows only recent weeks once history passes ~7 weeks in one city
- Final: Ruling: minors 1 (POI filter), 2 (smoothing seam), 3 (RawFix → Sample), 4 (dead covariance), 5 (comment) join the fix wave — near-free and they remove duplication before release — cost if wrong: none
- Final: Ruling revised after the owner's question: newest-200k-only contradicts the app's purpose ("everywhere you've been"); it stays only as a temporary cap in v0.2.0-preview.1 (it can't bite for ~7 weeks of the owner's data) and the proper fix — per-trip level-of-detail line cache (trip bounding boxes + a coarse simplified line per trip, built by the smoothing service; zoomed-out views draw every trip from the cache, zoomed-in views load full points) — is the first task of the next build, before stage 2b's places
- Final: Ruling: held release; residual Task 8 — trim only the settling cluster: walk back from the end and drop trailing points only while they are within 30 m of the still point AND within 5 m of the previous point (slow wander), never leave fewer than 1 kept point, then append the still point's position as the line's last vertex so every trip reaches its dot; short trips survive — principle 1 (complete) outranks a tidy line — cost if wrong: a little wander remains at some arrivals

## Deferred minor findings

- Task 1: minor (deferred): Trips assumes time-sorted input; no boundary tests (600 s / 500 m); DP tolerance-in-metres not directly tested
- Task 4: minor (deferred): misplaced 'unknown kind' comment in Diary point(_:); no exact-boundary point in testPointsInBox; lat/lon index only serves lat range; FilteredPoint Codable lacks decodeIfPresent for course
- Task 2: minor (deferred): smoothed covariance unused in output; never-bridges test passes by construction
- Task 5: minor (deferred): first run loads all points at once; no BG resubmit inside the handler; nil diary spends the foreground run; cancellation only between trips
- Final: minor (deferred): box query scans the t index on long ranges (LOD cache next build); foreground-skip after quick background/foreground; smoothing reprocesses trips before keepFrom
