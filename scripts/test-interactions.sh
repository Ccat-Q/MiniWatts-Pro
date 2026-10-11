#!/bin/bash
# All simulator builds and runtime interaction tests run on GitHub Actions.
set -euo pipefail
simulator=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime in sorted(devices, reverse=True) for d in devices[runtime] if d["isAvailable"] and d["name"].startswith("iPhone")))')
xcrun simctl boot "$simulator" || true
finish_tests() {
  local test_status=$?
  if [ -d build/ui-tests.xcresult ]; then
    xcrun xcresulttool export attachments --path build/ui-tests.xcresult --output-path build/ui-attachments || true
    xcrun xcresulttool get test-results summary --path build/ui-tests.xcresult > build/ui-summary.json || true
  fi
  xcrun simctl shutdown "$simulator" || true
  exit "$test_status"
}
trap finish_tests EXIT
xcrun simctl bootstatus "$simulator" -b
xcodebuild test -project MiniWatts.xcodeproj -scheme MiniWatts \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath build/UITestDerivedData -resultBundlePath build/ui-tests.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" | tee build/ui-tests.log
