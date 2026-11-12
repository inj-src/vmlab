#!/bin/bash
# vmlab: Samba's smbd for QEMU's private per-VM share (-netdev user,smb=). The system services
# are masked first, so the host never serves SMB by itself.
set -e
systemctl mask smbd.service nmbd.service samba-ad-dc.service
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends samba || { apt-get update && apt-get install -y --no-install-recommends samba; }
systemctl is-active smbd nmbd samba-ad-dc || true
