# Life-long map (level of detail) decisions

Decisions taken on the owner's behalf while building the level-of-detail map, with what each costs if wrong.

- Ruling: Task 2 defines the TripLine struct itself (Task 1 adds TripLines in the same file); controller reconciles at merge — lets both run in parallel — cost if wrong: one trivial merge conflict
- Ruling: Task 1 task review done by the controller reading the 30-line diff (bbox over all points, DP at 15 m, unknown speeds → trip median or −1, hand-written Equatable; min()! safe since Trip has ≥ 2 points) — cost if wrong: caught by the final review
- Ruling: Task 2's task review is folded into the final review with an explicit migration-v3 data-safety focus; Tasks 3 and 4 go to one implementer (small, same files, sequential) — cost if wrong: findings land in one fix wave
- Final: Ruling: one fix wave removes every Principle 1 violation — streaming chunked fallback (ascending 400k-point chunks, trips carried across chunk edges, simplified per trip, memory bounded by output) replaces even()/points(every:); still dots from their own query over the full range, one per cell; heat built over chunks with Core Heat.grid carrying the boundary pair; custom range clamps the cache query to its end; first cache build in monthly chunks; zoomed-out threshold 7.5 m per point to match the cache's 15 m; no double-drawn seam trip; comment that backup merge/import must clear the trip cache; map reloads once after a smoothing run finishes — cost if wrong: one more review cycle

## Deferred minor findings

- Final: minor (deferred): cached trips crossing a filter edge drawn whole; small visual break where the newest cached trip continues after until; Recorded mode/lagging cache at All reads all history (unmeasured); map reloads after nearly every smoothing run; still-dot cells in degrees vs heat's Mercator cells
