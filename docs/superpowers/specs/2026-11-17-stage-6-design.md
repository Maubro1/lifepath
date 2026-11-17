# Stage 6: LifePath design

Agreed with the owner on 17 November 2026, section by section. Replaces the default SwiftUI look of v0.7.1 (impeccable critique 21/40: map buried under 14 controls, Timeline a dead end, Stats a bare list, no identity).

## Intent

The owner opens LifePath mostly to **watch the map fill up**: see which streets and areas they have covered and find new ones. The map is the heart; days and stats support it. The look comes from the owner's own study-map page (warm paper surfaces, solid fills, retro-print colours). Effects are modern but light: no hitches, no jumping lines, no frames where things disappear, and the phone stays cool.

## Decisions taken with the owner

| Question | Decision |
|---|---|
| Main reason to open the app | Watch my map fill up |
| How filling up looks | A toggle between **Streets** (walked streets light up) and **Fog** (fog clears where you have been) |
| Feel | Like the owner's study page |
| Structure | Two tabs: **Map** and **You** |
| Progress | Per city and per neighbourhood, not one total |
| Fog width | 15 m each side on foot or bike, 6 m in a road vehicle, 25 m circle at places |
| Old lines | Never grey, never faded with age; orange by default |
| Compass and locate | Never overlap |
| Appearance | Switch: System, Light, Dark |

## 1. Visual system

**Colours** are dynamic colours with separate light and dark values, defined once in Core so they can be contrast-tested; nothing is inverted automatically.

| Role | Light | Dark |
|---|---|---|
| Page | #FAFAF9 | #141414 |
| Card | #EDECE8 | #222222 |
| Inset (box in a card) | #E1DFDA | #2E2E2E |
| Text | #1C1C1E | #EDEDEC |
| Muted text | #5C5E63 | #A6A6A3 |
| Progress / your lines (satsuma) | #C4521A | #F08C4E |

Travel modes (fill, light / dark): walk satsuma #C4521A / #F08C4E, run cherry #B2362C / #E86A5B, bike olive #5A842C / #9DC46A, car coffee #87573A / #C99772, bus mustard #B07D12 / #E7B547, tram teal #227A72 / #5DB8AC, train cobalt #3A69AE / #82A8E2, boat sea #4E8FB8 / #7FB7DA, unsure grey #8E8E93 / #8E8E93. No purple, nothing neon.

Date colouring is a warm ramp at full strength: newest mustard, then satsuma, oldest deep cherry. Lines never turn grey or transparent with age.

**Surfaces** are filled, never outlined; depth comes from page, card, inset steps, not shadows or glass. LifePath's own cards and buttons use a 3 pt corner radius; system sheets, switches and keyboards stay native.

**Type.** Bricolage Grotesque (SIL Open Font License, bundled) for big numbers and titles, through `Font.custom(_:size:relativeTo:)` so it follows Dynamic Type. Body text is SF Pro. Times and small figures use SF Mono (`.monospaced()`), with tabular digits wherever numbers update.

**Appearance switch** in Settings: System, Light, Dark (`@AppStorage`, `preferredColorScheme`); the map follows.

**Motion.** Numbers roll to new values (`contentTransition(.numericText())`); newly cleared fog and newly walked streets fade in once over 0.5 s when the map opens; cards move with a soft spring. Reduce Motion turns all of it into a plain fade. No looping or idle animation.

## 2. Map tab

Full-screen `MKMapView` with the muted standard style (or satellite), points of interest hidden, down to the tab bar. Three floating groups on card-coloured surfaces:

**Top left: place chip.** "Utrecht · 11%": the neighbourhood or city under the map centre and its progress in the current mode; updates while panning, the number rolls. Tap opens the **place card** (a sheet): the city percentage in large Bricolage digits, then its neighbourhoods with a thin satsuma bar each; tapping one flies the map there.

**Top right: one column.** Layers button, locate button, and below them the compass (`MKCompassButton`, visible only when rotated) with a fixed gap; the three never overlap. Layers opens a small sheet: colour lines by mode, date or speed (each with a legend whose chips also filter, off at 45% opacity), standard or satellite, heat on or off.

**Bottom card**, above the tab bar, two rows:
1. **Streets | Fog** (segmented) and a period chip for your own lines: Today (default), Week, Month, Year, All, Custom, Off.
2. Today in one line: "3,2 km · 4.120 steps · +2 new streets" (new streets in satsuma). Tap opens today's day page.

**Fog mode.** The fog is the paper itself: the page colour, opaque, over the whole map. Clearing: on foot, running or cycling 15 m each side of the matched line; car, bus and tram 6 m; train and boat clear only the stations or piers where you got on and off (25 m); a visited place clears a 25 m circle. The cleared edge is feathered over about 4 m. A cleared band is never drawn narrower than 2 pt on screen, so explored areas stay visible zoomed out to the whole country. Fog covers all time; it never resets.

**Streets mode.** Walked streets (the existing 90% rule) in satsuma with a soft glow (a wide translucent stroke under a solid one); countable streets not yet walked as thin faint lines. Below city zoom, individual streets give way to **neighbourhood shading**: each neighbourhood filled with satsuma in proportion to its progress; zooming in cross-fades back to streets.

**Your lines** on top, for the chosen period: satsuma by default, or by mode, date or speed. In Streets mode they get a thin dark edge so they stay distinct from the glowing streets. Saved places show as small square markers, with names from city zoom inward.

**Recorded line** moves to Settings, Help, Diagnostics.

## 3. You tab

One scrolling page:

1. **Status and lifetime.** A pill ("Recording", or "Resting since 10:03") and a gear button to Settings. A facts strip in Bricolage: streets walked, km walked, neighbourhoods explored, days recorded, each with a muted caption.
2. **Your places.** "+12 new streets this week" in satsuma, then each city walked in with its percentage and bar, the current city first. Tap opens the place card.
3. **This year.** A strip of 52 week squares, empty paper for still weeks, deeper satsuma for more walking; below, one bar of distance by travel mode with its legend. A period chip switches to month or all time.
4. **Your days.** Newest first under month headers. Each row: a map picture of the day (muted base, lines in satsuma), "Today" / "Yesterday" / "Mon 16 Nov", "26,4 km · 4 h 48 min · 11.253 steps", and "+5 new streets" when any.

**Day page** (pushed): the day's map at the top, tapping it switches to the Map tab showing only that day; a facts strip (km, moving time, steps, new streets); then the day as a story, visits and trips in order, each trip with its mode colour as a small square marker, its duration and distance. Unnamed places are called after the nearest street from the downloaded street maps ("near Leuvenlaan"); nothing leaves the phone for naming. Tapping a place opens its rename sheet, as in v0.7.1.

**Settings** (pushed from the gear), titled Settings, sections:
- Recording: recording detail, blue location bar, rest.
- Appearance: System, Light, Dark.
- Street maps: automatic downloads, mobile data, count cycling.
- Your data: save a backup (a satsuma dot when never saved or older than 30 days), last backup, restore, export.
- Help: health report, Diagnostics (recorded line, points stored, tracking events), version, SideStore refresh due.

All existing footers keep their plain-language explanations.

## 4. Data this needs

- **Borders.** Overpass requests for each street tile also fetch administrative boundary relations: the municipality (admin_level 8) and the finest level below it that exists in OSM there (the planning step checks which level holds Dutch wijken). Stored per tile as simplified polygons; the request still sends only the tile rectangle.
- **Progress per place.** A countable street segment belongs to the neighbourhood and city containing its midpoint. Percent = covered countable length / countable length within the border, using the existing 20 m segments and 90% street rule.
- **New streets.** The date a street became covered is the start of the trip whose segment hits first took it past the rule; derived from the existing `segmentHit.tripStart`, no new raw data. Counts per day, per week and per place come from it.
- **Fog geometry** comes from the matched trip lines and visits already stored; no new recording.
- **Day map pictures** are rendered once with `MKMapSnapshotter` per day and appearance, cached in Caches, and redone when that day's lines change.

## 5. Drawing without flicker

Fog, streets and lines are each **one long-lived `MKOverlay` with its own `MKOverlayRenderer`**. MapKit draws renderers in tiles on background threads and keeps each tile until told otherwise. When data changes, the renderer invalidates only the map rects the change touches (`setNeedsDisplay(_:)`); overlays are never removed and re-added, so nothing on screen disappears or jumps. Each renderer reads from an immutable snapshot of its data, swapped atomically, so a tile is never drawn half-updated. Line geometry per tile is looked up through a spatial index built once per data snapshot. The live trip extends its own rect instead of replacing its overlay.

Battery and heat: tiles are only drawn when visible or changed; no timers; the map does no work while the app is in the background.

## 6. Accessibility

Dynamic Type everywhere (Bricolage through `relativeTo:`); 44 pt touch targets; every colour coding also has a label or legend; VoiceOver labels for the place chip ("Utrecht, 11 percent of streets walked"), the toggle and day rows; contrast checked in both appearances; Reduce Motion honoured.

## 7. Testing

Core logic gets unit tests on Windows: progress per border (segments split across borders, a street on a border), the first-covered date, fog buffer widths per mode, the day story built from visits and stretches. App code is checked on CI and on the owner's phone, with screenshots in light and dark at default and large text sizes.

## Out of scope

Route suggestions to unwalked streets, sharing, widgets, badges or achievements, iPad layout. Each could come later.
