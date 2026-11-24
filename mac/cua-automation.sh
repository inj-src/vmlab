#!/bin/zsh
# cua-automation.sh: allow Cua Driver to send Apple Events to every installed app (macOS's
# Automation consent), as if each first-use prompt had been answered Allow. Cua uses them for a
# background Save, a Finder rename and System Events; an unanswered prompt blocks the action.
# From the host, with mac running: ssh mac 'zsh -s' < /vmlab/tools/vmlab/mac/cua-automation.sh
# It runs as dev over SSH, whose Full Disk Access lets it write dev's TCC database (SIP guards
# only the system one). Each row carries both sides' designated requirements, as macOS's own
# rows do, so a re-signed app is asked again. Run it again after installing an app.
set -euo pipefail
db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
client=com.trycua.driver
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

req_hex() { # app path -> hex of its compiled designated requirement
  local dr
  dr=$(codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p') || return 1
  [[ -n $dr ]] || return 1
  print -r -- "$dr" | csreq -r- -b "$tmp/req" 2>/dev/null || return 1
  xxd -p "$tmp/req" | tr -d '\n'
}

client_hex=$(req_hex /Applications/CuaDriver.app)
apps=( "/System/Library/CoreServices/System Events.app" /System/Library/CoreServices/Finder.app
       /Applications/*.app(N) /Applications/*/*.app(N) /System/Applications/*.app(N) /System/Applications/Utilities/*.app(N) )
sql="BEGIN;"
n=0
for app in $apps; do
  [[ $app == /Applications/CuaDriver.app ]] && continue
  id=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null) || continue
  hex=$(req_hex "$app") || { print -u2 "skipped (unsigned): $app"; continue; }
  sql+="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags) VALUES ('kTCCServiceAppleEvents','$client',0,2,3,1,X'$client_hex',NULL,0,'$id',X'$hex',0);"
  n=$((n+1))
done
sql+="COMMIT;"
sqlite3 "$db" "$sql"
killall tccd 2>/dev/null || true   # dev's tccd reads the database again when launchd restarts it
print "Automation allowed for $n apps"
