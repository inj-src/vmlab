#!/bin/bash
# vmlab: the host's shared folder in the Mac guest, at ~/share. Run over SSH as dev, then
# `vm commit mac`. Idempotent.
# The host side is QEMU's private Samba server at //10.0.2.4/qemu (mac26.sh, MAC26_SHARE). A
# LaunchAgent in the desktop session mounts it at login and every minute while it is not
# mounted; SSH sessions see that mount too.
#
# One step is by hand, once: macOS keeps network volumes from SSH sessions ("Operation not
# permitted", whoever mounted them) until System Settings > General > Sharing > Remote Login (i)
# > "Allow full disk access for remote users" is on. With System Integrity Protection on, no
# command can set that. It also opens ~/Desktop, ~/Documents and ~/Downloads to SSH sessions.
set -euo pipefail

mkdir -p ~/share ~/Library/LaunchAgents ~/.local/bin
cat > ~/.local/bin/vmlab-share <<'SH'
#!/bin/sh
# vmlab: mount the host's shared folder, QEMU's private SMB server, as a guest
mount | grep -q " on $HOME/share (smbfs" || /sbin/mount_smbfs -N //guest@10.0.2.4/qemu "$HOME/share"
SH
chmod +x ~/.local/bin/vmlab-share
cat > ~/Library/LaunchAgents/local.vmlab.share.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.vmlab.share</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/vmlab-share</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/local.vmlab.share" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.vmlab.share.plist

ls ~/share >/dev/null 2>&1 && echo "~/share is readable here" \
  || echo "~/share is not readable in this session: see the step by hand at the top of this script"
