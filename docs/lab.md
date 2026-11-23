# vmlab: how the lab is put together

For people and agents working **on** the lab. Agents that only use the VMs read the skill, `skills/vmlab/`; keep what they need there and the rest here.

The VMs run on this Linux laptop (Ubuntu 24.04, 23 GB RAM, i5-12450HX, RTX 4050) as QEMU user units outside libvirt, each rendering on the RTX 4050 through a virtual GPU. Their disks are on the spare SSD at `/vmlab`. `vm` calls each VM's launcher: `gpu/win3d/win-venus.sh` and `gpu/reims/mac26.sh`; their headers list more commands, and `gpu/README.md` explains the GPUs and every local patch.

## How agents get the lab

- **The skill** `skills/vmlab/` is linked into `~/.claude/skills/` and `~/.codex/skills/` by `./install.sh`. Its description is what every session sees; its files load when a task matches.
- **vmlab-mcp** (`vmlab-mcp/`) is registered for Claude Code (user scope) and Codex (with `tool_timeout_sec = 180`: the first call after `vm start` can wait 90 s for the desktop), also by `./install.sh`. Antigravity has vmlab-mcp (`~/.gemini/config/mcp_config.json`) but not the skill: it skips linked skills. Build and install the binary as `vmlab-mcp/README.md` says. Its `INSTRUCTIONS` (`src/server.rs`) point to the skill.
- Nothing about the lab belongs in the global `CLAUDE.md` or `~/.codex/AGENTS.md`.

## Behaviour behind the skill

- **Speed:** both VMs are pinned to the fast cores (CPUs 0–7). The lab leaves the laptop's power profile alone: the user picks Performance on the 170 W barrel charger. Linux reports the 100 W USB-C charger exactly like the barrel one (`ACAD` online, the Type-C port shows nothing), and Performance there (CPU limits 60 W sustained, 119 W bursts) draws more than the charger gives, which drops charging until it is replugged.
- **SSH on the desktop:** `win/desktop-ssh.ps1` runs sshd from dev's logon (elevated) with `win/vmshell` as its shell (Git Bash, or PowerShell for `VMLAB_SHELL=pwsh`, which `ssh win-pwsh` sets); `win/bash-env.sh` is the Git Bash setup. `mac/desktop-ssh.sh` does the Mac's; its SSH permissions are charged to `/usr/libexec/sshd-keygen-wrapper`, granted by hand in the clean state, and the 30-day Screen Recording re-ask is moved to 2100 for SSH and Cua. Cua Driver runs on the Mac as LaunchAgent `com.trycua.cua-driver` (`/Applications/CuaDriver.app`).
- **Debloat:** consumer apps, Widgets, Copilot, OneDrive and telemetry are removed or off on `win` (`win/debloat.ps1`); Siri, analytics and media analysis on `mac` (`mac/debloat.sh`). Chrome policies: `HKLM\SOFTWARE\Policies\Google\Chrome` on `win`, profile `local.vmlab.chrome` on `mac`.
- **PostgreSQL's installer:** EDB's server answers winget with 403, so `win/install-postgres.ps1` takes the address and hash from `winget show` and downloads with `curl.exe`.
- **The VM window:** keys go to the guest while it is active (GNOME asks "Allow inhibiting shortcuts" once per VM; Super+Escape or a click on the title bar gives the desktop its shortcuts back). The pointer is never held. On `mac`, moving the window between the 100% monitor and the 125% panel keeps the old resolution until Ctrl+Alt+F twice. The Mac's clipboard is `mac/spice-agent`, reached through SSH; a saved state keeps the agent it was saved with, and its `tests/unit.swift` is not for a VM you commit (it leaves a CPU loop).

## Sources

- **Windows GPU**, all in `gpu/win3d/`: the lab's QEMU (`build-qemu.sh`, `qemu-patches/`, source in `/vmlab/tmp/win-qemu/qemu`), the guest's Direct3D driver, which is Mesa (`build-guest-umd.sh`, `guest-patches/`), and its kernel driver (`build-guest-kmd.sh`, `kmd-patches/`). Upstream is github.com/VMLabDev/vmlab (`guest/win3d/`); the driver comes from github.com/arehnman/virtio-win-mesa.
- **Mac GPU:** `gpu/reims-vgpu-dev/` is github.com/steelbrain/reims-vgpu plus `gpu/reims/patches/*.dev.patch`; `gpu/reims/build-dev.sh` builds it.
- **Guest setup:** `win/`, `mac/`, `gpu/win3d/guest-scripts/`.
- **Keeping a workaround:** add it here as a script or a patch, with a line in the matching README that says why, and commit. Ask the user before `vm commit`, before posting upstream and before anything that needs root.

## Where things live

- **`win`:** three disk layers in `/vmlab/images`. `win11-base.qcow2` is Windows as installed and is never written. `win11-ready.qcow2` on it is the default state (`clean` inside the launchers; GPU driver and the lab's fixes); `vm reset` returns to it and `vm commit` writes to it. `win11-venus.qcow2` holds the current run. Saved states are files in `/vmlab/images/states/win/`, each one run's changes on the clean state: `vm commit win --keep-states` moves them onto the new clean state, `--drop-states` deletes them, and `win-venus.sh setup` (rebuilds the clean state from `win11-base`, about 4 minutes) refuses while they exist.
- **`mac`:** one disk, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/disk.qcow2`. Its snapshot `clean` is the default state (`vm` shows it as `default`) and each saved state is a snapshot beside it; a commit leaves them alone. `/vmlab/images/states/<vm>/` holds the states' notes and the marks of which state a disk is on (`gpu/states.sh`).
- **`/vmlab/share`:** served to each guest alone by a private `smbd` per VM run (`gpu/share-smbd.sh`, `\\10.0.2.4\qemu`); this machine's Samba services are masked. Leases and oplocks are off: with them, a file replaced here could not be opened in the VM until its cache let go. Guest side: `win/setup-share.ps1`, `mac/setup-share.sh`.
- **Build caches:** `~/.local/share/vmlab/cache/win.qcow2` and `mac.qcow2` on the system disk, made again at the VM's start from `/vmlab/images/<name>-cache-empty.qcow2` when missing. Guest side: `win/setup-cache.ps1`, `mac/setup-cache.sh`. `VMLAB_CACHE=off` starts a VM without it.
- **Guest tools:** Rust `win/install-rust.ps1`, `mac/install-rust.sh`; Windows' web tools (pnpm, fnm, the download caches, `host.vmlab`) `win/install-web-tools.ps1`; PostgreSQL `win/install-postgres.ps1`; `win/focus.ps1` and `win/tray.ps1` live in the VM's `C:\vmlab`.
- **`~/.local/bin/fzf`** (0.75.0, the release's single binary, checked against its checksums; not in git) draws `vm states`; without it `vm states` prints the table.
- `~/.local/bin/vm`, its helpers and the app-grid launchers are links into `home/`, made by `./install.sh`. Edit them in place.

## Freeing disk space on /vmlab

The VM SSD is 239 GB. The VMs' fixed cost is about 100 GB (Windows 45, Mac 55) and cannot shrink. Deleting anything below needs the user's go. Measure with `df -h /vmlab`, not `du`: the disk is XFS, copies share blocks (reflink), and `du` counts shared blocks once per file.

- **Temporary first:** `vm reset win` drops the current run (`win11-venus.qcow2`); `/vmlab/share` holds what agents left. Build output is in the build caches on the system disk (`vm cache`). The Mac disk only grows (55 of up to 96 GB); `vm reset mac` does not shrink it.
- **Removable as it comes back:** earlier Mac QEMU builds, `/vmlab/reims-dev/data/reims-ctl/qemu/<date>-…/` other than the one `current` links to (0.6 GB each, VM off).
- **Removed on 2026-11-12** with the user's go, and what each costs to get back: the macOS offline installer (19 GB; `reims` downloads it again), the stable lane's checkout and QEMU builds (patches kept in `/vmlab/tmp/old-git/`), the old plain Mac VM's install media (`mac/create-mac.sh` wants them back), `gpu/reims-vgpu-dev/target/` (12 GB; a full rebuild), `/vmlab/iso/win11.iso` (8.5 GB; address in `/vmlab/iso/win11.url`, checksum beside it), the Windows driver and QEMU build trees in `/vmlab/tmp` (6 GB; their build scripts make them again; the signing key is not among them), and an older activated Windows backup.
- **Never delete:** `/vmlab/images/win11-base.qcow2` and `win11-ready.*`, `/vmlab/images/*-cache-empty.qcow2`, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/`, `/vmlab/reims/rustup` and `/vmlab/reims/cargo`, `/vmlab/iso/virtio-win.iso` and `win-config.iso`.
