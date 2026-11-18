# Stage 7 decisions: honest transit, steady map, real heat

Spec: `docs/superpowers/specs/2026-11-18-stage-7-design.md`. Plan: `docs/superpowers/plans/2026-11-18-stage-7.md`. Evidence: `reports/LifePath stage 7 techniques.md`.

## Stops
- The first 15 minutes of a stop away from a known place check back every 15 s and wake on 15 steps. A wander-return does not restart that window, so a long stay is not checked every 15 s all day.
- Indoor stops without any fix keep the slower checks: there is no GPS to check with.
- At a known place, and after the first 15 minutes, the old step backoff applies (it keeps a big home from tracking every walk to the kitchen).

## Lines
- The trip-line cache holds each finished trip snapped to its streets, rails and transit routes at 3 m detail; the map draws only that source for finished trips, at every zoom.
- Visvalingam areas are computed per load from the cached coordinates (same input, same result) rather than stored.
- Lines are drawn as uniform Catmull–Rom curves through the kept vertices.
- Past the 400,000-vertex load budget the loader still thins by Douglas–Peucker; one person's data rarely gets there.

## Fog and heat
- Fog opacity 82%, applied inside the draw call; grid index for fog only (streets and lines keep their rect test).
- Heat is a map mode. Its scale is the busiest cell in the loaded region at the loading zoom, so brightness can shift slightly between regions.

## Modes
- `vehicle` is a new internal mode for rides with no confident kind. Modes never appear in the interface; lines are one colour or by age; the You tab's period picker went with the mode bar it served.

## Transit
- Route snaps are stored as matched stretches on way id = −relation id; `Diary.ways(ids:)` returns the route's track for those, so every consumer draws them and cache rebuilds keep them.
- Two lines on one track with similar slices: the first is used (they draw the same).
- One geometry request per tile for all new routes; a timeout in a large bus city skips routes for that run.

## Look
- The bottom panel is a floating glass panel, not a sheet: a sheet would cover the tab bar.
