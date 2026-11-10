# vmlab-spice-agent

A SPICE guest agent for the vmlab macOS VM (`mac`). It shares the clipboard with the SPICE client
(virt-viewer, `vm view mac`) in both directions and saves files dropped on the viewer window to
`~/Desktop`. There is no SPICE agent for macOS upstream; this one is written from
`protocol/vd_agent.h` (spice-protocol, BSD licence).

## What it does

| Direction | Formats |
|---|---|
| host → guest | UTF-8 text; PNG (BMP, JPEG and TIFF are converted to PNG). Text and an image offered together are both put on the pasteboard. macOS serves TIFF to apps that ask for it. |
| guest → host | UTF-8 text; images as PNG (TIFF/JPEG/BMP pasteboard images are converted). A Finder file copy goes over as its text (the file name), not its icon. |
| file drop | `FILE_XFER_*`: each file lands in `~/Desktop`. Existing files are never overwritten (`name (1).ext`). Cancelled or failed transfers leave nothing behind. |

Not handled: display resize (fixed framebuffer), mouse (the domain uses `<mouse mode='server'/>`, so
spice-server never routes the mouse through the agent), audio, multiple monitors.

## How it works

- The device is `/dev/cu.com.redhat.spice.0`, created by macOS's own `AppleVirtIOConsole` driver
  from the domain's `spicevmc` channel `com.redhat.spice.0`. It is opened raw (`cfmakeraw`, no
  XON/XOFF, no CR/LF mapping) so binary payloads pass through untouched.
- Reads use a kqueue-backed dispatch source (no polling). Chunks (2048 data bytes each) are
  reassembled per port into messages; outgoing messages are split into chunks and written whole
  on one serial queue.
- Clipboard uses the by-demand flow (`GRAB`/`REQUEST`/`CLIPBOARD`/`RELEASE`).
  - guest → host: NSPasteboard has no change notification, so the agent compares `changeCount`
    every 0.5 s, **only while a client is connected**. With no viewer open it does no periodic work.
  - host → guest: on the client's `GRAB` the agent requests the data at once and writes it to the
    pasteboard. The `changeCount` after that write is remembered, so the agent never grabs its own
    write back (no echo loop). If the guest copies something while host data is in flight, the
    guest copy wins.
  - `VD_AGENT_MAX_CLIPBOARD` is honoured: a guest clipboard larger than the client's limit is
    answered with empty data.
- A client is "connected" from its first message on the client port until `CLIENT_DISCONNECTED`
  (or the port closes). Its `ANNOUNCE_CAPABILITIES` is not always first: after an agent restart
  spice-gtk flushes a queued `GRAB` before it.
- The device missing at login is retried every 3 s; a read error or EOF closes and reopens it,
  and every open announces capabilities again.
- File transfers run on their own queue, so a macOS privacy prompt for `~/Desktop` can block only
  file transfers, never the clipboard.

## Files

- `Sources/` — the agent (Swift, AppKit only). `build.sh` compiles it with the Command Line
  Tools' `swiftc` inside the VM.
- `install.sh` — runs in the VM: build, install `/usr/local/libexec/vmlab-spice-agent`, load
  LaunchAgent `local.vmlab.spice-agent` (KeepAlive, Aqua session). Called by
  `../install-spice-agent.sh` from the host.
- `tests/test_agent.py` — headless end-to-end tests (see below). `tests/pbtool.swift` is a
  pasteboard helper they compile in the VM. `tests/qemu-cpu.sh` measures the VM's CPU.
- `protocol/vd_agent.h` — the protocol header the code was written from.

Log: `~/Library/Logs/vmlab-spice-agent.log` in the VM. Add `-v` to the LaunchAgent's
`ProgramArguments` to log every message type in and out.

## Tests

`python3 tests/test_agent.py [name-words...]` on the host, with `mac` running and the agent
installed. The script is its own SPICE client (SpiceClientGLib over `virDomainOpenGraphicsFD`,
main channel only), so the host desktop clipboard is never touched. Guest state is checked with
`pbpaste`/`pbcopy`/`pbtool` over SSH.

Only one SPICE client can connect. If the user opens the viewer during a run, the test client is
dropped and the run stops with exit code 3 instead of reconnecting.
