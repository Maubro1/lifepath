# Stage 6 decisions: design

Spec: `docs/superpowers/specs/2026-11-17-stage-6-design.md`. Plan: `docs/superpowers/plans/2026-11-17-stage-6-design.md`.

## Taken with the owner
Map is the heart ("watch my map fill up"); Streets or Fog toggle; the owner's study-page look; two tabs (Map, You); progress per city and neighbourhood; fog 15 m on foot, 6 m in road vehicles, 25 m at places and stops; old lines stay full orange; compass and locate never overlap; appearance switch; Bricolage Grotesque bundled (owner approved the download).

## Made while building
- **Borders in two steps.** Per tile a light index (relation tags, place ways with shape), then each relation's shape once. A city outline is downloaded once, not once per tile.
- **Borders and progress are caches in their own tables** (`area`, `areaTile`, `areaProgress`, `streetCovered`). No change to the `tile` table, so backups made with v0.7 still restore; after a restore borders download again.
- **A neighbourhood** is the smallest admin area of level 9 to 11, or a `boundary=place` / `place=suburb|quarter|neighbourhood` area, inside the city; Dutch OSM tags wijken inconsistently, so all of these are read. A city without any counts as its own neighbourhood.
- **A street belongs** to the areas holding the middle of its longest way; it is counted once per area.
- **Fog** comes from the cached trip lines for all time plus the lines of the chosen period, so a walk clears the fog as soon as it is recorded.
- **Times along a trip line** are placed by distance at constant speed (trip lines store no times); mode edges are off by metres at most.
- **Drawing:** three overlays live as long as the map; content is swapped and only changed rects redraw. Items are filtered by rect per tile, without a grid index.
- **Not built:** the one-time 0.5 s fade-in of new fog and streets when the map opens. It would redraw every visible tile each frame, which costs battery and heat for a flourish.
- **Line colours:** "One colour" (satsuma) is the default; date runs mustard (newest) to cherry (oldest), never grey.

## Deferred minors
- Settings still shows the full status block; the You tab shows only the headline pill.
- City list in You is ordered by streets walked, not by the city you are in now.
