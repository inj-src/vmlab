# vmlab reference

How to use the VMs (rules, commands, getting code in, running things, the GUI server) is in `/vmlab/tools/vmlab/AGENTS.md`; read that first. This file is the reference behind it.

**Status (2026-11-12):** `win` and `mac` are both live, each on a virtual GPU.

The VMs run on this Linux laptop (Ubuntu 24.04, 23 GB RAM) as QEMU user units, outside libvirt, and render on the laptop's RTX 4050 through a virtual GPU. Their disk images are on the spare SSD, mounted at `/vmlab`.

Each VM is run by its own launcher, which `vm` calls: `/vmlab/tools/vmlab/gpu/win3d/win-venus.sh` and `/vmlab/tools/vmlab/gpu/reims/mac26.sh`. Their headers list more commands (screenshots, guest keyboard and mouse without SSH), and `/vmlab/tools/vmlab/gpu/README.md` explains how the GPUs work and what was measured.

## Smoke-test app

Electron 38 "Bench Form".

- `win`: `C:\vmlab\bench-app`. Start it with `C:\vmlab\run-interactive.ps1 -Command "& C:\vmlab\bench-app\start.ps1"`.
- `mac`: `~/vmlab/bench-app`. Start it with `open -n ~/vmlab/bench-app/node_modules/electron/dist/Electron.app --env BENCH_DIR=$HOME/bench --args ~/vmlab/bench-app`.

## When a VM lacks something you need

The user's word on this (2026-11-12): when the work needs something the VMs don't have, hack around it yourself. The lab is theirs to change and its sources are here.

- **Tell the user every time:** when you had to work around something, say so in your report: what was missing, what you changed to get past it, and whether the change is still in place.
- **Read first:** `/vmlab/tools/vmlab/gpu/README.md` has every local change to the GPU stack with its cause and its test, and what is known not to work.
- **Sources:** the lab's repository is `/vmlab/tools/vmlab` (git, branch `main`, no remote).
  - Windows GPU, all in `gpu/win3d/`: the lab's QEMU (`build-qemu.sh`, `qemu-patches/`, source in `/vmlab/tmp/win-qemu/qemu`), the guest's Direct3D driver, which is Mesa (`build-guest-umd.sh`, `guest-patches/`), and its kernel driver (`build-guest-kmd.sh`, `kmd-patches/`). Upstream is github.com/VMLabDev/vmlab (`guest/win3d/`); its driver comes from github.com/arehnman/virtio-win-mesa.
  - Mac GPU: `gpu/reims-vgpu-dev/` is github.com/steelbrain/reims-vgpu plus `gpu/reims/patches/*.dev.patch`; `gpu/reims/build-dev.sh` builds it.
  - Guest setup: `win/`, `mac/`, `gpu/win3d/guest-scripts/`.
- **What stays as it is:** a workaround made in a running VM lasts until `vm reset`. To keep one, add it to the lab's repository as a script or a patch with a line in the README that says why, and commit there; ask the user before `vm commit`, before posting anything upstream and before anything that needs root on this machine.
- **Known case, Direct3D 12 on `win`:** the driver has Direct3D 9 to 11 only; Mesa has no Direct3D 12 driver interface, so adding it there is a new driver. An app that draws with Direct3D 12 alone (wgpu's `dx12` backend, for one) gets Microsoft's software renderer (WARP) at best.
  - The driver package ships a Direct3D 12 to Vulkan bridge (vkd3d-proton): `d3d12.dll`, `vkd3dcore.dll`, `dxgi-vulkan.dll` and `vulkan-1.dll` in `C:\ProgramData\vmlab-win3d\bundle\runtime\x64` (and `x86`).
  - `win-venus.sh d3d12 bridge` installs it for all of Windows, and Chrome and Electron then lose WebGL (their GPU process takes only Microsoft-signed DLLs); `d3d12 native` undoes it.
  - Not tried, and the likely way to have both: copy the bridge's DLLs beside the one app's `.exe` and leave Windows' own file alone. Windows looks in the app's folder first.

## Gotchas

- **Windows PowerShell 5.1 from SSH** needs a clean module path: `Remove-Item Env:PSModulePath; powershell …`. Otherwise core cmdlets such as `Get-FileHash` are missing, and `run-interactive.ps1` fails that way.
- **Windows Direct3D 12:** a native program finds no Direct3D 12 device; Direct3D 11, Vulkan and OpenGL work. See [When a VM lacks something you need](#when-a-vm-lacks-something-you-need).
- **Windows `Path` over SSH:** an SSH session gets the machine's `Path`, not the user's. A tool installed per user (as cargo is) is found over SSH only once its folder is on the machine `Path` and Windows has restarted.
- **Windows features:** Windows Update is disabled, so `Add-WindowsCapability` and the Store fail. Use winget, or GitHub MSIs.
- **Node 26 and Electron's postinstall:** the electron package's zip extraction can exit early, leaving `node_modules/electron/dist` with only `locales/`. Fix it by extracting the cached zip from `C:\cache\electron` with `tar -xf` into `dist`, then writing `electron.exe` to `path.txt`.
- **Electron's output through a pipe:** started with its output piped through PowerShell, Electron's main process dies with EPIPE once the pipe's reader is gone. `run-interactive.ps1 -Start` sends the output to a log file instead.
- **Node versions on Windows:** `fnm install <n>` makes its first version fnm's default, and that would replace Node 26 in every new shell. The PowerShell 7 profile (`C:\Program Files\PowerShell\7\profile.ps1`) therefore ends with `fnm use system`: Node 26 unless a command says `fnm use <n>`. Nothing switches at `cd`.
- **PostgreSQL's installer and winget:** EDB's download server answers winget with 403. `win/install-postgres.ps1` takes the address and the hash from `winget show` and downloads with `curl.exe`.
- **A forward that is taken:** Windows' sshd accepts a second forward of a port that is in use and says nothing, so `vm forward` checks this machine's own forwards first.
- **Killing processes by command line:** `pkill -f <pattern>` (and the PowerShell equivalent, filtering on `CommandLine -match`) also matches the shell that runs it, so the command kills itself. Anchor the pattern (`^ssh .*`) or filter by process name.
- **macOS packages:** Homebrew's installer refuses Intel Macs, so install tools from vendor builds (nodejs.org tarballs, `uv`, app zips).
  - Some Python packages no longer ship Intel-mac wheels (for example `cryptography` 49 and later), and building them from source fails. Pin an older version, and use `--no-build` to find such packages quickly.
- **macOS privacy permissions:** a tool started over SSH gets no Accessibility or Screen Recording access. That is why Cua Driver's daemon runs as LaunchAgent `com.trycua.cua-driver` in the desktop session and holds the grants (`/Applications/CuaDriver.app`); `cua-driver mcp` over SSH only proxies to its socket.
  - Reinstalling or updating Cua Driver can drop the grants. Check with `cua-driver permissions status`.
  - A new GUI tool needs a one-time approval in System Settings. Do that through `mac26.sh gui` (screenshots, clicks and typing from the host) or the VM window; the admin password is `vmlab`.
  - SSH sessions have full disk access (System Settings > General > Sharing > Remote Login > "Allow full disk access for remote users", set by hand: no command can). Without it SSH cannot read `~/Desktop`, `~/Documents`, `~/Downloads` or `~/share` ("Operation not permitted").
  - To serve another stdio GUI tool from the desktop session, use a socket-activated LaunchAgent (`inetdCompatibility` + `Sockets` on `127.0.0.1:<port>`) and connect with `vm-mcp-tcp mac <port>`. On `win`, the equivalent is a logon task running `win/stdio-tcp-bridge.ps1` from the build scripts.
- **Electron on mac:** the same Node 26 postinstall bug applies. Extract `~/Library/Caches/electron/*/electron-v*-darwin-x64.zip` with `ditto -xk` (it keeps the framework symlinks) into `node_modules/electron/dist`, then write `Electron.app/Contents/MacOS/Electron` to `path.txt`.
- **GPU:** apps that keep the normal 60 Hz frame limit run fine on both. Uncapped rendering on `win` (`--disable-gpu-vsync --disable-frame-rate-limit`) fills the card's 6 GB in about 10 s and Chrome loses its WebGL context: keep such runs to a few seconds. `win` shows a "Test Mode" watermark because its GPU driver is test-signed. Details: `/vmlab/tools/vmlab/gpu/README.md`.
- **Speed:** both VMs are pinned to the laptop's fast cores (CPUs 0–7). Keep Spotlight indexing on in `mac`: GUI agents open apps with Cmd+Space. `vm start` switches the laptop to the `performance` power profile when the barrel charger is connected (never on USB-C), and `vm stop` restores the previous profile.
- **Browsers:** Chrome is the default browser on both VMs, pinned and frozen at one version (updater off). Policies turn off sign-in, sync, the password manager and promotions (`win`: `HKLM\SOFTWARE\Policies\Google\Chrome`; `mac`: configuration profile `local.vmlab.chrome`).
  - `win` still has Edge, because Windows only lets Edge be uninstalled on PCs set up in the EEA. It is unpinned and its updater is off; WebView2 is intact. Open web pages with Chrome.
- **Debloat:** consumer apps, Widgets, Copilot, OneDrive and telemetry are removed or off on `win` (`win/debloat.ps1`); Siri, analytics and media-analysis agents are off on `mac` (`mac/debloat.sh`). Store, Notepad, Calculator, Paint, Terminal, Photos and Snipping Tool stay.
- **VM window** (`vm start <name> --window`, `vm view <name>`, or "Windows 11" and "macOS 26 Tahoe" in the app grid): it opens maximized and the guest takes the window's pixels, so the picture is unscaled. The title bar's full-screen button or Ctrl+Alt+F fills the screen; Ctrl+Alt+F leaves it. Text and pictures copied on either side paste on the other, and files dragged onto the window land on the guest's desktop, large ones too (on `mac` folders as well; a copy that takes more than 2 s shows a notification, and `mac26.sh drop PATH...` does the same by hand). Closing the window shuts the guest down cleanly: the window goes at once, the VM about 10 s later (`vm status` shows it running until then, and a start given in that time waits for it).
  - Keyboard and pointer, both VMs: while the window is the active one every key goes to the guest, the desktop's shortcuts too (the Windows key, Win+R, Alt+Tab; on `mac` Super is Command). The pointer is never held: the title bar and other windows are one move away, and a click on another window gives it the keyboard. GNOME asks "Allow inhibiting shortcuts" once per VM (Allow); its Super+Escape gives the desktop its shortcuts back until the window is next activated. A click or a drag on the VM window's own title bar does the same (Super, Alt+Tab are the desktop's) until a click in the picture or until the window is activated again; the Mac's full screen has no title bar, so there the keys are the guest's.
  - `mac`: moved between the 100% monitor and the 125% laptop panel while windowed, macOS keeps its old resolution and the picture is slightly scaled. Ctrl+Alt+F twice gives it the new screen's pixels.
  - The guest side of the clipboard on `mac` is vmlab-spice-agent (`/vmlab/tools/vmlab/mac/spice-agent`). It reaches the window through SSH (a Unix socket, no VM device). A saved state keeps the agent it was saved with. `tests/unit.swift` there is not for a VM you commit: an unsigned binary run over SSH leaves a CPU loop in the guest.
- **Clock drift:** after the laptop sleeps, VM clocks drift. `vm start` resyncs them. If you see TLS or time errors, run `vm start <name>` again; on a running VM it just resyncs.

## Where things live

- `win`: three disk layers in `/vmlab/images`. `win11-base.qcow2` is Windows as installed and is never written. `win11-ready.qcow2` on it is the clean state (GPU driver and the lab's fixes); `vm reset` returns to it and `vm commit` writes to it. `win11-venus.qcow2` holds the current run's changes. Saved states (`vm states`) are files in `/vmlab/images/states/win/`: each is one run's changes on the clean state, so a new clean state under them would make them unusable. `vm commit win --keep-states` moves them to the new clean state, each reading as before (`--drop-states` deletes them); `win-venus.sh setup` refuses while states exist (`vm clear win --all`). `win-venus.sh setup` builds the clean state again from `win11-base` (about 4 minutes).
- `mac`: one disk, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/disk.qcow2`. Its snapshot `clean` is the clean state, and each saved state is a snapshot beside it in the same file (`mine` is the user's own session); a commit leaves them alone. `/vmlab/images/states/<vm>/` holds the states' notes and the marks that say which state a VM's disk is on and whether it ran since (`gpu/states.sh`).
- `/vmlab/share` is the folder both VMs share with this machine. QEMU's own network serves it to the guest alone (a private `smbd` per VM run, at `\\10.0.2.4\qemu`, started by `gpu/share-smbd.sh`); this machine's Samba services are masked and nothing listens on its network. That script turns Samba's leases and oplocks off: with them, a file replaced on this machine (a build's output, an editor's save) could not be opened in the VM any more ("The parameter is incorrect") until the VM's cache let go of it. Guest side: `win/setup-share.ps1`, `mac/setup-share.sh`. Rust: `win/install-rust.ps1`, `mac/install-rust.sh`. Windows' web tools (pnpm, fnm, the download caches on `C:\cache`, the name `host.vmlab`) and PostgreSQL 16: `win/install-web-tools.ps1`, `win/install-postgres.ps1`; the helpers `win/focus.ps1` and `win/tray.ps1` are in the VM's `C:\vmlab`.
- The build caches are `~/.local/share/vmlab/cache/win.qcow2` and `mac.qcow2`, on the system disk. A missing one is made again at the VM's start from the empty formatted disk `/vmlab/images/<name>-cache-empty.qcow2`. Guest side: `win/setup-cache.ps1`, `mac/setup-cache.sh`. `VMLAB_CACHE=off` starts a VM without it.
- `/vmlab/tools/vmlab/` is the lab's git repository (branch `main`, no remote): the GPU VMs' launchers and patches (`gpu/`), the build scripts (`win/`, `mac/`), the `vmlab-mcp` source (`vmlab-mcp/`) and the computer-use benchmark (`bench/`; run `python3 bench.py report`). Its `README.md` has the layout and what stays out of git.
- `~/.local/bin/fzf` (0.75.0, the single program file of the release at github.com/junegunn/fzf, checked against the release's checksum list; not in the repository) draws the list of `vm states`. Without it `vm states` prints the table.
- This file, `~/.local/bin/vm`, its helpers and the two app-grid launchers are links into that repository's `home/`; `./install.sh` there makes the links. Edit them in place.

## Freeing disk space on /vmlab

The VM SSD is 239 GB. On 2026-11-12 it had 119 GB free, after the clean-up below. The VMs' fixed cost is about 100 GB (Windows 45 GB, Mac 55 GB) and cannot shrink; Rust and the Visual Studio Build Tools are 6.4 GB of the Windows figure and 0.6 GB of the Mac's. Deleting any of what is left needs the user's go.

Check first what is temporary: `vm reset win` drops the current Windows run (`win11-venus.qcow2`), which is usually the quickest gain. `/vmlab/share` holds whatever agents left in it. Build output is not on `/vmlab`: it is in the build caches on the system disk (`vm cache`, `vm cache clear <name>`). The Mac disk only grows (55 GB of a possible 96 GB); `vm reset mac` returns to its `clean` snapshot but the file keeps its size.

Removed on 2026-11-12 with the user's go (31 GB freed, measured with `df`): the macOS offline installer (`/vmlab/reims/data/reims-ctl/installers/`, 19 GB; `reims` downloads it again when a Mac VM is built from zero), the dropped stable lane's checkout and QEMU builds (`gpu/reims-vgpu/`, `/vmlab/reims/data/reims-ctl/qemu/`; its one local commit and its uncommitted changes are kept as two patches in `/vmlab/tmp/old-git/`), the old plain Mac VM's install media (`/vmlab/iso/BaseSystem.img`, `/vmlab/iso/macos/`; `mac/create-mac.sh` wants them back before it can run) and one earlier build of the Mac's QEMU.

Removable again as it comes back, without losing anything in use:

| Path | Size | What is lost |
|---|---|---|
| `/vmlab/reims-dev/data/reims-ctl/qemu/<date>-…/`, every folder but the one `current` links to | 0.6 GB each | Earlier builds of the Mac's QEMU: each `gpu/reims/build-dev.sh` run adds a folder and moves `current`. With the Mac VM off. |

Also removed that day, each at a cost the user accepted (26 GB more by `df`):

- `gpu/reims-vgpu-dev/target/` (12 GB), the Mac window program's build cache: the next `gpu/reims/build-dev.sh` is a full build. It grows back to that size.
- `/vmlab/iso/win11.iso` (8.5 GB): needed only to reinstall Windows from zero (`win/create-win.sh`); download it again from the address in `/vmlab/iso/win11.url` and check it against `win11.iso.sha256`.
- `/vmlab/tmp/win3d-cache`, `win3d-src`, `podman`, `m2v-target`, `win-qemu` (6 GB): build trees of the Windows drivers, the shader translator and QEMU. `gpu/win3d/build-guest-umd.sh`, `build-guest-kmd.sh` and `build-qemu.sh` make them again (downloads and a container image included); the signing key is not among them (`gpu/win3d/signing/`). They grow back when those scripts run.

- `/vmlab/images/win11-venus.backup-2026-11-12.*` (4.3 GB by `du`, about 1 GB freed by `df`: it shared most of its blocks with `win11-ready.qcow2`), the older activated Windows clean state: `win11-ready.qcow2` is now the only activated Windows (`gpu/README.md`, "Activation").

Never delete: `/vmlab/images/win11-base.qcow2` and `win11-ready.*` (Windows), `/vmlab/images/*-cache-empty.qcow2` (the empty build cache disks), `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/` (the Mac), `/vmlab/reims/rustup` and `/vmlab/reims/cargo` (the Rust toolchain `build-dev.sh` uses), `/vmlab/iso/virtio-win.iso` and `win-config.iso`.

Measure with `df -h /vmlab` before and after, not with `du`: the disk is XFS, copies made on it can share blocks (reflink), and `du` counts shared blocks once per file. Deleting the stable Mac VM (54 GB by `du`) freed almost nothing, because the dev Mac's disk was such a copy.
