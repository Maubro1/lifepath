# LifePath design direction (stage 6)

Source: the owner's request on 17 Nov ("an actually good design, cool and good experience, checked for AI-design signs"), the impeccable critique of v0.7.1 (21/40), and the owner's own HTML page they like (a study map), whose choices carry over.

## Feel
A personal diary printed on good paper: warm neutral ground, solid filled surfaces (no outlined boxes), colour only where it carries information, big confident numbers. Calm, precise, a little retro-print.

## Carried over from the owner's page
- Neutral warm ground: light #FAFAF9 / surface #EDECE8 / inset #E1DFDA; dark #141414 / #222222 / #2E2E2E. Text #1C1C1E / #EDEDEC, muted #5C5E63 / #A6A6A3.
- Colour roles per travel mode, each with a fill tuned separately for light and dark (asset catalog Any/Dark), never just inverted. Retro-print palette, saturated but never neon, no purple: cherry red, satsuma orange, mustard, teal, cobalt, olive, coffee; grey for unsure.
- Legend chips are also the filter: tap a mode to hide it; off = 45% opacity. Fixes invisible toggle state.
- Facts strip: a row of big tabular numbers with a small muted caption (Stats headline, day page summary).
- Display face for headlines and numbers, mono for small metadata (times, distances in lists), system body. Bricolage Grotesque (OFL, free) is a candidate for display; Instrument Sans is flagged as overused by the detector, so the body stays SF Pro.
- Tight geometry: custom surfaces use small radii (4 pt); system controls stay native.
- A live "now" marker in the warning colour on today's timeline.
- Appearance switch: System / Light / Dark in Settings (AppStorage, preferredColorScheme).

## Screen plan
- Map: full screen, muted base map, one "Today" chip, a layers button opening a sheet (colour, style, overlays, legend), a status pill (Recording / Resting since 10:03).
- Timeline: relative dates, month headers, map-snapshot thumbnails in mode colours; tap opens a Day page (map + story of places and trips + facts strip).
- Stats: period picker, facts strip, distance-per-mode bar, calendar strip of active days, top places, Streets walked progress. Points stored moves to Settings > Diagnostics.
- Settings: titled Settings, sections Recording / Appearance / Street maps / Your data / Help; backup nudge when never or old.
