# Stage 4 decisions

Decisions taken on the owner's behalf while building the Timeline, Stats and steps, with what each costs if wrong. The look of these screens is designed with the owner in stage 6.

- Ruling: day summaries (distance along the smoothed line, moving time, walked distance from confident walk/run stretches, points) are a recomputable cache; trips crossing midnight are split between the two days; a day at home has 0 moving time — cost if wrong: retune
- Ruling: steps, distance and floors come from CMPedometer and are copied permanently (iOS keeps 7 days); a stored count is never lowered, never replaced by nothing, and a failed day is left out instead of stored as 0 — cost if wrong: none
- Ruling: the timeline's route drawing is a plain line without a map underneath (costs nothing, sends nothing); the spec's map snapshot can come with the design stage — cost if wrong: redesign in stage 6
- Ruling: distance walked is GPS-based (confident walk/run); pedometer distance is stored but not shown — cost if wrong: show it later
- Ruling: a day with steps but no recording counts in Stats, not on the Timeline — cost if wrong: list it later
- Ruling: day recomputation looks back past yesterday only when the street cursor moved; moving time under a minute shows "< 1 min"; missing steps show "No data" — cost if wrong: none
- Ruling: day keys use the Gregorian calendar and the phone's current time zone — cost if wrong: days shift after travel across time zones

## Deferred minor findings

- A trip spanning two days draws its full line on both day cards; today's drawing stays blank until smoothing has run
- Jump-to-date and per-day place visits on the Timeline are not built yet
- Not verified on the phone
