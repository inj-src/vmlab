# vmlab: Windows and macOS test VMs

How to use the lab's two VMs: the rules, the commands, getting code in, running things, driving the GUI. The reference behind this file is `~/.config/vmlab/README.md`; [the last section](#when-to-open-the-reference) says when to open it.

## The VMs

| Name | Guest | Inside it |
|---|---|---|
| `win` | Windows 11 Pro 26300, x64. Defender and Windows Update are disabled. GPU: Direct3D 9 to 11, OpenGL and Vulkan (so WebGL works); no Direct3D 12 or WebGPU. | OpenSSH (default shell: pwsh 7), Git, Node 26 LTS, Python 3.12, uv, Rust 1.99 (MSVC target; Visual Studio 2022 Build Tools with the C++ tools and the Windows 11 SDK; clippy, rustfmt), 7-Zip, VS Code, Chrome (default browser), Cua Driver |
| `mac` | macOS Tahoe 26.7, x64 (Intel). Automatic updates are off. GPU: Metal 3. | Remote Login (zsh), Xcode Command Line Tools (git, clang, swiftc; not Xcode itself), Node 26 LTS (`/usr/local/bin`), Python 3.12 and uv, Rust 1.99 (clippy, rustfmt), VS Code, Chrome (default browser), Cua Driver. No Homebrew. |

- Login on both: user `dev`, password `vmlab`. It is an admin account and logs in automatically.
- Each VM has 6 CPUs and 8 GB, a 1920×1080 screen when it runs without a window, and internet.
- `mac` runs only x64 builds. For arm64 or Apple Silicon checks, use a GitHub Actions `macos-15` runner.

## Rules

- **One VM at a time.** If `vm status` shows another VM running, leave it alone and ask the user. Another agent, or the user at the VM window, may be in the middle of something.
- **Start without a window** (`vm start <name>`). A window on the user's desktop takes their keyboard when clicked; open one only when the user wants to watch or take over.
- **Clean up what you started.** When you finish, run `vm stop <name>` and then `vm reset <name>`. Reset discards everything since the clean state, except the build cache (`C:\cache`, `~/cache`).
- `vm commit` changes the clean state for every agent. Run it only when the user asks for a permanent change.
- The user may take over the VM window at any time. If GUI automation sees unexpected input or focus changes, stop and ask.
- **Disk:** VM data belongs on `/vmlab`. The user's 500 GB system disk holds only the two build caches (`~/.local/share/vmlab/cache`, 25 GB each at most); put nothing else of the VMs there.

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
vm view <name>               boot it in its window for the user (mouse and keyboard)
vm stop <name>               shut down
vm reset <name>              back to the clean state
```

## Getting code and files into a VM

- **A repository: `vm push <name> <dir> [dest]`.** It mirrors the git work tree at `<dir>` to `C:\cache\src\<repo>` on `win` or `~/cache/src/<repo>` on `mac`: committed, uncommitted and untracked files, without ignored ones. The first push sends everything, later ones only the changes, and the guest's ignored build output (`target/`, `node_modules/`) stays, so builds after a push are incremental.
  - The host repository's index and branches are untouched; the push adds the ref `refs/vmlab/push/<name>` there.
  - Limits: git repositories only; submodules and Git LFS content are not sent. The guest copy is a mirror: files changed or added there (other than ignored ones) are overwritten or removed by the next push.
- **The build cache: `C:\cache` on `win`, `~/cache` on `mac`.** A disk of its own per VM that `vm reset` and `vm commit` leave alone, so a pushed checkout, its build output and cargo's downloads (`.cargo\registry` and `.cargo\git` are links into it) are still there after a reset, and the next build is incremental.
  - 25 GB per VM at most. `vm cache` shows the size; `vm cache clear <name>` empties one (VM stopped). When a build runs out of room, remove old checkouts' `target` folders in it or clear it.
  - It belongs to every agent and project: another project's checkout there is not yours to delete. What a test must not inherit from an earlier run (an installed app, settings, a database) belongs on the system disk, which reset does clean.
- **Large or loose files: the shared folder.** `/vmlab/share` on this machine is `C:\share` on `win` and `~/share` on `mac`, both ways, while the VM runs. On `mac` it appears about 30 s after SSH answers.
  - Measured with 1 GB: `win` reads 400 MB/s and writes 165 MB/s; `mac` reads 170 MB/s and writes 23 MB/s. For a large file out of `mac`, `scp` is faster (140 MB/s): `scp -P 2227 -i ~/.ssh/vmlab_ed25519 dev@127.0.0.1:<file> <dir>`.
  - Build on the guest's own disk (`vm push`), not in the shared folder: there every file is a network round trip. Builds in it were not measured.
  - It is one folder for both VMs and outlives `vm reset`: remove what you put there.

## Running things in a VM

- **Builds, installs, test suites:** `vm ssh win "cd C:\cache\src\app; cargo build"`; on `mac` the same with its paths (`~/cache/src/app`). The shell is PowerShell 7 on `win` and zsh on `mac`.
- **On the visible Windows desktop:** anything started over SSH runs in an invisible session (Session 0): its screenshots come out black and Vulkan finds no GPU there. To start something on the visible desktop, run `C:\vmlab\run-interactive.ps1 -Command "<ps>" [-NoWait]`. It shows no console window of its own. Use the same wrapper for winget, which only works in the desktop session.
- **On the visible Mac desktop:** `open -a <App>` over SSH starts the app there (auto-login is on); stop it with `pkill -x <App>`. Use these in place of `osascript` AppleEvents (`tell app …`, `quit app …`): each of those puts a privacy (Automation) prompt on the desktop that blocks GUI work until someone answers it.
- **Electron app internals:** start the app inside the VM with `--remote-debugging-port=9222`, run `vm tunnel win 9222`, then connect Playwright or playwright-mcp to `http://localhost:9222`. Run Playwright `_electron` tests inside the VM.
- **Native GUI** (installers, file dialogs, tray, menus, any app's real UI): the vmlab MCP server, next section.

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
- Cua runs in the desktop session, so its screenshots work on win too (unlike apps started over SSH; see [Running things in a VM](#running-things-in-a-vm)).
- Don't call `install_extension`, `install_ffmpeg` or `check_for_update`. They change the VM's Cua install.
- Check outcomes over `vm ssh` (files written, app state). Don't trust a screenshot alone.

## When to open the reference

`~/.config/vmlab/README.md`, by section:

- **Gotchas:** something fails or behaves oddly in a VM. Read it before debugging: Windows PowerShell 5.1, `Path` over SSH and Windows features; Electron's postinstall; macOS packages and privacy permissions; killing processes by command line; GPU limits; browsers; the VM window; clock drift.
- **When a VM lacks something you need:** a capability is missing (Direct3D 12 on `win` is the known case). You may work around it yourself; the section has the terms, the sources and what to tell the user.
- **Smoke-test app:** a ready Electron app in both VMs for checking the lab itself.
- **Where things live** and **Freeing disk space on /vmlab:** the disk images, the caches, what is safe to delete.

`/vmlab/tools/vmlab/gpu/README.md`: how the virtual GPUs work, every local patch with its cause, and each launcher's own commands (screenshots, guest keyboard and mouse without SSH).
