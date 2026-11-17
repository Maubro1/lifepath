# Stages 3b and 3c decisions

Decisions taken on the owner's behalf while building travel modes (3b) and Streets walked (3c), with what each costs if wrong. Open questions for the owner are in handoff/STATE.md.

- Ruling: travel modes come from a Viterbi pass over 30 s windows (activity, speed, halts at mapped stops, nearness to each network, share of rough fixes); unsure stretches draw grey — cost if wrong: retune from health reports
- Ruling: CoreMotion activity is copied into the diary for good (iOS keeps 7 days), with a one-hour overlap per copy, and the copy cursor moves only after a successful query — cost if wrong: none (on-device only)
- Ruling: car wins over bus without bus-stop evidence; a halt is ≥ 10 s of slow fixes — cost if wrong: some bus rides show as car
- Ruling: confident trains match rail only, bikes prefer cycle paths, slow rough trams and trains match when their mode is confident — cost if wrong: grey instead of solid for unsure stretches
- Ruling: mode stretches, like matched stretches, are identified by timestamps — cost if wrong: none
- Ruling: every stored tile is downloaded once more to get stops, cycle paths and the countable flag (OSM versions 2 and 3); without a network, matching continues on stored tiles — cost if wrong: one extra download round
- Ruling: Streets walked uses 20 m segments, a walk within 15 m credits a street, ≥ 90% of a street's length (100% for ≤ 10 segments) covers it; running counts as walking; motorways, service roads, sidewalks and private ways are not streets; same-name ways join only where they touch; vehicles never count; cycling only with the setting on — cost if wrong: tally slightly off
- Ruling: zoomed out, walked streets are not drawn (only the tally shows); a version change clears all segment hits and recomputes — cost if wrong: zoom in to see them
- Ruling: the Streets walked tally sits under the map controls until stage 4's Stats screen — cost if wrong: moved in stage 4

## Deferred minor findings

- A 15 m reach credits a road beside a cycle path when cycling counts; under bridges likewise (shortcut comments)
- Unnamed path fragments each count as a street (as CityStrides does)
- Coverage is recomputed fully after each run that matched or fetched (open or charging only)
- Not verified on the phone: modes, matching and coverage on real data
