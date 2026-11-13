# vmlab GPU: virtual GPUs for the test VMs

The lab's `win` and `mac` VMs render on the laptop's GPUs without a card passed through, each in
its own way. Both run outside libvirt as user units. Since 2026-11-12 they are what `vm start
win|mac` runs (`~/.local/bin/vm` calls the two launchers here; the earlier CPU-rendered libvirt
VMs are gone), and both count as "a VM" for the one-VM-at-a-time rule.

Host GPUs: Intel UHD (ADL-S GT0.5, `/dev/dri/renderD128`, drives the laptop panel) and NVIDIA RTX
4050 Laptop (`renderD129`, drives HDMI). Check with `/vmlab/reims/bin/reims gpus`.

## Windows: `win3d/win-venus.sh` (virtio-gpu Venus)

Windows 11 with the vmlab-win3d guest driver: Direct3D 9–11, OpenGL and Vulkan are forwarded to
the host's Vulkan driver. Three disk layers in `/vmlab/images`: `win11-base.qcow2` (Windows as
installed, never written), `win11-ready.qcow2` on it (the ready state: the driver and the lab's
fixes; `reset` returns to it, `commit` writes to it, `setup` builds it again, "The ready state"
below) and `win11-venus.qcow2` on that (this run's changes). The driver is test-signed, so
Windows shows "Test Mode"; Secure Boot is off in this VM only. 6 CPUs on the fast cores
(`../pin.py`), 8 GB, 1920×1080 without a window (in a window: the window's size, below).

```sh
W=/vmlab/tools/vmlab/gpu/win3d/win-venus.sh
$W start nvidia           # the RTX 4050, no window: for agents. `start intel` is the slower fallback
$W start nvidia --window  # for a person: a window on the desktop (below)
$W ssh 'hostname'         # dev@127.0.0.1:2222; the SSH shell is PowerShell 7. `start` returns before
                          # Windows is up: wait until `$W ssh 'query session'` lists an Active session
$W scp FILE dev@127.0.0.1:FILE
$W shot /tmp/s.png        # screenshot (over VNC, 127.0.0.1:5911; `$W view` opens a VNC console)
$W stop                   # $W reset: back to the ready state. $W commit: this run becomes it
```

- **GUI programs need the desktop session**, as on `win`: `C:\vmlab\run-interactive.ps1`. Chrome
  started from plain SSH does render on the virtual GPU, but presents far slower (`fill` 116
  frames a second against 3600), and Vulkan finds no GPU at all there. The helper shows no
  window of its own: its task runs `conhost.exe --headless powershell.exe …` (`powershell.exe
  -WindowStyle Hidden` opens a console first and hides it after, which flashed on the desktop at
  each full screen toggle, when the launcher sets Windows' mode and scaling through it). Cua
  Driver's logon task is started the same way (`guest-scripts/quiet-helpers.ps1`). Test:
  `guest-scripts/watch-windows.ps1 SECONDS`, run through the helper with `-NoWait`, logs every
  window that appears to `C:\vmlab\interactive\watch.log`.
- **Boot screen**: black, then Windows' own logo. `firmware()` in `win-venus.sh` boots a copy of
  the system's OVMF (`firmware/OVMF_CODE_4M.vmlab.fd`, made by `firmware/make-firmware.py`,
  remade when the system's file changes) in which the driver that draws the TianoCore logo
  never runs (LogoDxe's dependency expression is FALSE) and the "BdsDxe: loading Boot000x" line
  is empty: 3 bytes changed inside the compressed volume. With no logo shown, the firmware
  hands Windows no boot picture (no BGRT table) and Windows draws its own. `WIN_VENUS_FIRMWARE=stock`
  boots the system's file. `firmware/boot-shots.py DIR` takes a screenshot series of a start.
- **Run Windows PowerShell 5.1 from SSH with a clean module path**: `Remove-Item Env:PSModulePath;
  powershell …`. Without it, 5.1 inherits PowerShell 7's path and core cmdlets (`Get-FileHash`)
  are missing; the driver's `Install.cmd` and `run-interactive.ps1` fail that way.
- **Keyboard without SSH** (a locked account, a boot menu, Automatic Repair after a forced
  power-off): `python3 -I reims/qdrive.py /vmlab/run/win-venus/qmp.sock key cmd+r`, `type
  'text'`, `key alt+y` (the UAC prompt's Yes), with `$W shot` to see. `vm gui win …` is the
  same tool with the screen's size and picture taken from VNC (`QDRIVE_VNC=5911`), which adds
  `click`, `move`, `drag`, `size` and `shot`. Windows takes these keys for a keyboard's: a
  low-level keyboard hook sees them without the "injected" flag that `SendInput` leaves.
- **Network**: guest 10.0.2.15, host 10.0.2.2, through a second QEMU that acts as the NAT box.
  Only SSH is forwarded.
- Logs: `/vmlab/run/win-venus/qemu.log` (QEMU and the render server). `WIN_VENUS_STRACE=FILE`
  records the system calls of QEMU's main thread.

### The window (`--window`)

A GTK window titled "Windows 11" with the Windows 11 icon (`icons/vmlab-win11-light.svg`, through
`~/.local/share/applications/vmlab-win11.desktop`, which also puts the VM in the app grid as
"Windows 11"), sound (PipeWire) and the host's own pointer wearing Windows' cursor shapes ("The
pointer" below). Closing it shuts Windows down. Names the desktop shows carry no "vmlab" or
"dev" (the user's request).

- **Full screen**: the round button at the title bar's right, or Ctrl+Alt+F; Ctrl+Alt+F leaves
  it. Windows takes the screen's own size and gives it back: 1920×1008 ↔ 1920×1080 in the test
  rig at 100%, 1920×990 ↔ 1920×1080 at 125%. There are no menus (the user asked for full screen
  and its shortcut alone).
- **Keyboard and pointer** (the same on the macOS window; the user's request, 2026-11-12):
  while the window has the keyboard every key goes to Windows, the desktop's shortcuts too (the
  Windows key, Win+R, Alt+Tab); the pointer is never held, so the title bar and other windows
  are one move away, and a click on another window gives it the keyboard. There is no release
  chord. GNOME asks once per app "Allow inhibiting shortcuts" (Allow; the answer is kept for
  the launcher's app), and its own Super+Escape gives the desktop its shortcuts back until the
  window is next activated. Ctrl+Alt+F stays QEMU's. `qemu-patches/0012`: one Wayland shortcuts
  inhibitor for the window, kept while it is mapped. GDK's keyboard grab at each change of
  focus cannot be used: GNOME's question takes the keyboard for a moment, the grab is dropped,
  and that withdraws the question.
  **The title bar is the desktop's** (2026-11-12, `0013`): a press on it (not on its buttons)
  lets the inhibitor go, so Super and Alt+Tab are the desktop's though the window keeps the
  keyboard; a press in the picture, or the window gaining the keyboard again (coming back
  from the overview counts), asks for it again. The inhibitor is the surface's and GTK draws
  the title bar in the same surface, so mutter itself makes no difference there (read in
  mutter 46.2: shortcuts come back only through its restore-shortcuts key). A drag of the
  title bar keeps them the desktop's too: the drag is the compositor's window move, which
  takes the keyboard away and gives it back (`wl_keyboard.leave`, `enter`), and `0013` does
  not count that as the window gaining the keyboard (the keyboard leaving while a button is
  down on the title bar). Checked in the rig with the Windows guest, 2026-11-12: Super opens
  Start; after a click or a drag on the title bar it opens GNOME's overview; back from the
  overview, or after a click in the picture, it opens Start again.
- **Clipboard and files**: text and pictures copied on either side paste on the other, and
  files dragged onto the window land on Windows' desktop (`-chardev qemu-vdagent`, the SPICE
  agent in the guest; `qemu-patches/0009` to `0011`). Large files too: checked 2026-11-13 in
  the rig with 40 MB, 1.5 GB (15 s) and 4.5 GB (30 s), each with the same SHA-256, two files
  in one drag, and a name already there (it gets `(1)`). The window's clipboard was off before
  `0011`, GTK's default for it: nothing was shared until then, whatever this file said.

Changing the icon: give the new picture a new file name and change `Icon=` (GNOME Shell keeps a
picture it has drawn under its path until logout), then wait 10 s before starting the VM: the
shell re-reads launcher entries about 5 s after a change, and a window that opens sooner keeps
the old icon for as long as it is open.

- **Pinned resolution, maximized window (asked for by the user, for both VMs).** The window
  opens maximized and Windows takes its size once, as it starts: 1920×1040 on the 1920×1080
  monitor (the rest is the title bar; the size is rounded down to a width of a multiple of
  8 and an even height, and 1920×1042 under XWayland). The user called that size fine. QEMU
  logs `vmlab: the guest took the window's size, 1920x1040: pinned`. From then on the resolution does not follow the window: a resize scales the
  picture, keeping its shape. Maximized, a Windows pixel is a screen pixel (sharp).
  `WIN_VENUS_WINDOW_SIZE=1920x1080` is the earlier behaviour: that size always, scaled into the
  window's 1043 rows by the CPU (0.966, so visibly softer than the mac's window, which the
  user noticed 2026-11-11) and unscaled only full screen (Ctrl+Alt+F) on a 1920×1080 screen
  at 100%. Checked 2026-11-11 with the window under XWayland ("Testing the windows" below):
  restore, 1280×700, 900×900, maximize again, Windows at 1920×1042 throughout.
- **Scaled screens: sharp, and the same size as the desktop's** (`qemu-patches/0007`; the user
  asked 2026-11-11 for each VM to adapt to the screen its window is on: the monitor is 100%,
  the laptop's panel 125%). GTK 3 draws at whole-number scales only, so on the panel it drew
  at 2 and mutter shrank that: soft. With `VMLAB_WINDOW` on Wayland the guest's frame now goes
  to a Wayland sub-surface of QEMU's own over the drawing area (`ui/gtk-vmlab-wl.c`: shared
  memory, `wp_viewport`, the scale from `wp_fractional_scale_v1`), a guest pixel on a screen
  pixel. QEMU logs `vmlab: the picture is shown at the screen's own pixels`.
  - **Resolution**: when the window fills a screen of another scale (maximized or full screen
    there, settled for 300 ms), Windows is offered that screen's pixels, once per change. A
    window that does not fill its screen keeps Windows' resolution, scaled to fit.
  - **Windows' own scaling** follows the screen whatever the window's state: QEMU keeps
    `/vmlab/run/win-venus/scale` at the scale in percent, and the `vmlab-win-venus-scale` unit
    (`win-venus.sh scale-watch`) runs `guest-scripts/set-scale.ps1` in the desktop session
    (`SPI_SETLOGICALDPIOVERRIDE`: at once, no sign-out; log `scale.log`). `$W scale [PERCENT]`
    reads or sets it by hand.
  - Measured in the test rig ("Testing the windows" below), maximized: 1920×1008 at 100% and
    1920×990 at 125% (the rig's screen loses rows to its own window), every screen pixel of
    the picture equal to Windows' own, scaling 100% ↔ 125% each way.
  - **Not checked**: the real panel (expected about 1920×1040 at 125%), and the pointer's
    look at 125% (GDK shows pointer images at whole scales; the patch makes the image 1.6
    times the guest's and shows it at 2).
  - `VMLAB_WINDOW_NATIVE_SCALE=0` turns the sub-surface off; under XWayland
    (`WIN_VENUS_WINDOW_X11=1`) there is none, and mutter 46 stretches the window on the panel
    (`xwayland-native-scaling` in its settings does nothing before mutter 47).
- **QEMU is built here**: `build-qemu.sh` builds vmlab-win3d's patched QEMU at the release's
  commit with a GTK window, user networking, io_uring and PipeWire, into `opt/qemu-ui/`
  (`opt/qemu/` is their release binary). `qemu-patches/`, applied in order:
  - `0001`: the window's title, application id (for the icon) and close-shuts-down
    (`VMLAB_WINDOW_TITLE`, `_APP_ID`, `_CLOSE_POWERS_DOWN`);
  - `0002`: with `VMLAB_WINDOW` set, a plain (non-OpenGL) GTK window opens beside `-display
    egl-headless` and shows the frames that reads back;
  - `0003`: `VMLAB_WINDOW_FIXED_SIZE=1920x1080` (the guest is always offered that size; offering
    nothing leaves Windows at 1024×768) and `VMLAB_WINDOW_MAXIMIZE`;
  - `0004`: the host's pointer takes the cursor the guest hands over ("The pointer" below);
  - `0005`: `VMLAB_WINDOW_FIXED_SIZE=first` (the guest takes the window's size once, above; a
    picture within a step of the window's size is drawn unscaled);
  - `0006`: QEMU's menus (Machine: pause, reset, power down; View: full screen, zoom) sit in
    the title bar, at its right, not in a row of their own (the user's request: no rows taken
    from the picture; the bar stays 37 rows high), and full screen keeps the picture's shape
    (1920×1040 unscaled on the 1920×1080 screen, 20 black rows above and below).
  - `0007`: the picture at the screen's own pixels on a scaled Wayland screen (above);
  - `0008`: the two menus are icon buttons (a power sign, a screen) at the title bar's right,
    left of the window's own buttons (the user's request); they take no keyboard focus.
  - `0009`: pictures on the shared clipboard (PNG, up to 64 MiB) and files sent to the guest
    through the agent's file transfer;
  - `0010`: one full screen button in the title bar in place of the two menu buttons of `0006`
    and `0008`, and files dropped on the window go to the guest. (An open menu's popup also
    crashed mutter 46.2 when QEMU died under it; not reported to mutter.)
  - `0011`: the window's clipboard is on; full screen at the screen's size;
    `VMLAB_WINDOW_SIZE_FILE` gets the size last offered, which `win-venus.sh` applies in the
    guest (`guest-scripts/set-mode.ps1`), because Windows, shown a new size while it starts,
    sometimes settles on 1024×768; and the picture's sub-surface (`0007`) comes off the window
    at the full screen toggle. A sub-surface that covers the whole window leaves mutter nothing
    of the window to draw, so it sends no frame callback, GTK 3 waits for one before drawing,
    and the window never left full screen.
  - `0012`: every key goes to the guest while the window has the keyboard ("Keyboard and
    pointer" above).
  - `0013`: a press on the title bar gives the desktop its shortcuts back (the same place).
  Checked 2026-11-12: `0001` to `0013` on the release's sources give the built files byte for
  byte.
    To try a window change without a guest: `build/qemu-system-x86_64 -L build/pc-bios
    -machine q35 -nodefaults -device VGA -display egl-headless` with `VMLAB_WINDOW=1
    GDK_BACKEND=x11` as a `systemd-run --user` unit, then `xwd` its window ("Testing the
    windows" below; the capture shows the title bar, the picture area comes out black).
  After editing `/vmlab/tmp/win-qemu/qemu`: stop the VM, `build-qemu.sh rebuild`.
- **Why not `-display gtk,gl=on`**: GTK draws on the desktop's GPU (Intel), whose driver cannot
  use NVIDIA's frames: QEMU's main thread loops for ever on `DRM_IOCTL_I915_GEM_EXECBUFFER2 =
  ENOMEM`. On NVIDIA's own EGL, QEMU's GTK code finds no dma-buf support and aborts. So frames
  are read back on the NVIDIA card and the window draws them with the CPU.
- **Cost of the window**: `draws` 307 frames a second with it, 350 without; pacing at 60 Hz is
  the same (0 to 2 late frames in 20 s). One earlier session measured `draws` at 146 with the
  window, before the size was fixed; the cause was not found (suspect: the laptop panel's 125%
  scaling, where GTK draws at twice the size). Measure again if the window feels slow there.

### The pointer (`kmd-patches/0003`, `qemu-patches/0004`)

The pointer in the window is the host's own, drawn by the desktop with no delay, in the shape
Windows asks for (arrow, I-beam, resize, hand; hidden while typing). Three things make that so;
before 2026-11-11 the pointer trailed the mouse:

- **Windows hands its cursor over.** Release 0.1.2-alpha's kernel driver (`viogpu3d.sys`,
  Yttrium's) has the hardware pointer switched off in code ("Disable pointer on viogpu3d for
  now", the same in every upstream version to 2026-11-02), so Windows drew the pointer into each
  frame and it arrived with the frame, a few frames late. `kmd-patches/0003` implements it:
  shapes go to a 64×64 resource and virtio-gpu's cursor queue. A host pointer cannot invert
  what is under it, which is what the I-beam asks for: those pixels become black with a white
  outline. Registry `HWCursor=1` in the driver's class key (`…\Control\Class\{4d36e968-…}\0001`)
  turns it on; the INF's default is 0.
- **QEMU's window wears it** (`qemu-patches/0004`). With an absolute pointer QEMU's GTK window hid
  the host's pointer; now it shows the guest's cursor on it, hides it when the guest does, and
  puts it back after grabs.
- **The mouse is the USB tablet.** The clipboard channel (`-chardev qemu-vdagent`) also offers
  itself as a mouse and QEMU preferred it, so every move went through the SPICE agent program
  inside Windows. `mouse=off` on that chardev (in `win-venus.sh`) leaves the tablet.
  `query-mice` over QMP shows which device is current.

- **The GPU keeps its PCI slot** (2026-11-12). Windows keeps a device's driver settings under
  the slot it sits in. `win-venus.sh` left the slots to QEMU's numbering, so the build cache's
  disk, added before the GPU on the command line, moved the GPU from slot 4 to 5: Windows set
  it up as a new device (class key `0002`) with the INF's `HWCursor=0`, and the pointer
  trailed again. Every device now has its slot written out (`addr=`), `HWCursor=1` is in both
  keys, and `ready-checks.ps1` reads the key of the device that is present, not any key. If
  the pointer trails: `vnccursor.py` (below) times out when Windows is not handing its cursor
  over; then look at `HWCursor` under the present device's class key.

`build-guest-kmd.sh` builds and test-signs the driver (the release's build scripts, podman, the
lab's own key in `signing/`, output `guest-kmd/`; 2 minutes once Microsoft's driver kit is in
`/vmlab/tmp/win3d-cache`); `build-guest-kmd.sh install` puts `viogpu3d.sys` into the running VM's
driver store folder (the release's stays beside it as `viogpu3d.sys.release`), imports the
certificate and sets `HWCursor=1`; then restart Windows. The overlay keeps a `pre-kmd` snapshot
from before the swap (`qemu-img snapshot -a pre-kmd /vmlab/images/win11-venus.qcow2`, VM stopped).

- Check: `python3 -I win3d/vnccursor.py 5911 FILE.png` saves the cursor QEMU holds (enlarged);
  `$W shot` no longer shows a pointer, because it is not in the frame.
- Measured 2026-11-11: a move injected over QMP is back at the host as a cursor command in 1 to
  2 ms, a shape change too.
- Reported upstream 2026-11-11 with the patch: VMLabDev/vmlab#235 (no Yttrium branch has a
  hardware pointer; upstream's `main` now has its own kmd patches 0003 and 0004, so this one
  needs a new number and a rebase there). Windows asks for at most 64×64: a larger pointer (accessibility sizes,
  display scaling well above 100%) is drawn by Windows into the frame again, with the old delay.

### Local fix in the guest's Direct3D driver (`guest-patches/9001`)

Release 0.1.2-alpha draws nothing from static vertex buffers in Chrome: the WebGL Aquarium showed
no fish, with no error anywhere. Chrome's ANGLE creates every
`STATIC_DRAW` vertex buffer as "vertex + stream output" and fills it with a buffer-to-buffer
copy. The driver (Mesa's Yttrium winsys) keeps such a buffer as a GPU buffer plus a CPU copy, and
that copy path wrote the CPU copy only, so draws read zeros. Map/unmap and `UpdateSubresource`
were right, which is why dynamic buffers, index buffers and `gl_VertexID` draws worked.

- `guest-patches/9001-…patch` uploads the copied range to the GPU buffer too
  (`yttrium_resource_copy_region`).
- `build-guest-umd.sh` builds the driver DLLs with the release's own build scripts (podman in
  place of docker, everything under `/vmlab/tmp`) plus `guest-patches/`, into `guest-umd/`; run
  it as a `systemd-run --user` unit (about 6 minutes once the toolchain image exists).
  `build-guest-umd.sh install` copies `viogpu_d3d10.dll` (x64 and x86) into the running VM and
  keeps the release's as `viogpu_d3d10.dll.release` beside it; then restart Windows. It replaces
  the copy in the driver store too: when Windows installs the device anew it links System32's
  file to that copy again. That happened on 2026-11-12 (the build cache disk moved the card
  from PCI slot 4 to 5) and brought the release DLL back unnoticed. **The ready state made that
  day, and every state saved from it, still has the release DLL** until the install is run in
  them again (`Get-FileHash C:\Windows\System32\viogpu_d3d10.dll` against
  `sha256sum guest-umd/x64/viogpu_d3d10.dll`).
- Tests, in the guest: `node page-shot.mjs file:///C:/Users/dev/gl-vertex.html out.png 6` (18
  ways to feed vertices; the static-buffer ones fail on the release DLL) and `gl-features.html`
  (72 cases). Both pass with the fix. The first Chrome start after swapping the DLL once failed
  to create WebGL contexts; it did not repeat in five runs (probably the `d3d12.dll` crash below,
  which was not known then).
- Reported upstream 2026-11-11: https://github.com/VMLabDev/vmlab/issues/233 (upstream moved to
  `VMLabDev/vmlab`, `guest/win3d/`). The driver's base, `arehnman/virtio-win-mesa`, fixed the
  same spot in its November release (76c095bb); VMLabDev's `build/mesa/PINS` still pins
  September (374c3022). When a win3d release moves that pin, take its `viogpu_d3d10.dll` and
  drop patch 9001. The memory fault below (host layer) is
  https://github.com/VMLabDev/vmlab/issues/234.

### Local fix: gaps in Direct2D shapes (`guest-patches/9002`)

Seen 2026-11-13 in Microsoft Word 16.0.20527: short pale gaps in the ribbon's rounded boxes (the
search box, the Styles gallery), in other places at every start of Word; the page and its text
were clean. Any Direct2D program on feature level 11.1 can show it.

- Direct2D antialiases shapes with target-independent rasterization: triangle fans drawn with
  ForcedSampleCount 16 into a single-sampled R16_UINT texture, the pixel shader writing
  SV_Coverage, the output merger XORing. The driver drew that as one 16-sample draw whose
  fragment shader XORs under a pixel interlock (`VK_EXT_fragment_shader_interlock`). On this
  host (NVIDIA 595.99 through Venus) two fragments of one pixel with disjoint coverage, which
  is every pixel on an edge two triangles share, lose one of their XORs.
- Evidence: clean with `ENABLE_FL11_1=0` (Direct2D then does not use the path) and with
  `FORCED_SAMPLE_COUNT_MAX=1` (no antialiasing there); the same gaps with ordered interlock;
  far worse with no interlock; three starts with one setting differ in 260 to 370 pixels.
  Whether NVIDIA's driver or the Venus renderer loses the lock was not looked into.
- `guest-patches/9002-…patch` sends such a draw as one single-sampled draw per sample, with
  the texture as a colour attachment and the blender's logic op XOR: no lock. The patch's
  header has how one pipeline serves all 16 draws. `FORCED_SAMPLE_PASSES=0` brings the
  interlock path back.
- Test: Word's ribbon in three starts is the same to the pixel, and 5 pixels differ from
  feature level 11.0. Not measured: what 16 draws for one cost (nothing felt slower).
- Not reported upstream yet.

The driver's options are environment variables (`D3D10UMD_YTTRIUM_…`) or lines `KEY=VALUE` in
`C:\ProgramData\Yttrium\yttrium.ini` (the prefix may be left off), read once per process. Its
logs are `yttrium-user.log` and `yttrium-errors.log` in that folder; a line `forced-sample draw
WINWORD.EXE … coverage=passes` says the patched path drew.

### Direct3D 12: Microsoft's `d3d12.dll`, not the package's (`$W d3d12`)

The driver package replaces Windows' `d3d12.dll` with an unsigned bridge (Direct3D 12 through
vkd3d-proton) and a boot task, `vmlab-win3d-repair`, puts it back at every boot. **With the
bridge, Chrome loses WebGL**, and so would an Electron app:

- Chrome's GPU process takes only Microsoft-signed DLLs once it is running (`Get-ProcessMitigation
  -Id <pid>`: `MicrosoftSignedOnly: ON`). The driver's own DLLs are loaded before that.
- When a page makes Chrome look for GPU video encoders (anything with WebRTC or WebCodecs; with
  Chrome's normal profile, not with a new one), the GPU process loads `d3d12.dll` then. Windows
  refuses (error 577, invalid image hash) and Chrome ends the GPU process on purpose
  (`media::CreateD3D12Device` → `HandleDelayLoadFailureCommon`, exception 0x80000003).
- After three such crashes Chrome runs without GPU until it is started again: "It does not
  appear your computer supports WebGL", `GL_VENDOR = Disabled`, `BindToCurrentSequence failed`.
  Seen 2026-11-11 at 10:18 and 19:06; the dumps are in
  `%LOCALAPPDATA%\Google\Chrome\User Data\Crashpad\reports`.

So the lab's guest has Microsoft's file: `$W d3d12 native` (`guest-scripts/d3d12-mode.ps1`:
it copies the package's `vmlab-win3d\d3d12-native.dll` back, x64 and x86, with the owner it had,
and disables the boot task), then restart Windows. Chrome then loads Microsoft's `d3d12.dll`,
finds no Direct3D 12 on this GPU (the driver has none) and carries on. `$W d3d12 bridge` runs the
package's task to put the bridge back, for a native Direct3D 12 program; `$W d3d12` says which
is there. WebGPU has no adapter either way.

Test, in the guest's desktop session with Chrome's normal profile: `guest-tests/venc.html`
(asks for a hardware H.264 encoder, then tries WebGL for 20 s). With the bridge, each run adds a
dump; with Microsoft's file, none in three runs, and the GPU process has `d3d12.dll (Microsoft
Corporation)` loaded. Reading such a dump: the failed load's record (`DelayLoadInfo`, 72 bytes)
is on the crashing thread's stack, with the DLL's name and `dwLastError`; Chrome's symbols are on
its symbol server (`chrome.dll.pdb`, 5.8 GB) and `llvm-symbolizer-18 --obj=chrome.dll
--relative-address` names the frames. Not reported upstream yet.

### Saved states (`vm save`, `vm states`)

A saved state is a run's disk kept as it was: `/vmlab/images/states/win/NAME.qcow2`, a copy of
`win11-venus.qcow2` (the changes since the ready state, so as large as what the run wrote),
with its firmware variables beside it. `$W state load NAME` copies it back to
`win11-venus.qcow2`; on this XFS disk a copy shares its blocks with the original (reflink), so
saving and loading take no time and no room until the two differ. `../states.sh` has what
Windows and the Mac share: the names, and the marks `.current` and `.changed` that say which
state the disk is on and whether it ran since. A VM that ran on a named state and was not
saved since is not reset or loaded over without `--discard`.

The states are changes to this ready state: on another one they are a broken disk. `$W commit`
therefore refuses while states exist, unless told what to do with them. `--keep-states` moves
them along: each state is pointed at a copy of the ready state as it is (`win11-ready.held.qcow2`,
a reflink), the commit runs, and `qemu-img rebase` moves each state to the new ready state,
copying into it whatever the commit changed underneath. A state then reads as before the
commit, without the commit's change, and has grown by about the commit's size; with the two
states of 2026-11-13 it took 2 minutes. A state that could not be moved stays whole on the
copy and the next `commit --keep-states` moves it. `--drop-states` deletes the states. `$W setup`
asks for `vm clear win --all` first. Its trial runs (`WIN_VENUS_READY`, `WIN_VENUS_DISK`) keep
their marks in `/vmlab/run/win-venus/trial-states`, away from the real ones.

The Mac keeps its states as snapshots inside its one disk file, beside `clean`
(`reims/mac26.sh state …`); each is a whole disk of its own, and a commit leaves them alone.

One state of `win` belongs to the lab: `defender`, the clean state with Defender antivirus
switched on again (`win/enable-defender.ps1`). A commit with `--drop-states` or a new ready
state deletes it; `win/README-defender.txt` has the steps that build it again.

### The ready state (`$W setup`)

`$W reset` returns to `win11-ready.qcow2`, which has everything below, so nothing needs doing
after a reset. `$W setup` (`setup-ready.sh`; run it as a `systemd-run --user` unit, no window
opens) builds that state again from `win11-base` on a new file and swaps it in only when its
checks hold (`guest-scripts/ready-checks.ps1`). A trial took 3 min 46 s and gave a 572 MB
layer. What it does:

1. The driver package from the CD (`D:\Install.cmd`, `win3d-guest.iso`). It restarts Windows
   twice; its state is `C:\ProgramData\vmlab-win3d\state.json`, its log `journal.log` there.
2. `build-guest-umd.sh install`, `build-guest-kmd.sh install` (the pointer; it sets
   `HWCursor=1`) and `$W d3d12 native` (Chrome's WebGL, above), then a restart.
3. `net accounts /lockoutthreshold:0`. **Chrome locks the account otherwise**: every Chrome
   start with a new profile tries a logon with an empty password (Security event 4625), and
   Windows 11 locks `dev` for 10 minutes after 10 failures, SSH key included ("Permission
   denied"). `win11-base` still has that default.
4. The lab's `win/run-interactive.ps1` in place of `win11-base`'s older copy, and
   `guest-scripts/quiet-helpers.ps1`: no console windows ("GUI programs" above). Then
   `guest-scripts/clear-history.ps1`: `win11-base` carries the Run box's list and the recent
   items of the lab's own setup.
5. The theme "Windows (light)" (`guest-scripts/set-theme.ps1`, the user's choice).
6. Windows' own animations, fades, shadows and transparency (`guest-scripts/default-ui.ps1`,
   run with step 2 before its restart; the user's wish, 2026-11-12). `win11-base` has them
   off, the "best performance" set from the time the VM had no GPU. Applied by hand to the
   ready state in use and checked in its desktop session (`SystemParametersInfo`: client
   area, minimize, menu, combo box and tooltip animation all on); the step inside `setup`
   has not been run.

**Not in `setup`** (in the ready state in use, put there by hand, 2026-11-12; a ready state
built by `setup` lacks them until these are run again, then `$W commit`):

- The build cache disk and the shared folder: `win/setup-cache.ps1`, `win/setup-share.ps1`,
  and Rust (`win/install-rust.ps1`).
- `win/install-web-tools.ps1` (over SSH, as `dev`): pnpm and fnm as single programs in
  `C:\Program Files`, their and Electron's download caches on `C:\cache`, the name
  `host.vmlab` for this machine.
- `win/install-postgres.ps1` (through `run-interactive.ps1`): PostgreSQL 16 as EDB's installer
  sets it up on a customer's PC, 244 MB, the service `postgresql-x64-16` on port 5432,
  `postgres`/`postgres`, without pgAdmin and Stack Builder.
- `win/focus.ps1` and `win/tray.ps1` copied to `C:\vmlab`.

**The shared folder's server** is `../share-smbd.sh`, not QEMU's `smb=`: the same `smbd` with
leases and oplocks off, reached through `guestfwd` at the same address. With QEMU's own
settings Samba refused to open a file that had been replaced on the host under the same name
while Windows still held a lease on the old one (`STATUS_INVALID_PARAMETER`, "The parameter
is incorrect"); no setting of Windows' SMB client changed that. Measured after the change:
503 MB/s read, 264 MB/s write.

**Activation**: the ready state in use reports Windows as activated (a digital licence on the
generic retail key). `win11-base` carries the generic volume key and is not activated, so a
ready state built by `setup` is not either. `win11-ready.qcow2` is the only activated copy
(its backup of 2026-11-12 was deleted for the space, at the user's word): running `setup`
replaces it with an unactivated one. The lab runs no activation script.

Measured 2026-11-11, Chrome 157 WebGL2 (`bench/`, 4 s a test), frames per second. Chrome renders
through ANGLE's Direct3D 11 on "Hardsoft VirtIO GPU 3D controller"; pixels match native.

| Test | Host Chrome (native Intel) | Venus VM, `nvidia` | Venus VM, `intel` | Plain `win` VM |
|---|---|---|---|---|
| Any test, normal frame-rate limit | 60 | 60 | 60 | WebGL context is lost |
| `fill`, no limit | 120 | 3690 | guest crashes | — |
| `draws`, no limit | 1400 | 325 to 390 | 315 | — |
| `upload`, no limit | 1053 | 390 to 620 | 254 | — |

Both GPUs are fine for apps that keep the normal frame-rate limit, which is every normal app.
`upload` is 620 on its own and about 390 (sometimes under 100) right after `draws`, which leaves
queued frames behind. The numbers are the same with the driver fix and with the memory layer.
Without the limit (`--disable-gpu-vsync --disable-frame-rate-limit`, the benchmark's default):

- **On NVIDIA, video memory fills up.** In `draws` and `upload` the guest queues frames faster than
  they are released: the card's 6 GB is full after about 10 s, the render server logs
  `vkAllocateMemory failed: ret -2` in `qemu.log`, and Chrome loses its WebGL context (the
  benchmark then reports pixel `[0,0,0,0]`). Windows and the host carry on, and the memory comes
  back when Chrome closes. With the limit on, memory stays flat (about 60 MiB over idle for 25 s
  a test). So keep uncapped runs to a few seconds.
- **On Intel, a GPU-saturating shader crashes the guest.** `fill` makes i915 reset the engine
  ("Resetting rcs0 for preemption time out", `GPU HANG` in `journalctl -k`), and Windows
  bugchecks 0x116 and restarts. The host desktop recovered both times.
- **On NVIDIA the render server runs with a Vulkan layer of ours, `win3d/host-layer/`.** Without
  it Windows draws images with dark dashes, each 16 pixels long: on this laptop (Intel CPU,
  NVIDIA GPU) the GPU misses some of the guest's writes to NVIDIA's uncached host-visible memory
  (type 2), one 64-byte cache line at a time. vmlab-win3d documents the fault in its
  `docs/nvfb.md` and avoids that memory in its Vulkan and OpenGL drivers, but not in its
  Direct3D 9 to 11 driver, which the Windows desktop and Chrome use. The layer reports type 2 as
  not host-visible, so every guest driver takes the cached type 3 instead. `start nvidia` loads
  it (`WIN_VENUS_LAYER=off` starts without, to compare); `host-layer/build.sh test` rebuilds it
  and prints the memory types. Measured over two boots each: 133 and 31 dashes in the wallpaper's
  sky without it, none with it.
- **NVIDIA has shown no driver errors here** (no `Xid` or `NVRM` lines in `journalctl -k`; check
  after anything odd). The same laptop family once lost the card until reboot (Xid 79) in the
  driver authors' tests. That would take the HDMI monitor down until a reboot, so the user was
  asked and agreed to `start nvidia` on 2026-11-11.
- The render server's own `install.sh` exits silently on this host (a `pipefail` on `ldconfig -p |
  awk … exit`); `opt/virgl/libexec/virgl_render_server` was copied by hand.

## macOS: `reims/mac26.sh` (reims-vgpu)

[reims-vgpu](https://github.com/steelbrain/reims-vgpu) gives a macOS guest Metal, translated to
Vulkan on the RTX 4050. The guest is macOS Tahoe 26.7.1 (x64): 6 CPUs, 8 GB, 1920×1080, user
`dev` / `vmlab`, auto-login, passwordless sudo. Inside: Xcode Command Line Tools, Node 26, Python
3.12 and uv, VS Code, Chrome 157 (default browser, with the lab's policy profile), the Electron 38
bench app (`~/vmlab/bench-app`), Cua Driver 0.47 (LaunchAgent `com.trycua.cua-driver`, with its
Accessibility and Screen Recording grants), the debloat (`../mac/debloat.sh`; `PerfPowerServices`
does not spin on macOS 26, so `pps-stop.sh` is not installed) and vmlab-spice-agent (clipboard
and file drop, `../mac/install-spice-agent.sh`).

**One VM since 2026-11-12: `mac26d` (port 2227), the lane called dev below.** The user chose it
alone: reims' `master` (the stable lane) does not run this guest well, and its VM is no longer
started by `mac26.sh`. What follows about two lanes and `MAC26_LANE` is the record of how the
choice was made; the switch itself is gone.

There were two lanes, each a VM with its own disk and `clean` snapshot, chosen with `MAC26_LANE`:

| | `MAC26_LANE=dev` | `MAC26_LANE=stable` |
|---|---|---|
| VM, SSH port | `mac26d`, 2227 | `mac26`, 2226 |
| reims | upstream `development` (a7761508), in `/vmlab/reims-dev`, checkout `reims-vgpu-dev/` | upstream `master` (1fe0acb) plus the shader patch below, in `/vmlab/reims`, checkout `reims-vgpu/` |
| GPU device | `reims-graphics-pci` with reims' own guest driver (ReimsGraphics.kext, from its OpenCore image): Metal 3 | Apple's paravirtual GPU (`apple-gfx-pci`), Apple's x64 driver patched by ReimsVgpu.kext: Metal 2 |
| Frames later than 25 ms in 20 s of a 60 Hz animation | 0 to 1 | 14 to 38 |

The dev lane is the default since 2026-11-11 and the one that feels smooth: five boots in a row
came up, each with 0 or 1 late frame, 60 frames a second in all three benchmark tests and the
Electron 38 app running; VS Code and the WebGL Aquarium run too. It has had one afternoon of use,
and the stable lane is gone since 2026-11-12: its VM, its checkout `reims-vgpu/`, its QEMU builds and the macOS installer were deleted for the space (its local commit and uncommitted changes are two patches in `/vmlab/tmp/old-git/`), so the column and the notes on it below are history. What the stable lane's lag was: it copies about 68 MB
of guest memory into video memory every frame, whether or not it changed (measured with the
`wcs` counters, an uncommitted diff in `reims-vgpu/…/gpu/timing.rs`). Only one lane's VM can run.

```sh
M=/vmlab/tools/vmlab/gpu/reims/mac26.sh
$M start                # no window; returns when SSH answers (about 20 s)
$M ssh 'sw_vers'        # dev@127.0.0.1, port 2227
$M gui shot /tmp/s.png  # also: click X Y | type 'text' | key cmd+q   (pixels of that screenshot)
$M stop
$M reset                # back to the clean snapshot; $M commit makes the current disk the clean one
```

- **GUI apps from SSH** start on the visible desktop, as on `mac` (`open -a …`, or run the binary).
- **Full screen, clipboard, files** (2026-11-12): the title bar's round button or Ctrl+Alt+F
  fills the screen, and Ctrl+Alt+F leaves it; macOS takes the screen's pixels and gives them
  back (1920×1008 ↔ 1920×1080 in the test rig, at 100% and at 125%; `Pin` keeps a mode per
  scale and per full screen state). Text and pictures copy both ways: `native/linux/agent.rs`
  speaks the SPICE agent protocol over `VMLAB_AGENT_SOCKET` to the guest's vmlab-spice-agent
  (the link is below). Checked in the rig: text and a PNG each way byte for byte. The window's side is
  `patches/window-full-screen-clipboard-file-drop.dev.patch`.
  - **Files and folders dragged onto the window land on the guest's desktop, over SSH**
    (2026-11-13). The window gives one drag's paths to `VMLAB_DROP_COMMAND` (`mac26.sh drop`,
    which also works by hand): a tar stream over SSH into `~/Library/Caches/vmlab-drop/` in
    the guest, then a move onto `~/Desktop` under a free name (`name 2.ext`, as the Finder
    numbers them; nothing is overwritten). Nothing in the guest takes part but sshd, so it
    works in every saved state. A drag longer than 2 s shows a desktop notification
    ("Copying to the Mac", then "On the Mac's desktop"); a failure always shows one. Checked
    in the rig through the window: 11 bytes, 40 MB, a folder, and 1.5 GB (about 10 s, same
    SHA-256); by hand also links, a name starting with a dash, two files of one name, an
    `.app` folder and a missing file. Links inside a folder stay links; a dragged link sends
    what it points at.
  - **Dock badges show no number (not fixed).** The red dot on a Dock icon is drawn, its
    digits are almost the same red (stretching the contrast of a picture shows them). Seen
    2026-11-13 with System Settings' "1" (a pending Safari update) and with a test app's
    `dockTile.badgeLabel = "7"`; in the clean state too. System Settings' own sidebar draws
    its "1" right. Reduce transparency changes nothing; cause not found.
  - **The clipboard's link is a Unix socket carried by SSH** (2026-11-13). The guest's agent
    listens on `~/Library/Caches/vmlab-spice-agent.sock`; `mac26.sh start --window` runs
    `ssh -N -L $V/agent.sock:<that socket>` as the unit `vmlab-mac26d-agent`, bound to the VM's
    unit (it ends with it) and started again every 2 s when SSH ends (macOS restarting). The
    window connects to `$V/agent.sock` and tries again every 2 s, as before. No QEMU device
    takes part, and a closed connection is seen on both ends: the agent watches the
    pasteboard only while a window is connected.
    - Checked: `mac/spice-agent/tests/link_test.py 30 60` (its own client, no window): 3.55 GB
      of text, 60 MB at a time each way, same SHA-256, 2.5 s a round. Through the window in
      the rig: text both ways, six 50 MB pictures in a row (their exact sizes in the agent's
      log), and text again after the agent was restarted and after macOS was restarted,
      with no hand in between.
    - The agent in a state must match: one saved before 2026-11-13 has the old agent, which
      waits for a serial port that is no longer there, and its clipboard is dead until
      `mac/install-spice-agent.sh` has run in it (done for `clean`, `mine`, `pebble`,
      `office-wip`).
    - **Why**: the link was a virtio serial port (`com.redhat.spice.0`), and macOS stopped
      reading it at random. It stops offering receive buffers on the port's queue
      (`x-query-virtio-queue-status`, queue 4: last-avail = shadow-avail = used) while the
      agent sits idle in its run loop and about 200 KB wait unread in QEMU's end of the
      socket. Seen after 82 MB (a 1.4 GB file, when files still went this way), after 8 MB
      (a 20 MB picture on the clipboard) and after 128 MB. From then on nothing passed
      either way until the guest restarted. `CRTS_IFLOW` on the port was no fix (three
      pictures arrived, the next request stalled). A TCP connection from the agent to the
      host was not tried: macOS's local-network privacy covers login items (Apple TN3179),
      so it risks a permission prompt in every state.
  - **Keyboard and pointer**: the Windows window's rule ("Keyboard and pointer" there). Every
    key goes to macOS while the window has the keyboard (Super is Command: Cmd+Space, Cmd+Tab),
    the pointer is never held, there is no release chord, and GNOME asks "Allow inhibiting
    shortcuts" once. Upstream reims captures at a click into the picture, confines the pointer
    to it and releases at Ctrl+Alt+Super; `patches/window-keys-to-the-guest-pointer-free.dev.patch`
    changes `native/linux/input.rs` (capture from focus gained to focus lost, no confinement,
    no chord; the click that focuses the window is sent).
    **The title bar is the desktop's**, as on the Windows window: a press on it releases
    capture (SDL lets its keyboard grab go; the window keeps the keyboard), a click into the
    picture or gaining the keyboard again captures, and so does going to the whole screen,
    which has no title bar (so the title bar's full screen button does not leave macOS without
    Command). The title bar is libdecor's, and stock SDL drops a press on it; the lab's SDL
    sends `SDL_EVENT_WINDOW_HIT_TEST` for it (`patches/sdl3-src-3.4.18-title-bar-press.patch`),
    and `patches/window-title-bar-gives-the-desktop-its-shortcuts.dev.patch` acts on it.
    libdecor starts the compositor's window move at every press on its title bar, a plain
    click too, and mutter takes the keyboard away for it and gives it back at the button's
    release: a loss within 250 ms of the press, and the gain that ends it, are the press's own
    and capture nothing (`TITLE_MOVE_NS`; without it the window captured again at once and
    Super never reached GNOME). Checked in the rig with macOS, 2026-11-12: after a click or a
    drag on the title bar Super opens GNOME's overview; back from the overview, after a click
    in the picture, and on the whole screen, Super+Space opens Spotlight.
    In a rig test answer GNOME's "Allow inhibiting shortcuts" with a click on Allow first:
    Escape there is Deny, and the answer holds for that window until the VM is started again.
  - **Boot screen**: black until macOS draws. `mac26.sh` boots a quiet copy of reims' firmware
    (`OVMF_CODE.vmlab.fd` in the VM's folder, made from its `OVMF_CODE.fd` by
    `../win3d/firmware/make-firmware.py`, as the Windows VM's, and again when reims' file
    changes): no TianoCore logo, no "BdsDxe: loading Boot000x" line. reims' own file is not
    touched; the launcher points `run.sh` at the copy. `MAC26_FIRMWARE=stock` boots reims' file.
  - **Known limit**: windowed and moved between the 100% and the 125% screen, the window
    offers the new size (the log's "the display's mode is the window's pixels" line) and the
    guest senses the display again, but WindowServer sets its old mode (its log:
    `IOFBSetDisplayModeAndDepth: Setting mode 0x7 … 1920x1008`, with 1920×990 the one mode
    listed). Seen for 1008 → 990 at 100% → 125%; 990 → 1008, and both ways to 1080, are taken.
    The picture is then scaled by 2%. Ctrl+Alt+F twice fixes it. The cause is not established
    (a guess: the guest's kext still answers for the mode it is in, and WindowServer keeps a
    mode it can still set).
  - The title bar is libdecor's cairo plugin with `libdecor-vmlab/vmlab-titlebar.patch`: it
    matches the Windows window's GTK title bar (Yaru dark, the desktop's font, the same
    buttons).
- **A person at the screen**: `$M start --window` (also "macOS 26 Tahoe" in the app grid,
  `~/.local/share/applications/vmlab-macos26.desktop`, icon `icons/vmlab-macos26.svg`). The
  window opens maximized (asked for by the user, for both VMs, with a resolution that does not
  follow the window). **Dev lane: macOS takes the pixels of the window while it fills its screen**:
  1920×1056 maximized on the 1920×1080 monitor, and again, once, when it is maximized on a
  screen of another scale (expected 1920×1050 on the laptop's 125% panel; "Wayland window"
  below). `REIMS_VGPU_WINDOW_MODE=first`, a local switch: `Pin` in
  `reims-vgpu-dev/crates/reims-vgpu-window/src/env.rs` takes the window's measures
  (`Shell::measure` in `sdl/shell.rs`: pixels, the screen's scale, maximized or full screen)
  once they have been the same for 400 ms, one size per scale; `WindowScreen::mode` in
  `crates/reims-vgpu/src/graphics.rs` asks it at every refresh, and the device tells macOS
  when the answer changes. The guest's first scanout pins only if nothing is pinned yet.
  Maximized, the window's pixels are macOS's (checked: 0 of 2,000,640
  differ); resized, the window fits the whole picture into its size, scaled, between black
  bars (`graphics/sink.rs` then draws a presented surface with reims' present shaders, which
  sample it, where it used to copy and clip). Before this reims made every resize a new macOS
  resolution, which is what the user saw as resizing not working. `MAC26_WINDOW_SIZE=1920x1080`
  pins that size instead, scaled into the window (softer; the boot logo, drawn before
  WindowServer presents surfaces, is clipped, not scaled); `=follow` is reims' own behaviour.
  Without a window it is 1920×1080. The stable lane scaled a fixed 1920×1080 when its window
  switch was written (not checked again since). **Closing the window hides it at the click and shuts macOS down** (since 2026-11-12; `mac26.sh closed`,
  run by the window code through our switch `REIMS_VGPU_WINDOW_CLOSE_COMMAND`: `sudo shutdown -h
  now` over SSH, as `stop`). Where macOS cannot be reached (still starting, hung) or is still up
  after 30 s, the VM is powered off. `start` waits for a shutdown that is under way.
  `MAC26_CLOSE=poweroff` is reims' own behaviour, a power cut, with the window hidden at once
  too. Before this the window stayed on its last frame until QEMU's shutdown reached the
  display, about 5 s on the user's desktop, which read as a hang, and macOS came back with
  "You shut down your computer because of a problem". Measured in the rig: the window gone
  within 0.3 s of the click, the VM gone 8 to 10 s after it, 19 s from the click to SSH on a
  start given at once; a close 3 s into boot powers off after 6 s (SSH's 5 s timeout). Not
  checked: a close while macOS is up but refuses to shut down (the 30 s path). Maximized and the title "macOS
  26 Tahoe" come from two local switches in reims' window code, `REIMS_VGPU_WINDOW_MAXIMIZED=1`
  and `REIMS_VGPU_WINDOW_TITLE=…` (uncommitted in `reims-vgpu/` and `reims-vgpu-dev/`:
  `crates/reims-vgpu-window/src/{env.rs,handle.rs,native/linux/sdl.rs,sdl/shell.rs}`; a `reims
  update` or a fresh checkout loses them, and the window then opens at its default size with
  the title "Reims vGPU"). The icon needs only `SDL_APP_ID=vmlab-macos26` in the environment.
- **Wayland window (dev lane's default since 2026-11-11)**: reims' window is SDL 3, which on
  this desktop picks X11 by itself (mutter 46 has no `fifo-v1`), and an XWayland window on
  the 125% panel is drawn at 80% and stretched: the softness the user saw. `mac26.sh` sets
  `SDL_VIDEO_DRIVER=wayland`; SDL then draws at the screen's pixels. Three things make that
  safe here, all needed:
  - **Title bar from libdecor's cairo plugin** (`LIBDECOR_PLUGIN_DIR=reims/libdecor-cairo`,
    the file from Ubuntu's `libdecor-0-plugin-1-cairo`). The GTK plugin starts GTK on reims'
    window thread while QEMU's main thread runs the same GLib loop; GTK then loads
    `canberra-gtk-module` (named by the desktop's settings while event sounds are on) and
    QEMU segfaults in it within seconds. The cairo bar is plain, 24 units high, and has no
    room for menu buttons: the launcher's right-click menu in the dock has Shut Down macOS
    and Power Off Now instead (`Actions=` in `vmlab-macos26.desktop`; added 2026-11-11, not
    yet clicked by anyone).
  - **SDL without xdg-foreign export** (`reims/sdl3-src-3.4.18-vmlab`, a copy of the crate
    with `reims/patches/sdl3-src-3.4.18-no-xdg-foreign-export.patch` and
    `sdl3-src-3.4.18-title-bar-press.patch` ("Keyboard and pointer" above); `Cargo.toml` in
    `reims-vgpu-dev/` points at it with `[patch.crates-io]`). **SDL's export crashes mutter
    46.2, and on the real desktop that ends the user's whole session.** SDL exports every
    window (`zxdg_exporter_v2.export_toplevel`); when the client goes without destroying its
    objects (QEMU killed, or just exiting), mutter frees the surface first and
    `meta_wayland_xdg_exported_destroy` then disconnects a signal from the freed surface
    (`meta-wayland-xdg-foreign.c`; the "unmapped" handler that should have cleared the
    pointer is disconnected before the surface is finalized). Seen as the nested compositor
    ending with status 139 when the Mac stopped; every time with `MALLOC_PERTURB_=165`, some
    of the time without. With the patched SDL: no `export_toplevel` request in the trace, and
    the compositor lives through `kill -9` and a clean stop (wait 60 s: mutter saw the
    disconnect 25 s after the kill). `MAC26_SDL_XDG_EXPORT=1` turns the export back on:
    **nested rig only**. Not reported to mutter. The stable lane's SDL still exports, so it
    stays under XWayland.
  - the pin rule above (on Wayland the first scanout comes before the window has its size).
  Measured in the rig: 1920×1010 at 125%, 1920×1024 at 100%, 1920×996 at 150%, every screen
  pixel of the picture equal to macOS's own each time. On the real monitor: 1920×1056, 171
  presented frames in 6 s of Mission Control. **Not checked**: the real panel; pacing with
  the window hidden or on another workspace (no `fifo-v1`); `MAC26_WINDOW_X11=1` (XWayland,
  the fallback) since the pin rule changed. macOS has no 125%: on the panel it is sharp at
  1x, so its text is smaller than the desktop's (a HiDPI mode would fix that; not built).
  `MAC26_WAYLAND_DEBUG=1` puts the protocol trace in `logs/qemu.log`.
- **Guest settings made for a person** (in the `clean` snapshot since 2026-11-11): no startup
  chime (`sudo nvram StartupMute=%01`, kept in the VM's NVRAM) and the menu bar stays visible
  with a full-screen window (`defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen
  -bool true`).
- **CPUs and memory**: the guest's 6 CPUs run on the fast cores (`../pin.py`, `VCPUS` in
  `mac26.sh`). Guest RAM has transparent huge pages off, because with them reims ended the VM
  at about every second boot (`MAC26_HUGE_PAGES=on` tries them).
- **Disk**: the dev lane's system disk is `virtio-blk-pci` on its own I/O thread
  (`MAC26_DISK=virtio`, its default; `sata` keeps reims' emulated SATA disk, the stable lane's
  default). macOS has the driver; OpenCore's disk stays on SATA. Uncached 4 KiB random reads:
  29 µs each (34,000 a second; 81,000 with 4 threads) against 183 to 205 µs on SATA (5,000;
  15,000).
- **How fast apps open** (dev lane, 2026-11-11; `bench/guest-perf/launchtime.swift` times from
  launch to the first window):
  - an app opened before since boot: Calculator 0.7 s, TextEdit 0.5 s, Safari 0.9 s, Chrome
    0.7 s, VS Code 0.8 s, System Settings 1.05 s. This is one thread's work in the app, at
    close to host speed;
  - after `sudo purge` (nothing cached): 2.4 to 2.8 s on virtio, 3.0 to 3.7 s on SATA;
  - **the first launch after each boot of a large app that is not Apple's is slow, and that is
    macOS**: `syspolicyd` checks the whole bundle at about 85% of a CPU for 3.6 to 4 s before the
    app's process starts (VS Code: window after 5 to 6 s; Chrome 6 s; Safari 1.45 s). Turning
    Gatekeeper off (`spctl --global-disable` plus "Anywhere" in System Settings) does not skip
    it, `spctl --assess` does not warm it, and a real Mac does the same check;
  - tried without gain: huge pages for guest RAM (`MAC26_HUGE_PAGES=on`) and the SHA
    instructions for the guest CPU (`MAC26_CPU_EXTRA=+sha-ni`: visible in the guest, `sha256sum`
    stays at 430 MB/s).
  `bench/guest-perf/coldbench.sh` runs the set; `randread.py` is the disk test (after `sudo
  purge`). Build `launchtime` in the guest with `swiftc -O`; its first compile takes 85 s.
- **Diagnosis switches**: `MAC26_LOG=…` (reims' log filter), `MAC26_STATS=1` (a line of frame
  statistics a second), `MAC26_TRACE=FILE` (timeline of doorbells, interrupts, commits and
  presents). Frame pacing: `bench/guest-perf/frames2.mjs 20` in the guest counts late frames.
- **Recovery**: `$M start --picker`, then `$M gui key right ret`. Recovery has no SSH; copy a file
  out with `nc 10.0.2.2 PORT` to a listener on the host's 127.0.0.1.
- **Stable lane's boot image: keep the "stock" one.** reims' default image adds its ported arm64 GPU kexts, and
  with them macOS 26.7.1 panics here whenever WindowServer frees certain textures (twice at the
  same Setup Assistant screen: null lock in `AppleParavirtMemoryMap::removeResource`, called from
  `AppleParavirtResource::free`). `opencore.stock.qcow2` is made with `reims-util opencore
  --no-apv-arm64-port`, so Apple's x64 driver runs, patched by ReimsVgpu.kext. So:
  - never run `reims update-opencore mac26` (it brings the ported kexts back; that image is kept
    as `opencore.port.qcow2`);
  - there is no paravirtual video decoder or scaler in the guest (video decodes on the CPU).
  Upstream dropped the ported kexts on 2026-11-06 and replaced this GPU device on its
  `development` branch, which is the dev lane here. When upstream's `master` takes that work
  (it moves past 1fe0acb), the stable lane can be retired.
- **A shader reims cannot translate ends the VM** (both lanes). reims treats a Metal request it cannot carry
  out as fatal and aborts QEMU, so the guest just disappears. `$M status` then prints the reason
  (`reims-vgpu: fatal: …`, from `logs/qemu.log`). One such case is patched here (next section);
  for a new one, see "Finding the shader behind an abort" there.
- `METAL_ERROR_MODE=5` is set in the guest's global preferences, which reims requires on x64
  guests. A reinstall needs it again, from Recovery (reims README, "x86-64 macOS guests").
- reims' own CLI is `/vmlab/reims/bin/reims` (stable) or `/vmlab/reims-dev/bin/reims` (dev):
  wrappers that keep config, data and cache on the VM SSD. A VM's files are in
  `<prefix>/data/reims-ctl/vms/<name>`. `reims doctor` checks the host.
- **The dev lane's VM** was made with `reims create mac26d --disk …/mac26/disk.qcow2 --cpus 6
  --memory 8G --resolution 1920x1080 --gpu "NVIDIA GeForce RTX 4050 Laptop GPU" --ssh-port 2227`
  (the disk is a reflink copy of `mac26`'s clean disk, 2026-11-11). **Rebuilding it**:
  `reims/build-dev.sh` as a `systemd-run --user` unit (about 10 minutes): `scripts/install-ctl.sh`
  in `reims-vgpu-dev/` with the wrapper's environment and without `--yes` (with it the script
  stops at an optional `sudo` step for USB devices).
- **Local window changes** (both lanes): `reims/patches/window-maximized-and-title.{dev,stable}.patch`
  and, on top of it in the dev lane, `window-pinned-mode.dev.patch`,
  `sdl-no-xdg-foreign-export.dev.patch` (`Cargo.toml`; `Cargo.lock` follows at the build),
  `window-full-screen-clipboard-file-drop.dev.patch`,
  `window-keys-to-the-guest-pointer-free.dev.patch`,
  `window-title-bar-gives-the-desktop-its-shortcuts.dev.patch` and
  `window-close-hides-and-shuts-down.dev.patch`, are the uncommitted diff in each checkout
  (checked 2026-11-12 for all but the last: applied in that order to a7761508 they give the
  built sources; the last was made as the difference from that state). Apply them again after an update, then rebuild. A new SDL
  version needs a new copy of its crate with `sdl3-src-3.4.18-no-xdg-foreign-export.patch` and
  `sdl3-src-3.4.18-title-bar-press.patch`;
  the installed QEMU has the change if `strings` finds `VMLAB_SDL_XDG_EXPORT` in it. Tests:
  `cargo test -p reims-vgpu-window --lib env::` with `RUSTUP_HOME=/vmlab/reims/rustup
  CARGO_HOME=/vmlab/reims/cargo`.
- **Testing the windows** (both VMs): the desktop is Wayland, where no tool can measure or
  resize another program's window. `WIN_VENUS_WINDOW_X11=1` / `MAC26_WINDOW_X11=1` open the
  window under XWayland for one run: `xwininfo -root -tree | grep vmlab` gives its id and
  size, `python3 -I xmax.py ID off|on` restores or maximizes it, `xdotool windowsize ID W H`
  resizes it, and `xwd -silent -id ID -out F.xwd` captures the mac's window (QEMU's GTK window
  captures black). Compare with the guest's own picture (`win-venus.sh shot`, `mac26.sh gui
  shot`) to see whether the window scales.
- **Testing the windows on a scaled Wayland screen: `rig/nested.sh`** (its header has the
  commands). A nested GNOME compositor, the desktop's own mutter, with one 1920×1080 screen
  at a scale, in a window; `WAYLAND_DISPLAY=vmlab-test-0` before a VM's start command opens
  the VM in it. `nested.sh scale 1.25` is the window moving to such a screen, `nested.sh shot`
  the screen at its own pixels, and `python3 rig/cmp.py GUEST.png SCREEN.png` finds the
  guest's picture in it and counts equal pixels (100.00% = unscaled).
  - **The rig's helpers talk only to the nested compositor's bus** (`/vmlab/tmp/nested-bus`).
    The same `org.gnome.Mutter.DisplayConfig` call on the session bus changes the user's real
    screens (it happened once, 2026-11-11: the panel went off until the layout was put
    back). Never call DisplayConfig or ScreenCast on the session bus.
  - `NESTED_GDB=1 nested.sh start` runs the compositor under gdb with freed memory
    overwritten, which is how the xdg-foreign crash above was pinned down. Ubuntu's
    debuginfod has no symbols for this libmutter build; the 46.2 sources read for it are in
    `/vmlab/tmp/mutter-src`.
  - If the nested compositor is not running, QEMU's GTK window opens on the real desktop.

Measured 2026-11-11, Chrome 157 WebGL2 (`bench/`), frames per second, pixels identical to native:

| Test | Host Chrome (native Intel) | dev lane (`mac26d`) | stable lane (`mac26`) |
|---|---|---|---|
| `fill` (shader-bound), no limit | 120 | 625 | 600 |
| `draws` (3000 draw calls a frame), no limit | 1400 | 156 | 76 |
| `upload` (4 MB texture a frame), no limit | 1053 | 293 | 94 |
| Normal frame-rate limit | 60 / 60 / 60 | 60 / 60 / 60 | 60 / 47 / 60 |

Shading runs at the RTX's speed; what costs is each command's trip through the virtual device, so
pages with thousands of draw calls a frame are the slow case. The WebGL Aquarium (500 fish) holds
60 on both lanes.

### Local patch: empty inline assembly in shaders

Stable lane only (the dev lane's pinned metal2vulkan already has this fix). Its installed QEMU
(`/vmlab/reims/data/reims-ctl/qemu/current`, build `…-5e1ad946`) is built from local branches,
not upstream:

- `metal2vulkan/`, branch `vmlab`: upstream 219f013 plus one commit. Chromium's ANGLE Metal
  backend writes `__asm__("")` into loop bodies so Apple's compiler keeps the loop, which puts an
  empty `asm sideeffect` call in the shader's bitcode. Upstream refuses any inline assembly;
  the patch accepts the empty, argument-free kind and drops the call (it does nothing). Any
  other inline assembly is still refused.
- `reims-vgpu/`, branch `vmlab`: upstream 1fe0acb plus a `[patch]` in `Cargo.toml` that takes
  metal2vulkan from `../metal2vulkan`.

Without it, any Electron or Chrome build whose Skia uses the Ganesh renderer ends the VM the
first time it strokes a path: the Electron 38 bench app (Chromium 140) did. Chrome 157 and VS
Code (Chromium 150) never produced this shader. `reims/notes/angle-loop-empty-asm.ll` is it,
disassembled.

- **Rebuild** (about 10 min; run it as a `systemd-run --user` unit), with the environment
  `/vmlab/reims/bin/reims` sets: `cd reims-vgpu && XDG_DATA_HOME=/vmlab/reims/data
  XDG_CACHE_HOME=/vmlab/reims/cache RUSTUP_HOME=/vmlab/reims/rustup CARGO_HOME=/vmlab/reims/cargo
  CARGO_INSTALL_ROOT=/vmlab/reims scripts/install-ctl.sh --yes`. It installs a new dated
  directory beside the old one and moves `current`; the previous build stays as a fallback.
- **Tests** for the translator change: `cargo test -p metal2vulkan-air` in `metal2vulkan/`.
- **Going back to upstream**: `reims update stable` checks out upstream `master` and rebuilds,
  which drops the patch. Upstream fixed this the same way on metal2vulkan's `development`
  branch (1e44dcf8, 2026-11-03), which reims' `development` pins; neither `master` has it yet
  (checked 2026-11-11). So drop the patch once reims' `master` pins a metal2vulkan that contains
  that commit, and test with the bench app.
- **Finding the shader behind an abort**: run QEMU under gdb so the abort leaves a core (`gdb
  -batch -ex 'handle SIGUSR1 SIGUSR2 SIGPIPE SIGALRM nostop noprint pass' -ex run -ex 'bt 40'
  -ex 'gcore FILE' --args` plus the command in the VM's `run.sh`). Carve the `BC\xC0\xDE`
  modules out of the core, pad each to a multiple of 4 bytes, and read them with
  `llvm-bcanalyzer-18 --dump`. The fatal line's `Feature` names the record to look for. Write
  the core to `/vmlab/tmp`: it is as large as the guest's memory.

## `bench/`: the comparison benchmark

`node gpu-bench.mjs` starts Chrome, runs three WebGL2 workloads and prints one JSON line with the
GPU Chrome uses and the frame rates. `BENCH_TESTS=fill,draws,upload|none`, `BENCH_CAPPED=1`,
`BENCH_SECONDS=4`. It needs Node 22+ and a visible desktop session. The pixels it reports are the
same on every machine that renders correctly.
