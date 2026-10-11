"""Check the distributed IPA identities and corresponding source entitlements."""
import plistlib
import sys
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


with zipfile.ZipFile(sys.argv[1]) as ipa:
    app_plists = [name for name in ipa.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
    require(len(app_plists) == 1, "Expected one main app")
    app = plistlib.loads(ipa.read(app_plists[0]))
    extension_plists = [name for name in ipa.namelist() if name.endswith(".appex/Info.plist")]
    require(len(extension_plists) == 1, "Expected one widget extension")
    widget = plistlib.loads(ipa.read(extension_plists[0]))
    require(app["CFBundleIdentifier"] == "io.github.ccatq.MiniWattsPro", "Wrong main app identifier")
    require(widget["CFBundleIdentifier"] == app["CFBundleIdentifier"] + ".Widget", "Wrong widget identifier")
    require(app["CFBundleDisplayName"] == widget["CFBundleDisplayName"] == "MiniWatts Pro", "Wrong display name")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(app[key] == widget[key] and bool(app[key]), "App/widget version mismatch: " + key)
    require(app["MinimumOSVersion"] == "17.0", "Unexpected deployment target")
    for file in (Path("MiniWatts/MiniWatts.entitlements"), Path("Widget/Widget.entitlements")):
        entitlement = plistlib.loads(file.read_bytes())
        require(entitlement["com.apple.security.application-groups"] == ["group.io.github.ccatq.MiniWattsPro"], "Wrong App Group: " + str(file))
    print("MiniWatts Pro IPA identities, display names, versions, iOS 17 and shared group verified")
