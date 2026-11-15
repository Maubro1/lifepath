# Original brief (the owner's words)

The owner's first message, kept verbatim. Later decisions (in the spec, `docs/decisions/` and STATE.md) refine it; where they differ, the later decision wins.

> I want to spend €0 on making the app or getting it installed on my phone. I want this app to be extremely lightweight and not drain your battery and precise and nice to use and look good and have good settings. It should be a joy to use. I'm going to be installing it on my iPhone 15 Pro and I'm working on this on my Windows 11 laptop. Don't have a macbook or imac.

## What LifePath is

LifePath is a private diary of everywhere you go. You install it, give it permission once, and then forget about it. It runs in the background all day, every day, and slowly builds a map of your life: every street you've walked, the routes you take without thinking, and the places you spend your time.

It belongs entirely to you. There's no account to create, no server, no cloud, and nobody else ever sees a thing. Your whole history lives in a single file on your phone, and updating the app never touches it. It also costs nothing, which shaped a lot of decisions along the way. It's built for one person and one iPhone, and it doesn't pretend to be anything bigger.

## Recording in the background

The core of the app is invisible. While your phone sits in your pocket, LifePath collects your position and writes it into the diary, whether the app is open, closed, or hasn't been touched in weeks.

Everything about how it records comes back to one question it keeps asking itself: are you moving right now? While you are, it records properly with the satellites switched on. While you're sitting still, it switches nearly everything off, pins your dot where it is, and waits. Battery is spent while you're going somewhere and saved the rest of the time, which matters a great deal because almost any day is mostly spent not going anywhere.

The app leans hard towards recording. Guessing wrong one way costs a little battery, while guessing wrong the other way loses a piece of your day for good, so whenever it's unsure it picks recording.

## Noticing when you set off and when you stop

Setting off gets four separate ways of being noticed, and any single one is enough. The step counter inside your iPhone is the fastest: fifteen steps and the app wakes up, even indoors or in a basement where the signal is hopeless. The phone's motion chip noticing walking or driving is the second. A position reading landing well away from where you settled catches you pulling away in a car without walking first. Finally, an invisible circle of 200 metres around where you stopped tells iOS to wake LifePath the moment you cross it, even if the app had been shut down completely.

Deciding you've stopped is deliberately slower and more suspicious. You have to stay within a small area for a little while, and if you were recently in a car or on a bike it waits a few extra minutes, since traffic stops at every red light and then carries on.

## Drawing an accurate line

Phone positioning wobbles. Left raw, a walk down a straight street comes out as a zigzag, and sitting on the sofa looks like pacing around the block. LifePath cleans this up before anything reaches the map.

It throws out readings that are plainly broken, including ones that would have you teleporting further than you could possibly have travelled. It then averages the rest together, trusting confident readings more and shaky ones less, so the wobble cancels out and the line follows where you actually went. On a typical walk, what LifePath draws lands within about 8 metres of your true path, where the raw signal was off by around 30.

While you're sitting still, your position is held in place rather than allowed to drift, so an afternoon at home shows up as one calm dot instead of a scribble. It also saves a point every five minutes while you're still, so the map knows you were home.

## Quality levels and battery

You choose how hard the app works through a quality setting with four levels. Saver uses only Wi-Fi and phone masts, costs very little, and tells you which part of town you were in rather than which road. Balanced is the everyday default, draws your street properly, and costs roughly 6 percent of a charge on a day at home or around 14 percent on a day with a walk in it. Precise squeezes a bit more accuracy out at a bit more battery, and Max goes full navigation-grade for a day you want mapped down to the last detail.

A handful of extra settings sit around that. You can choose how often a point gets saved while you move, how much smoothing to apply, whether to show the blue location bar at the top of the screen, and a deep sleep mode that stops the phone being woken constantly while you're at rest. That last one is what cured the phone running warm. If the phone does get hot or Low Power Mode comes on, the app eases off by itself, making the line a bit coarser rather than stopping recording.

## The map

The map is the heart of what you actually look at. Your paths are drawn as lines, coloured either by date so you can tell old trips from recent ones, or by speed so walks, bike rides and drives stand apart. You can filter to today, this week, this month, this year, all time, or a custom range, and switch between a standard map and satellite imagery.

A heat view shows where you spend your time. It counts time spent rather than the number of points saved, so a night's sleep doesn't make your bedroom glow as though you'd spent twelve hours pacing it. There's a Streets toggle that highlights which streets you've covered, and a button that centres the map on wherever you are now. Gaps in time split the lines into separate trips, so the map never draws a straight line across town connecting two unrelated journeys.

## The timeline

The timeline breaks your history into days, newest first. Each day gets a card with a little drawing of that day's route, how far you travelled, how long you spent moving, and your steps when step counting is switched on. Days spent at home don't inflate the moving time, so a lazy Sunday reads as a lazy Sunday.

## Stats

The stats screen gathers the big numbers. Under "Where you went" sits your lifetime distance, how many days you've been tracked, and how many points are stored. Under "On foot" come your steps, the distance you've walked and the flights of stairs you've climbed. Under "Streets walked" is your progress at covering the streets around you.

## Streets walked

This is the feature built most directly for your original goal of seeing every street. For an area you've visited, you can download the street map from OpenStreetMap, the free community-made world map. LifePath then checks your history against it and works out which streets you've walked, piece by piece. A street counts as covered once you've been along most of it, and the app always matches you to the single nearest street, so walking down one road never lights up the parallel one or the alley behind it.

It never moves or redraws your recorded track to fit the streets. Your path stays exactly as recorded, and the coverage sits on top of it. Downloading a whole city costs a tiny fraction of a charge, and after a few walks it identifies the large majority of what you covered.

## Steps and stairs

With your permission, the app reads your steps, walking distance and flights climbed from the iPhone's motion chip and shows them alongside each day's route. The iPhone only remembers a week of this, so every time you open LifePath it copies those days into its own diary, gradually turning that rolling week into a permanent record. The same permission is what lets the app tell so reliably when you're sitting still, so granting it also makes the battery last longer.

## Export, backup and restore

Your history can leave the app in four forms: GPX for hiking apps, GPS watches and Strava; GeoJSON for web mapping tools; KML for Google Earth; and a complete backup holding everything. You can export everything or just a chosen date range, and the files land in the iPhone's Files app under LifePath.

Bringing history back is just as easy. The import option finds backups in the Files app, shows how many points and which dates each holds, and merges the one you pick into what's already there. Since it merges instead of replacing, importing an old backup can never wipe out anything recorded since. On a fresh install with an empty diary, the app looks for a backup by itself and offers to restore it, so a reinstall picks up where the last one left off.

## Settings, status and the health report

At the top of Settings sits a status box showing at a glance whether tracking is healthy, when the last point was saved, and when the phone last checked in. It says so plainly when tracking is resting because you've been still, and gives pointers when something looks wrong, such as location access being changed or the app having been swiped away.

There's also a health report. One tap writes a text file into the Files app covering the last few days: how much of each hour was spent resting, how often the app woke up, how warm the phone ran, how accurate the readings were, and why the app made the choices it did. It's written to be handed to an AI, which can then say exactly where the battery went or why a stretch is missing. Pulling down on any of the main screens refreshes it, so you never need to close the app to see current numbers.

## First launch

The first time you open it, a short series of screens walks you through it: what the app does, permission for your location, which iOS asks for in two rounds (While Using first, then Always), a friendly request not to swipe the app away in the app switcher since that's the one thing that stops background recording, and an optional step to switch on step counting. Then it starts recording and asks nothing more of you.

## The short version

LifePath is a free, private, always-on diary of your movements that works out by itself when you're moving and when you're not, cleans up the wobble so lines follow the streets you walked, and turns all that into a map, a day-by-day timeline, lifetime stats and a growing tally of the streets you've covered. You can carry the history out of the app whenever you like, and a new install can bring it straight back in. Whoever rebuilds it has a clear brief: keep it private, keep it free, keep it out of the way, and make that map of your life as complete and honest as possible.
