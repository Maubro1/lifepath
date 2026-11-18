# High-performance rendering of large personal track overlays on iOS (MapKit focus)

Note on evidence quality: official Apple docs are fetched directly. Apple forum threads were fetched and summarised. Strava's Medium posts returned HTTP 403, so Strava details below come from search-result summaries of the post and are flagged. Items marked "design suggestion" are my engineering inference, not sourced facts. Where I found nothing, it is under Gaps.

## MapKit options: MKOverlayRenderer, MKTileOverlay, MKMultiPolyline, SwiftUI Map

### Takeaway
A custom MKOverlayRenderer (draw(_:zoomScale:in:)) over ONE overlay is Apple's own recommended route for big, changing, custom-drawn data. Many separate MKPolyline overlays are the documented slow path, with MKMultiPolyline as Apple's own advice. MKTileOverlay for generated tiles works but has repeated, unresolved flicker reports from iOS 15 to iOS 18. SwiftUI Map gives no custom renderer, so stay on MKMapView.

### Cited Findings
- draw(_:zoomScale:in:) gets a mapRect to update and must not draw outside it. Apple says to compute positions in map points, convert with the renderer's methods, and use Core Graphics. zoomScale is meant for stroke widths. — [Apple: draw(_:zoomScale:in:)](https://developer.apple.com/documentation/mapkit/mkoverlayrenderer/draw(_:zoomScale:in:).md)
- Overlay drawing typically happens on background threads, and the map view may split the overlay into tiles rendered on separate threads concurrently. Implementation must be thread-safe, no UIKit views or main-thread-only objects. — same Apple page
- setNeedsDisplay(_:zoomScale:) invalidates a region at one zoom scale only; setNeedsDisplay(_:) invalidates at all zoom scales. If canDraw(_:zoomScale:) returns false, the app must call setNeedsDisplay when data is ready. — [Apple: setNeedsDisplay(_:zoomScale:)](https://developer.apple.com/tutorials/data/documentation/mapkit/mkoverlayrenderer/setneedsdisplay(_:zoomScale:).md), [canDraw](https://developer.apple.com/tutorials/data/documentation/mapkit/mkoverlayrenderer/candraw(_:zoomscale:).md)
- Common tile-cache pattern on Stack Overflow: canDraw returns true only when the tile is cached, else starts a fetch and invalidates on completion. A user reported that invalidating inside canDraw looped without redrawing; replies suggested dispatching the invalidation asynchronously. — search summary of community posts, [index of results](https://gist.github.com/2641246) (low-grade source)
- Open Apple bug rdar://33638875 (iOS 11 beta 4): mapRect/zoomScale passed to canDraw can differ from those passed to draw, with draw receiving smaller rects at the same scale; reported mainly for 3D Flyover. No resolution found. — [OpenRadar 33638875](https://openradar.appspot.com/33638875)
- MKTileOverlay: tileSize (pixels), minimumZ/maximumZ, canReplaceMapContent ("tile content is fully opaque"), and loadTile(at:result:) can be overridden to supply tile Data asynchronously (so tiles can be rendered on device). A corresponding MKTileOverlayRenderer draws them. — [Apple: MKTileOverlay](https://developer.apple.com/documentation/mapkit/mktileoverlay.md)
- Flicker with canReplaceMapContent: one developer says YES flickers, NO gave grey/no tiles on some devices. Another reports the whole screen flashing blank for a frame on every zoom level change even with cached local tiles (filed FB13989005); a subclass giving the overlay direct cache access removed it. — [search digest of forum posts](https://developer.apple.com/forums/thread/670706), [Apple forums thread 696780](https://developer.apple.com/forums/thread/696780)
- iOS 15 (and macOS 12): custom tile overlays flash/disappear when an annotation updates or the map moves; poster linked it to MKPolyline rendering; Apple had fixed a similar bug in iOS 13; no confirmed workaround. — [Apple forums 696780](https://developer.apple.com/forums/thread/696780)
- iOS 18.x regression: showing ~12 small local 512px tiles took about 38 s. Cause found by developer: setting MKTileOverlayRenderer.alpha on every visible-region change triggers a Metal command on the main thread plus redraw flash. Workaround: leave renderer.alpha alone and call context.setAlpha inside a draw override that calls super.draw. Same thread: the only mitigation for zoom flicker was canReplaceContent = false, which makes Apple base-map tiles download and render underneath (wasted bandwidth/energy). Tracked as FB16110803; no official fix. — [Apple forums 770925](https://developer.apple.com/forums/thread/770925)
- Many overlays: iOS 16 forum thread reports hundreds of coloured MKPolygons going from ~3 s to ~1 min on iPhone 12 Pro; poster found MKMultiPolygon; no Apple reply. — [Apple forums 715655](https://developer.apple.com/forums/thread/715655)
- Apple DTS (July 2024, iOS 17 lag with two polylines being rebuilt on drag): use MKMultiPolyline/MKMultiPolylineRenderer when segments share style, avoid bulk remove-then-re-add of overlays (map must redisplay without them, costly because overlays can be transparent and z-order matters), use a custom renderer that redraws only the changed region (points to the "Displaying an updating path of a user's location history" sample), and check SwiftUI update frequency. — [Apple forums 759309](https://developer.apple.com/forums/thread/759309)
- That Apple sample uses MKOverlayPathRenderer, with invalidatePath() when the path changes. — [MapKit overlays index](https://developer.apple.com/documentation/mapkit/mapkit-overlays.md), [MKOverlayPathRenderer](https://developer.apple.com/documentation/mapkit/mkoverlaypathrenderer.md) (details of the sample not confirmed)
- Reports of freezes with many polylines on iOS 16.1+, said to improve in 16.4 beta 1; others used a quadtree to draw only the visible region or skipped drawing below a zoom threshold. — [Apple forums 719084](https://developer.apple.com/forums/thread/719084)
- SwiftUI Map (iOS 17) has MapPolyline with strokeStyle styling but no custom overlay renderer / geodesic polyline; one dev says it is slow with large annotation counts. — [Medium: SwiftUI MapKit iOS 17 missing features](https://medium.com/@gerdcastan/swiftui-mapkit-ios-17-the-missing-features-4b08fa42ee9f), [Apple forums 737613](https://developer.apple.com/forums/thread/737613)

### Inferences
- Fog and heatmap should each be a single custom MKOverlay with a custom MKOverlayRenderer (one object each), never one overlay per track. Tracks themselves as lines: one MKMultiPolyline per style, or drawn in the same custom renderer.
- Do not animate renderer.alpha or fade via the layer; apply opacity inside draw (context.setAlpha) per the iOS 18 workaround.
- Prefer a draw-based renderer over MKTileOverlay: it avoids the canReplaceMapContent trade-off (flicker vs. wasted base-map downloads) entirely, since a plain overlay renderer composites over the base map. Because the renderer is tiled by MapKit anyway, tile-level caching in your own code (keyed by zoom level and tile) gives the same benefit without the flicker reports.
- Design suggestion: in draw, query a spatial index with mapRect (expanded by stroke width converted via zoomScale) so each concurrent tile only touches its own geometry; never retain a CGContext or share mutable state across threads; do data edits by swapping an immutable snapshot, then setNeedsDisplay(rect, zoomScale:) only for the changed rects (new track points) instead of the whole overlay.
- Stay on UIKit MKMapView (wrapped in UIViewRepresentable) rather than iOS 17 SwiftUI Map.

### Gaps
- No Apple-published numbers on how many polyline points or overlays MapKit handles smoothly; only anecdotes.
- Could not confirm exact tile size or threading model MapKit uses when splitting a custom renderer (docs say "may").
- Did not verify whether the flicker reports persist on iOS 19/26; no 2026 reports found in these searches.
- No sourced detail of the Apple location-history sample's drawing code.

## Alternatives: Core Graphics/Metal rasters, MapLibre Native, and how fog-of-war apps are built

### Takeaway
MapLibre Native is a viable free GPU replacement (Metal on iOS, built-in heatmap/line/fill layers), but no head-to-head battery or memory numbers exist, its heatmap is point-based, and it needs a free tile source and a basemap swap. Public sources do not reveal how Fog of World etc. are built.

### Cited Findings
- MapLibre Native for iOS moved to Metal (v6.0.0, January 2024); OpenGL ES described as deprecated on iOS; the ios-metal preset is stable and recommended; WebGPU experimental. — [MapLibre: Metal support is here](https://maplibre.org/news/2024-01-19-metal-support-for-maplibre-native-ios-is-here/), [iOS rendering backends](https://maplibre.org/maplibre-native/docs/book/platforms/ios/ios-rendering-backends.html)
- MapLibre iOS render thread is the UI thread (unlike Android). — [MapLibre Native docs](https://maplibre.org/maplibre-native/docs/book/print.html) (as summarised by search)
- Recent MapLibre iOS/Android releases allow GeoJSON sources with synchronous updates, recommended for time-sensitive layers; geojson-vt onboarded for incremental tile updates of GeoJSON. — [MapLibre Newsletter Dec 2025](https://maplibre.org/news/2026-01-03-maplibre-newsletter-december-2025/)
- MapLibre project is working on low-memory hardening (RAM and GPU), e.g. falling back to a simpler style; no numbers. — [MapLibre roadmap](https://maplibre.org/roadmap/maplibre-native/low-memory-hardening)
- A map that is alive but hidden keeps rendering, wasting GPU/battery (Flutter plugin guidance; pause/remove hidden maps). A style layer over GeoJSON becomes much cheaper than per-item annotations past ~50 items. — [MapLibre Flutter performance](https://maplibre.org/flutter-maplibre-gl/advanced/performance/)
- Heatmap layers use an MLNShapeSource (clustering off) plus MLNHeatmapStyleLayer on iOS. — [MapMetrics iOS heatmap guide](https://docs.mapatlas.xyz/overview/sdk/ios-native/mapmetrics-ios-Map-add-Heatmap) (third-party example)
- Fog-of-war "inverse" masks are done as one big polygon with holes (turf.mask: world ring minus input polygons as interior rings). — [turf.mask](https://atlas.co/functions/turf/turf-mask/)
- Fog of World: fog lifted by GPS tracking; no user account, data stored on device; database designed for minimum storage; users can erase GPS-drift points and add missing tracks. Its rendering technique is not documented in what I found. — [mwm.ai listing](https://mwm.ai/apps/fog-of-world/505367096), [Fog of World 2 note](https://brianmme-website.pages.dev/posts/fog-of-world-2)
- Open-source fog apps found: Footprint (vishal2376/footprint, Kotlin Multiplatform, MIT, tile stream provider checking tile exploration status), UMA (GitSquared/uma, geometry-based fog on-device, CC BY-NC 4.0, non-commercial), FogOff (Android), quentinchaignaud/fog-of-war (Flutter, GPL v3). None is MapKit-based. — [FogOff](https://github.com/mxvlk/FogOff), [UMA](https://www.github.com/GitSquared/uma), [fog-of-war](https://github.com/quentinchaignaud/fog-of-war) (descriptions via search snippets, licences unverified on the repos)
- Skyty blog argues Apple's terms forbid caching MapKit tiles for offline use; single-source claim. — [Skyty blog](https://skyty-web.pages.dev/blog/why-protomaps-and-maplibre/)

### Inferences
- Rendering your own raster (CG or Metal) per tile on a MapKit overlay is just the draw-renderer approach; a Metal path inside draw() is possible but background-thread Metal adds complexity with no source showing it is needed. Core Graphics with a cached tile bitmap is the lowest-risk start.
- MapLibre would give GPU-composited fog (inverted polygon with holes) and lines, but fog polygons from years of tracks must be simplified/generated into a mask; soft feathered edges and constant on-screen minimum width are easier in a raster/shader pipeline than in vector fill. Switching also loses Apple's basemap, so you need a free vector tile source (MapLibre style + OpenFreeMap/Protomaps PMTiles are candidates I did NOT verify; free tile licence terms and tile-fetching privacy (tile requests reveal viewed area, not track data) are gaps).
- Privacy holds in both: track data stays local. MapKit and MapLibre tile fetches reveal only viewed regions.

### Gaps
- No benchmarks comparing MapLibre vs MapKit for battery, memory, or frame rate with large overlays.
- Internals of Fog of World / Wanderer / World Explorer are not public in what I found.
- Free tile sources and their usage terms for MapLibre not researched.
- MapLibre heatmap handling of line data (it is point-kernel based) and fill-layer performance with very large polygon-with-holes were not found.

## Heatmap technique

### Takeaway
Strava rasterises activity paths (not points), then normalises each pixel with a CDF (percentile rank) computed over a tile plus neighbours, blended bilinearly across tile edges, so no global maximum is needed. GPU heatmaps accumulate Gaussian kernels additively into a half-float texture, then colour-ramp the density.

### Cited Findings
- Strava (via search summary of "Building the Global Heatmap"): choice of normalisation has huge visual impact and must be monotonic; a single global function would reserve the hottest colour for the most popular areas; so a joint CDF per tile is computed from that tile and neighbours within 5 tiles; normalised value = share of pixels with a lower heat value; per-tile CDFs jump at tile edges so bilinear interpolation (weighted average of CDFs of the 4 nearest tiles) is used. — [Strava: Building the Global Heatmap](https://medium.com/strava-engineering/the-global-heatmap-now-6x-hotter-23fc01d301de) (page returned 403; read via search summaries only), [Strava Labs Spark talk](https://pt.slideshare.net/databricks/strava-labs-exploring-a-billion-activity-dataset-from-athletes-with-apache-spark-with-drew-robb)
- 2017 update: rasterised data as paths instead of points, twice the resolution, improved normalisation. — [FlowingData](https://flowingdata.com/2017/11/21/global-cycling-and-running-heatmap)
- 2014 version: per-tile 95th percentile of non-zero counts over 8 neighbours, bilinearly interpolated; pixel count divided by that, capped at 1. — search summary of Strava Engineering posts, [What Do 220,000,000,000 Data Points Look Like?](https://medium.com/strava-engineering/what-do-220-000-000-000-data-points-look-like-d267107d9aa7)
- Strava built the global map across several hundred machines in a few hours for a few hundred dollars (search summary). — [Strava post](https://medium.com/strava-engineering/the-global-heatmap-now-6x-hotter-23fc01d301de)
- Mapbox/MapLibre GL heatmap: 2D Gaussian kernel density; each point drawn as a blurred circle into an offscreen half-float texture with additive blending; separate pass maps density (0 to 1) through heatmap-color ramp; kernels cropped below 1/255/16; density pass at quarter resolution per side (16x fewer pixels) with linear upscaling; heatmap-intensity is typically scaled with zoom; ramp should start at transparent. 60 fps with 400,000 points claimed. — [Mapbox blog: Introducing heatmaps](https://www.mapbox.com/blog/introducing-heatmaps-in-mapbox-gl-js), [Mapbox heatmap example](https://docs.mapbox.com/mapbox-gl-js/example/heatmap-layer/)

### Inferences
- Design suggestion for a MapKit per-tile heatmap with no global max: draw lines additively into an offscreen 8-bit/float count buffer per tile (with a margin overlapping neighbouring tiles by the blur radius so no block edges), blur once (CIGaussianBlur or a separable box blur), then normalise with a log or percentile mapping fixed in code (e.g. value = log(1+count)/log(1+K) or a precomputed per-zoom percentile), then colour via a 256-entry LUT (CIColorMap or CGImage mask). A fixed-per-zoom K avoids tile-to-tile discontinuities cheaply; Strava's neighbour-CDF is the heavier, higher-quality version.
- Personal data is small, so the global max can be computed once per zoom level over the whole dataset (or coarse grid) and cached, which gives exact consistency without neighbour interpolation. This is my inference, not a sourced technique.
- Mapbox-style heatmaps are point-based; for lines, rasterise segments (Core Graphics stroke with additive/plusLighter blend) rather than interpolating points.
- Core Image filters (CIGaussianBlur, CIColorMap) were not researched with sources here; treat their use as untested.

### Gaps
- Strava primary post could not be read directly; exact CDF sampling details unverified.
- No sources on CGBlendMode.plusLighter accumulation precision (8-bit saturation) or on Core Image CIColorMap performance/battery.
- No memory/battery figures for per-tile CG rasterisation on iPhone.

## Fog technique: compositing, soft edges, minimum width, spatial indexes

### Takeaway
I found no authoritative source for these specifics; what follows is the supported platform guidance plus design inferences. Apple's guidance supports: draw only within the requested mapRect, work in map points, keep draw thread-safe.

### Cited Findings
- Draw only within mapRect and avoid redrawing the whole overlay each call; use zoomScale to size strokes. — [Apple: draw(_:zoomScale:in:)](https://developer.apple.com/documentation/mapkit/mkoverlayrenderer/draw(_:zoomscale:in:).md)
- Quadtree/visible-region filtering and skipping drawing at low zoom were practitioner workarounds for many-polyline slowness. — [Apple forums 719084](https://developer.apple.com/forums/thread/719084)
- Mask built as a world polygon with holes (inverted polygon) is the vector approach. — [turf.mask](https://atlas.co/functions/turf/turf-mask/)

### Inferences (design suggestions, unsourced)
- In draw: fill the tile with fog colour/alpha, then stroke the visible paths with blendMode .clear (or .destinationOut) using round caps/joins and line width = max(minPixels, trackMetres converted to map points) / zoomScale... i.e. width in map points = max(pixelMin / zoomScale, metresToMapPoints(radius)). Doing the fog on a per-tile offscreen bitmap and then drawing it to the context avoids partial-erase artefacts.
- Soft edge: stroke the same path several times with decreasing width and alpha (cheap feather), or erase into a small offscreen bitmap, apply CIGaussianBlur / box blur on the alpha channel with a margin so tile seams do not show, then composite. Cache the finished tile bitmap by (z,x,y) in memory (NSCache) and optionally on disk; invalidate only tiles intersecting new track points.
- Precompute: convert lat/lon to MKMapPoint once at import, simplify per zoom (Douglas-Peucker with tolerance proportional to 1/zoomScale), keep a uniform grid or R-tree on segment bounding boxes keyed in map-point space; each draw call asks for segments intersecting mapRect inset by the stroke width.
- Combine all spatially close segments into one CGPath per tile and stroke once (fewer state changes) instead of stroking each segment.

### Gaps
- No benchmark or source on CGBlendMode.clear vs destinationOut cost, blur cost per 256/512 px tile, or R-tree vs grid for this case.
- No documented figures for memory per cached tile (back-of-envelope: a 512x512 RGBA tile at 2x scale is 1024x1024x4 = 4 MB; an alpha-only 8-bit tile is 1 MB. Arithmetic, not sourced).
- No battery measurements found for any approach.

## Memory and battery numbers

### Takeaway
No credible measurements found for these approaches. Only qualitative signals.

### Cited Findings
- iOS 18.x alpha-change on a tile renderer ran a Metal command on the main thread and stalled ~38 s; avoiding it fixed it. — [Apple forums 770925](https://developer.apple.com/forums/thread/770925)
- canReplaceContent = false makes Apple base tiles download and render underneath, wasting bandwidth and energy. — [Apple forums 770925](https://developer.apple.com/forums/thread/770925)
- Mapbox heatmap density pass at 1/16 pixel count; ~60 fps with 400k points. — [Mapbox blog](https://www.mapbox.com/blog/introducing-heatmaps-in-mapbox-gl-js)
- Hidden live map views keep rendering. — [MapLibre Flutter performance](https://maplibre.org/flutter-maplibre-gl/advanced/performance/)

### Inferences
- Lowest-energy design: render each tile once, cache bitmaps, redraw only dirty tiles, render heatmap density at reduced resolution (as Mapbox does) and upscale, avoid per-frame invalidation during pans, and avoid canReplaceMapContent=false-style hacks.
- Measure with Instruments (Time Profiler, Energy Log, Allocations) on the iPhone 15 Pro; no published numbers will substitute.

### Gaps
- No MapKit vs MapLibre battery or memory comparison anywhere in the sources found.
