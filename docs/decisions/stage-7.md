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
- Fog is warm paper mist (light F1ECE2, dark 4A443C) at 80% opacity, applied inside the draw call; the owner picked it from three looks. Grid index for fog only (streets and lines keep their rect test).
- Heat is a map mode and cumulative: full colour needs at least 40 passes (more when the busiest cell in view has more), so one walk is a faint mustard trace. The owner rejected a scale relative to the busiest cell alone: in a young diary one walk saturated it. Lines are 8 points wide before a triple blur; the blur's spread is divided out so a count stays a true pass count.

## Modes
- `vehicle` is a new internal mode for rides with no confident kind. Modes never appear in the interface; lines are one colour or by age; the You tab's period picker went with the mode bar it served.

## Transit
- Route snaps are stored as matched stretches on way id = −relation id; `Diary.ways(ids:)` returns the route's track for those, so every consumer draws them and cache rebuilds keep them.
- Two lines on one track with similar slices: the first is used (they draw the same).
- Pieces of a ride are linked (`Transit.link`), rail and tram only: one route between two stations, ends settled by a walk or a 30 s dwell (a station passed at speed is no end, also for a piece the trip snapped alone), no stay or walk over 2 min between, gaps passable at 320 km/h, under 3 h apart. One run of joined pieces at a time, with only the routes around it. Each piece carries `lead` and `tail`: the last precise fix before it and the first after it (up to 90 min, never past another ride of the trip), because waiting on the platform records nothing new and the ride's own end fixes are rough and late. Single rides go through the same check. Each trip stores its share of the track, running on across the gap; the street run looks back 3 h.
- One geometry request per tile for all new routes; a timeout in a large bus city skips routes for that run.

## Look
- The bottom panel is a floating glass panel, not a sheet: a sheet would cover the tab bar.
- One card radius, 22 points continuous, as the glass panel and the system lists; thumbnails inside padded cards keep 12. Status colours come from the palette (olive, cherry), never system green and red.
- Days can be deleted from a day page or from Settings (a period); places left without visits go too, and street coverage is rebuilt.
