#!/bin/bash
# vmlab macOS bootstrap. Run once in Terminal as: curl -fsSL http://192.168.122.1:8765/b.sh | sudo bash
set -x
U=dev
# SSH: agent key + Remote Login
install -d -m 700 -o $U -g staff /Users/$U/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUEPIiYLWaKxnr+KS1KWgJvms7gTVBgGmHIQMS9hYL7 vmlab-agents' > /Users/$U/.ssh/authorized_keys
chown $U:staff /Users/$U/.ssh/authorized_keys; chmod 600 /Users/$U/.ssh/authorized_keys
launchctl enable system/com.openssh.sshd
launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || launchctl load -w /System/Library/LaunchDaemons/ssh.plist
# Passwordless sudo for agents
echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vmlab; chmod 440 /etc/sudoers.d/vmlab
# Auto-login as dev (FileVault must be off)
echo 'C+Q+QrC83eqjuR99' | base64 -D > /etc/kcpassword; chmod 600 /etc/kcpassword
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser $U
# Never sleep, no screensaver password, no lock
pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 standby 0 autorestart 1
sudo -u $U defaults -currentHost write com.apple.screensaver idleTime 0
sudo -u $U defaults write com.apple.screensaver askForPassword -int 0
# No automatic macOS updates (testing VM)
softwareupdate --schedule off
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
# Keep Spotlight indexing ON: with it off, Spotlight finds no apps and GUI agents that open apps
# with Cmd+Space waste turns. Let the first index finish before committing the base image.
# Reduce Motion / Reduce Transparency (less CPU rendering, no mid-animation screenshots) cannot be
# written with `defaults` (protected domain); set them in System Settings > Accessibility > Display.
systemsetup -settimezone Asia/Dhaka 2>/dev/null
# QEMU USB keyboard (vendor 1575, product 1) is ANSI: no Keyboard Setup Assistant; U.S. layout only
defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype -dict-add "1-1575-0" -integer 40
US='<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>0</integer><key>KeyboardLayout Name</key><string>U.S.</string></dict>'
sudo -u $U defaults write com.apple.HIToolbox AppleEnabledInputSources -array "$US"
sudo -u $U defaults write com.apple.HIToolbox AppleSelectedInputSources -array "$US"
# Clean desktop on every boot: no reopened windows (GUI agents expect a known start state)
sudo -u $U defaults write com.apple.loginwindow TALLogoutSavesState -bool false
sudo -u $U defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
sudo -u $U defaults write -g NSQuitAlwaysKeepsWindows -bool false
# No "See what's new" Tips notifications popping over the desktop
sudo -u $U launchctl disable gui/$(id -u $U)/com.apple.tipsd
# The wheel scrolls as on the host's desktop (macOS's "natural scrolling" off; the user's wish,
# 2026-11-12). In a running session, apply it without a logout:
# /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
sudo -u $U defaults write -g com.apple.swipescrolldirection -bool false
# Stable Dock: no "recent apps" section that shifts with whatever ran last
sudo -u $U defaults write com.apple.dock show-recents -bool false
# The first-boot "See what's new in macOS" notification survives the tipsd disable: click it once
# (opens Tips), then quit Tips, before committing the base image.
# Wallpaper: the default Sequoia Sunrise is a video and renders white without a GPU. Set a still
# image from the GUI session (NSWorkspace needs it), e.g. as root:
#   launchctl asuser 501 sudo -u dev swift setwp.swift "/System/Library/Desktop Pictures/Sonoma.heic"
# with setwp.swift calling NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]).
echo VMLAB-BOOTSTRAP-OK
