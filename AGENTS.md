# vmlab: Windows and macOS test VMs

How to use the lab's two VMs: the rules, the commands, getting code in, running things, driving the GUI. The reference behind this file is `~/.config/vmlab/README.md`; [the last section](#when-to-open-the-reference) says when to open it.

## The VMs

| Name  | Guest                                                                                                                                                     | Inside it                                                                                                                                                                                                                                    |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `win` | Windows 11 Pro 26300, x64. Defender and Windows Update are disabled. GPU: Direct3D 9 to 11, OpenGL and Vulkan (so WebGL works); Direct3D 12 for native programs through a bridge to Vulkan; no WebGPU on the GPU. Screen capture with Desktop Duplication works. | OpenSSH (default shell: pwsh 7), Git, Node 26 LTS, pnpm 12, fnm, PostgreSQL 16, Python 3.12, uv, Rust 1.99 (MSVC target; Visual Studio 2022 Build Tools with the C++ tools and the Windows 11 SDK; clippy, rustfmt), 7-Zip, VS Code, Chrome (default browser), Cua Driver |
| `mac` | macOS Tahoe 26.7, x64 (Intel). Automatic updates are off. GPU: Metal 3.                                                                                   | Remote Login (zsh), Xcode Command Line Tools (git, clang, swiftc; not Xcode itself), Node 26 LTS (`/usr/local/bin`), Python 3.12 and uv, Rust 1.99 (clippy, rustfmt), VS Code, Chrome (default browser), Cua Driver.                         |

- Login on both: user `dev`, password `vmlab`. It is an admin account and logs in automatically.
- Each VM has 6 CPUs and 8 GB, a 1920×1080 screen when it runs without a window, and internet.
- `win` is set up for testing, not like a customer's PC: Defender antivirus and Windows Update are off. For a test that depends on the antivirus (an installer, a first launch, a flagged binary), use the saved state with Defender on: `vm start win defender`. Its definitions are of 2026-11-12, and real-time protection comes on some seconds after SSH answers (wait for `(Get-MpComputerStatus).RealTimeProtectionEnabled`). When a result depends on Windows Update, say in your report that the VM could not show it.
- SmartScreen is on in every state of `win`. Its "Windows protected your PC" box appears only for a file that carries the Mark-of-the-Web and is started through Explorer, so a file you built in the VM or copied in with `scp` or `vm push` starts without it. To see what a customer's download does, mark the file first: `Set-Content -Path app.exe -Stream Zone.Identifier -Value '[ZoneTransfer]','ZoneId=3'`, then `explorer.exe app.exe` through `run-interactive.ps1`.
- `mac` runs only x64 builds. For arm64 or Apple Silicon checks, use a GitHub Actions `macos-15` runner.

## Rules

- **One VM at a time.** If `vm status` shows another VM running, leave it alone and ask the user. Another agent, or the user at the VM window, may be in the middle of something.
- **Start without a window** (`vm start <name>`). A window on the user's desktop takes their keyboard when clicked; open one only when the user wants to watch or take over.
- **Clean up what you started.** When you finish, run `vm stop <name>` and then `vm reset <name>`. Reset discards everything since the clean state, except the build cache (`C:\cache`, `~/cache`). Though aggressive resets might bring repetitive tasks, find a good balance between them: a setup worth keeping across resets is a [saved state](#saved-states).
- `vm commit` changes the clean state for every agent. Run it only when the user asks for a permanent change. On `win` the saved states stand on the clean state: `vm commit win --keep-states` keeps each as it was (a state does not get the commit's change: make it inside the state too, and save it again), `--drop-states` deletes them.
- **A saved state you did not make is not yours:** start it, but do not save over it or delete it. `pebble` on each VM is the user's own setup. When `vm reset` refuses because the VM ran on a state and was not saved since, pass `--discard` only for a run you started yourself; otherwise ask the user.
- **GUI work goes through vmlab-mcp.** For anything a VM shows (an app's UI, a tray icon, a menu, a dialog, an installer), use [its tools](#driving-the-gui-vmlab-mcp); every Claude Code and Codex session has them. The page inside an Electron app is the one place with a second way, Playwright: [choose per check](#running-things-in-a-vm).
- The user may take over the VM window at any time. If GUI automation sees unexpected input or focus changes, stop and ask.
- **Disk:** VM data belongs on `/vmlab`. The user's 500 GB system disk holds only the two build caches (`~/.local/share/vmlab/cache`, 25 GB each at most); put nothing else of the VMs there. For some tasks if 25GB is limiting, ask the user for an increase.

## Commands

`vm help` is the authoritative reference.

```
vm status                    which VM is running, and who started it
vm start <win|mac>           boot without a window and wait until SSH answers
vm start <name> --window     the same, in a window on the user's desktop
vm ssh <name> "<command>"    run a command inside the VM
vm ip <name>, vm port <name> where its SSH is: 127.0.0.1, port 2222 (win) or 2227 (mac)
vm push <name> <dir> [dest]  mirror the git work tree at <dir> into the VM
vm cache [clear <name>]      size of each VM's build cache; empty one
vm tunnel <name> <port> [lp] forward the VM's 127.0.0.1:<port> to localhost:<lp>
vm untunnel <lp>             close that forward
vm forward <name> <port>...  the other way: this machine's localhost:<port> on the VM's localhost
vm unforward <name>          close that VM's forwards
vm gui <name> shot <f.png>   the VM's screen as a picture
vm gui <name> click X Y | type 'text' | key ctrl+s
                             its real keyboard and pointer, at pixels of that picture
vm view <name>               boot it in its window for the user (mouse and keyboard)
vm stop <name>               shut down
vm reset <name>              back to the clean state
vm states --plain            the saved states of both VMs (--json for a program)
vm start <name> <state>      boot a saved state
vm save <name> <state> "note"  keep the stopped VM as it is under a name
vm clear <name> <state>      delete a saved state
```

## Saved states

A saved state is a VM's whole disk kept under a name beside the clean state: a Windows with a project installed and its database filled, a browser that is logged in. Use one when you would otherwise redo the same setup after every reset.

- **See them:** `vm states --plain` (name, size, when saved, a note, and which one the VM is on). Run in a terminal by the user, `vm states` is a list to work in.
- **Use one:** `vm start win hq` boots it as it was saved. What your run changes is not in the state until you save again, so every agent starts from the same thing. Clean up with `vm stop win` and `vm reset win --discard`.
- **Make one:** set the VM up, `vm stop win`, then `vm save win hq "HQ shell installed, database seeded"`. Name it after the project and say in the note what is in it. `--replace` writes over a state of that name. Tell the user about each state you made.
- **Cost:** a state of `win` is as large as what its run wrote: 0.4 GB after ten minutes, 1 to 2 GB after a long session. Save right after the setup. States of `mac` are inside the Mac's disk file, whose size the list cannot split up.
- **Remove:** `vm clear win hq`, for states you made.
- **`defender` on `win` is the lab's and `pebble` on each VM is the user's:** start them, save nothing over them.

## Getting code and files into a VM

- **A repository: `vm push <name> <dir> [dest]`.** It mirrors the git work tree at `<dir>` to `C:\cache\src\<repo>` on `win` or `~/cache/src/<repo>` on `mac`: committed, uncommitted and untracked files, without ignored ones. The first push sends everything, later ones only the changes, and the guest's ignored build output (`target/`, `node_modules/`) stays, so builds after a push are incremental.
  - The host repository's index and branches are untouched; the push adds the ref `refs/vmlab/push/<name>` there.
  - Limits: git repositories only; submodules and Git LFS content are not sent. The guest copy is a mirror: files changed or added there (other than ignored ones) are overwritten or removed by the next push.
- **The build cache: `C:\cache` on `win`, `~/cache` on `mac`.** A disk of its own per VM that `vm reset` and `vm commit` leave alone, so a pushed checkout, its build output and cargo's downloads (`.cargo\registry` and `.cargo\git` are links into it) are still there after a reset, and the next build is incremental.
  - 25 GB per VM at most. `vm cache` shows the size; `vm cache clear <name>` empties one (VM stopped). When a build runs out of room, remove old checkouts' `target` folders in it or clear it.
  - It belongs to every agent and project: another project's checkout there is not yours to delete. What a test must not inherit from an earlier run (an installed app, settings, a database) belongs on the system disk, which reset does clean.
- **Large or loose files: the shared folder.** `/vmlab/share` on this machine is `C:\share` on `win` and `~/share` on `mac`, both ways, while the VM runs. On `mac` it appears about 30 s after SSH answers.
  - Measured with 1 GB: `win` reads 500 MB/s and writes 260 MB/s; `mac` reads 155 MB/s and writes 22 MB/s. For a large file out of `mac`, `scp` is faster (140 MB/s): `scp -P 2227 -i ~/.ssh/vmlab_ed25519 dev@127.0.0.1:<file> <dir>`.
  - Build on the guest's own disk (`vm push`), not in the shared folder: there every file is a network round trip. Builds in it were not measured.
  - It is one folder for both VMs and outlives `vm reset`: remove what you put there.

## Running things in a VM

- **Builds, installs, test suites:** `vm ssh win "cd C:\cache\src\app; cargo build"`; on `mac` the same with its paths (`~/cache/src/app`). The shell is PowerShell 7 on `win` and zsh on `mac`.
- **On the visible Windows desktop:** anything started over SSH runs in an invisible session (Session 0): its screenshots come out black and Vulkan finds no GPU there. `C:\vmlab\run-interactive.ps1` runs things on the visible desktop, with no console window of its own. Call it from `vm ssh win` as `Remove-Item Env:PSModulePath; powershell -File C:\vmlab\run-interactive.ps1 …`:
  - `-Command "<PowerShell>"` waits, prints the command's output and returns its exit code (`-TimeoutSec`, default one hour). Use it for test scripts and for winget, which only works in the desktop session.
  - `-Start "<command line>" [-Log <file>] [-Dir <folder>]` is for a program that stays (a GUI app, a dev server): it returns in 2 s with the log file and a process id. The program's output goes to the log file itself, so start Electron this way: piped through PowerShell its main process dies with EPIPE. Stop it with `taskkill /T /F /PID <id>`.
- **On the visible Mac desktop:** `open -a <App>` over SSH starts the app there (auto-login is on); stop it with `pkill -x <App>`. Use these in place of `osascript` AppleEvents (`tell app …`, `quit app …`): each of those puts a privacy (Automation) prompt on the desktop that blocks GUI work until someone answers it.
- **An Electron app, two ways, yours to choose per check:** vmlab-mcp works the window as a person does, and reaches what is outside the page too (the installer, a native dialog, the tray). Playwright works the page from inside: start the app inside the VM with `--remote-debugging-port=9222`, run `vm tunnel win 9222 9333`, then connect Playwright or playwright-mcp to `http://localhost:9333`. (The third number is the port on this machine; the user's own Chrome often holds 9222.) Run Playwright `_electron` tests inside the VM.
- **A service of this machine, from inside the VM:** `vm forward <name> 5800 7000` puts this machine's `localhost:5800` and `:7000` on the VM's own `localhost`, so an app built against `http://localhost:5800` works unchanged. `vm unforward <name>` closes them. Where a forward does not fit, this machine is `host.vmlab` on `win` and `10.0.2.2` on both.
- **Node and pnpm on `win`:** `node` is 26. For a project on another version: `fnm install 24` once (kept on `C:\cache`), then `fnm use 24` at the start of each `vm ssh` command, or `fnm exec --using=24 -- <command>` in the desktop session. `pnpm` is on the Path and switches to the version in the project's `packageManager` by itself. Downloads of Electron, electron-builder, npm and pnpm are kept on `C:\cache`.
- **PostgreSQL on `win`:** 16, installed as on a customer's PC: service `postgresql-x64-16`, port 5432, user `postgres`, password `postgres`, tools in `C:\Program Files\PostgreSQL\16\bin` (not on the Path). Its databases are on the system disk: `vm reset` empties it.
- **A build from GitHub (an installer from Actions, a release):** download it on this machine, where `gh` is signed in, into `/vmlab/share`. The VMs have no `gh` and get no GitHub token.
- **Native GUI** (installers, file dialogs, tray, menus, any app's real UI): vmlab-mcp, the next section.

## Driving the GUI (vmlab-mcp)

`~/.local/bin/vmlab-mcp` is a stdio MCP server with the [Cua Driver](https://cua.ai/docs/cua-driver) computer-use tools of both VMs in one tool list: elements found by name, clicks and right-clicks on them, hotkeys, window state, the accessibility tree, screenshots. **It is how you test or check anything a VM shows**; confirm the result over `vm ssh`. Source and design notes are in `/vmlab/tools/vmlab/vmlab-mcp/README.md`.

**Every session has the tools:** the server is installed for all Claude Code sessions (`mcp__vmlab__*`; a tool search for `vmlab` finds them) and all Codex sessions (`codex mcp list` shows `vmlab`), since 2026-11-13. A session started before that gets them at its next start; if a later one lacks them, tell the user.

- Installed with `claude mcp add -s user vmlab -- ~/.local/bin/vmlab-mcp` and `codex mcp add vmlab -- ~/.local/bin/vmlab-mcp`, the latter with `tool_timeout_sec = 180` added under `[mcp_servers.vmlab]` in `~/.codex/config.toml`: the first call after `vm start` can wait up to 90 s for the desktop.

Using it:

- Every tool takes a required `machine` argument, `"win"` or `"mac"`. A tool that only one OS has says so in its description.
- Start the VM first with `vm start <name>`, one VM at a time. While the VM is off, calls return `<name> is not running: run \`vm start <name>\` first`.
- Each agent session has its own Cua connection per VM, so element refs and Cua sessions last between calls. A VM reboot resets them; the next call reconnects.
- Cua runs in the desktop session, so its screenshots work on win too (unlike apps started over SSH; see [Running things in a VM](#running-things-in-a-vm)).
- Don't call `install_extension`, `install_ffmpeg` or `check_for_update`. They change the VM's Cua install.
- Check outcomes over `vm ssh` (files written, app state). Don't trust a screenshot alone.

## The plain picture and real input (`vm gui`)

`vm gui` needs no setup and knows nothing of what is on the screen: it works in pixels. Two uses beside vmlab-mcp:

- **The screen as it is:** `vm gui <name> shot <file.png>`, whatever is on it: a crash dialog, a prompt, the wrong window in front. **Look at it before you debug a GUI test from logs.**
- **Input that has to be real:** `vm gui <name> click X Y [right|double]`, `type 'text'`, `key ctrl+s` (also `win`, `alt`, `shift`; `ret`, `esc`, `tab`, `f4`) use the VM's own keyboard and pointer, at pixels of the screenshot. The guest takes them for a person's. Use them to test anything that watches input (a keyboard hook, a hotkey, a text expander): keys sent from inside Windows, by Cua, SendKeys or SendInput, carry Windows' "injected" mark, and real ones never do.
- **Bring a window to the front first:** `run-interactive.ps1 -Command "C:\vmlab\focus.ps1 notepad"` (part of the title, a process name or a process id). It prints what it focused and fails with exit code 1 if that window is not in front. A script's own `SetForegroundWindow` or `AppActivate` fails most of the time on Windows, and the keys then go to whatever was in front.
- **A tray icon:** Windows 11 hides a new icon under the "Show Hidden Icons" arrow. After the app has shown its icon once, `vm ssh win "C:\vmlab\tray.ps1 <part of the program's name>"` puts it beside the clock.
- **Display scaling on `win`:** `/vmlab/tools/vmlab/gpu/win3d/win-venus.sh scale 125` (or 150, 100) sets it at once.

## When to open the reference

`~/.config/vmlab/README.md`, by section:

- **Gotchas:** something fails or behaves oddly in a VM. Read it before debugging: Windows PowerShell 5.1, `Path` over SSH and Windows features; Electron's postinstall and its output through a pipe; Node versions with fnm; macOS packages and privacy permissions; killing processes by command line; GPU limits; browsers; the VM window; clock drift.
- **When a VM lacks something you need:** a capability is missing (WebGPU and what an app draws with Direct3D 12 on `win` are the known cases). You may work around it yourself; the section has the terms, the sources and what to tell the user.
- **Smoke-test app:** a ready Electron app in both VMs for checking the lab itself.
- **Where things live** and **Freeing disk space on /vmlab:** the disk images, the caches, what is safe to delete.

`/vmlab/tools/vmlab/gpu/README.md`: how the virtual GPUs work, every local patch with its cause, and each launcher's own commands (screenshots, guest keyboard and mouse without SSH).
