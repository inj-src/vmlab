# vmlab-mcp

A stdio MCP server that drives the desktops of the vmlab `win` (Windows 11) and `mac` (macOS) VMs through [Cua Driver](https://cua.ai/docs/cua-driver). Agents add it per project; see the vmlab README (`~/.config/vmlab/README.md`).

## Behaviour

- **One tool list for both VMs.** It is Cua's list, with a required `machine` argument (`"win"` or `"mac"`) added to every tool. The argument is removed before the call is forwarded.
  - A tool only one VM has says so in its description (today only `debug_window_info`, which is win only). Calling it for the other VM returns a tool error.
  - When the two VMs describe a tool differently, the description gives both texts. Input properties only one VM has are marked `(win only)` or `(mac only)`.
- **Cached tool list.** tools/list is served from `~/.cache/vmlab/cua-tools-<win|mac>.json`, which every successful connect rewrites. When there is no cache yet, it falls back to `seed/`, which is compiled into the binary. The list is therefore complete with both VMs off.
- **Lazy, persistent upstream.** The first call for a VM checks `vm status`. It then opens `ssh -T dev@<ip>` to a remote command that waits for the Cua daemon in the desktop session (up to about 40 s on win and 90 s on mac, the same checks the old `vm gui` made) and then runs `cua-driver mcp`.
  - The MCP session is kept until the agent session ends.
  - If it drops (the VM stopped or rebooted), the next call reconnects once. A call that was in flight when it dropped returns a tool error and is not retried, because Cua actions are not idempotent.
  - A VM that is off returns `mac is not running: run \`vm start mac\` first` within milliseconds.
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
| `VMLAB_MCP_TEST_UPSTREAM` | tests only: run `sh -c "<cmd> <machine>"` instead of SSH |

## Build, test, install

```
cargo test                      # unit tests + stdio integration tests against tests/fake_cua.py
cargo build --release && install -m755 target/release/vmlab-mcp ~/.local/bin/vmlab-mcp
scripts/update-seed.sh          # after connecting to both VMs: refresh seed/ from the cache
```

Build output stays in `target/`, inside this repo on the spare SSD (`.cargo/config.toml`).

## Layout

- `src/catalog.rs`: cache and seed, the unified list (schema rewrite, merge), routing.
- `src/upstream.rs`: VM checks, ssh arguments, the remote command, connect and reconnect.
- `src/server.rs`: the MCP server (list, call, cancel, progress).
- `tests/stdio.rs`: runs the real binary over stdio, against a fake `vm` and a fake Cua.
