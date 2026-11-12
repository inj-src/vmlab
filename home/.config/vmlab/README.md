# vmlab: Windows and macOS test VMs

**Status (2026-11-12):** `win` and `mac` are both live, each on a virtual GPU.

## What the lab provides

The VMs run on this Linux laptop (Ubuntu 24.04, 23 GB RAM) as QEMU user units, outside libvirt, and render on the laptop's RTX 4050 through a virtual GPU. Their disk images are on the spare SSD, mounted at `/vmlab`. The user's 500 GB system disk is never used for VM data.

| Name | Guest | Inside it |
|---|---|---|
| `win` | Windows 11 Pro 26300, x64. Defender and Windows Update are disabled. GPU: Direct3D 9 to 11, OpenGL and Vulkan (so WebGL works); no Direct3D 12 or WebGPU. | OpenSSH (default shell: pwsh 7), Git, Node 26 LTS, Python 3.12, uv, 7-Zip, VS Code, Chrome (default browser), Cua Driver |
| `mac` | macOS Tahoe 26.7, x64 (Intel). Automatic updates are off. GPU: Metal 3. | Remote Login (zsh), Xcode Command Line Tools (git, clang, swiftc), Node 26 LTS (`/usr/local/bin`), Python 3.12 and uv, VS Code, Chrome (default browser), Cua Driver. No Homebrew. |

Login on both VMs: user `dev`, password `vmlab`. It is an admin account and logs in automatically. Each VM has 6 CPUs and 8 GB, and a 1920×1080 screen when it runs without a window. `mac` runs only x64 builds. For arm64 or Apple Silicon checks, use a GitHub Actions `macos-15` runner.

Each VM is run by its own launcher, which `vm` calls: `/vmlab/tools/vmlab/gpu/win3d/win-venus.sh` and `/vmlab/tools/vmlab/gpu/reims/mac26.sh`. Their headers list more commands (screenshots, guest keyboard and mouse without SSH), and `/vmlab/tools/vmlab/gpu/README.md` explains how the GPUs work and what was measured.

## Rules

- **One VM at a time.** If `vm status` shows another VM running, leave it alone and ask the user. Another agent, or the user at the VM window, may be in the middle of something.
- **Clean up what you started.** When you finish, run `vm stop <name>` and then `vm reset <name>`. Reset discards everything since the clean state.
- `vm commit` changes the clean state for every agent. Run it only when the user asks for a permanent change.
- The user may take over the VM window at any time. If GUI automation sees unexpected input or focus changes, stop and ask.

## Commands

`vm help` is the authoritative reference.

```
vm status                    which VM is running, and who started it
vm start <win|mac>           boot without a window and wait until SSH answers
vm start <name> --window     the same, in a window on the user's desktop
vm ssh <name> "<command>"    run a command inside the VM
vm ip <name>, vm port <name> where its SSH is: 127.0.0.1, port 2222 (win) or 2227 (mac)
vm tunnel <name> <port> [lp] forward the VM's 127.0.0.1:<port> to localhost:<lp>
vm untunnel <lp>             close that forward
vm view <name>               boot it in its window for the user (mouse and keyboard)
vm stop <name>               shut down
vm reset <name>              back to the clean state
```

## How to drive the VMs

- **Builds, installs, test suites:** `vm ssh win "cd C:\src\app; npm ci; npx playwright test"`. On `mac`, use the same command with POSIX paths. Run Playwright `_electron` tests inside the VM.
- **Native GUI** (installers, file dialogs, tray, menus, any app's real UI): use the vmlab MCP server. See [Driving a VM's GUI](#driving-a-vms-gui-vmlab-mcp).
- **Electron app internals:** start the app inside the VM with `--remote-debugging-port=9222`, run `vm tunnel win 9222`, then connect Playwright or playwright-mcp to `http://localhost:9222`.
- **Smoke-test app:** Electron 38 "Bench Form".
  - `win`: `C:\vmlab\bench-app`. Start it with `C:\vmlab\run-interactive.ps1 -Command "& C:\vmlab\bench-app\start.ps1"`.
  - `mac`: `~/vmlab/bench-app`. Start it with `open -n ~/vmlab/bench-app/node_modules/electron/dist/Electron.app --env BENCH_DIR=$HOME/bench --args ~/vmlab/bench-app`.

## Driving a VM's GUI (vmlab-mcp)

`~/.local/bin/vmlab-mcp` is a stdio MCP server. It exposes the [Cua Driver](https://cua.ai/docs/cua-driver) computer-use tools of both VMs as one tool list. Source and design notes are in `/vmlab/tools/vmlab/vmlab-mcp/README.md`.

**Add it only when the user asks for GUI work on a VM, and only for the current project.** Never add it globally.

- **Claude Code:** `claude mcp add -s local vmlab -- ~/.local/bin/vmlab-mcp`. The tools are `mcp__vmlab__*`. A session that is already running may need a restart before it sees them. Remove with `claude mcp remove -s local vmlab`.
- **Codex:** `codex mcp add` writes the global config, so don't use it. Put this in `.codex/config.toml` at the project root:
  ```toml
  [mcp_servers.vmlab]
  command = "/home/inj-src/.local/bin/vmlab-mcp"
  tool_timeout_sec = 180
  ```
  - Codex reads a project's `.codex/config.toml` only if that project is trusted (`trust_level = "trusted"` under `[projects."<path>"]` in `~/.codex/config.toml`). Otherwise it ignores the file without a message. Check with `codex mcp list` from the project directory.
  - If the file should not be committed, add `.codex/config.toml` to `.git/info/exclude`.
  - The timeout matters: the first call after `vm start` can wait up to 90 s for the desktop.

Using it:

- Every tool takes a required `machine` argument, `"win"` or `"mac"`. A tool that only one OS has says so in its description.
- Start the VM first with `vm start <name>`, one VM at a time. While the VM is off, calls return `<name> is not running: run \`vm start <name>\` first`.
- Each agent session has its own Cua connection per VM, so element refs and Cua sessions last between calls. A VM reboot resets them; the next call reconnects.
- Cua runs in the desktop session, so its screenshots work on win too (unlike apps started over SSH; see Session 0 below).
- Don't call `install_extension`, `install_ffmpeg` or `check_for_update`. They change the VM's Cua install.
- Check outcomes over `vm ssh` (files written, app state). Don't trust a screenshot alone.

## Gotchas

- **Start agent work without a window** (`vm start <name>`). A window on the user's desktop takes their keyboard when clicked; open one only when the user wants to watch or take over.
- **Windows Session 0:** anything started over SSH runs in an invisible session: its screenshots come out black and Vulkan finds no GPU there. To start something on the visible desktop, run `C:\vmlab\run-interactive.ps1 -Command "<ps>" [-NoWait]`. It shows no console window of its own. Use the same wrapper for winget, which only works in the desktop session.
- **Windows PowerShell 5.1 from SSH** needs a clean module path: `Remove-Item Env:PSModulePath; powershell …`. Otherwise core cmdlets such as `Get-FileHash` are missing, and `run-interactive.ps1` fails that way.
- **Windows features:** Windows Update is disabled, so `Add-WindowsCapability` and the Store fail. Use winget, or GitHub MSIs.
- **Node 26 and Electron's postinstall:** the electron package's zip extraction can exit early, leaving `node_modules/electron/dist` with only `locales/`. Fix it by extracting the cached zip from `%LOCALAPPDATA%\electron\Cache` with `tar -xf` into `dist`, then writing `electron.exe` to `path.txt`.
- **Killing processes by command line:** `pkill -f <pattern>` (and the PowerShell equivalent, filtering on `CommandLine -match`) also matches the shell that runs it, so the command kills itself. Anchor the pattern (`^ssh .*`) or filter by process name.
- **macOS GUI from SSH:** with auto-login on, `open -a <App>` over SSH starts the app in the visible desktop session. Stop apps with `pkill -x <App>`.
  - Avoid `osascript` AppleEvents (`tell app …`, `quit app …`) over SSH. Each one puts a privacy (Automation) prompt for `sshd-keygen-wrapper` on the desktop, and that prompt blocks GUI work until someone answers it.
- **macOS packages:** Homebrew's installer refuses Intel Macs, so install tools from vendor builds (nodejs.org tarballs, `uv`, app zips).
  - Some Python packages no longer ship Intel-mac wheels (for example `cryptography` 49 and later), and building them from source fails. Pin an older version, and use `--no-build` to find such packages quickly.
- **macOS privacy permissions:** a tool started over SSH gets no Accessibility or Screen Recording access. That is why Cua Driver's daemon runs as LaunchAgent `com.trycua.cua-driver` in the desktop session and holds the grants (`/Applications/CuaDriver.app`); `cua-driver mcp` over SSH only proxies to its socket.
  - Reinstalling or updating Cua Driver can drop the grants. Check with `cua-driver permissions status`.
  - A new GUI tool needs a one-time approval in System Settings. Do that through `mac26.sh gui` (screenshots, clicks and typing from the host) or the VM window; the admin password is `vmlab`.
  - SSH cannot read `~/Desktop`, `~/Documents` or `~/Downloads` ("Operation not permitted"). Keep test files elsewhere, such as `~/bench`.
  - To serve another stdio GUI tool from the desktop session, use a socket-activated LaunchAgent (`inetdCompatibility` + `Sockets` on `127.0.0.1:<port>`) and connect with `vm-mcp-tcp mac <port>`. On `win`, the equivalent is a logon task running `win/stdio-tcp-bridge.ps1` from the build scripts.
- **Electron on mac:** the same Node 26 postinstall bug applies. Extract `~/Library/Caches/electron/*/electron-v*-darwin-x64.zip` with `ditto -xk` (it keeps the framework symlinks) into `node_modules/electron/dist`, then write `Electron.app/Contents/MacOS/Electron` to `path.txt`.
- **GPU:** apps that keep the normal 60 Hz frame limit run fine on both. Uncapped rendering on `win` (`--disable-gpu-vsync --disable-frame-rate-limit`) fills the card's 6 GB in about 10 s and Chrome loses its WebGL context: keep such runs to a few seconds. `win` shows a "Test Mode" watermark because its GPU driver is test-signed. Details: `/vmlab/tools/vmlab/gpu/README.md`.
- **Speed:** both VMs are pinned to the laptop's fast cores (CPUs 0–7). Keep Spotlight indexing on in `mac`: GUI agents open apps with Cmd+Space. `vm start` switches the laptop to the `performance` power profile when the barrel charger is connected (never on USB-C), and `vm stop` restores the previous profile.
- **Browsers:** Chrome is the default browser on both VMs, pinned and frozen at one version (updater off). Policies turn off sign-in, sync, the password manager and promotions (`win`: `HKLM\SOFTWARE\Policies\Google\Chrome`; `mac`: configuration profile `local.vmlab.chrome`).
  - `win` still has Edge, because Windows only lets Edge be uninstalled on PCs set up in the EEA. It is unpinned and its updater is off; WebView2 is intact. Open web pages with Chrome.
- **Debloat:** consumer apps, Widgets, Copilot, OneDrive and telemetry are removed or off on `win` (`win/debloat.ps1`); Siri, analytics and media-analysis agents are off on `mac` (`mac/debloat.sh`). Store, Notepad, Calculator, Paint, Terminal, Photos and Snipping Tool stay.
- **VM window** (`vm start <name> --window`, `vm view <name>`, or "Windows 11" and "macOS 26 Tahoe" in the app grid): it opens maximized and the guest takes the window's pixels, so the picture is unscaled. The title bar's full-screen button or Ctrl+Alt+F fills the screen; Ctrl+Alt+F leaves it. Text and pictures copied on either side paste on the other, and files dragged onto the window land on the guest's desktop. Closing the window shuts the VM down.
  - Keyboard and pointer, both VMs: while the window is the active one every key goes to the guest, the desktop's shortcuts too (the Windows key, Win+R, Alt+Tab; on `mac` Super is Command). The pointer is never held: the title bar and other windows are one move away, and a click on another window gives it the keyboard. GNOME asks "Allow inhibiting shortcuts" once per VM (Allow); its Super+Escape gives the desktop its shortcuts back until the window is next activated. A click or a drag on the VM window's own title bar does the same (Super, Alt+Tab are the desktop's) until a click in the picture or until the window is activated again; the Mac's full screen has no title bar, so there the keys are the guest's.
  - `mac`: moved between the 100% monitor and the 125% laptop panel while windowed, macOS keeps its old resolution and the picture is slightly scaled. Ctrl+Alt+F twice gives it the new screen's pixels.
  - The guest side of the clipboard on `mac` is vmlab-spice-agent (`/vmlab/tools/vmlab/mac/spice-agent`). Never run that repo's tests on a VM you commit: they leave a CPU loop in the guest.
- **Clock drift:** after the laptop sleeps, VM clocks drift. `vm start` resyncs them. If you see TLS or time errors, run `vm start <name>` again; on a running VM it just resyncs.

## Where things live

- `win`: three disk layers in `/vmlab/images`. `win11-base.qcow2` is Windows as installed and is never written. `win11-ready.qcow2` on it is the clean state (GPU driver and the lab's fixes); `vm reset` returns to it and `vm commit` writes to it. `win11-venus.qcow2` holds the current run's changes. `win-venus.sh setup` builds the clean state again from `win11-base` (about 4 minutes).
- `mac`: one disk, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/disk.qcow2`. Its snapshot `clean` is the clean state.
- `/vmlab/tools/vmlab/` is the lab's git repository (branch `main`, no remote): the GPU VMs' launchers and patches (`gpu/`), the build scripts (`win/`, `mac/`), the `vmlab-mcp` source (`vmlab-mcp/`) and the computer-use benchmark (`bench/`; run `python3 bench.py report`). Its `README.md` has the layout and what stays out of git.
- This file, `~/.local/bin/vm`, its helpers and the two app-grid launchers are links into that repository's `home/`; `./install.sh` there makes the links. Edit them in place.

## Freeing disk space on /vmlab

The VM SSD is 239 GB. On 2026-11-12 it had 69 GB free. The VMs' fixed cost is about 92 GB (Windows 38 GB, Mac 54 GB) and cannot shrink. Deleting any of this needs the user's go; nothing below is removed yet.

Check first what is temporary: `vm reset win` drops the current Windows run (`win11-venus.qcow2`), which is usually the quickest gain. The Mac disk only grows (54 GB of a possible 96 GB); `vm reset mac` returns to its `clean` snapshot but the file keeps its size.

Removable without losing anything in use, about 33 GB:

| Path | Size | What is lost |
|---|---|---|
| `/vmlab/reims/data/reims-ctl/installers/` | 19 GB | The macOS 26.7.1 offline installer. Only needed to build a Mac VM from zero; `reims` downloads it again. |
| `/vmlab/tools/vmlab/gpu/reims-vgpu/` | 8.9 GB | The stable lane's checkout (8.3 GB of it is `target/`). The lane was dropped; `mac26.sh` uses only `/vmlab/reims-dev`. |
| `/vmlab/iso/BaseSystem.img`, `/vmlab/iso/macos/` | 3.4 GB | Install media of the old plain Mac VM, which is deleted. |
| `/vmlab/reims/data/reims-ctl/qemu/` | 1.9 GB | The stable lane's QEMU builds. |

Removable at a cost:

| Path | Size | Cost |
|---|---|---|
| `/vmlab/iso/win11.iso` | 8.5 GB | Needed only to reinstall Windows from zero (`win11-base.qcow2` exists); download again from the address in `win11.url`. |
| `/vmlab/tools/vmlab/gpu/reims-vgpu-dev/target/` | 12 GB | Build cache. Without it the next Mac window change is a full build, not about 10 minutes. |
| `/vmlab/images/win11-venus.backup-2026-11-12.*` | 4.3 GB | The only other copy of the activated Windows clean state. |
| `/vmlab/tmp/win3d-cache`, `win3d-src`, `podman`, `m2v-target`, `win-qemu` | 6 GB | Build trees of the Windows drivers, the shader translator and QEMU; their build scripts make them again (`win-qemu` holds the patched QEMU source, which `qemu-patches/` reproduces). |

Never delete: `/vmlab/images/win11-base.qcow2` and `win11-ready.*` (Windows), `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/` (the Mac), `/vmlab/reims/rustup` and `/vmlab/reims/cargo` (the Rust toolchain `build-dev.sh` uses), `/vmlab/iso/virtio-win.iso` and `win-config.iso`.

Measure with `df -h /vmlab` before and after, not with `du`: the disk is XFS, copies made on it can share blocks (reflink), and `du` counts shared blocks once per file. Deleting the stable Mac VM (54 GB by `du`) freed almost nothing, because the dev Mac's disk was such a copy.
