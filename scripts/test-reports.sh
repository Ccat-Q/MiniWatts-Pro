#!/bin/bash
# Run only on the macOS/Xcode GitHub Actions runner.
set -euo pipefail

mkdir -p build/ReportTests.app
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
architecture=$(uname -m)
xcrun swiftc -swift-version 6 -parse-as-library \
  -sdk "$sdk" -target "${architecture}-apple-ios17.0-simulator" \
  MiniWatts/Core/Model/EnergyTotals.swift MiniWatts/Core/Model/ChargeSession.swift \
  MiniWatts/Core/Model/ChargeAnalysis.swift MiniWatts/Core/Model/ReportCSV.swift \
  MiniWatts/Core/Model/ReportGenerator.swift Tests/ReportTests.swift \
  -o build/ReportTests.app/ReportTests

# Give the standalone simulator test executable the application's localization keys.
python3 - <<'PY'
import json
import plistlib
from pathlib import Path
bundle = Path('build/ReportTests.app')
with (bundle / 'Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable': 'ReportTests', 'CFBundleIdentifier': 'io.github.ccatq.MiniWattsPro.ReportTests',
                  'CFBundleName': 'ReportTests', 'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en',
                  'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0'}, output)
strings = json.loads(Path('MiniWatts/Localizable.xcstrings').read_text())['strings']
for language in ('en', 'zh-Hans'):
    folder = bundle / (language + '.lproj')
    folder.mkdir(exist_ok=True)
    translations = {key: value.get('localizations', {}).get(language, {}).get('stringUnit', {}).get('value', key)
                    for key, value in strings.items()}
    with (folder / 'Localizable.strings').open('wb') as output:
        plistlib.dump(translations, output, fmt=plistlib.FMT_BINARY)
PY

simulator=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime in sorted(devices, reverse=True) for d in devices[runtime] if d["isAvailable"] and d["name"].startswith("iPhone")))')
xcrun simctl boot "$simulator" || true
trap 'xcrun simctl shutdown "$simulator" || true' EXIT
xcrun simctl bootstatus "$simulator" -b
SIMCTL_CHILD_REPORT_TEST_OUTPUT="$PWD/build/report-fixtures/en" xcrun simctl spawn "$simulator" "$PWD/build/ReportTests.app/ReportTests" -AppleLanguages '(en)' -AppleLocale en_US
SIMCTL_CHILD_REPORT_TEST_OUTPUT="$PWD/build/report-fixtures/zh-Hans" xcrun simctl spawn "$simulator" "$PWD/build/ReportTests.app/ReportTests" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN --chinese
