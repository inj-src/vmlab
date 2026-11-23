# vsock: a control channel to the Windows VM

`vmlab-agent` runs in Windows and `vmlab-vx` runs here; they talk over virtio-vsock, a socket
between host and guest with no network in between. It does what `ssh win` does (run a command
on the desktop, move files) at a lower cost per call, and SSH stays the lab's standard way in:
everything works without the agent. `src/lib.rs` documents the protocol.

```
vmlab-vx ping                         the agent's name and version, ~1 ms
vmlab-vx exec [--pwsh] [COMMAND...]   as `ssh win "COMMAND"` (`ssh win-pwsh` with --pwsh)
vmlab-vx put LOCAL REMOTE             a file into the VM (REMOTE: a Windows path)
vmlab-vx get REMOTE LOCAL             a file out of it (LOCAL "-": stdout)
vmlab-vx proxy PORT [--fallback H:P]  for ssh's ProxyCommand
```

Without the agent (a state saved before it, a VM started without the device), `exec` runs
`ssh win` in its place and `proxy` uses `--fallback`; `put` and `get` fail with 255.
`VMLAB_VX_FALLBACK=0` turns the fallback off. The first call that finds no agent waits 500 ms
and leaves `$XDG_RUNTIME_DIR/vmlab-vx-noagent-3` holding the QEMU pid, so later calls to that
QEMU process skip the wait. `vm push win` sends its bundle with `put` when the agent answers.

## Pieces

- **The device:** `gpu/win3d/win-venus.sh` adds `vhost-vsock-pci,guest-cid=3` in slot 8 when
  `/dev/vhost-vsock` is usable (group kvm) and QEMU has the device (`build-qemu.sh`'s
  `--enable-vhost-kernel`). `WIN_VENUS_VSOCK=off` leaves it out. Saved states are disk-only,
  so the new device changes nothing for them.
- **The driver:** virtio-win's viosock (`/vmlab/iso/virtio-win.iso`, `viosock/w11/amd64`) and
  its Winsock provider (address family 40, from `IOCTL_GET_AF` on `\\.\Viosock`).
- **The agent:** `C:\vmlab\vmlab-agent.exe`, built in the guest from this source. A logon task
  `vmlab-agent` runs `C:\vmlab\agent-loop.cmd` under a headless conhost in dev's desktop
  session, elevated, as sshd runs (`win/desktop-ssh.ps1`), so commands run where `ssh win`
  runs them: through `C:\vmlab\vmshell.exe -c`. Its log is `C:\vmlab\agent.log`.
- **The token:** `~/.config/vmlab/agent-token` (64 hex digits, mode 600, not in git), copied to
  `C:\vmlab\agent-token` (Administrators and SYSTEM only). The agent answers only CID 2 with
  the token. Anyone who can read the host's copy can run anything in the VM, the same as with
  the lab's SSH key.

## Installing

With `win` running: `win/install-vsock-agent.sh`. It builds and installs `vmlab-vx`, makes the
token if it is missing, and copies the driver, the source, the token and `win/vsock-agent.ps1`
into the guest, which installs the driver, builds the agent, and registers and starts the task.
Running it again replaces the agent. The agent then lives in the current run's disk:
`vm commit win --keep-states` puts it in the default state. Saved states without it fall back
to SSH.

## Measured (2026-11-23, 8 vCPUs)

| | idle | 8 busy loops in the guest |
|---|---|---|
| `vmlab-vx ping` | 1 ms | 2 ms |
| `vmlab-vx exec 'echo ok'` | 29 ms | 46 ms |
| `ssh win 'echo ok'` (shared connection) | 34-46 ms | 51 ms |
| `ssh` with a new connection, TCP | 213 ms | 285 ms |
| `ssh` with a new connection, `ProxyCommand=vmlab-vx proxy 22` | 171 ms | 252 ms |
| `vmlab-vx exec --pwsh 'echo ok'` / `ssh win-pwsh` | 270 / 276 ms | |

Most of an `exec`'s time is Git Bash starting in the guest. Files of 64 MB: `put` 71-79 ms
against `scp` 326 ms and 0.55 s through `ssh win 'cat > f'`; `get` 79 ms against `scp`
882 ms. `vm push win`: a one-line change 400 ms against 485 ms, a first push of 41 MB 1.9 s
against 2.1 s (git in the guest takes the rest).

SSH's ProxyCommand is not in `ssh_config`: it saves time only on a new connection, which
ControlMaster makes rare.

## What to know when changing it

- **viosock sockets cannot be duplicated** (`WSADuplicateSocket` gives 10045), so
  `TcpStream::try_clone` fails on them. The agent shares one `Arc<TcpStream>` between threads
  and reads and writes through `&TcpStream`.
- **The command reaches vmshell as `-c` and one argument** (`.arg("-c").arg(cmd)`), which is how
  sshd hands it over. Quoting it into one string (`raw_arg`) loses double quotes.
- **When the host goes away mid-command** the agent ends the command's process tree
  (`taskkill /T /F`), as sshd does. Checked: neither leaves a process behind.
- **The loop outlives its task:** `Stop-ScheduledTask` does not end `agent-loop.cmd` (it runs
  under a headless conhost), so `vsock-agent.ps1` stops every process whose command line holds
  it. An agent that finds the port taken waits a minute before it exits, which keeps the
  loop's log quiet.
- Build the host side with `cargo build --release --bin vmlab-vx` here;
  `cargo check --target x86_64-pc-windows-msvc --bin vmlab-agent` checks the agent.
