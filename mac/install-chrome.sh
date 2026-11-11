#!/bin/bash
# install-chrome.sh: Google Chrome for the mac VM with no first-run noise. Run over `vm ssh mac` as dev.
# Afterwards, launch Chrome once in the GUI: untick both boxes in "Welcome to Google Chrome", click OK,
# answer the two macOS notification banners with Options > Don't Allow, quit Chrome, then commit the base.
set -euo pipefail
cd /tmp
curl -fsSL -o chrome.dmg https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
hdiutil attach -nobrowse -quiet -mountpoint /tmp/chromedmg chrome.dmg
sudo ditto "/tmp/chromedmg/Google Chrome.app" "/Applications/Google Chrome.app"
hdiutil detach -quiet /tmp/chromedmg; rm chrome.dmg
sudo mkdir -p /Library/Google
sudo tee "/Library/Google/Google Chrome Initial Preferences" >/dev/null <<'J'
{"distribution": {"skip_first_run_ui": true, "suppress_first_run_default_browser_prompt": true,
  "suppress_first_run_bubble": true, "make_chrome_default": false, "make_chrome_default_for_user": false,
  "import_bookmarks": false, "import_history": false, "import_home_page": false, "import_search_engine": false},
 "browser": {"check_default_browser": false, "has_seen_welcome_page": true},
 "sync_promo": {"show_on_first_run_allowed": false}}
J
# Policies: /Library/Managed Preferences is wiped at every boot unless a configuration profile owns
# it, so they come from chrome-policy.mobileconfig. Copy it to the VM, `open` it, then approve it in
# System Settings > General > Device Management (double-click, Install, password vmlab).
# Check with `sudo profiles list` and chrome://policy.
# No auto-update in a test VM (same as macOS updates)
sudo defaults write /Library/Preferences/com.google.Keystone.Agent checkInterval -int 0
defaults write com.google.Keystone.Agent checkInterval -int 0
echo CHROME-OK
