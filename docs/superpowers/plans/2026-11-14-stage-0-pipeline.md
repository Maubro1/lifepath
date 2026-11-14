# Stage 0: Build and Install Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the €0 route end to end: code pushed from Windows is built on GitHub's free Mac runners into an unsigned IPA, installed on the owner's iPhone 15 Pro via SideStore, survives an update with its data intact, and survives one SideStore refresh.

**Architecture:** XcodeGen `project.yml` defines the app target and the local `Core` Swift package. The app is one SwiftUI screen showing version, launch count (proves data survives updates) and signing expiry (read from `embedded.mobileprovision` by Core). GitHub Actions runs Core tests on every push and publishes a GitHub Release with the IPA on `v*` tags.

**Tech Stack:** Swift 6, SwiftUI, iOS 26.0, XcodeGen, GitHub Actions (`macos-26`), SideStore + LocalDevVPN.

**Spec:** `docs/superpowers/specs/2026-11-14-lifepath-design.md` (sections "Toolchain", "Signing expiry reminder", "Stages" item 0)

## Global Constraints

- Deployment target iOS 26.0; Swift 6 language mode; Core `swift-tools-version: 6.0`.
- Bundle ID `app.lifepath.LifePath`, display name `LifePath`. Never change it.
- Core imports Foundation only (no UIKit, CoreLocation, SwiftUI).
- No third-party dependencies in this stage (GRDB arrives in stage 1).
- Repo is public: never commit `*.lifepath`, `*.gpx`, `*.geojson`, `*.kml` outside `Core/Tests/**/Fixtures/`; git identity stays `LifePath <lifepath@users.noreply.github.com>`.
- Unsigned build: `CODE_SIGNING_ALLOWED=NO`; SideStore signs on the phone.
- Development happens on Windows with no local Swift toolchain: CI is the only compiler. Each code task is verified by pushing and reading the CI result.

## Review Focus

1. Runner image lacks Xcode 26 / iOS 26 SDK → CI must fail loudly at a version check, not with an obscure compile error. (Task 3 step "Assert Xcode version")
2. IPA layout wrong (`Payload/LifePath.app` missing or nested) → SideStore rejects it. (Task 3 step "Verify IPA layout")
3. Missing privacy strings or background mode in the built Info.plist → crash or rejection in stage 1. (Task 3 step "Verify Info.plist keys")
4. App run where no `embedded.mobileprovision` exists, or file is garbage → screen shows "Signing expiry: unknown", no crash. (Task 1 test `testGarbageReturnsNil`, `testMissingPlistEndReturnsNil`)
5. Update re-signed under a different bundle ID by SideStore → data loss. (Task 5 launch-counter check)

---

### Task 1: Core package with provisioning-profile parser

**Files:**
- Create: `Core/Package.swift`
- Create: `Core/Sources/Core/ProvisioningProfile.swift`
- Create: `Core/Tests/CoreTests/ProvisioningProfileTests.swift`

**Interfaces:**
- Produces: `public enum ProvisioningProfile { public static func expirationDate(from data: Data) -> Date? }`

`Package.swift`: library product `Core`, target `Core`, test target `CoreTests`, platforms `.iOS(.v26), .macOS(.v15)` (macOS so `swift test` runs on the runner host).

- [ ] **Step 1: Write the failing tests**

```swift
final class ProvisioningProfileTests: XCTestCase {
    // A real profile is CMS-signed binary wrapping an XML plist; simulate with junk around it.
    func wrap(_ plist: String) -> Data {
        Data([0x30, 0x82, 0x01, 0xFF]) + Data(plist.utf8) + Data([0x00, 0xA0, 0x82])
    }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>ExpirationDate</key><date>2026-11-21T10:00:00Z</date></dict></plist>
    """
    func testReadsExpirationDate() {
        XCTAssertEqual(ProvisioningProfile.expirationDate(from: wrap(plist)),
                       ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
    }
    func testGarbageReturnsNil() { XCTAssertNil(ProvisioningProfile.expirationDate(from: Data([1, 2, 3]))) }
    func testMissingPlistEndReturnsNil() {
        XCTAssertNil(ProvisioningProfile.expirationDate(from: wrap(String(plist.dropLast(8)))))
    }
    func testPlistWithoutDateReturnsNil() {
        let noDate = plist.replacingOccurrences(of: "ExpirationDate", with: "Other")
        XCTAssertNil(ProvisioningProfile.expirationDate(from: wrap(noDate)))
    }
}
```

- [ ] **Step 2: Implement `expirationDate(from:)`**

Find the byte range from `<?xml` to the end of `</plist>`, decode with `PropertyListSerialization`, return `dict["ExpirationDate"] as? Date`. Any failure returns nil.

- [ ] **Step 3: Commit** (verified by CI in Task 3)

```bash
git add Core && git commit -m "Core: provisioning profile expiry parser"
```

### Task 2: App target and project definition

**Files:**
- Create: `project.yml`
- Create: `LifePath/LifePathApp.swift`
- Create: `LifePath/PipelineView.swift`
- Create: `LifePath/Info.plist` (generated keys via `project.yml` `info.properties` is fine instead)
- Create: `LifePath/Assets.xcassets` (AppIcon placeholder, AccentColor)

**Interfaces:**
- Consumes: `ProvisioningProfile.expirationDate(from:)`

`project.yml` decisions: project name `LifePath`; target `LifePath`, type `application`, platform iOS, deploymentTarget `26.0`; `packages: Core: { path: Core }`, dependency `- package: Core`; settings `PRODUCT_BUNDLE_IDENTIFIER: app.lifepath.LifePath`, `SWIFT_VERSION: 6.0`, `MARKETING_VERSION: 0.0.1`, `CURRENT_PROJECT_VERSION: 1`, `TARGETED_DEVICE_FAMILY: 1`, `GENERATE_INFOPLIST_FILE: NO`. Scheme `LifePath`.

Info.plist must contain (copy for later stages, exact strings may be restyled at stage 5):
- `UIBackgroundModes`: `[location]`
- `NSLocationWhenInUseUsageDescription`: "LifePath draws a private map of where you go. Your location never leaves this iPhone."
- `NSLocationAlwaysAndWhenInUseUsageDescription`: "LifePath records in the background so your map stays complete, even when the app is closed. Nothing leaves this iPhone."
- `NSMotionUsageDescription`: "LifePath uses your steps and motion to notice when you set off and to save battery while you're still."
- `UILaunchScreen`: empty dict; `CFBundleDisplayName`: LifePath

- [ ] **Step 1: Implement `PipelineView`**

One SwiftUI screen with three rows:
- "Version" → `CFBundleShortVersionString (CFBundleVersion)`
- "Opened" → launch count. `LifePathApp.init` increments `UserDefaults.standard` key `pipeline.launchCount` once per process start.
- "Signing expires" → `Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")` → `Data` → `ProvisioningProfile.expirationDate`, formatted `.dateTime`; nil anywhere → "unknown".

- [ ] **Step 2: Commit**

```bash
git add project.yml LifePath && git commit -m "App: pipeline screen with version, launch count, signing expiry"
```

### Task 3: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/package-ipa.sh`

**Interfaces:**
- Produces: artifact `LifePath-ipa` on every push; GitHub Release asset `LifePath.ipa` on tags `v*`.

Jobs, all `runs-on: macos-26` (if that label is unavailable when this runs, `macos-15` plus `sudo xcode-select -s` the newest `/Applications/Xcode_26*.app`):

- [ ] **Step 1: `test` job** — checkout; assert Xcode version (`xcodebuild -version | grep -q "Xcode 26"` else `exit 1` with message "Runner lacks Xcode 26"); `swift test --package-path Core`.
- [ ] **Step 2: `build` job** (needs `test`) — `brew install xcodegen`; `xcodegen generate`; `xcodebuild archive -project LifePath.xcodeproj -scheme LifePath -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/LifePath.xcarchive CODE_SIGNING_ALLOWED=NO`; `scripts/package-ipa.sh build/LifePath.xcarchive build/LifePath.ipa`.
- [ ] **Step 3: `scripts/package-ipa.sh`** — copy `Products/Applications/LifePath.app` into a temp `Payload/`, `zip -qry` to the output path. `set -euo pipefail`.
- [ ] **Step 4: Verify IPA layout** — `unzip -l build/LifePath.ipa | grep -q "Payload/LifePath.app/LifePath"` else fail.
- [ ] **Step 5: Verify Info.plist keys** — for each of `UIBackgroundModes NSLocationWhenInUseUsageDescription NSLocationAlwaysAndWhenInUseUsageDescription NSMotionUsageDescription`: `/usr/libexec/PlistBuddy -c "Print :$k" <app>/Info.plist` must succeed; also `Print :CFBundleIdentifier` must equal `app.lifepath.LifePath`.
- [ ] **Step 6: Upload and release** — `actions/upload-artifact@v4` name `LifePath-ipa`; on `startsWith(github.ref, 'refs/tags/v')`, `softprops/action-gh-release@v2` with `files: build/LifePath.ipa` (job `permissions: contents: write`).
- [ ] **Step 7: Commit**

```bash
git add .github scripts && git commit -m "CI: Core tests, unsigned IPA build, release on tags"
```

### Task 4: GitHub repository and first green build (owner + Claude)

- [ ] **Step 1 (owner):** sign in or create a free GitHub account; create a **public** repository named `lifepath` with no README.
- [ ] **Step 2:** `git remote add origin https://github.com/<owner>/lifepath.git`; `git push -u origin main` (Git Credential Manager opens a browser sign-in for the owner).
- [ ] **Step 3:** Read the Actions run. Expected: `test` and `build` green, artifact `LifePath-ipa` present. Red → fix via superpowers:systematic-debugging, push, repeat.
- [ ] **Step 4:** `git tag v0.0.1 && git push origin v0.0.1`. Expected: Release `v0.0.1` with `LifePath.ipa`.

### Task 5: Install, update and refresh on the iPhone (owner, guided live)

Follow the current Windows guide on docs.sidestore.io at the time of execution (iOS 26.6.x; nightly SideStore if the docs say so). Do not use LiveContainer.

- [ ] **Step 1:** iPhone: Settings → Privacy & Security → Developer Mode on (restart).
- [ ] **Step 2:** Install SideStore from Windows with the tool the docs name, signed with the owner's Apple ID; install LocalDevVPN from the App Store.
- [ ] **Step 3:** On the iPhone, open the v0.0.1 Release in Safari, download `LifePath.ipa`, install via SideStore. Expected: LifePath opens showing `0.0.1 (1)`, "Opened 1", expiry about 7 days ahead.
- [ ] **Step 4:** Bump `MARKETING_VERSION` to `0.0.2`, `CURRENT_PROJECT_VERSION` to `2`, commit, tag `v0.0.2`, push. Install over the old app from SideStore. Expected: `0.0.2 (2)` and "Opened" count continues (> 1). If it resets to 1, the bundle ID changed: stop and investigate before stage 1.
- [ ] **Step 5:** In SideStore (LocalDevVPN connected) tap Refresh All. Expected: LifePath still opens, expiry moved later, count continues.
- [ ] **Step 6:** Record the outcome (dates, any workaround needed) in `docs/install.md` as the owner's install and refresh guide; commit.

Stage 0 is done when steps 3–5 all pass.
