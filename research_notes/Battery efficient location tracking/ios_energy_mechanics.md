# iOS background location: energy mechanics and low-cost all-day tracking (iOS 17 to 26)

Scope: what costs battery when an iOS app tracks location in the background, how each Core Location / Core Motion mechanism behaves, which ones relaunch the app, why DIY trackers drain the battery, and the iOS 17, 18 and 26 differences. Research date: 2026-11-14. Target: private always-on location diary on iPhone 15 Pro, iOS 26.

## 1. Apple's own guidance on cost (Energy Efficiency Guide, WWDC23, WWDC24)

### Takeaway
Apple's guidance has three parts. Request the lowest accuracy you need, because higher accuracy "powers up additional hardware". Let the system pause updates when the device is stationary. Prefer visit and region monitoring over continuous or significant-change updates. Apple publishes no figures for the cost of GPS versus Wi-Fi or cell positioning, and the modern API (CLLocationUpdate) saves power mainly by pausing automatically when the device is stationary.

### Cited Findings
- "Requesting higher accuracy than you need causes Core Location to power up additional hardware and waste power for unnecessary precision. Unless your app really needs to know the user's position within a few meters, don't set the accuracy level to best ... or nearest ten meters." — [Energy Efficiency Guide for iOS Apps, Location Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Standard location updates default to accuracy "best", so apps must lower it explicitly. Actual accuracy can be better than requested: with kCLLocationAccuracyThreeKilometers "you may receive accuracy within a hundred meters or so". — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- If accuracy doesn't improve, the desired level may not be available, so "stop location updates and try again later". The guide also says to use `requestLocation` for one-shot fixes, because it stops location services automatically. — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Background: keep `allowsBackgroundLocationUpdates` NO until it is actually needed, set `pausesLocationUpdatesAutomatically = YES` "to help conserve power", and set `activityType` so the system can pick update timing ("background location updates may be auto-paused if the system determines that the user isn't moving"). Call stopUpdatingLocation even with auto-pause on. — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Priority order: "Region and visit monitoring are sufficient for most use cases and should always be considered before significant-change location updates. Significant-change location updates run continuously, around the clock, until you stop them, and can actually result in higher energy use if not employed effectively." — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- The Energy Guide (archived, pre-iOS 13) still describes deferred updates (`allowDeferredLocationUpdatesUntilTraveled:timeout:`), which batch GPS fixes so the app wakes less often. That API is now deprecated (see section 2). — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- WWDC23 "Discover streamlined location updates": CLLocationUpdate.liveUpdates is pitched for "improved battery performance". The session says "we can be power efficient here by pausing the updates. This off loads your app as well, by not giving it redundant locations to process." — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- WWDC23: LiveConfiguration presets are default, automotiveNavigation, otherNavigation, fitness and airborne. They map to CLActivityType, and the session gives no numeric accuracy per preset. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- WWDC24: "Core Location does not take measures to keep apps running continuously when it has nothing to deliver to them." — [WWDC24 10212 What's new in location authorization](https://developer.apple.com/videos/play/wwdc2024/10212/)
- WWDC24: with approximate location only, updates come "only every 15 to 20 minutes" (the `accuracyLimited` diagnostic). — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- distanceFilter is disputed. Developer reports say the filter sits above the GPS driver, so it reduces callbacks (CPU wakeups) but not GPS chip power. One field test suspected that a large filter let the GPS switch off between fixes. Apple's Energy Guide doesn't mention distanceFilter. — [Stack Overflow archive: defer vs accuracy](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/20446113/ios7-is-it-more-power-efficient-to-defer-updates-or-to-set-desired-accuracy-to); [Medium, mizutori, "Tracking highly accurate location in iOS vol 3"](https://medium.com/@mizutori/tracking-highly-accurate-location-in-ios-vol-3-7cd827a84e4d); [Flybuy test](https://www.flybuy.com/?p=2471)

### Inferences
- Battery cost comes from two separate things. Radio and sensor power is set by accuracy: GPS versus Wi-Fi or cell. App CPU wakeups are set by how often callbacks arrive and how much work each one does. distanceFilter mostly affects the second. desiredAccuracy and stopping updates while stationary affect the first.
- For a diary, the biggest saving is not running GPS while the user is stationary, which is most of the day. Both the Energy Guide (auto-pause) and WWDC23 (isStationary) point there.

### Gaps
- Apple publishes no mW or %/hour figures for GPS versus Wi-Fi or cell positioning, or for each accuracy constant. I found no Apple statement on which accuracy levels turn the GPS chip on (it is commonly believed to be HundredMeters or better, but that is unsourced).
- The page "Accessing the device's location efficiently" (developer.apple.com/documentation/xcode/accessing-the-device-s-location-efficiently) didn't render for fetching, so its contents aren't captured here.
- I didn't find WWDC20 or WWDC22 energy sessions with location-specific numbers. I did not fetch them.

## 2. How each mechanism behaves and what it costs; which ones relaunch the app

### Takeaway
- **Cheap and relaunching:** visit monitoring and region monitoring (CLMonitor or CLCircularRegion), plus significant-location-change (SLC).
- **Precise and power-aware:** liveUpdates with automatic stationary pause, plus CLBackgroundActivitySession. It relaunches after system termination when updates become available.
- **Legacy:** standard updates at reduced accuracy.
- **Dead:** deferred updates, deprecated, and the availability check has returned false since iOS 10.
- **Force-quit:** in iOS 26 it appears to block relaunch by SLC and regions, according to developer reports with no Apple confirmation.

### Cited Findings
**CLLocationUpdate.liveUpdates (iOS 17+)**
- Each update carries a location and `isStationary` (renamed `stationary` in iOS 18). When the device has been still "for a sufficient amount of time", the API triggers automatic pause. It sends one update with a non-nil location and isStationary = true, then resumes automatically with isStationary = false when the device moves. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/); [Forum thread 810433](https://developer.apple.com/forums/thread/810433)
- Suspension happens "when there are no updates to deliver", for example during automatic pause. The session says "CLLocationUpdate is not going to leave your app in the suspended state". As soon as updates are available, the app is unsuspended into background running, with no action needed. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- After termination (crash, user close, or system pressure): "Our API can recover your app in most cases, even when it's terminated ... by launching it in the background." The app must immediately call liveUpdates again and recreate CLBackgroundActivitySession in didFinishLaunching. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- Apple DTS (accepted answer): don't stop liveUpdates yourself when stationary, because the system already stops delivery. "If the app is terminated while updates are inactive, it won't be launched again when the device starts moving." The API can't be paused and resumed at fine grain. For more control, combine standard updates, SLC and region monitoring, but recovery after termination is "clunky". — [Forum thread 810433](https://developer.apple.com/forums/thread/810433)
- Automatic pause can't be disabled for liveUpdates. Setting `pausesLocationUpdatesAutomatically = false` on a CLLocationManager didn't stop the stationary pause, which kicked in after about 10 minutes. DTS's only answer was that keeping a WebSocket alive isn't a valid use of background location (App Review Guideline 2.5.4). — [Forum thread 763696](https://developer.apple.com/forums/thread/763696)
- A known iOS 17 confusion about when isStationary flips is discussed in [Forum thread 750531](https://developer.apple.com/forums/thread/750531). I didn't fetch it.

**CLBackgroundActivitySession (iOS 17+)**
- It shows the blue background-location indicator and grants background capability to the app as a whole, covering liveUpdates and CLMonitor. It needs `location` in UIBackgroundModes. A new session must start in the foreground, but an app can rejoin an existing one from the background. Deallocating the object invalidates it, so store it in a property. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- In the field, an expo-location app using only the legacy `allowsBackgroundLocationUpdates` path (no CLBackgroundActivitySession) was suspended about 50 seconds to a few minutes after backgrounding on iOS 26 and 27 while driving. A native app holding the session kept the indicator indefinitely. — [Forum thread 844579](https://developer.apple.com/forums/thread/844579)
- Developers report that the session always shows the indicator, and no Apple-supported way to relaunch after force-quit without it has been identified. DTS recommends accepting the indicator rather than working around it. — [Forum thread 826964](https://developer.apple.com/forums/thread/826964); [Forum thread 810433](https://developer.apple.com/forums/thread/810433)

**CLServiceSession (iOS 18+)**
- It declares an authorization goal. Iterating liveUpdates or CLMonitor.events implicitly holds a `.whenInUse` session. `.always` needs an explicit session, and from iOS 18 "Always authorization will only be effective when you hold one of these, and you can only start holding one when your app is in the foreground." — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- Sessions survive suspension. After termination, Core Location remembers outstanding sessions and sequences and "will resume or re-launch the app into the background when new information is ready". It holds them for "only a few seconds after the app is launched again", so launch code must re-take sessions and resume iteration immediately. — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- Diagnostics are reported as `.authorizationDenied`, `.authorizationDeniedGlobally`, `.insufficientlyInUse`, `.alwaysAuthorizationDenied`, and on updates as `.stationary`, `.accuracyLimited` and `.locationUnavailable`. `NSLocationRequireExplicitServiceSession` in Info.plist disables implicit sessions. — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)

**Visit monitoring (CLVisit)**
- Covers arrivals and departures at places the user visits often or stays at for a long time. "If your app isn't running when a visit event is delivered, your app is relaunched automatically." It needs Always authorization, and calling it "enables all visit updates in your app". — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- iOS 26 regression: `didVisit` stops being delivered on some user devices after updating to 26.0, 26.0.1 or 26.1, while didUpdateLocations keeps working. Only reinstalling fixes it. One developer gets about 20-30 user reports per week. An Apple engineer called it a probable regression, and it is tracked as FB21022960. No fix is confirmed. — [Forum thread 807301](https://developer.apple.com/forums/thread/807301)

**Region monitoring (CLCircularRegion, CLMonitor)**
- Delivers entry and exit only. The app must call requestLocation or startUpdatingLocation to get the actual position. It needs Always authorization. — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- CLMonitor events report a diagnostic when a condition can't be served, for example because too many conditions of that type are already monitored. — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)

**Significant-location-change (SLC)**
- Apple calls SLC a last resort: it "can actually result in higher energy use if not employed effectively". — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Legacy docs: "If your app is terminated either by a user or by the system, the system doesn't automatically restart your app ... The only way to have your app relaunched automatically is to use region monitoring or the significant-change location service." This is the archived Location Awareness guide as quoted in the forum thread. A developer tested in 2022 and saw no relaunch after force-quit. — [Forum thread 701377](https://developer.apple.com/forums/thread/701377)
- iOS 26.4.2 test: with SLC and a CLCircularRegion, a suspended app got every event reliably. After a force-quit from the App Switcher, a 30 km drive produced no relaunch, no UIApplicationLaunchOptionsLocationKey and no callbacks. The poster says iOS 18 did relaunch in the same scenario. There is no Apple reply. — [Forum thread 826964](https://developer.apple.com/forums/thread/826964)
- A 2012 report says Apple told a developer that SLC doesn't need `location` in UIBackgroundModes, and that removing the key stopped their battery drain. This is historical. — [Stack Overflow archive 9513249](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/9513249/battery-drain-when-using-corelocation-significant-location-monitoring-coreblue)

**Deferred updates**
- `allowDeferredLocationUpdates(untilTraveled:timeout:)` and `deferredLocationUpdatesAvailable` are listed as deprecated. — [Core Location deprecated symbols](https://developer.apple.com/documentation/corelocation/deprecated-symbols)
- Deprecated with no stated replacement. — [Forum thread 654296](https://developer.apple.com/forums/thread/654296)
- `deferredLocationUpdatesAvailable` has returned false on devices since iOS 10, so deferral doesn't actually work. — [Stack Overflow archive 39498899](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/39498899/deferredlocationupdatesavailable-returns-no-in-ios-10)

**Core Motion (CMMotionActivityManager, CMPedometer)**
- Live `startActivityUpdates` is best-effort, and updates are not delivered while the app is suspended. To recover missed activity, use `queryActivityStarting(from:to:to:withHandler:)`. — [CMMotionActivityManager startActivityUpdates docs](https://developer.apple.com/tutorials/data/documentation/coremotion/cmmotionactivitymanager/startactivityupdates(to:withhandler:).md); [CMMotionActivityManager](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager)
- Only about the last 7 days of activity history can be queried. This comes from a forum user, not Apple docs. Apps need to track their suspend times to avoid double counting. — [Forum thread 685532](https://developer.apple.com/forums/thread/685532)
- A change in activity alone does not move a suspended app into background execution. Another background mode, such as location, is needed. — [Stack Overflow archive 20083032](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/20083032/coremotion-updates-in-background-state)
- Historical query results for the same window can shift between queries (watchOS 27 report). — [Forum thread 856631](https://developer.apple.com/forums/thread/856631)
- Open question whether background CMDeviceMotion delivery depends on an active Core Location session. — [Forum thread 841001](https://developer.apple.com/forums/thread/841001)

### Inferences
- Relaunch summary from the evidence above:
  - **Visits:** relaunch, documented.
  - **Regions and SLC:** relaunch after system termination, documented. After a user force-quit, apparently no relaunch on iOS 26, per developer reports.
  - **liveUpdates and CLServiceSession:** relaunch after termination "in most cases" when updates are available. After force-quit the behavior isn't documented.
  - **Standard updates:** don't relaunch.
  - **Core Motion:** never wakes the app, but can be back-filled by query later.
- A low-cost diary design that follows from these sources: CMMotionActivity history plus visits as the always-on low-power backbone, liveUpdates (default or fitness configuration) plus CLBackgroundActivitySession while moving, and the built-in stationary pause instead of hand-rolled stop and start logic.
- Back-fill motion with queryActivityStarting on each wake rather than relying on live handlers.

### Gaps
- The exact SLC parameters (roughly 500 m movement, at most once per 5 minutes, cell or Wi-Fi based) are widely cited, but the Apple doc page didn't render for fetching, so they are unverified here.
- The CMMotionActivity 7-day window is a forum claim, not confirmed by Apple docs.
- No Apple numbers on the power draw of the motion coprocessor or of visit monitoring.
- How long "a sufficient amount of time" is before the stationary pause isn't documented. One report saw about 10 minutes ([763696](https://developer.apple.com/forums/thread/763696)).

## 3. Background execution rules: suspension, low-accuracy keep-alive, force-quit

### Takeaway
- **When iOS suspends:** an app with background location is suspended when Core Location has nothing to deliver: during a stationary pause, with no fix available, or when the app doesn't hold a session.
- **Suspended apps get nothing:** Core Motion live callbacks stop.
- **Low-accuracy keep-alive:** keeping the app alive with low-accuracy updates is a pre-iOS 17 folk technique. Apple doesn't document or guarantee it, and liveUpdates pauses regardless.
- **Force-quit:** generally ends location-driven relaunch until the user opens the app again, and iOS 26 appears to enforce this for SLC and regions too.

### Cited Findings
- WWDC24: "Core Location does not take measures to keep apps running continuously when it has nothing to deliver to them". A `.whenInUse` app gets no background updates without a LiveActivity or CLBackgroundActivitySession. — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- WWDC23: a LiveActivity is "the best way to enable background location updates". A CLBackgroundActivitySession is the alternative. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- Field report, iOS 26 and 27: an app with BestForNavigation, `pausesLocationUpdatesAutomatically = NO`, the indicator on and `allowsBackgroundLocationUpdates` on was still suspended for 2-9 minutes while driving. The fixes were:
  - Adopt CLBackgroundActivitySession.
  - Stop re-rendering a map view with about 750 children plus a 5-second UI timer while the app was in the background. This cut per-update processing from about 150 ms to under 20 ms, and the suspensions stopped.
  - The stationary-session indicator disappeared after about 1 minute.
  Apple DTS gave no technical explanation. — [Forum thread 844579](https://developer.apple.com/forums/thread/844579)
- A developer workaround is to briefly turn on GPS at each cold start so iOS keeps the app running. This is informal and undocumented. — [Medium, gtreulands, car drive tracking](https://medium.com/@gtreulands/ios-fully-working-background-app-to-track-car-drives-499d4f1e3ff0)
- The archived Location Awareness guide says user- or system-terminated apps aren't restarted for standard updates, and only regions and SLC relaunch them. — quoted in [Forum thread 701377](https://developer.apple.com/forums/thread/701377)
- iOS 26.4.2: force-quit blocked relaunch by both SLC and CLCircularRegion. — [Forum thread 826964](https://developer.apple.com/forums/thread/826964)
- Relaunched apps sometimes get only about 10 seconds, or are suspended again shortly after an SLC relaunch. These are older reports. — [Forum thread 827476](https://developer.apple.com/forums/thread/827476); [Forum thread 652985](https://developer.apple.com/forums/thread/652985)
- Using background location for non-location purposes, such as keeping a socket alive, is rejected under App Review Guideline 2.5.4. — [Forum thread 763696](https://developer.apple.com/forums/thread/763696)

### Inferences
- With liveUpdates, being suspended while stationary is the intended design, not a bug. The app should persist state before going idle and expect to be woken.
- Heavy per-update work in the background, such as UI or map rendering, appears to correlate with the system suspending the app, besides costing energy directly ([844579](https://developer.apple.com/forums/thread/844579)). Apple hasn't confirmed this mechanism.
- Users should be told not to swipe the app away. iOS 26 reports suggest that ends tracking until the app is reopened.

### Gaps
- No Apple statement on whether a kCLLocationAccuracyThreeKilometers standard session keeps an app running indefinitely on iOS 26, or how much power that costs.
- Force-quit behavior for liveUpdates, CLServiceSession and visits isn't documented by Apple.

## 4. Why DIY tracking apps drain the battery

### Takeaway
The documented and reported culprits are:
- GPS-class accuracy left on all the time, especially BestForNavigation with auto-pause disabled.
- Running GPS while stationary.
- Heavy per-update work in the background, such as UI or map rendering and timers.
- Misuse of SLC (Apple says it can cost more than expected), and duplicate overlapping services on one manager.
- Using location as a keep-alive for other work.

I found no good post-mortems with measured numbers for disk writes, logging, network or thermal effects.

### Cited Findings
- Requesting more accuracy than needed powers up extra hardware. The default is "best", so apps that never set desiredAccuracy run at maximum. — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- Typical bad configuration seen in a real app: `kCLLocationAccuracyBestForNavigation`, `distanceFilter` none or 5 m, `pausesLocationUpdatesAutomatically = NO`, and startUpdatingLocation plus startMonitoringSignificantLocationChanges called unconditionally on the same manager. — [Forum thread 844579](https://developer.apple.com/forums/thread/844579)
- Background UI work starved the location callback: a 750-child map view re-rendered by a position watcher plus a 5-second tick, at about 150 ms per update. — [Forum thread 844579](https://developer.apple.com/forums/thread/844579)
- SLC "run[s] continuously, around the clock ... and can actually result in higher energy use if not employed effectively." — [Energy Guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html)
- An unnecessary `location` UIBackgroundModes entry combined with SLC triggered battery drain in a 2012 case. — [Stack Overflow archive 9513249](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/9513249/battery-drain-when-using-corelocation-significant-location-monitoring-coreblue)
- distanceFilter doesn't reduce GPS power, so apps that rely on it to save battery while keeping high accuracy still drain. — [Stack Overflow archive](https://kaweah.freedombox.rocks/kiwix/content/stackoverflow.com_en_all_2023-11/questions/20446113/ios7-is-it-more-power-efficient-to-defer-updates-or-to-set-desired-accuracy-to); [Medium, mizutori](https://medium.com/@mizutori/tracking-highly-accurate-location-in-ios-vol-3-7cd827a84e4d)
- Example of a successful design: Arc Timeline says it is "only awake and using GPS when you are active and moving", stays in "a low power sleep mode, with GPS turned off" the rest of the day, and warns that long trips use more battery. — [Arc Timeline App Store](https://apps.apple.com/us/app/arc-timeline-trips-places/id1063151918)
- The LocoKit author's own claim, not independently measured: with dynamic accuracy plus low-power sleep while stationary, recording sessions run 24-48 hours on one charge (2-4 days on larger phones). — [LocoKit issue 72](https://www.github.com/sobri909/LocoKit/issues/72); [LocoKit README](https://github.com/sobri909/LocoKit) (`useLowPowerSleepModeWhileStationary`, "Automatic energy use management, enabling all day recording")
- Using location only to keep the app alive is disallowed. — [Forum thread 763696](https://developer.apple.com/forums/thread/763696)

### Inferences
- Rules for a diary:
  - Never use BestForNavigation.
  - Rely on stationary pause, or visits plus motion, to turn GPS off at rest.
  - Batch database writes rather than committing on every fix.
  - Do no UI, map or timer work while backgrounded.
  - Avoid network calls (a private diary needs none).
  - Keep logging minimal.
  These follow from the CPU-wakeup and radio cost model above. Only the UI and map item has direct field evidence here.

### Gaps
- I found no sourced measurements of the energy cost of SQLite or Core Data commits per fix, verbose logging, background timers, or thermal throttling for location apps. These are plausible but unverified here.
- No Apple DTS post-mortem of a specific drain case was found.

## 5. Changes in iOS 17, 18 and 26

### Takeaway
- **iOS 17:** introduced liveUpdates, CLMonitor and CLBackgroundActivitySession.
- **iOS 18:** added CLServiceSession, made Always authorization effective only while a session is held, and renamed isStationary to stationary.
- **iOS 26.x:** has reported regressions (didVisit stops delivering, FB21022960) and stricter force-quit behavior for SLC and regions. Neither is officially confirmed or documented.
- **iOS 27** (current release, autumn 2026): developers report the same background suspension gaps as on iOS 26.

### Cited Findings
- iOS 17 introduced CLLocationUpdate.liveUpdates, isStationary, LiveConfiguration and CLBackgroundActivitySession. — [WWDC23 10180](https://developer.apple.com/videos/play/wwdc2023/10180/)
- iOS 18 introduced CLServiceSession, implicit sessions, diagnostics and `NSLocationRequireExplicitServiceSession`. From iOS 18, Always authorization is effective only while a session is held, and one can only be started in the foreground. — [WWDC24 10212](https://developer.apple.com/videos/play/wwdc2024/10212/)
- The iOS 18 SDK uses `update.stationary` in place of `isStationary`. — [Forum thread 810433](https://developer.apple.com/forums/thread/810433)
- iOS 26.0, 26.0.1 and 26.1: didVisit stops delivering on some devices, and only a reinstall fixes it. Apple called it a possible regression (FB21022960). — [Forum thread 807301](https://developer.apple.com/forums/thread/807301)
- iOS 26.4.2: no relaunch by SLC or regions after force-quit, versus relaunch on iOS 18 according to the poster. No Apple reply. — [Forum thread 826964](https://developer.apple.com/forums/thread/826964)
- iOS 26: background location stopped with kCLErrorDomain error 1 when permission was "Ask" or "Never". It worked on iOS 18. — [Forum thread 735929](https://developer.apple.com/forums/thread/735929)
- iOS 26 and 27: suspension gaps of 2-9 minutes while driving with legacy configuration. The poster corrected the report to say it is not an iOS 27 regression, because the gaps were also present on iOS 26. — [Forum thread 844579](https://developer.apple.com/forums/thread/844579)
- General iOS 26 battery-drain complaints from users are anecdotal. Some guides attribute post-update drain to re-indexing, but that isn't verified against Apple. — [Apple Community thread](https://discussions-kr-prz.apple.com/en/thread/256153355?page=11); [allthings.how](https://allthings.how/ios-26-battery-drain-explained-whats-normal-and-how-to-fix-it)

### Inferences
- An iOS 26 diary shouldn't rely on visits alone, given FB21022960. It should cross-check visits against liveUpdates or motion data, and detect missing visits so it can surface a "reinstall or re-grant" hint.
- Target the modern stack: liveUpdates, CLBackgroundActivitySession, CLServiceSession(.always) and CLMonitor. This is the path Apple keeps investing in, while the legacy SLC and region relaunch path appears to be tightening.

### Gaps
- I didn't review the official iOS 26 release notes for Core Location changes. No Apple-documented iOS 26 API additions for location energy were found in this pass.
- No confirmation of whether FB21022960 was fixed in a later 26.x release.
