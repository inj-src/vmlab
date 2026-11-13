# vmlab-spice-agent

A SPICE guest agent for the lab's Mac VM. It shares the clipboard with the Mac's window (reims'
window with the lab's `agent.rs`, `gpu/README.md`) in both directions. There is no SPICE agent
for macOS upstream; this one is written from `protocol/vd_agent.h` (spice-protocol, BSD licence).

## What it does

| Direction | Formats |
|---|---|
| host → guest | UTF-8 text; PNG (BMP, JPEG and TIFF are converted to PNG). Text and an image offered together are both put on the pasteboard. macOS serves TIFF to apps that ask for it. |
| guest → host | UTF-8 text; images as PNG (any pasteboard image type ImageIO reads: TIFF, JPEG, HEIC, GIF, BMP…, plus PDF, is converted, with EXIF orientation applied). A Finder file copy goes over as its text (the file name), not its icon. |
| file drop | `FILE_XFER_*`: each file lands in `~/Desktop` once complete. Existing files are never overwritten (`name (1).ext`). Cancelled or failed transfers leave nothing behind. The lab's Mac window does not send these: its drops go over SSH (`gpu/reims/mac26.sh drop`). |

Not handled: display resize, mouse, audio, multiple monitors.

## How it works

- The link is a Unix socket the agent listens on, `~/Library/Caches/vmlab-spice-agent.sock`
  (mode 600). The host reaches it through SSH: `mac26.sh start --window` keeps
  `ssh -L <its agent.sock>:<this socket>` running, and the window connects to that. So sshd
  carries the bytes, and no device of the VM takes part.
  - It was the virtio console (`/dev/cu.com.redhat.spice.0`) until 2026-11-13. macOS stopped
    reading that device at random after some tens of megabytes, and the clipboard was dead
    until the guest restarted (`gpu/README.md` has the evidence).
- One client at a time: a new connection replaces the one before it, which is closed (an old
  one may be what a client that was killed left behind).
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
  - Replies carry no request id and spice-gtk silently drops requests it won't serve (data over
    its `max-clipboard`), so at most one `REQUEST` is in flight. A newer host `GRAB` waits for
    the outstanding reply, which is discarded, and a reply that never comes is given up on
    after 10 s without bytes from the host.
  - `VD_AGENT_MAX_CLIPBOARD` is honoured: a guest clipboard larger than the client's limit is
    answered with empty data.
- A client is "connected" from its first message on the client port until its connection
  closes (or `CLIENT_DISCONNECTED`). Every new connection is greeted with the agent's
  capabilities. Its `ANNOUNCE_CAPABILITIES` is not always first.
- A read error, end of file, a protocol error or a message that could not be written whole
  closes the connection; the socket goes on listening, and the window connects again within
  2 s. A lock file beside the socket (`.lock`) keeps a second agent, say one started by hand,
  from taking the socket's name away from the first: it waits and tries every 3 s.
- File transfers go from the reader straight to their own queue, never through the clipboard's
  main queue. Each file is received in `~/Library/Caches/vmlab-spice-agent/partial/<device>/`
  and moved into `~/Desktop` with an exclusive rename when complete; leftovers from a killed
  agent are deleted when the next client connects. A transfer with no data for 20 s is dropped.
- macOS privacy (TCC): the LaunchAgent may create files in `~/Desktop` without a prompt. An SSH
  session can only `stat` files there (no read, list or delete), which is why the tests check
  Desktop files by size and check contents with `--drop-dir`.

## Files

- `Sources/` — the agent (Swift, AppKit only). `build.sh` compiles it with the Command Line
  Tools' `swiftc` inside the VM.
- `install.sh` — runs in the VM: build, install `/usr/local/libexec/vmlab-spice-agent`, load
  LaunchAgent `local.vmlab.spice-agent` (KeepAlive, Aqua session). Called by
  `../install-spice-agent.sh` from the host, with the Mac running. A saved state keeps the
  agent it was saved with: run it in each state after a change here, and save the state again.
- `tests/link_test.py` — the link end to end, from the host (below).
- `tests/unit.swift` — the file-name sanitizer, the key-file parser, the exclusive publish and
  chunk reassembly. It has no runner now: compile it in the VM with `Sources/Protocol.swift`
  and `Sources/FileXfer.swift` as its `main.swift`, on a run that is reset afterwards
  (an unsigned binary started over SSH leaves a tccd/sandboxd/apfsd loop at about 100% guest
  CPU that survives a restart).
- `protocol/vd_agent.h` — the protocol header the code was written from.

Log: `~/Library/Logs/vmlab-spice-agent.log` in the VM. Arguments (add them to the LaunchAgent's
`ProgramArguments`): `-v` logs every message type in and out; `--drop-dir DIR` saves dropped
files in DIR instead of `~/Desktop`; a positional argument replaces the socket's path (the
host's `AGENT_SOCK` in `gpu/reims/mac26.sh` names the same one).

## Tests

`python3 tests/link_test.py [ROUNDS [MEGABYTES]]` on the host, with the Mac running (no window
needed) and the agent installed. The script is its own client: it forwards the agent's socket
with its own `ssh -L` and speaks the protocol there, so neither the lab's window nor the host's
clipboard takes part; the guest's pasteboard is read and written with `pbpaste` and `pbcopy`
over SSH. It checks text both ways, that a second connection replaces the first, that the next
connection works after the agent was restarted, and then ROUNDS times (default 4) MEGABYTES
(default 60) of text each way by SHA-256. `link_test.py 30 60` is 3.55 GB and took 90 s on
2026-11-13. It runs nothing unsigned in the guest and leaves only the pasteboard changed.

Not covered by a test any more (the old suite spoke through libvirt's SPICE server, which the
lab no longer has): pictures and their conversions, file transfers, and the request timeouts.
Pictures were checked by hand through the window (`gpu/README.md`).
