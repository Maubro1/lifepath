# SDD ledger — plan: docs/superpowers/plans/2026-11-15-stage-2b-places.md
Setup: base 572f28a on main (v0.2.1-preview.1 released). Task 1 first (Core types used by 2, 4, 5); then 2 and 4 in parallel; 3 after 2; 5 after 3.
Pre-flight: T2/T3/T4/T5 consume T1 Place, PlaceCell, Visit, Places.visits/learn, Place.region/contains/pin; T4 adds PlaceShape; T5 consumes T2 places()/renamePlace and T3 placesChanged. Consistent.
Ruling (owner feedback): a candidate becomes a place only after visits on ≥ 3 different days; the '3 hours in total' shortcut is removed (one long stay must never make a place) — cost if wrong: home appears as a place on day 3 instead of day 1
Ruling (owner feedback): promotion needs visits on ≥ 5 different days with first and last ≥ 7 days apart; Place gains lastVisit for pin fading on the map (rule pending owner confirmation) — cost if wrong: places appear after ~1 week
Task 1: implemented 630d199, 12899c6 (places-t1), local 129/129, CI 43655388521
Ruling: Task 2 stores Place's recent map, visitDays and lastVisit too (placeCell gets a recent column; place gets visitDays TEXT and lastVisit REAL); pin stays computed and pinLat/pinLon are a cache — Task 1 added them — cost if wrong: none
Ruling: Task 4's PlaceShape carries a precomputed region Set so contains is O(1) per wake fix; Place.contains recomputing region stays for occasional use — cost if wrong: none
Task 1: Ruling: drop the 60-day trim of visitDays — the owner's rule has no window, and a monthly visit (family) deserves to become a place over time; clutter is handled by pin hiding after weeks without a visit — cost if wrong: a rarely-visited spot becomes a place after 5 visits spread over months
Task 1: Ruling: minors pulled into fix round 1 — split visits on a > 30 min gap between still points (no mixing two places after a recording break); guard the empty-cells pin; tell Task 3 that a merge can change a visit's placeId (removed ids map to the survivor)
Task 1: minor (deferred): pin tie set includes neighbours of the peak; pin candidates not restricted to region; garden test passes via merge
Ruling (owner): still points (and so heat) require confirmed presence — a consistent location reading within 30 min; unconfirmed stretches are filled only when a later reading confirms the same place and CoreMotion shows no departure; new Task 4b — cost if wrong: some honest gaps in heat during long signal-less stretches
Task 2: implemented 7fb7373 (places-t2), CI 43655924190
Task 2: complete (12899c6..7fb7373 on places-t2, review approved, data-safety verdict: upgrade cannot alter recordings)
Task 2: Ruling (carried to merge): Task 1's fix round makes Place.pin optional; at merge Diary.savePlaces writes pin?.lat / pin?.lon (columns already nullable) — cost if wrong: compile error caught by CI
Task 3: Ruling (carried): when learn merges places, remap stored visits of removed ids to the survivor and save them in the same run
Task 2: minor (deferred): no test for empty visitDays / shrinking cells / orphan placeCell rows; updatedAt/lastVisit read non-optional; no index on visit.end
Task 1: fix round 1/5 (6 addressed: week-span tests, decay test now fails without decay, far-place bbox skip, no 60-day window, 30-min gap split, nil pin when empty; b50a60f; local 134/134; CI 43656167467)
Ruling: Task 1 scoped re-review replaced by the controller checking the named tests and the report's RED→GREEN evidence; the final review covers the code — cost if wrong: caught at final review
Task 1: complete (572f28a..b50a60f)
Merged T1+T2 into places at 4ca923a (pin optional reconciled); T3 in main checkout on places, T4b in worktree places-t4b from 4ca923a; T4 waits for the owner's tier decision
