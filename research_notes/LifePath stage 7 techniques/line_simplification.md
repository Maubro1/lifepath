# Line simplification and smoothing for years of GPS tracks (iPhone, Swift)

Scope note: about 10 searches/fetches, mostly search snippets plus two page fetches (Bostock, mapshaper). The primary papers (Visvalingam-Whyatt 1993, Saalfeld 1999) were NOT read in full.

## 1. Zoom-stable (progressive) simplification: which gives monotone vertex sets?

### Takeaway
Visvalingam-Whyatt (VW) with a stored per-vertex "effective area", made monotone by taking the max with the last removed area, gives exactly nested vertex sets: pick a cutoff, keep vertices with area >= cutoff. Douglas-Peucker (DP) can do the same only if per-vertex split tolerance from its recursion tree is stored, with caveats. Compute importance once, store it with the vertex, filter at render time; never re-simplify on data load.

### Cited Findings
- VW: a point's effective area is the triangle area it forms with its two neighbours; the smallest is removed first and neighbours recomputed. — [Hull repository / Visvalingam](https://hull-repository.worktribe.com/output/376330)
- Bostock: to keep values monotone, the algorithm uses the larger of the point's own triangle and the last removed triangle's area, so the stored value never drops below an earlier removal's. Effective area can be stored in the geometry (e.g. as z) and the renderer drops points below a cutoff instead of re-simplifying; works even if the algorithm ran server-side. Removing 95%+ of points often keeps enough detail (US outline 531KB to 27KB). He does not cover topology there. — [Bostock, Line Simplification](https://bost.ocks.org/mike/simplify/)
- TopoJSON `presimplify` attaches importance (default planar triangle area; pass spherical area for lon/lat) so clients can drop points below a threshold at render time. CLI advice: threshold should be less than per-pixel area of the map; a 2016 walkthrough used 1 square pixel after projection. — [TopoJSON 1.x CLI reference](https://github.com/topojson/topojson-1.x-api-reference/blob/master/Command-Line-Reference.md), [Command-Line Cartography 3](https://medium.com/@mbostock/command-line-cartography-part-3-1158e4c55a1e)
- PostGIS ST_SetEffectiveArea stores VW effective area per vertex (M value) without dropping, for later filtering (secondary source, treat cautiously). — [atlas.co PostGIS](https://atlas.co/functions/postgis/st-simplify-vw/)
- mapshaper default is "weighted Visvalingam" (down-weights sharp angles; fewer spikes). DP "at high simplification tends to produce visible spikes". With VW, `interval=` approximates the size of the smallest remaining detail; with DP it is max deviation. — [mapshaper simplification guide](https://mapshaper.org/docs/guides/simplification.html)
- Visvalingam's own review: mapshaper's variants differ from the original; ties among equal effective areas are chosen arbitrarily; the weighted option was not intended for caricatural generalisation. — [Hull repository](https://hull-repository.worktribe.com/OutputFile/376364)
- DP recursion produces a binary tree hierarchy (Saalfeld 1999 studied it); it starts from the single first-last edge, and the plain hierarchy can self-intersect. — [Survey, arXiv cs/0209007](https://arxiv.org/pdf/cs/0209007), [Wu et al.](https://dca.fee.unicamp.br/projects/prosim_root/publications/congress/wu-roci-2003-rfm.pdf)
- Van der Poorten/Zhou/Jones: DP's hierarchical vertex ordering may not correspond to a monotonic change in threshold values, a problem for multi-scale hierarchies. — [Cardiff PDF](https://mysite.cs.cf.ac.uk/C.B.Jones/articles/vanderPoortenGIScience02.pdf)
- A GPU LOD-for-2D-polygons paper says its scheme works with any algorithm that removes vertices sequentially (DP, VW). — [UZH LOOPS](https://www.ifi.uzh.ch/dam/jcr:484e2332-8a47-4a43-8c7f-049cbd765803/LOOPS.pdf)

### Inferences
- For a "never changes shape" requirement, VW with monotone effective area is the cleanest: one number per vertex, nested sets by construction, deterministic if ties are broken by vertex index.
- A monotone DP variant: record at each split the distance of the farthest point, then set each vertex's value to min(own distance, parent's value) so thresholds nest. (My reasoning; no source describes exactly this.)
- Appending new GPS points changes the tail only if the algorithm is rerun on it; store tracks as immutable chunks (per day or trip) with values computed once, so reloading never changes old geometry. Chunk boundaries should be forced-keep vertices.

### Gaps
- Original VW 1993 and Saalfeld 1999 papers not read directly.
- No source found on stored DP split tolerance as an LOD scheme.

## 2. Topology, shape fidelity, tolerances per zoom, memory

### Takeaway
Tracks are mostly single lines, so topology reduces to avoiding self-crossings and preserving corners/switchbacks. Use a per-pixel threshold (about 0.5-1 px at the shown zoom) with weighted VW or DP, and check intersections.

### Cited Findings
- mapshaper `-simplify` detects intersections and rolls back simplification where they occur; its `resolution=` is estimated from the full data extent and can over-simplify. — [mapshaper guide](https://mapshaper.org/docs/guides/simplification.html)
- Saalfeld's fix: keep refining segments where a self-intersection or side-flip occurs; Wu and Marquez: star-shaped polylines cannot self-intersect under DP. — [Wu 2004 DOI](https://www.doi.org/10.1590/S0104-65002004000100006)
- Tippecanoe: at every zoom, lines/polygons are DP-simplified to the resolution of the tile; tolerance keeps geometry within about one tile unit; `-d` detail at max zoom default 12 (4096 grid); `-ps` disables simplification, `-pS` only at low zooms. Felt: it replaced TopoJSON shared-border handling with a sorted list of never-simplified nodes. — [Tippecanoe README mirror](https://github.com/anandthakker/tippecanoe), [Felt blog](https://felt.com/blog/tippecanoe-polygons-shard-gaps)
- geojson-vt defaults: tolerance 3, extent 4096, buffer 64, maxZoom 17; tiles are simplified per zoom. — [npm geojson-vt](https://www.npmjs.com/package/geojson-vt)

### Inferences
- Pixel tolerance: VW threshold area about (0.5-1 px)^2 (Bostock: 1 px^2), or 0.5-1 px max deviation for DP. At max zoom keep everything (cutoff 0). Compute cutoff from current metres per pixel (with cos(lat) correction for Web Mercator), never from track extent (mapshaper pitfall).
- Memory (my arithmetic, not sourced): Int32 lat/lon (1e-7 deg) = 8 B plus Float32 importance = 4 B gives 12 B/vertex. 10M vertices is about 120 MB; keep full raw points on disk, and keep only vertices above the finest useful cutoff (often 5-20%) in the render path.

### Gaps
- No published pixel-tolerance-per-zoom standard beyond tippecanoe/geojson-vt defaults and Bostock's 1 px^2.
- No source measuring corner/switchback fidelity of VW vs DP on GPS data.

## 3. Rendering-time selection: per-tile filtering vs LOD pyramid, caching

### Takeaway
Two proven designs: (a) per-vertex importance with a threshold filter at draw (Bostock/TopoJSON); (b) pre-cut per-zoom tiles (tippecanoe, geojson-vt). (a) is smaller and exactly nested; (b) is faster at scale but each zoom is its own simplification unless built from one importance ranking.

### Cited Findings
- See [Bostock](https://bost.ocks.org/mike/simplify/) for (a); [Tippecanoe](https://github.com/anandthakker/tippecanoe) and [geojson-vt](https://www.npmjs.com/package/geojson-vt) for (b). Tippecanoe's per-zoom simplification targets tile size and fidelity, not cross-zoom shape stability.

### Inferences
- Recommended: one importance value per vertex; discrete cutoff levels (one per integer zoom, 2x metres/pixel per step); cache the filtered index list per (chunk, level) in memory. Levels nest, so crossing a zoom only adds or removes vertices and nothing jumps. Cull by chunk bounding box first.
- Snap the cutoff to zoom-level steps rather than continuous pinch zoom, and rebuild only when the level changes.

### Gaps
- No iOS benchmark numbers (MapKit, MapLibre Native, Metal) found.

## 4. Smoothing vs simplification

### Takeaway
Smooth noise first on raw data with a corner-aware method, store the result, then compute importance once. For display curves, Catmull-Rom keeps vertices on the line; Chaikin shrinks corners.

### Cited Findings
- RTS smoother = Kalman forward pass plus backward pass using future observations (fixed-interval). — [pyehicle docs](https://pyehicle.readthedocs.io/en/latest/_modules/pyehicle/preprocessing/filtration.html), [Emergent Mind](https://www.emergentmind.com/topics/rauch-tung-striebel-smoother)
- Practitioner note: using course rather than heading in the motion model can overshoot corners. — [Notion post](https://williamgrand.notion.site/Smoothing-Trajectories-Using-Kalman-Filter-with-GPS-Doppler-Speed-Part-2-3a314d16bef480e096d3c0b11af0ff46) (low-quality source)
- Chaikin can shift boundaries inward and multiplies vertices (about 4x per iteration per the PostGIS page); Catmull-Rom interpolates (passes through originals), Chaikin approximates. — [PostGIS ST_ChaikinSmoothing](https://atlas.co/functions/postgis/st-chaikin-smoothing/), [Bill Mill notes](https://notes.billmill.org/programming/algorithms/Chaikin_s_corner-cutting_algorithm.html)
- Kalman then DP/sliding-window pipelines exist; none found measuring corner distortion. — [LACCEI 2021](https://laccei.org/LACCEI2021-VirtualEdition/full_papers/FP96.pdf)

### Inferences
- Use centripetal Catmull-Rom on the already-filtered visible vertices; every kept vertex stays exactly on the line, so corners remain where VW/DP kept them. Avoid Chaikin where turns matter.
- Before simplification do only light smoothing (RTS or speed-gated outlier removal); heavy smoothing rounds switchbacks. Keep raw separately.
- Importance is computed after smoothing, once, and never recomputed on style change.

### Gaps
- No evidence quantifying corner displacement from RTS then simplify.

## 5. How Strava, Apple Fitness, Google Timeline, GPX viewers store and draw

### Takeaway
Only Strava's API-level representation is documented: a lossy Google-encoded `summary_polyline` for overview plus per-sample streams for detail. Internal rendering for Strava/Apple/Google was not found.

### Cited Findings
- Strava activity/segment/route responses include `summary_polyline` (lower-res), Google polyline format; detailed polyline only in detailed route representation; per-second GPS in streams (needs approval). — [Strava API docs](https://developers.strava.com/docs), [openwearables guide](https://openwearables.io/blog/strava-api-developer-guide-activities-heart-rate-gps-data)
- Google's encoded polyline format is described as lossy compression. — [Google polyline algorithm](https://developers.google.com/maps/documentation/utilities/polylinealgorithm)

### Inferences
- Worth copying: a small always-loaded overview plus full detail on demand, which matches the importance-filtered design.

### Gaps
- Nothing found on Apple Fitness/Health route storage, Google Maps Timeline internals, or GPX viewer rendering; any claim would be speculation.
