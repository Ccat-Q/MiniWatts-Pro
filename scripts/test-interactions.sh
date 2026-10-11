#!/bin/bash
# All simulator builds and runtime interaction tests run on GitHub Actions.
set -euo pipefail
simulator=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime in sorted(devices, reverse=True) for d in devices[runtime] if d["isAvailable"] and d["name"].startswith("iPhone")))')
xcrun simctl boot "$simulator" || true
trap 'xcrun simctl shutdown "$simulator" || true' EXIT
xcrun simctl bootstatus "$simulator" -b
xcodebuild test -project MiniWatts.xcodeproj -scheme MiniWatts \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath build/UITestDerivedData -resultBundlePath build/ui-tests.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" | tee build/ui-tests.log
