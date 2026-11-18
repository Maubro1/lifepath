# Stage 7: honest transit, steady map, real heat

Owner requests of 18 November 2026 after using v0.8.0, with the research behind each answer.

## 1. Travel modes become internal

**Request.** The current technique cannot reliably tell modes apart; the owner does not need modes in lines or stats.

**Design.** Modes stay as an internal signal (fog width, which network a trip is snapped to, streets-walked rules) and leave the interface: no "colour by mode", no mode bar in You, no mode squares in the day story (trips read "Trip · 14 min · 6,1 km", walks "Walk"). A vehicle stretch is classified once as a whole, after the 30 s windows, from:
- **Top speed**: the 95th percentile of its speeds, not the mean. Research uses the 95th percentile because a single maximum is a glitch and a mean is dragged down by traffic lights and stations ([Dabiri 2018](https://vtechworks.lib.vt.edu/bitstream/10919/86845/1/Dabiri_S_T_2018.pdf), [TKDE 2020](https://dmkd.cs.vt.edu/papers/TKDE20.pdf)).
- **Signal**: the share of rough fixes and the median accuracy. Cars, buses and trains are metal boxes; a train is the strongest Faraday cage, a car the weakest.
- **Route evidence** (section 3), which overrides speed when it is clear.

## 2. Look, checked by eye

**Rounded corners**: 12 pt cards, 22 pt floating panels, continuous corners (`.rect(cornerRadius:style: .continuous)`), map controls in the system's glass material. Palette and Bricolage stay.

**A visual check that runs without a Mac.** The app gets a demo mode (`-demo` launch argument): a generated diary of a week in Utrecht (walks, a train, a bus, places) and recording off. CI builds for the iOS Simulator, launches each screen in light and dark (`-screen map|fog|heat|you|day|settings`, `-appearance light|dark`), captures `xcrun simctl io booted screenshot`, and pushes the PNGs to a `screens` branch. I fetch that branch and look at every screen before a release. These are real iOS renders, not a mock-up.

**UX walk-through.** Every screen is checked against what someone actually does: glance at today, see progress, explore the map, look back at a day, change a setting. Anything not needed for those goes.

## 3. Trains, trams, metros and buses snap to their route

**Request.** A trip that keeps following one railway and starts and ends at stations is a train; snap it to the railway. Same for tram, metro and bus. Worldwide.

**Design.** OpenStreetMap public-transport route relations (`route=train|subway|light_rail|tram|bus`) carry, for every line in the world, its stops in order and its track. A vehicle stretch whose start and end each lie near a stop (rail 150 m, tram and metro 80 m, bus 40 m) that are members of the **same route relation, in travel order**, and whose fixes mostly lie near that route's track, is that route. It is drawn as the route's track between those two stops, replacing the recorded line. Without a route match the line keeps its street or rail matching. This uses the PT schema's ordered stop lists ([OSM PT schema notes](https://wiki.openstreetmap.org/wiki/Bus_routes_in_Montr%C3%A9al)) and the stop-sequence matching idea from GTFS work ([AGILE 2016](https://agile-gi.eu/images/conferences/2016/documents/shortpapers/164_Paper_in_PDF.pdf)).

**Data, worldwide and light.** Per street tile a light index request (`rel[route~...](bbox); out body;`: relation ids, tags and member ids, no shapes), then each relation's track once by id, exactly as borders. Overpass covers the whole planet; nothing is Dutch-specific. Only tile rectangles and relation ids leave the phone.

Metro: `route=subway` with `railway=station` plus `station=subway`. Tram: `route=tram`. Bus: `route=bus` (bus stops already stored).

## 4. Standing still is not stopping

**Request.** A few minutes standing somewhere must not pause tracking or leave gaps.

**In v0.8.0** tracking went still after 2 minutes inside a 20–100 m fence (6 after a vehicle). **Design.** 5 minutes on foot and 10 after a vehicle (traffic lights, platforms, queues), the common 50 m / 300 s stay-point setting from the literature ([stay-point guide](https://spatiotemporalmovement-com.pages.dev/movement-pattern-extraction-trajectory-analysis/stay-point-detection-algorithms/), [stopdetection](https://search.r-project.org/CRAN/packages/stopdetection/index.html)). While settling, GPS keeps running at the settled accuracy, so a resumed walk has no gap. A known place (home, work) still settles at 2 minutes, because there the stop is expected.

## 5. Fog you can see through, lines that hold still

**Fog** is paper at 82% opacity, so streets and water show faintly through it. Cleared bands keep their soft edge.

**Panning lag** comes from each tile converting every coordinate of every stroke and testing every item. Items now keep their map points from load time and sit in a grid index (1/4096 of the world per cell); a tile draws only its cells' items.

**Lines that keep changing** come from simplifying per zoom level (a new tolerance each zoom gives a new shape) and from switching between point data and the line cache by zoom. Lines are now simplified **once**: Visvalingam–Whyatt gives each vertex the area at which it would be dropped; a tile draws a vertex only if its area is above one screen pixel² at that zoom. The vertex set only shrinks as you zoom out, so lines never jump between shapes ([progressive simplification, Buchin et al.](https://conference.imp.fu-berlin.de/eurocg18/download/paper_13.pdf), [Bostock](https://gist.github.com/mbostock/6245977)). The line cache keeps far more detail (3 m instead of 15 m), and the map uses one source at every zoom.

## 6. Heat that follows your lines

**Request.** No blocks; follow the shape of the lines with natural gradients.

**Design.** The Strava method: lines are rasterised as paths into a density image per tile, softened, then coloured through a ramp ([Strava engineering](https://medium.com/strava-engineering/the-global-heatmap-now-6x-hotter-23fc01d301de), [FlowingData](https://flowingdata.com/2017/11/21/global-cycling-and-running-heatmap)). Each trip adds a soft line (a wide faint stroke under a narrow brighter one) to a grey density buffer; places add a glow by time spent there. Density maps through `1 − e^(−k·n)` so a tile needs no global maximum, then through the warm ramp: transparent → mustard → satsuma → cherry → near-white core for the most-walked routes. Tiles are drawn once per zoom and kept.

## 7. The map screen, rethought

What someone wants on the map: where they are, today's line, how far along they are, and a way to switch what the map shows. Everything else can wait one tap.

- **Top left**: the place chip (rounded capsule, glass), unchanged in role.
- **Top right**: one glass column with layers, locate and compass.
- **Bottom**: one floating glass panel, 22 pt corners, two rows:
  - **Streets · Fog · Heat**: three ways to see your life on the map (what you walked, where you have been, where you go most), as a segmented control with icons.
  - **Today**: "3,2 km · 4.120 steps · +2 new streets", tap for today's page.
- **Layers sheet** keeps the rare choices: which of your lines show (Today default … All, Off), lines in one colour or by age, standard or satellite.

Heat moves from a toggle to a map mode; the period chip moves into Layers.

## Testing

Core: the stretch classifier (top speed, signal, route evidence), route matching between ordered stops, the settle times, Visvalingam importances and the heat ramp. Visual: the simulator screenshots, light and dark, every screen, inspected before release.

## Out of scope

Route suggestions, widgets, sharing, iPad.
