#!/bin/bash
# debloat.sh: quieter macOS test VM. Run over `vm ssh mac` as dev (uses passwordless sudo); reboot after.
# Apple's apps live on the sealed system volume and stay; this only switches off background work,
# prompts and clutter that cost CPU or get in the way of GUI agents. Reversible: launchctl enable ...
set -u
U=$(id -u)
# Background services. SIP ignores `launchctl disable` for some system daemons (PerfPowerServices
# among them), so pps-stop.sh freezes that one; these lines stay for the daemons that do honour it.
for s in com.apple.PerfPowerServices com.apple.PerfPowerServicesExtended com.apple.analyticsd com.apple.SubmitDiagInfo; do
  sudo launchctl disable system/$s
done
for s in com.apple.photoanalysisd com.apple.mediaanalysisd com.apple.Siri.agent com.apple.assistantd \
         com.apple.siriknowledged com.apple.suggestd com.apple.knowledge-agent com.apple.parsecd \
         com.apple.gamed com.apple.newsd com.apple.followupd; do
  launchctl disable gui/$U/$s
done
# Siri off; no AirPlay receiver or Handoff
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults -currentHost write com.apple.controlcenter AirplayRecieverEnabled -bool false
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
# Clear the red badge on System Settings (Apple Account sign-in nag)
defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null
# Chrome as the default browser (applied at next login, no confirmation dialog), and a short Dock
~/.local/bin/python3 - <<'PY'
import os, plistlib, subprocess, urllib.parse
home = os.path.expanduser("~")
ls = f"{home}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
os.makedirs(os.path.dirname(ls), exist_ok=True)
d = plistlib.load(open(ls, "rb")) if os.path.exists(ls) else {}
h = [x for x in d.get("LSHandlers", []) if x.get("LSHandlerURLScheme") not in ("http", "https")
     and x.get("LSHandlerContentType") not in ("public.html", "public.xhtml")]
for scheme in ("http", "https"):
    h.append({"LSHandlerURLScheme": scheme, "LSHandlerRoleAll": "com.google.chrome",
              "LSHandlerPreferredVersions": {"LSHandlerRoleAll": "-"}})
for ct in ("public.html", "public.xhtml"):
    h.append({"LSHandlerContentType": ct, "LSHandlerRoleAll": "com.google.chrome",
              "LSHandlerPreferredVersions": {"LSHandlerRoleAll": "-"}})
d["LSHandlers"] = h
plistlib.dump(d, open(ls, "wb"))
apps = ["/System/Applications/Launchpad.app", "/Applications/Safari.app", "/Applications/Google Chrome.app",
        "/System/Applications/Utilities/Terminal.app", "/Applications/Visual Studio Code.app",
        "/System/Applications/System Settings.app"]
def tile(p):
    url = "file://" + urllib.parse.quote(p) + "/"
    return {"tile-data": {"file-data": {"_CFURLString": url, "_CFURLStringType": 15}}, "tile-type": "file-tile"}
tiles = [tile(p) for p in apps if os.path.exists(p)]
subprocess.run(["defaults", "write", "com.apple.dock", "persistent-apps", "-array", *[
    plistlib.dumps(t, fmt=plistlib.FMT_XML).decode().split("<plist version=\"1.0\">")[1].rsplit("</plist>", 1)[0].strip()
    for t in tiles]], check=True)
print("dock:", len(tiles), "apps; default browser: com.google.chrome")
PY
killall Dock 2>/dev/null
echo DEBLOAT-OK
