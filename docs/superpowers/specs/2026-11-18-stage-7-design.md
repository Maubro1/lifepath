# Stage 7: honest transit, steady map, real heat

Owner requests of 18 November 2026 after using v0.8.0. Evidence: `reports/LifePath stage 7 techniques.md` (six researched sections, notes in `research_notes/LifePath stage 7 techniques/`).

## 1. Travel modes become internal

Modes leave the interface: no colour by mode, no mode bar in You, no mode squares in the day story (trips read "Trip · 14 min · 6,1 km", walks "Walk"). They stay as an internal signal for fog width, the network a trip is snapped to, and the streets-walked rules.

**How a trip is classified** (report §1):
1. **Cut at walking.** Points below 1.8 m/s and 0.6 m/s² are possible walk points; the start and end of each walk run are the candidate mode changes (Geolife). Car, bus and bike are followed by walking 95–98% of the time, so a vehicle-to-vehicle change without walking in between is penalised.
2. **Gate by P95 speed**, the owner's top-speed idea in its robust form: the 95th percentile, never the maximum (a maximum is one GPS spike; Geolife measured raw top speed as among the weakest features). Below ~8 km/h walk; ~8–35 km/h with CoreMotion cycling and a low stop rate bike; above ~35 km/h motorised. Starting values, tuned on the owner's own days.
3. **Motorised pieces are decided by the map**, which adds about 17 points of accuracy over GPS alone (Stenneth): a fit to a rail, metro or tram route between two stations is that mode (section 3); dwells at mapped bus stops plus a bus-route fit is bus; anything else on roads is car. Stop rate, heading-change rate and speed-change rate (Geolife's strongest features) and CoreMotion's activity feed the score.
4. **Signal loss is a soft hint with a check** (the owner's Faraday-cage idea; physically sound, metallised train glazing costs 20–30 dB, but iOS hides signal strength and no study measured it on phones): a fix gap counts toward train or metro only when both ends are near mapped stations and the speed across the gap fits rail. A gap without stations is a tunnel or a building.
5. **When nothing clearly wins, the piece is "motorised"**, never a guess (LocoKit's practice).

## 2. Look, checked by eye

Rounded, continuous corners: 12 pt cards, 22 pt floating panels concentric with the screen. Map controls are one group of system glass buttons; the bottom panel is a system sheet with a partial detent so the map shows through (iOS 26 Liquid Glass guidance: glass is one thin layer, never stacked, no custom sheet backgrounds). Palette and Bricolage stay. Every glass element is checked with Reduce Transparency and Increase Contrast.

**Visual check.** The app has a demo mode (`-demo`, a generated week in a grid town near Utrecht, nothing recorded). CI builds for the iOS Simulator for commits marked `[screens]`, opens each screen in light and dark (`-screen streets|fog|heat|you|day|settings`), takes `xcrun simctl io` screenshots and pushes them to the `screens` branch. Every UI change is looked at there before release.

**UX walk-through.** Each screen is checked against what someone does: glance at the day, see progress, explore the map, look back at a day, change a setting, back up. Anything not serving those goes.

## 3. Trains, metros, trams and buses snap to their route

OpenStreetMap route relations (`route=train|subway|light_rail|tram|bus|ferry`) hold, for lines worldwide, their stops in order and their track (report §2).

**Matching.** For a motorised piece: find stations or stops near its first and last fixes (rail 150 m, metro and tram 80 m, bus 40 m); keep route relations that list the boarding stop **before** the alighting stop (this also settles direction); check that the fixes lie near the relation's track between them; where several lines share the track, prefer the one whose intermediate stops the trip passed; if still tied, use the plain railway geometry. The piece is then drawn as the relation's track between the two stops. Across a total signal gap (metro), the path is the track between the stations on either side, timed by distance. With no relation match, rail-like pieces fall back to the existing matching on railway ways. The idea follows pfaedle (most matched paths within 20 m), reimplemented, since its code is GPL.

**Data, worldwide.** Per street tile, a light index request (relation ids, tags and member ids, no shapes); each chosen relation's geometry once by id; both cached permanently. Only tile rectangles and relation ids leave the phone. Overpass fair use (about 10,000 requests a day) is respected by the same backoff as streets.

## 4. Short waits never leave gaps

LifePath never uses iOS's automatic pause and keeps its location session alive. Two thresholds (report §3, after Arc's LocoKit2):
- **Power stop** after 2 minutes inside a 20–100 m circle: precise GPS goes off, but for the first 15 minutes it checks back every 15 seconds (instead of waiting for 15–150 steps), and wakes on the first 15 steps without the step backoff. A traffic light never reaches the stop; a platform wait costs at most seconds of track.
- **Diary stop** (a visit in the timeline) needs 10 minutes, so platforms, bus stops and crossings never become places.

On departure the first stretch, from the stop to the first moving fix, starts at the moment CoreMotion's history says walking began, and is drawn as inferred.

## 5. Fog you can see through, lines that hold still

**Fog** is paper at 82% opacity, applied inside the drawing (`context.setAlpha`), never through the renderer's `alpha`, which stalled tiles for 38 s on iOS 18. Cleared bands keep a soft edge and a 2 pt minimum width.

**No lag.** Items keep their map points from load time and sit in a grid index; a tile draws only its cells' items. One custom renderer per layer, as Apple recommends; no tile overlays (reported flicker on iOS 15–18).

**Lines that never change shape.** Visvalingam–Whyatt gives each vertex, once, the area at which it would be dropped (monotone: at least the area of the vertex removed before it). A tile keeps vertices whose area exceeds one screen pixel² at its zoom; the kept set only shrinks as you zoom out, so a line never jumps between shapes. Importances are computed once per trip when its line is cached; trip ends are always kept. The cache keeps 3 m of detail instead of 15 m; the map uses that one source at every zoom. Lines are drawn as centripetal Catmull-Rom curves through the kept vertices.

## 6. Heat that follows your lines

Strava's method on one person's data (report §4): trip lines are stroked additively into a low-resolution density buffer per tile (a quarter of the tile per side, with a margin into the neighbours), blurred once, mapped through `log(1 + n)` scaled by the true maximum density of the whole diary at that zoom (computed once per data change, so tiles never show seams), and coloured through a 256-entry ramp: transparent → mustard → satsuma → cherry → a light core on the most-walked routes. Places add a soft glow by time spent.

## 7. The map screen

Full-bleed map in Apple's muted style, so LifePath's layers carry the colour.
- **Top left**: the place chip, "Science Park · 64%", with the rule stated in its card ("212 of 331 streets walked, a street counts at 90% of its length").
- **Top right**: one glass group with layers, locate and compass.
- **Bottom**: a system sheet with a small detent: **Streets · Fog · Heat** as a segmented control with icons, and today's line ("3,2 km · 4.120 steps · +2 new streets"); pulled up, it shows today's page.
- **Layers** holds the rare choices: which of your lines show (Today default … All, Off), one colour or by age, standard or satellite.

No streaks or badges (they backfire in the studies). Backup stays visible in You with its reminder, since data loss on a new phone is the top complaint about Fog of World.

## Testing

Core: walk segmentation, the P95 gates and the motorised fallback, route matching between ordered stops (direction, shared track, signal gap), the power-stop and diary-stop thresholds, Visvalingam importances (nested vertex sets), the heat ramp. Visual: the simulator screenshots in light and dark for every screen, inspected before release. On the phone: the owner's health reports, especially platform waits and train rides.

## Out of scope

Route suggestions, widgets, sharing, iPad, timetable data (GTFS).
