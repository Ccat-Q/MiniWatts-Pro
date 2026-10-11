# MiniWatts Pro

**English** · [简体中文](README.zh-Hans.md)

[![Build](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml/badge.svg)](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml)

An iPhone battery and charging monitor built on Apple's private APIs. It reads the
phone's own power-management sensors — the ones iOS uses to run the charge — and shows
what the charger is delivering, how much of it reaches the cell, the phone's own consumption and conversion loss, and what every temperature sensor in the phone is doing while it happens.

| Power | Thermal | Adapter | History |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="Power"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="Thermal"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="Adapter"> | <img src="docs/screenshots/history.jpg" width="200" alt="History"> |

> **Sideload only.** Private APIs mean this can never be on the App Store — you sign
> and install it yourself. Analysis is local and nothing is uploaded automatically;
> reports leave the device only when you choose to share them.

## Install

Download the latest `MiniWattsPro-unsigned.ipa` from
[Releases](https://github.com/Ccat-Q/MiniWatts-Pro/releases), or the latest successful
[Actions build](https://github.com/Ccat-Q/MiniWatts-Pro/actions/workflows/build.yml), and sign it with your own
Apple ID — [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io),
[SideStore](https://sidestore.io) and Xcode all do this. A free Apple ID works; the app
then expires after seven days and you re-sign it.

Requires iPhone, iOS 17 or later.

Or add the source to SideStore or AltStore — including the SideStore bundled with
LiveContainer — and install from there, so new versions show up as updates:

```
https://github.com/Ccat-Q/MiniWatts-Pro/releases/latest/download/apps.json
```

LiveContainer cannot run app extensions, so installed inside it MiniWatts Pro has no widget
and no Live Activity.

MiniWatts Pro includes a Home Screen and Lock Screen widget, and a Live Activity while
charging. The widget extension is one more App ID when you sign — a free Apple ID gets
ten a week — and if your signing tool offers to remove extensions, doing so removes the
widget.

## What it can't do

Sensor names, scales and even which sensors exist differ by iPhone model, and none of
it is documented. The upstream sensor implementation was verified on an iPhone Air; on another
model a reading can be missing or mean something other than its name suggests.
Impossible values — a charge IC at −9199 °C, which someone really did see — are hidden
rather than shown, but a wrong value that looks plausible cannot be caught that way.
Please report anything surprising with your model identifier.

Only what iOS actually hands a sandboxed app. Battery health and cycle count are
filtered out of the registry; accessory batteries (Watch, AirPods) come back empty;
wireless charging exposes no input current, so on MagSafe you only see what reaches the
cell; discharge power has no sensor and is estimated from the percentage. Charging holds
can only be inferred, and the app labels them `inferred` when that is what happened.

Widgets refresh when iOS decides to, usually every 15 to 60 minutes, and each one shows
when its numbers were taken. The Live Activity only updates while MiniWatts Pro is running;
once the app is suspended it shows the reading as paused. Neither can be made to update
once a second — that budget is the system's to spend, not the app's.

For a reading that does move once a second while you are in another app, open the
floating meter from Settings: a small Picture in Picture window that keeps MiniWatts Pro
running, so it also records the charge with the screen locked. It costs battery, and
you close it yourself. It plays no sound — Picture in Picture is a video feature, which
is the only reason the app declares audio playback at all.

## Charge analysis and reports

MiniWatts Pro installs alongside the original MiniWatts with its own history. Set a
charge target from 50% to 100% (100% by default); remaining time combines the current
percentage trend with comparable local history. Estimates show their basis, and stop
when charging pauses or observation is interrupted. The target does not control iOS's
charging limit.

The Analysis tab offers an overview and records, 7/30/90-day and custom date filters,
separate wired/wireless comparisons of the same percentage range, and coverage-aware
energy and temperature statistics. All recorded five-second samples are retained until
you delete them. Delete one record, a date range or all finished records; the current
charge keeps running. No history is imported from the original app.

Export a single charge or selected date range as a PDF report, or export session and
sample CSV tables through the system share sheet. Missing readings remain missing;
background gaps are excluded. See [the feature specification](docs/analysis-design.md).

All compilation and automated tests run in GitHub Actions. Development builds provide
`MiniWattsPro-unsigned.ipa` as a workflow artifact; version-tag builds publish releases.
Device interaction and sensor validity still require testing on an iPhone.

## Build

Xcode 26 or later, iOS 17 deployment target, no dependencies.

Use **Actions → Build → Run workflow** for a development build. The workflow runs
model/storage tests, simulator PDF/CSV tests in English and Chinese, and IPA identity
and privacy checks before uploading the IPA. No local compilation is used for this
implementation.

[`CLAUDE.md`](CLAUDE.md) is the engineering notebook: which APIs the sandbox blocks and
how that was established, what each sensor turned out to be, and the Swift 6 isolation
traps this project has already fallen into.

## Licence

Based on [MiniWatts by ResistanceTo](https://github.com/ResistanceTo/MiniWatts).

Apache 2.0 — see [LICENSE](LICENSE). The method for reading the PMU is derived from
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor) (MIT);
`BatteryCenterBridge` owes two details to [Batsie](https://github.com/leptos-null/Batsie).
Both are credited in [NOTICE](NOTICE), which carries the upstream MIT notice.

Private APIs can change or disappear in any iOS update.
