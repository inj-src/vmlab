#!/usr/bin/env bash
# share-smbd.sh DIR STATE: serve the host folder DIR to one VM as \\10.0.2.4\qemu. QEMU's user
# network runs this for each connection the guest makes to 10.0.2.4:445, with the connection
# as stdin (guestfwd=tcp:10.0.2.4:445-cmd:...), which is how QEMU's own `smb=DIR` runs smbd.
# The settings are QEMU's, and leases and oplocks off.
#
# Why not `smb=`: with leases on, a file replaced on the host (sed -i, an editor's save, git
# checkout: a new file under the old name) could not be opened in Windows for about a minute:
# "The parameter is incorrect". Windows keeps a lease on the file it read and offers the same
# lease for the name again; Samba finds another file there and refuses. Seen 2026-11-12;
# turning the caches and oplocks off in Windows' own SMB client changed nothing.
set -euo pipefail
dir=$1 state=$2
mkdir -p "$state"
[[ -f $state/smbpasswd ]] || : > "$state/smbpasswd"
cat > "$state/smb.conf.$$" <<CONF
[global]
private dir=$state
interfaces=127.0.0.1
bind interfaces only=yes
pid directory=$state
lock directory=$state
state directory=$state
cache directory=$state
ncalrpc dir=$state/ncalrpc
log file=$state/log.smbd
smb passwd file=$state/smbpasswd
security = user
map to guest = Bad User
load printers = no
printing = bsd
disable spoolss = yes
usershare max shares = 0
smb2 leases = no
oplocks = no
level2 oplocks = no
[qemu]
path=$dir
read only=no
guest ok=yes
force user=$(id -un)
CONF
mv "$state/smb.conf.$$" "$state/smb.conf"
exec /usr/sbin/smbd -l "$state" -s "$state/smb.conf"
