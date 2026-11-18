#!/bin/bash
# Screenshots of every screen, light and dark, from the iOS Simulator with the app's demo data (CI, macOS).
set -euo pipefail
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
phones = [d for rt, l in devs.items() if "iOS" in rt for d in l if d["name"].startswith("iPhone") and "Pro" in d["name"] and "Max" not in d["name"]]
print(sorted(phones, key=lambda d: d["name"])[-1]["udid"])')
echo "Simulator $UDID"
xcodebuild build -project LifePath.xcodeproj -scheme LifePath -sdk iphonesimulator -destination "id=$UDID" \
  -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
APP=$(find build/sim/Build/Products -maxdepth 3 -name LifePath.app | head -1)
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always app.lifepath.LifePath || true
xcrun simctl location "$UDID" set 52.0880,5.1660 || true
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
mkdir -p screens
for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for screen in ${SCREENS:-streets fog heat you day settings}; do
    xcrun simctl launch --terminate-running-process "$UDID" app.lifepath.LifePath -demo -screen "$screen" -appearance "$appearance"
    sleep 15   # map tiles load over the network
    xcrun simctl io "$UDID" screenshot "screens/$screen-$appearance.png"
  done
done
ls -l screens
