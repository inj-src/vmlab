#!/bin/bash
# desktop-ssh.sh: every SSH session of dev on the Mac VM runs in dev's GUI login session
# (vmlab-ssh-session). Run in the guest as root, from the folder holding vmlab-ssh-session;
# from the host: /vmlab/tools/vmlab/mac/install-desktop-ssh.sh. macOS starts sshd for each
# connection, so the next connection already has it.
#
# Not scripted (SIP guards the system TCC database), done once by hand in the clean state:
# System Settings > Privacy & Security > Screen & System Audio Recording and > Accessibility,
# "+", Cmd+Shift+G /usr/libexec/sshd-keygen-wrapper (macOS counts SSH sessions as that program;
# it already has Full Disk Access). Then `screencapture` and AX calls work over SSH. macOS asks
# again every 30 days about bypassing the window picker; the date it asks next is pushed out
# for SSH and for Cua (with replayd stopped, or it writes its cached copy back):
#   sudo pkill -9 -x replayd; defaults write "$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals" \
#     <program> -dict-add kScreenCapturePrivacyHintDate -date "2100-01-01 00:00:00 +0000"
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 /usr/local/libexec
install -m 755 -o root -g wheel vmlab-ssh-session /usr/local/libexec/vmlab-ssh-session
conf=/etc/ssh/sshd_config.d/100-vmlab.conf
grep -q '^Include /etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config || { echo "sshd_config does not include sshd_config.d" >&2; exit 1; }
cat > "$conf.new" <<'EOF'
# vmlab: dev's SSH sessions run in dev's GUI login session (/usr/local/libexec/vmlab-ssh-session)
Match User dev
    ForceCommand /usr/local/libexec/vmlab-ssh-session
EOF
chmod 644 "$conf.new"
# check the whole configuration with the new file before it counts
mv "$conf.new" "$conf"
if ! /usr/sbin/sshd -t; then rm -f "$conf"; echo "sshd rejected the configuration; nothing changed" >&2; exit 1; fi
/usr/sbin/sshd -T -C user=dev,host=localhost,addr=127.0.0.1 | grep -i '^forcecommand'
echo "desktop SSH is set up"
