# Stage 5 decisions

Decisions taken on the owner's behalf while building export, backup and restore, with what each costs if wrong. Open questions are in handoff/STATE.md.

- Ruling: a restore only adds, never replaces: one transaction with INSERT OR IGNORE; where both have the same point, this diary's copy stays; a copy of the current diary (`before-import.lifepath`) is saved first, and nothing is merged if that fails — cost if wrong: none
- Ruling: a backup from a newer app version is refused (in the preview and in the merge itself); update the app first — cost if wrong: one extra step
- Ruling: on a fresh install the backup's map, places and days come over ready; otherwise caches rebuild while the app is open, and only when the merge added points — cost if wrong: none
- Ruling: places are taken from a backup only when this diary has none yet (see question 6) — cost if wrong: a few place names to retype
- Ruling: the 14-day diagnostic log is not imported — cost if wrong: none
- Ruling: exports (GPX, GeoJSON, KML) hold trips as recorded, streamed a month at a time; rough train positions are left out and the line breaks there (see question 7); gaps stay breaks — cost if wrong: re-export later
- Ruling: recording keeps working during a merge (points held in memory, flushed after) — cost if wrong: none

## Deferred minor findings

- A position-based place rewind during a merge is skipped (shortcut comment): a visit may be missed
- Not verified on the phone: restore from Files and iCloud Drive, export sharing
