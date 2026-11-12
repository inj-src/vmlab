# vmlab

A Windows 11 and a macOS 26 test VM on one Ubuntu 24.04 laptop (Intel + RTX 4050), each with a
virtual GPU, a window on the desktop and an MCP server for driving its GUI. This repository
holds everything that makes them run except the disks and what is downloaded or built.

- **Using the VMs** (the `vm` command, rules, gotchas): `home/.config/vmlab/README.md`. Agents
  read it as `~/.config/vmlab/README.md` before any VM work.
- **How the GPU VMs are built, and why each local change exists**: `gpu/README.md`.

## Layout

| Path | What |
|---|---|
| `home/` | Files that belong in the home folder, at the same paths: the `vm` command and its helpers, the lab's README, the two launchers of the app grid. `./install.sh` links them into place. |
| `gpu/win3d/` | The Windows VM: launcher `win-venus.sh`, the clean state's build (`setup-ready.sh`, `guest-scripts/`), patches for QEMU and the guest drivers, the boot firmware change. |
| `gpu/reims/` | The macOS VM: launcher `mac26.sh`, patches for the reims window and SDL, the title bar plugin. |
| `gpu/rig/` | A headless GNOME desktop for testing the VM windows without touching the real one. |
| `win/`, `mac/` | How the base disks were installed and set up; `win/run-interactive.ps1` (the helper for Windows' desktop session); `mac/spice-agent/` (clipboard and file drop in macOS). |
| `vmlab-mcp/` | The MCP server that drives a VM's GUI (Rust; `cargo build --release`, then copy `target/release/vmlab-mcp` to `~/.local/bin/`). |
| `bench/` | The computer-use benchmark. |
| `host/` | Copies of what the lab changed outside the home folder, as a record (below). |

## A change to a file in `home/`

`~/.local/bin/vm` and the others are links into `home/`, so editing either edits the one file.
A new home-folder file goes under `home/` at its path; then `./install.sh`.

## What is not in git

`.gitignore` keeps these out. Sizes on 2026-11-12.

| What | Where | How it comes back |
|---|---|---|
| The VM disks, 100 GB | `/vmlab/images/win11-*`, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/` | Not rebuildable by a script from start to end. Windows: `win/create-win.sh` installs `win11-base`, `gpu/win3d/win-venus.sh setup` builds the clean state on it (not activated; the activated one exists only as `win11-ready.qcow2` and its backup), then `win/setup-share.ps1` and `win/install-rust.ps1` over SSH. macOS also takes `mac/setup-share.sh` and `mac/install-rust.sh`. macOS: `reims create`, then the steps in `gpu/README.md`. Back these files up if they matter. |
| The VMs' SSH key | `~/.ssh/vmlab_ed25519` | The guests trust its public half (`host/vmlab_ed25519.pub`, `win/config/authorized_keys`). Lost, a new key has to be put into both guests through their windows. |
| The Windows kernel driver's test-signing key | `gpu/win3d/signing/` | Its own `.gitignore` keeps it out. Lost, `build-guest-kmd.sh` needs a new certificate, which the clean state then has to trust. |
| vmlab-win3d release 0.1.2-alpha (QEMU, virglrenderer, guest driver package) | `gpu/win3d/release-0.1.2-alpha/`, unpacked into `src/`, `opt/qemu`, `opt/virgl`, `guest/` | Download from the VMLabDev/vmlab releases; `SHA256SUMS` here checks it. |
| The guest driver package as a CD | `gpu/win3d/win3d-guest.iso` | An ISO of the release's driver package (`guest/`). The command that made it is not recorded. |
| The lab's QEMU for Windows | `gpu/win3d/opt/qemu-ui/`; source in `/vmlab/tmp/win-qemu/` | `gpu/win3d/build-qemu.sh`: VMLabDev/qemu at `d8a6048aae11c5e26168e173a7c1b1a4335d6a23` plus `qemu-patches/`. |
| The lab's guest drivers | `gpu/win3d/guest-umd/x64`, `x86`, `guest-kmd/viogpu3d.sys` | `build-guest-umd.sh`, `build-guest-kmd.sh` (podman; the pins are in each `BUILDINFO`). |
| The boot firmware copy | `gpu/win3d/firmware/OVMF_CODE_4M.vmlab.fd` | Made at the VM's start from the system's OVMF (`make-firmware.py`). |
| reims-vgpu, dev lane | `gpu/reims-vgpu-dev/`, installed in `/vmlab/reims-dev` | github.com/steelbrain/reims-vgpu at `a7761508c0e7fca7a49385e0b62b3c92f06b0ca0`, the `.dev.patch` files of `gpu/reims/patches/` in the order `gpu/README.md` gives, then `gpu/reims/build-dev.sh`. |
| SDL with the lab's change | `gpu/reims/sdl3-src-3.4.18-vmlab/` | The `sdl3-src` 3.4.18 crate with `patches/sdl3-src-3.4.18-no-xdg-foreign-export.patch`. |
| reims-util | `gpu/reims-util/` | github.com/steelbrain/reims-util at `ed7398997f83f9d004477e6eab8eaf46a462a47a`, unchanged. |
| The Mac window's title bar plugin | `gpu/reims/libdecor-cairo/libdecor-cairo.so` | `gpu/reims/libdecor-vmlab/build.sh install` (the tarball and the patch are tracked). |
| The Rust toolchain | `/vmlab/reims/rustup`, `/vmlab/reims/cargo` | rustup, with `RUSTUP_HOME` and `CARGO_HOME` set to those. |
| Stable lane leftovers | `gpu/reims-vgpu/`, `gpu/metal2vulkan/`, `gpu/win-research/` | Not used by the VMs (`home/.config/vmlab/README.md`, "Freeing disk space"). |

## The host

`host/` records what was changed as root; nothing installs it.

- `/etc/fstab`: the VM SSD at `/vmlab` by label (`host/etc/fstab.vmlab-line`).
- `host/etc/`: `modprobe.d/kvm.conf` (KVM ignores the MSRs it does not know, which macOS reads),
  `tmpfiles.d/vmlab-thp.conf` (huge pages for shared memory when a program asks) and
  `sysctl.d/90-vmlab-reims.conf` (`vm.max_map_count`, for reims-vgpu on NVIDIA).
- Packages for the builds: the list in `home/.config/vmlab/root-once.sh`, which ran once as
  root. The scripts also call `podman`, `qemu-img`, `virsh`, `passt`, `zenity`, `osslsigncode`
  and the system's OVMF (`/usr/share/OVMF`).
- Samba, for the folder the VMs share with this machine (`/vmlab/share`): `host/install-samba.sh`
  ran once as root. It masks `smbd`, `nmbd` and `samba-ad-dc` before installing, so this machine
  serves nothing by itself; QEMU starts `/usr/sbin/smbd` privately for each VM run. Without the
  package the launchers start the VMs without the shared folder.
- The user is in the groups `kvm` and `libvirt`.
- Root steps go through one zenity password prompt (`SUDO_ASKPASS=~/.local/bin/zenity-askpass sudo -A …`).
