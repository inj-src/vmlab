# vmlab-mcp

A stdio MCP server that drives the desktops of the vmlab `win` (Windows 11) and `mac` (macOS) VMs through [Cua Driver](https://cua.ai/docs/cua-driver). It is registered for every Claude Code and Codex session of this machine by the lab's `install.sh`. How agents use it is in the lab's skill (`skills/vmlab/gui.md`).

## Behaviour

- **One tool list for both VMs.** It is Cua's list, with a required `machine` argument (`"win"` or `"mac"`) added to every tool. The argument is removed before the call is forwarded.
  - A tool only one VM has says so in its description (today only `debug_window_info`, which is win only and opt-in). Calling it for the other VM returns a tool error.
  - **Descriptions are the lab's own** (`descriptions.md`, compiled in): one text per tool and parameter for both VMs, marking where they differ, with the lab's trial results (Electron typing needs `delivery_mode: "foreground"`, and similar). Each entry carries a fingerprint of Cua's two definitions it was written against; when Cua changes a tool, that tool falls back to Cua's text, with a warning in the log, until the entry is updated. `vmlab-mcp --fingerprints` lists every tool's fingerprint and whether its entry is `ok` or `STALE`, and `cargo test` fails while one is stale against `seed/`.
  - Without an entry (or with a stale one), when the two VMs describe a tool or one of its properties differently, the description gives both texts. Input properties only one VM has are marked `(win only)` or `(mac only)`; a field only one VM requires is not required and says `(required on win)`.
  - Other schema keywords the VMs disagree on (a default, a minimum) are dropped, and enums are joined, so the merged schema accepts what either VM accepts. Cua on the target VM still validates the call.
  - Behaviour hints are merged conservatively: read-only and idempotent only if both VMs say so, destructive and open-world if either does.
  - Eleven Cua tools are left out (`HIDDEN` in `src/catalog.rs`): driver upkeep (`check_for_update`, `install_extension`, `install_ffmpeg`), deprecated or legacy ones (`escalate_session`, `get_session_state`, `page`), the agent cursor's styling (`set_agent_cursor_*`), `replay_trajectory`, and the Mac's `agent_display` (a virtual display: a window moved onto it is out of the VM's screen, where `screenshot` and `vm view` never see it). A call to one is refused as an unknown tool. To bring one back, delete its line and reinstall.
  - Fifteen more are served only on request (`EXTRA_GROUPS`), because agents called them once in 2,715 calls: `session` (`start_session`, `list_sessions`, `get_session`, `end_session`, `get_agent_cursor_state`), `recording` (`start_recording`, `stop_recording`, `get_recording_state`), `admin` (`set_config`, `get_config`, `debug_window_info`, `health_report`, `check_permissions`), `vision` (`parse_visual_regions`) and `browser` (`browser_motion_policy`, new in Cua 0.61: reduced-motion emulation for a browser the driver launched). `get_guide` is as rare but stays, because other tools' texts send agents to its topics. `VMLAB_MCP_EXTRA_TOOLS=recording,admin` (group names, tool names or `all`) in vmlab-mcp's environment serves them. Without it a call to one is refused with that advice. Cua's optional `session` argument on the other tools still works without the session tools.
- **`screenshot`, the one tool of its own.** It is served here, not by Cua (`src/shot.rs`), and sits after `get_desktop_state` in the list. It asks QEMU for the screen over QMP (`screendump` to a PPM on a tmpfs, `$XDG_RUNTIME_DIR/vmlab-mcp`), then crops (`region`), shrinks by area averaging (`max_dimension`) and encodes (`png`, or `jpeg` at quality 85) on a blocking thread. The guest does nothing, so it holds up when the guest is busy: on 2026-11-23, with 8 busy loops in the Windows guest, a full-size shot took 46 ms against 168–404 ms for Cua's `get_desktop_state`; idle, 30 ms full size and 13 ms for a region. It also works on a locked desktop, a UAC or login screen and a hung guest.
  - Windows' picture reaches QMP through `gpu/win3d/qemu-patches/0017`; without it the tool says "no surface" and points to `vm gui win shot`, which uses VNC. The Mac's QEMU (reims) has it already.
  - QMP's socket takes one client at a time (`vm gui` and the launchers' CPU pinning use it too), so the connection lasts only for the dump, and a dump waits at most 10 s.
  - Its pixels are screen pixels, the ones Cua's scope `"desktop"` takes. The result's text says how to map an image point to the screen (an offset for `region`, a factor for `max_dimension`).
  - **Cua's desktop scaling.** After a `get_desktop_state` with a reducing `max_image_dimension`, Cua scales every later scope `"desktop"` x,y in that Cua session by the image's factor (tested 2026-11-23: x,y 300,100 after a 400-pixel image clicked at 1440,480), until a full-size `get_desktop_state`. On macOS every `get_desktop_state` without a `max_image_dimension` is reduced (to 1365×768 from 1920×1080), so there the scaling is the usual case. So vmlab-mcp notes which Cua sessions (the `session` label, or none) have a reduced capture, and `screenshot` for such a session first runs a full-size `get_desktop_state` (`max_image_dimension: 16384`) that writes its PNG in the guest (`C:\Windows\Temp\vmlab-mcp-desktop.png`, `/tmp/vmlab-mcp-desktop.png`), and says so. That costs a Cua capture, only when an agent switches between the two. A reconnect to Cua clears the notes.
- **Cached tool list.** tools/list is served from `~/.cache/vmlab/cua-tools-<win|mac>.json`, which every successful connect rewrites. The files are re-read only when they change. When there is no cache yet, it falls back to `seed/`, which is compiled into the binary. The list is therefore complete with both VMs off.
  - Once this session has connected to a VM, the VM's live list is used for that VM, even if the cache file could not be written.
  - A call that the cached list rejects (unknown tool, or a tool the other VM has) connects first if this session has not seen the VM's live list yet, in case Cua was updated on the VM. If that connect fails, the original error is returned.
  - The descriptions come from Cua on the guests and reach the agent as written. The guests are disposable test VMs, so treat their text as no more trusted than the VM itself.
- **Lazy, persistent upstream.** The first call for a VM runs `vm status` once, for the state and the address (`127.0.0.1:<port>`). It then opens `ssh -T dev@<ip>` to a remote command, in the guest's default shell (Git Bash on win, zsh on mac), that waits for the Cua daemon in the desktop session and then runs `cua-driver mcp`.
  - The wait is at most 90 s of wall-clock time, checking every second. On win the logon task is kicked after 12 s (as the old `vm gui` did). The probes get an empty stdin, so they cannot eat the MCP stream.
  - On mac, launchd holds Cua's LaunchAgent in "pending spawn" for 25–35 s after login, while the gui domain is in on-demand-only mode. So once `launchctl print gui/<uid>` succeeds and Cua is still down, the agent is kickstarted (no `-k`) every 2 s, at most 10 times. After 35 s it is restarted once with `kickstart -k`. Each kickstart is tried without sudo, then with `sudo -n`, so it works in the GUI login session (vmlab-ssh-session) and in older states whose sessions run where sshd started them. Gemini measured boot-to-first-MCP going from 61 s to 35 s with the early kickstart (n=3, 2026-11-23).
  - On win the check is `cua-driver.exe status` on Cua's pipe, under `timeout 5`: it answers in about 75 ms whether the daemon is up (rc 0) or down (rc 1). The PowerShell pipe listing it replaced took 0.25–0.45 s. Git Bash cannot see named pipes: `ls //./pipe/` fails after 2–5 s.
  - The whole connect (ssh, the wait, the MCP handshake and tools/list) is bounded by 120 s. It runs in its own task: if the agent cancels or times out the call that started it, the connect still finishes and the next call uses it.
  - The MCP session is kept until the agent session ends.
  - If it drops (the VM stopped or rebooted), the next call reconnects once. A call that was in flight when it dropped returns a tool error and is not retried, because Cua actions are not idempotent.
  - A VM that is off returns `mac is not running: run \`vm start mac\` first` within milliseconds.
  - A tool call that gets no answer in 15 minutes returns a tool error, and Cua is sent a cancel.
  - One message from Cua may be at most 16 MiB (rmcp's stdio line limit; without its newline). Plain rmcp would drop a longer one silently, and the call would hang until that timeout. Here the session is reset at once instead. Every call in flight on that VM returns `win: Cua's reply exceeded 16 MiB; the connection to the VM was reset`, the upstream is killed, and the next call reconnects. Nothing beyond the current read is buffered.
- **SSH sharing.** ssh uses `ControlMaster=auto`, `ControlPersist=10m` and `ControlPath=~/.cache/vmlab/ssh/%C`, `bash-%C` for win (the directory is mode 0700). Later sessions reuse the authenticated connection.
  - A session over a shared connection sends no SetEnv, so the master decides win's shell. Binaries up to 2026-11-22 asked for PowerShell (`SetEnv VMLAB_SHELL=pwsh`) and made their masters at `%C`; sessions still running one keep using those, and the Git Bash masters stay apart.
  - Every session still starts its own `cua-driver mcp`, because Cua state (element refs, sessions) belongs to a connection.
  - The master process outlives the session for 10 minutes by design. ServerAlive ends it within about 15 s once the VM goes away.
- **outputSchema is served as Cua sends it.** It is a quarter of tools/list's bytes, but neither client gives it to the model: on 2026-11-23, Claude Code 2.1.330 and Codex 0.171, pointed at a fake model API, sent each MCP tool's name, description and input schema only (Codex as `parameters`, Claude Code as `input_schema`). Dropping it would save no tokens.
- **Proxying.** Cua's results pass through unchanged, including image content and JSON-RPC errors, with one exception: three Cua errors that cost agents several turns get a line of advice appended to their text (`hint` in `src/server.rs`), their structured fields left as they are:
  - `foreground_unavailable` on win: bring the window forward with `ssh win-pwsh 'C:\vmlab\focus.ps1 <title, process name or pid>'`; when the error says the click was sent, read the window again first.
  - `No screenshot of window` / `No screenshot frame`: read the window with get_window_state (include_screenshot true, same `session`) before a coordinate action.
  - `AXPress returned -25206` on mac: click a text field by x,y in the foreground, then type in a second call (the rule in the skill's gui.md).
  - Concurrent calls run in parallel. A `notifications/cancelled` from the agent is forwarded to Cua. Progress notifications are mapped back to the agent's progress token. If a connect changes the unified list, the agent gets `notifications/tools/list_changed`.
- **Cleanup.** When the session ends (stdin EOF, SIGTERM, SIGINT or SIGHUP), each upstream's stdin is closed, and SIGTERM and then SIGKILL follow if needed. If vmlab-mcp itself is SIGKILLed, `PR_SET_PDEATHSIG` stops the ssh children. Either way the remote `cua-driver mcp` exits.
- stdout carries only MCP messages. Logs go to stderr (`RUST_LOG`, default `info,rmcp=warn`).

Environment variables:

| Variable | Effect |
|---|---|
| `VMLAB_VM` | path of the `vm` CLI (default `~/.local/bin/vm`) |
| `VMLAB_CACHE_DIR` | tool-list cache dir (default `~/.cache/vmlab`) |
| `VMLAB_SSH_MUX=0` | turn ControlMaster sharing off |
| `VMLAB_MCP_CONNECT_TIMEOUT` | bound on one connect, in seconds (default 120) |
| `VMLAB_MCP_CALL_TIMEOUT` | bound on one tool call, in seconds (default 900) |
| `VMLAB_MCP_EXTRA_TOOLS` | serve opt-in tools: `session`, `recording`, `admin`, `vision`, tool names or `all` |
| `VMLAB_QMP_WIN`, `VMLAB_QMP_MAC` | the VMs' QMP sockets for `screenshot` (default `/vmlab/run/win-venus/qmp.sock`, `/vmlab/reims-dev/data/reims-ctl/vms/mac26d/qmp.sock`) |
| `VMLAB_MCP_TEST_UPSTREAM` | tests only: run `sh -c "<cmd> <machine>"` instead of SSH |

## Build, test, install

```
cargo test                      # unit tests + stdio integration tests against tests/fake_cua.py
cargo build --release && install -m755 target/release/vmlab-mcp ~/.local/bin/vmlab-mcp
scripts/update-seed.sh          # after connecting to both VMs: refresh seed/ from the cache
vmlab-mcp --fingerprints        # after a Cua update: which descriptions.md entries are stale
```

After a Cua update: refresh `seed/`, run `--fingerprints`, read Cua's new text for each `STALE` tool (`On Windows:` and `On macOS:` in its served description), fix the entry and copy the new fingerprint into its `## name fp=` line.

ssh expands `%` and splits on spaces in some of its paths, so a home or cache path with spaces, quotes or `%` is refused with an error.

Build output stays in `target/`, inside this repo on the spare SSD (`.cargo/config.toml`).

## Layout

- `src/catalog.rs`: cache and seed, the unified list (schema rewrite, merge), routing.
- `src/descriptions.rs` and `descriptions.md`: the lab's tool descriptions, their fingerprints, and how they are applied before the merge.
- `src/upstream.rs`: VM checks, ssh arguments, the remote command, connect and reconnect.
- `src/child.rs`: the upstream child process as an rmcp transport, with the line-length cap and the stop sequence (stdin EOF, SIGTERM, SIGKILL).
- `src/server.rs`: the MCP server (list, call, cancel, progress), and the `screenshot` call with Cua's desktop scaling.
- `src/shot.rs`: `screenshot`: the QMP dump, PPM parsing, crop, shrink, PNG and JPEG, and the text that maps image points to the screen.
- `tests/stdio.rs`: runs the real binary over stdio, against a fake `vm` and a fake Cua.
