# When something fails or is missing

**Look at the screen first:** `vm gui <name> shot /tmp/now.png`, then read the picture. A crash dialog, a permission prompt or the wrong window in front explains most GUI failures that logs don't. Then check the list below.

## Known gotchas

- **Time or TLS errors:** VM clocks drift after the laptop sleeps. `vm start <name>` on a running VM resyncs it.
- **Electron dies with EPIPE** when its output pipe's reader is gone, and over `ssh` the output is such a pipe. Start Electron with its output in a file: `nohup <electron> . > /tmp/app.log 2>&1 &`.
- **Electron's postinstall under Node 26** can leave `node_modules/electron/dist` nearly empty: the fix per OS is in [windows.md](windows.md) and [mac.md](mac.md).
- **A kill that kills itself:** `pkill -f <pattern>` (or PowerShell filtering on `CommandLine`) also matches the shell running it. Anchor the pattern (`^ssh .*`) or match the process name.
- **A forward that is taken:** Windows' sshd accepts a second forward of a port in use and says nothing; `vm forward` checks this machine's forwards first, so trust its error.
- **GPU:** apps at the normal 60 Hz frame limit run fine. Uncapped rendering on `win` (`--disable-gpu-vsync --disable-frame-rate-limit`) fills the card's 6 GB in about 10 s and Chrome loses its WebGL context: keep such runs to a few seconds.
- **`ssh -t` on `win`** exits 0 and loses the output: leave it out.

## When a VM lacks something

The user's word (2026-11-12): when the work needs something the VMs don't have, work around it yourself. Tell the user every time: what was missing, what you changed, and whether the change is still in place. A change made in a running VM lasts until `vm reset`; ask the user before `vm commit`, before anything that needs root on this machine and before posting anything upstream.

Known cases on `win`:

- **Direct3D 12** comes from a bridge to Vulkan (vkd3d-proton) as `System32\d3d12.dll`. Native programs get a device and a queue, but the lab has drawn nothing through it: check your app's picture and say what you saw. `win-venus.sh d3d12 native` takes the bridge out (no Direct3D 12 at all), `d3d12 bridge` puts it back; restart Windows after either.
- **Chromium** (Chrome, Edge, Electron, WebView2) gets Microsoft's `d3d12.dll` instead, so WebGL works, but WebGPU gets no GPU adapter (SwiftShader on the CPU with `--enable-unsafe-webgpu`) and no hardware video encoder is offered.

The lab's sources, for a deeper fix: [/vmlab/tools/vmlab/docs/lab.md](/vmlab/tools/vmlab/docs/lab.md), "Sources".

## Checking the lab itself

Bench Form, an Electron 38 app, is installed in both VMs for checking that the lab works:

- `win`: `ssh win-pwsh 'C:\vmlab\bench-app\start.ps1'`
- `mac`: `ssh mac 'open -n ~/vmlab/bench-app/node_modules/electron/dist/Electron.app --env BENCH_DIR=$HOME/bench --args ~/vmlab/bench-app'`
