# Windows (`win`) specifics

## Git Bash, the default shell

- Windows programs and Git's Unix tools are both on the Path (cargo, node, pnpm, git, winget, python). `C:\cache` is `/c/cache`; Windows programs also take `C:/cache`.
- **Path conversion:** Git Bash turns an argument that looks like a Unix path into a Windows one, and a Windows switch with it (`/S` arrives as `S:/`). Double the slash (`setup.exe //S`, `cmd //c dir`, `taskkill //F //IM app.exe`) or put `MSYS_NO_PATHCONV=1` before the command.
- **An installer:** `./setup.exe //S; echo $?` waits for it and gives its exit code.
- `Path` is read from the registry for each session, so a tool installed in one call is found in the next. Other variables set since logon appear only after a Windows restart.

## PowerShell: `ssh win-pwsh`

The same desktop session in PowerShell 7, a script on stdin too (about 0.4 s a call). Use it for cmdlets and the lab's helpers (`C:\vmlab\*.ps1`).

- A failed program does not end a PowerShell script: test `$LASTEXITCODE` between steps. A script's exit code is its `exit N`, a program's own code, or 1 after a failed cmdlet.
- **Windows PowerShell 5.1** needs a clean module path: `Remove-Item Env:PSModulePath; powershell …`, or core cmdlets such as `Get-FileHash` are missing.

## Node, pnpm, Electron

- `node` is 26. For another version: `fnm install 24` once (kept on `C:\cache`), then `fnm use 24` at the start of each command. Nothing switches at `cd`.
- `pnpm` switches to the project's `packageManager` version by itself. Downloads of Electron, electron-builder, npm and pnpm are cached on `C:\cache`.
- **Electron's postinstall under Node 26** can stop early, leaving `node_modules/electron/dist` with only `locales/`. Extract the cached zip from `C:\cache\electron` with `tar -xf` into `dist`, then write `electron.exe` to `path.txt`.

## PostgreSQL 16

Installed as on a customer's PC: service `postgresql-x64-16`, port 5432, user `postgres`, password `postgres`, tools in `C:\Program Files\PostgreSQL\16\bin` (not on the Path). Its data is on the system disk, so `vm reset` empties it.

## Defender, SmartScreen, Windows Update

`win` is set up for testing, not like a customer's PC.

- **Defender antivirus is off.** For a test that depends on it (an installer, a first launch, a flagged binary), start with it on, from any state: `vm start win [state] --defender`. `vm start` returns once its definitions are up to date (downloaded once a week into the build cache), with real-time protection on. It stays on for that run (Windows does not let it be turned off from inside); `vm reset win --discard` or another state ends it. Saving such a run: [states.md](states.md).
- **SmartScreen is on** in every state, but its "Windows protected your PC" box appears only for a file with the Mark-of-the-Web started through Explorer. A file built in the VM or copied in starts without it. To see what a download does, mark it first: `ssh win-pwsh "Set-Content -Path app.exe -Stream Zone.Identifier -Value '[ZoneTransfer]','ZoneId=3'"`, then `ssh win 'explorer.exe app.exe'`.
- **Windows Update is off,** so `Add-WindowsCapability` and the Store fail: use winget or GitHub MSIs. When a result depends on Windows Update, say in your report that the VM could not show it.

## Browsers

Chrome is the default browser, pinned at one version (updater off; policies turn off sign-in, sync and the password manager). Edge is still installed, unpinned and not updated; WebView2 is intact. Open web pages with Chrome.

## Graphics

Direct3D 9 to 11, OpenGL and Vulkan run on the GPU, so WebGL works, and screen capture with Desktop Duplication works (ffmpeg: `-f gdigrab -i desktop`; `ddagrab` fails). Direct3D 12 for native programs goes through a bridge to Vulkan, and Chromium gets no WebGPU adapter: see [troubleshooting.md](troubleshooting.md).
