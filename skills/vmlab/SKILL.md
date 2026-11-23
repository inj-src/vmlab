---
name: vmlab
description: The Windows 11 and macOS test VMs on this laptop (`win`, `mac`), started with `vm` and driven over `ssh` and the vmlab MCP tools. Use before running, building or testing anything on Windows or macOS — Electron and native apps, installers, a tray icon, a dialog, a cross-platform build — and before any `vm` command.
---

# vmlab: the Windows and macOS test VMs

Two disposable VMs on this laptop, each with a GPU, internet and an admin user `dev` (password `vmlab`) that logs in by itself:

| | Guest | Has |
|---|---|---|
| `win` | Windows 11 Pro 26300, x64 | Git Bash and PowerShell 7, Git, Node 26 with pnpm and fnm, PostgreSQL 16, Python 3.12 with uv, Rust 1.99 (MSVC, VS 2022 Build Tools), VS Code, Chrome, 7-Zip |
| `mac` | macOS Tahoe 26.7, x64 (Intel) | zsh, Xcode Command Line Tools (not Xcode), Node 26, Python 3.12 with uv, Rust 1.99, VS Code, Chrome |

Each has 6 CPUs, 8 GB and a 1920×1080 screen while its window is hidden. `mac` runs only x64 builds: for Apple Silicon use a GitHub Actions `macos-15` runner.

## Rules

- **One VM at a time.** If `vm status` shows a VM you did not start, leave it alone and ask the user: another agent or the user may be in the middle of something.
- **Start hidden** (`vm start <name>`): the VM's window exists but is hidden, and a tray icon on the user's desktop shows it. Shown (`vm view`, `--window`, the tray), it takes the user's keyboard when clicked: show it only when the user wants to watch.
- **Clean up:** when done, `vm stop <name>`, then `vm reset <name>` (back to the default state; the build cache stays). A setup you would redo after every reset belongs in a saved state.
- **States you did not make are not yours.** `pebble` on each VM is the user's: start it, never save over or delete it. Pass `vm reset --discard` only after a run you started. `vm commit` changes the default state for everyone: only when the user asks. → [states.md](states.md)
- **Check outcomes inside the VM** over `ssh` (files written, processes, app state), not from a screenshot or a tool's "success" alone.
- **The user may show the VM's window or take it over at any time.** Shown, the guest takes the window's size (about 1920×1008) and, on `win`, the screen's scaling; hidden again, 1920×1080 at 100%. Its windows move then: find elements by name, not by remembered pixels. Unexpected input or focus changes: stop and ask.
- **Disk:** VM data goes on `/vmlab`. The system disk holds only the two build caches (25 GB each); ask the user before needing more.

## Commands

`vm help` is the full reference.

```
vm status                    which VM runs, and who started it
vm start <win|mac> [state]   boot (window hidden) and wait for SSH; win: --defender
vm stop <name>, vm reset <name>
vm push <name> <dir> [dest]  mirror a git work tree into the VM's build cache
vm tunnel <name> <port> [lp] the VM's 127.0.0.1:<port> on localhost:<lp>
vm forward <name> <port>...  this machine's localhost:<port> on the VM's localhost
vm gui <name> shot <f.png>   a picture of the VM's screen
vm view <name>, vm hide <name>  show its window to the user, hide it again
vm states --plain            saved states of both VMs
```

## Running things

`ssh win "<command>"` (Git Bash), `ssh win-pwsh "<command>"` (PowerShell 7) and `ssh mac "<command>"` (zsh) run on the VM's desktop as `dev` with admin rights (`sudo` asks nothing on `mac`), so windows show and the GPU is there. A script goes on stdin as a quoted heredoc, written as on the VM itself:

```
vm push win ~/src/app
ssh win <<'EOF'
set -e
cd /c/cache/src/app
cargo build --release && cargo test
EOF
```

- Exit code and UTF-8 output come back as from a Linux shell (Windows programs end lines with CRLF). `scp` and `sftp` work.
- **`ssh win` is Git Bash, not PowerShell:** cmdlets and `$env:` go to `ssh win-pwsh`. A Windows switch needs a doubled slash (`setup.exe //S`, `taskkill //F //IM app.exe`) or `MSYS_NO_PATHCONV=1`, and a path inside a string (`node -e`, JSON, a config file) is written `C:/cache/...`: only whole arguments are converted from `/c/...`.
- **No `-t`:** on `win` a session with a terminal exits 0 and loses the output.
- **A long build:** run the `ssh` as a background command of your harness and act on its exit code. Run one project's builds one after another. When the harness cuts `ssh` off, the command ends with it.
- **A program that stays** (a GUI app, a dev server): `nohup <command> > /tmp/app.log 2>&1 & echo $!` keeps it after the session; on `mac`, `open -a <App>`. Stop it with `kill <pid>`, `taskkill //T //F //IM app.exe` or `pkill -x <App>`.
- **A service of this machine** inside the VM: `vm forward win 5800` puts `localhost:5800` there.
- **A build from GitHub** (an Actions artifact, a release): download it here, where `gh` is signed in, into `/vmlab/share` (`C:\share`, `~/share`); the VMs have no `gh` and no GitHub token.

Per OS, read the matching file before your first command: [windows.md](windows.md) (Git Bash path conversion, PowerShell, Node versions, PostgreSQL, installers, SmartScreen and Defender), [mac.md](mac.md) (packages, privacy prompts, osascript). Getting a repository or large files in: [files.md](files.md).

## The GUI: vmlab MCP tools

Anything a VM shows (an app's UI, a tray icon, a menu, a dialog, an installer) is driven with the `vmlab` MCP tools (`mcp__vmlab__*`; a tool search for `vmlab` finds them). Every tool takes `machine: "win"` or `"mac"`; the VM must be running. Elements come from `get_window_state`; act on them by `element_token`. Several actions in a row go in one `run_steps` call, which can read the window after the last step; a re-read with `since: "latest"` returns only what changed. To check or poll a window, read it with `include_screenshot: false`: the tree alone comes back in 35 ms in place of 420 on `win`, and in 31–57 ms in place of 124–320 on `mac`. Take the screenshot when you must see the pixels, and before a coordinate action.

The traps that cost agents the most turns:

- **Electron or Chromium windows:** type and press keys with `delivery_mode: "foreground"`. In the background `win` refuses the keys and `mac` drops them while reporting them sent. Read a field back after typing.
- **`foreground_unavailable` on `win`:** bring the window forward with `ssh win-pwsh 'C:\vmlab\focus.ps1 <part of its title, a process name or a pid>'`, then act again.
- **A text field on `mac`:** click it by `x, y` in the foreground, not by `element_token` (`AXPress returned -25206`), then `type_text` in a second call.
- **A coordinate action** (`click` at x, y, `drag`, `scroll`, `zoom`) needs a screenshot of that window first: `get_window_state` with `include_screenshot: true`.

Before the first GUI step, read [gui.md](gui.md): Electron windows, text fields, save dialogs and `<select>` on each OS lose input or report false success unless driven its way. It also covers `vm gui` for input that must look like a person's (keyboard hooks, hotkeys) and Playwright for the page inside an Electron app.

## When something fails or is missing

Read [troubleshooting.md](troubleshooting.md) before debugging from logs: start with `vm gui <name> shot`, then the known gotchas (clock drift, Electron's postinstall and pipes, GPU limits, process matching). When a VM lacks something the task needs (WebGPU and Direct3D 12 drawing on `win` are the known cases), you may work around it yourself; the file says how, and you tell the user what you changed.
