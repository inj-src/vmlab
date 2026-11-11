#!/bin/bash
# pps-stop.sh: install a root LaunchDaemon that freezes PerfPowerServices (SIGSTOP) in the macOS VM.
# Why: its PLSMCMetricsAgent enumerates SMC keys by index, and QEMU's isa-applesmc only emulates a
# handful of keys, so the loop never ends and pins one host core (~100% CPU forever). SIP refuses
# `launchctl disable` for Apple daemons. A stopped process is not dead, so launchd leaves it alone.
# Run over `vm ssh mac` (passwordless sudo). Undo: sudo launchctl bootout system/local.vmlab.pps-stop
set -e
sudo install -d -o root -g wheel /usr/local/libexec
sudo tee /usr/local/libexec/vmlab-pps-stop >/dev/null <<'SH'
#!/bin/bash
# Wait for PerfPowerServices after boot, then stop it; re-run every 5 min covers relaunches.
for i in $(seq 60); do pgrep -x PerfPowerServices >/dev/null && break; sleep 2; done
pkill -STOP -x PerfPowerServices; exit 0
SH
sudo chmod 755 /usr/local/libexec/vmlab-pps-stop
sudo tee /Library/LaunchDaemons/local.vmlab.pps-stop.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.vmlab.pps-stop</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/vmlab-pps-stop</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PL
sudo chown root:wheel /Library/LaunchDaemons/local.vmlab.pps-stop.plist
sudo chmod 644 /Library/LaunchDaemons/local.vmlab.pps-stop.plist
sudo launchctl bootout system/local.vmlab.pps-stop 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/local.vmlab.pps-stop.plist
sleep 3; ps -o pid,stat,comm -p "$(pgrep -x PerfPowerServices)"
