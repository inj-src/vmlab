# vmlab-mcp

A stdio MCP server that drives the desktops of the vmlab `win` (Windows 11) and `mac` (macOS) VMs through [Cua Driver](https://cua.ai/docs/cua-driver). It is installed for every Claude Code, Codex and Antigravity (`agy`, `~/.gemini/config/mcp_config.json`) session of this machine; see the lab's `AGENTS.md` (`/vmlab/tools/vmlab/AGENTS.md`).

## Behaviour

- **One tool list for both VMs.** It is Cua's list, with a required `machine` argument (`"win"` or `"mac"`) added to every tool. The argument is removed before the call is forwarded.
  - A tool only one VM has says so in its description (today only `debug_window_info`, which is win only). Calling it for the other VM returns a tool error.
  - When the two VMs describe a tool or one of its properties differently, the description gives both texts. Input properties only one VM has are marked `(win only)` or `(mac only)`; a field only one VM requires is not required and says `(required on win)`.
  - Other schema keywords the VMs disagree on (a default, a minimum) are dropped, and enums are joined, so the merged schema accepts what either VM accepts. Cua on the target VM still validates the call.
  - Behaviour hints are merged conservatively: read-only and idempotent only if both VMs say so, destructive and open-world if either does.
  - Ten Cua tools are left out (`HIDDEN` in `src/catalog.rs`): driver upkeep (`check_for_update`, `install_extension`, `install_ffmpeg`), deprecated or legacy ones (`escalate_session`, `get_session_state`, `page`), the agent cursor's styling (`set_agent_cursor_*`) and `replay_trajectory`. A call to one is refused as an unknown tool. To bring one back, delete its line and reinstall.
- **Cached tool list.** tools/list is served from `~/.cache/vmlab/cua-tools-<win|mac>.json`, which every successful connect rewrites. The files are re-read only when they change. When there is no cache yet, it falls back to `seed/`, which is compiled into the binary. The list is therefore complete with both VMs off.
  - Once this session has connected to a VM, the VM's live list is used for that VM, even if the cache file could not be written.
  - A call that the cached list rejects (unknown tool, or a tool the other VM has) connects first if this session has not seen the VM's live list yet, in case Cua was updated on the VM. If that connect fails, the original error is returned.
  - The descriptions come from Cua on the guests and reach the agent as written. The guests are disposable test VMs, so treat their text as no more trusted than the VM itself.
- **Lazy, persistent upstream.** The first call for a VM checks `vm status`. It then opens `ssh -T dev@<ip>` to a remote command that waits for the Cua daemon in the desktop session and then runs `cua-driver mcp`.
  - The wait is at most 90 s of wall-clock time. On win the logon task is kicked after 12 s; on mac the LaunchAgent is kickstarted after 60 s (the checks the old `vm gui` made). The probes get an empty stdin, so they cannot eat the MCP stream.
  - The whole connect (ssh, the wait, the MCP handshake and tools/list) is bounded by 120 s. It runs in its own task: if the agent cancels or times out the call that started it, the connect still finishes and the next call uses it.
  - The MCP session is kept until the agent session ends.
  - If it drops (the VM stopped or rebooted), the next call reconnects once. A call that was in flight when it dropped returns a tool error and is not retried, because Cua actions are not idempotent.
  - A VM that is off returns `mac is not running: run \`vm start mac\` first` within milliseconds.
  - A tool call that gets no answer in 15 minutes returns a tool error, and Cua is sent a cancel.
  - One message from Cua may be at most 16 MiB (rmcp's stdio line limit; without its newline). Plain rmcp would drop a longer one silently, and the call would hang until that timeout. Here the session is reset at once instead. Every call in flight on that VM returns `win: Cua's reply exceeded 16 MiB; the connection to the VM was reset`, the upstream is killed, and the next call reconnects. Nothing beyond the current read is buffered.
- **SSH sharing.** ssh uses `ControlMaster=auto`, `ControlPersist=10m` and `ControlPath=~/.cache/vmlab/ssh/%C` (the directory is mode 0700). Later sessions reuse the authenticated connection.
  - Every session still starts its own `cua-driver mcp`, because Cua state (element refs, sessions) belongs to a connection.
  - The master process outlives the session for 10 minutes by design. ServerAlive ends it within about 15 s once the VM goes away.
- **Proxying.** Results pass through unchanged, including image content and JSON-RPC errors. Concurrent calls run in parallel. A `notifications/cancelled` from the agent is forwarded to Cua. Progress notifications are mapped back to the agent's progress token. If a connect changes the unified list, the agent gets `notifications/tools/list_changed`.
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
| `VMLAB_MCP_TEST_UPSTREAM` | tests only: run `sh -c "<cmd> <machine>"` instead of SSH |

## Build, test, install

```
cargo test                      # unit tests + stdio integration tests against tests/fake_cua.py
cargo build --release && install -m755 target/release/vmlab-mcp ~/.local/bin/vmlab-mcp
scripts/update-seed.sh          # after connecting to both VMs: refresh seed/ from the cache
```

ssh expands `%` and splits on spaces in some of its paths, so a home or cache path with spaces, quotes or `%` is refused with an error.

Build output stays in `target/`, inside this repo on the spare SSD (`.cargo/config.toml`).

## Layout

- `src/catalog.rs`: cache and seed, the unified list (schema rewrite, merge), routing.
- `src/upstream.rs`: VM checks, ssh arguments, the remote command, connect and reconnect.
- `src/child.rs`: the upstream child process as an rmcp transport, with the line-length cap and the stop sequence (stdin EOF, SIGTERM, SIGKILL).
- `src/server.rs`: the MCP server (list, call, cancel, progress).
- `tests/stdio.rs`: runs the real binary over stdio, against a fake `vm` and a fake Cua.
