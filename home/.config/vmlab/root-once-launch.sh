#!/bin/bash
# Waits until the 23:00-03:00 login rule lets sudo through, then raises one sudo prompt for
# root-once.sh. The prompt stays up until someone answers it. Log: /vmlab/reims/root-once.log
log=/vmlab/reims/root-once.log
echo "$(date '+%F %T') waiting for 03:01" >> "$log"
until t=$(date +%H%M); [[ $t > 0300 && $t < 2300 ]]; do sleep 30; done
echo "$(date '+%F %T') raising the sudo prompt" >> "$log"
SUDO_ASKPASS=$HOME/.config/vmlab/askpass-root-once sudo -A "$HOME/.config/vmlab/root-once.sh" >> "$log" 2>&1
echo "$(date '+%F %T') CHAIN exit=$?" >> "$log"
