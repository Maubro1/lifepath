# Snapping recorded public-transport trips to OSM route geometry (worldwide, on-device, Overpass)

## 1. OSM public transport schema and its global completeness

### Takeaway
PTv2 route relations (type=route, route=train/subway/light_rail/tram/bus/trolleybus/ferry/monorail) with ordered stop/platform members followed by ordered ways are the intended data source, and their quality is uneven worldwide. Treat relations as a strong prior that must be validated, with a fallback to the raw railway/highway network.

### Cited Findings
- Route relations carry `type=route` and `route=` one of train, subway, monorail, tram, bus, trolleybus, ferry. `light_rail` is in use though not in the 2010 proposal. Each direction and each variant gets its own relation, no forks. Recommended tags: ref, from, to, via, operator, network, colour, `public_transport:version=2` — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- Member order: stop_position 1, platform 1, stop_position 2, platform 2, ..., then the ways from start to terminus. Roles `stop`, `platform`; `hail_and_ride` for request-boarding sections — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- Roles `stop_entry_only`, `stop_exit_only` and platform variants exist: PTv2 roles begin with "stop" or "platform" — [OSM community forum thread (German) via search](https://community.openstreetmap.org/t/buslinien-via-overpass-in-bereich-finden/107831) (secondary; the wiki pages I could read did not mention stop_entry_only)
- stop_area relation: `type=public_transport` + `public_transport=stop_area`, groups stop_position/platform/station of one stop; stop_area_group exists above it — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- Stop tagging: bus = `highway=bus_stop` + `public_transport=platform` + `public_transport=stop_position` with `bus=yes`; rail = `railway=station`/`halt` once per station, stop_position `railway=stop` + `train=yes`, `railway=platform`; metro stations also `station=subway`; tram = `railway=tram_stop` with `tram=yes` — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- route_master: `type=route_master`, `route_master=<mode>`, members only route relations with empty roles; common tags only; must not join different lines of a network — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- Few or no maps render stop_position nodes, so they are often missing or wrong in practice — [OSM wiki Public_transport](https://wiki.openstreetmap.org/wiki/Public_transport)
- Order matters; iD auto-sorts but can fail after splitting ways in routes that fork, loop or double back. Common mistakes: wrong roles (`forward`/`backward` on PTv2, `route` role instead of empty), a way added twice, ways shared between routes handled inconsistently — [OSM wiki Relation:route](https://wiki.openstreetmap.org/wiki/Relation:route)
- Completeness is heterogeneous; the HeiGIT/AGIT 2021 paper (Fritz, Auer, Zipf) estimates bus route completeness globally from demographics calibrated with open GTFS, results in the ohsome History Explorer — [search summary of AGIT 2021 paper](https://gispoint.de/fileadmin/user_upload/paper_gis_open/AGIT_2021/537707025.pdf)
- Quality tooling exists (PTNA daily analysis, JOSM PT Assistant, Osmose); PTNA flags relations without platform members as incomplete — [OSM wiki Public_transport/Quality_Assurance](https://wiki.openstreetmap.org/wiki/Public_transport/Quality_Assurance)
- Example of uneven coverage: Glasgow bus relations "need a lot of work" — [OSM wiki Glasgow/PublicTransport](https://wiki.openstreetmap.org/Glasgow/PublicTransport)

### Inferences
- Europe (esp. Germany, Netherlands, Switzerland, Austria, where PTNA communities exist) likely has the best relation coverage; US bus data likely thinnest, with agencies' GTFS the real source (not verified; no source found with numbers). Rail/metro/tram relations are far more complete than bus relations everywhere.
- Robust parsing must not assume member order or presence of stops: use the member ways as an unordered set, plus stops as an ordered hint, and sort ways by connectivity yourself.
- Long-distance coaches (FlixBus etc.) are rarely mapped; an unmatched bus trip should fall back to the highway network or raw trace.

### Gaps
- No per-region completeness figures (Europe vs US vs Asia) found. The ohsomeHeX layer would answer it.
- Could not confirm bus-coach pitfalls from a source.

## 2. Efficient Overpass usage

### Takeaway
Use a bbox-limited index query (`out tags`/`out bb`, no geometry), then fetch `out geom` once per chosen relation id and cache it forever. Stay far under the fair-use ceiling; the practical risk is 429/504 throttling, so retry with backoff and allow mirrors.

### Cited Findings
- Fair use: about 10,000 requests/day and under 1 GB/day; Overpass users identified by IP; slots with cool-down; requests wait up to 15 s for a slot; 429 when denied, 504 when resources cannot be admitted; defaults timeout 180 s, maxsize 512 MiB; check `https://overpass-api.de/api/status` — [Overpass API User's Manual, commons](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html)
- Wiki: if an application uses it regularly, divide those numbers by 100; limits count per application — [OSM wiki Overpass API via search](https://wiki.openstreetmap.org/wiki/Overpass_API) (secondary summary; I did not read the page itself). Older sources said 5 GB/day; outdated. The "1-2 concurrent/IP" figures from third-party sites are unverified.
- Out modes: `ids`, `skel`, `body` (default), `tags` (ids + tags, no coords/members), `meta`; modifiers `geom` (adds coordinates to way/relation members), `bb`, `center`; `qt` sort is faster — [Overpass QL wiki](https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_QL)
- Recursion: `>` down, `>>` transitive down, `<` up; `[bbox:s,w,n,e]` is south,west,north,east; the page recommends bbox over `around` for speed; ways/relations may extend beyond the bbox — [Overpass QL wiki](https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_QL)
- Typical bbox example: `relation["route"="bus"]` in bbox, then recursion and output; stops/platforms in the same query via stop_position/platform filters — [OSM help example](https://help.openstreetmap.org/questions/50752/how-do-i-get-route_master-and-its-children-via-overpass-ql-in-overpass-turbo), [OSM community thread](https://community.openstreetmap.org/t/buslinien-via-overpass-in-bereich-finden/107831)

### Inferences (recipe, not directly sourced; verify with a test query)
- Step A (index, per tile/bbox, cached by tile): `[out:json][timeout:60][bbox:S,W,N,E]; (relation["type"="route"]["route"~"^(train|subway|light_rail|tram|monorail|ferry|bus|trolleybus)$"];); out tags bb;` Gives id, ref, from/to/name/network/operator, bbox only, without members. Add stations: `(nwr["railway"~"^(station|halt|tram_stop)$"]; nwr["public_transport"="stop_position"]; nwr["amenity"="ferry_terminal"];); out tags center;` (add bus stops only for bus trips).
- Step B (per chosen relation id, once, cached): `[out:json]; rel(id); out geom;` returns member coordinates; ordered members and stop nodes with roles included. Alternatively `rel(id); out body; >; out skel qt;`.
- Use the trace's bbox expanded by ~200 m (or per-stop `around` for small radii), not whole-city. Restrict mode by the detected mode of the trace (rail/metro/tram first).
- Order of magnitude (my guess): a tram or metro line = tens of KB; a large-city bus network index with tags only is hundreds of relations; do not fetch bus `out geom` for all of them. No source found for sizes.
- Cache keys: tile id (e.g., z12) for index, relation id for geometry; store relation `version`/timestamp is not needed for personal use. Privacy: only bbox and relation ids leave the phone. Use `kumi.systems`/other public mirrors on 429 (mirror availability not verified).

### Gaps
- Real response sizes and typical latency for Amsterdam/London/Tokyo-size bbox queries not measured. A short live test would settle this.
- Exact behavior of `out geom` on relation member nodes (stops) not read from the doc; the doc says geom adds coordinates to nodes of ways and relations.

## 3. Matching methods (trace to line between two stops)

### Takeaway
Do a two-stage match: (1) identify candidate lines by stops called at and spatial fit to the route polyline, (2) replace the trace by the sub-path of the relation geometry between the board and alight stops. Use HMM (Newson-Krumm style) restricted to the route/rail graph only for track choice when relations are missing. pfaedle shows the HMM on OSM rail graphs is accurate and uses route relations as a cost bonus.

### Cited Findings
- Newson & Krumm 2009: HMM that models GPS noise (emission) and road connectivity (transition) to find the most likely road path from a time-stamped lat/lon sequence, evaluated with varied noise and sparseness — [Microsoft Research](https://www.microsoft.com/research/publication/hidden-markov-map-matching-noise-sparseness/)
- Bast & Brosi 2018 (pfaedle): HMM that maps a sequence of stations onto the transit network; sample spacing may be hundreds of km, far sparser than the usual >30 s "sparse" in map matching; works on rail as well as roads; candidate nodes within a radius ri around each station; transitions are exponentially distributed over weighted features; turn restrictions (including between hops, and punishing 180° turns on open track) are modelled; falls back to a straight line if no path — [Sparse Map-Matching in Public Transit Networks with Turn Restrictions](https://ad-publications.informatik.uni-freiburg.de/SIGSPATIAL_Sparse%20map%20matching%202018.pdf)
- Same paper: OSM route relations are used by adding transition cost equal to the length of network segments with no matching route relation; station nodes and name similarity (token-subset edit distance) are used in emission probabilities; separate weights per mode (rail, subway, tram, bus; bus penalises higher road classes) — same PDF
- Same paper results: most paths deviate under 20 m from ground truth; adding OSM metadata gave only minor improvement over plain HMM; for trains simple baselines also work well because station candidate counts are small; runtime on an i7-2600: bus networks seconds to tens of minutes per feed, tram/subway milliseconds to seconds — same PDF
- pfaedle: open source, GPL-3.0, OSM XML/PBF input, `-X` filters OSM to the feed; generated shapes derive from OSM under ODbL and require OSM credit — [pfaedle GitHub](https://github.com/ad-freiburg/pfaedle). (GPL-3.0 matters if code is copied into an iOS app; reimplement the idea instead.)
- PublicTransitSnapper (Freiburg bachelor thesis 2022): live GPS matched to transit trips with GTFS + time; HMM on GTFS shape graph; accuracy over 90% on Freiburg and Zurich, lower where trams and buses share streets or two trips run the same stops at the same time; baselines that ignore time are bad because many trips share a shape; delays hurt — [Robin Wu thesis](https://ad-publications.informatik.uni-freiburg.de/theses/Bachelor_Robin_Wu_2022.pdf)
- Transit app uses a phone motion-sensor approach to estimate position underground, starting from the last GPS fix and the schedule — [search summary, third-party](https://www.producthunt.com/p/transit-bus-subway-times/go-underground) (weak source)

### Inferences (proposed recipe)
1. Detect a transit segment (speed profile, mode classifier, stops at station nodes). Take the first and last good fixes as board/alight.
2. Candidate stops: stations/stop_positions within ~150-300 m of the first/last fix (wider for rail stations with large footprints, since GPS drifts in stations).
3. Candidate relations: those from the index with bbox containing both fixes, whose member stops include a board stop before an alight stop in member order (directionality resolves opposite direction). This is the "choose by stops called at" rule for shared corridors; if several lines remain (same track, same stops), prefer the one whose intermediate stops match dwell/slow points in the trace, then the nearest timing; if still ambiguous, show the line group or generic rail geometry rather than guessing.
4. Fit check: mean/95th-percentile distance of the trace points to the relation polyline between the two stops, e.g. median below ~50 m (bus ~30 m on road) with a few outliers allowed; compute using projection onto the polyline and monotonic progress along it (to reject opposite-direction lines).
5. Gaps: if signal is lost (metro, tunnel), do not interpolate in a straight line; the stops before and after the gap pin the sub-path; the relation geometry between them is the track. The time gap can be distributed by distance along the path.
6. Replace: output polyline = relation geometry slice from the projection of board to alight, with the stops as waypoints. Keep raw trace separately.
7. Fallback when no relation matches: restricted HMM over `railway=rail|subway|light_rail|tram` ways (service=* ignored, usage=main/branch preferred) near the trace; for ferry use route=ferry relation or straight line; for bus keep raw or snap to highway ways.
8. Weighted rail graph with turn penalties from pfaedle is the safe pattern; for a phone, a simple Viterbi over candidate ways in a corridor is enough.

### Gaps
- Exact thresholds above are my suggestions; no source validates them. Test on the owner's own traces.
- Valhalla/OSRM transit matching and Google/Apple approaches: no reliable source found (not covered here).

## 4. How apps present past transit trips

### Takeaway
No reliable public documentation found. Google Timeline mainly gives mode summaries; Transit app uses schedule plus motion sensing live.

### Cited Findings
- Google Maps Timeline Insights shows mode breakdown (car, bike, walking, transit), not route-level snapping details — [9to5Google](https://9to5google.com/2021/07/21/google-maps-timeline-insights/)
- Transit app's underground location uses motion sensors and schedule from the last GPS fix — [Product Hunt summary](https://www.producthunt.com/p/transit-bus-subway-times/go-underground) (weak)

### Inferences
- Not sourced: I would expect these apps to show transit legs as straight or snapped lines between stations, with stop names, rather than raw noise.

### Gaps
- Arc Timeline, Citymapper, Google Timeline snapping behaviour not found in any source. Needs hands-on testing or vendor docs.

## 5. Alternatives to relations: railway ways and GTFS

### Takeaway
Raw railway ways (+ HMM) are a universal fallback; GTFS shapes are accurate but need per-feed download, are often missing, have per-feed licences, and are too large to ship on-device; pfaedle-style generation uses OSM anyway.

### Cited Findings
- GTFS `shapes.txt` is optional; most feeds in the thesis lacked it; pfaedle exists to generate it from OSM — [Wu thesis](https://ad-publications.informatik.uni-freiburg.de/theses/Bachelor_Robin_Wu_2022.pdf), [pfaedle GitHub](https://github.com/ad-freiburg/pfaedle)
- Transitland licences are per feed (listed in DMFR records); Transitland Atlas feed catalog is CC-BY; Mobility Database catalogs thousands of feeds; counts not stated — [Transitland feeds docs](https://transit.land/documentation/datastore/feeds.html), [MobilityData catalogs](https://github.com/MobilityData/mobility-database-catalogs)
- Using pfaedle-style output derived from OSM requires crediting OpenStreetMap (ODbL) — [pfaedle GitHub](https://github.com/ad-freiburg/pfaedle)

### Inferences
- GTFS needs fetching whole zip feeds (agency-wide, MBs) from third-party servers, which reveals the region, and licences differ, so for a €0 privacy-preserving app Overpass relations plus raw railway ways are the better default; GTFS shapes are an optional enrichment, not a dependency.
- OSM data used on device must credit "(c) OpenStreetMap contributors" (ODbL); caching derived route geometries is fine for personal use.

### Gaps
- Per-feed shapes.txt coverage percentage, shapes size, and railway `usage`/`service` tag usage statistics not found.
