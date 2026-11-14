# macOS (`mac`) specifics

- **Shell:** `ssh mac` lands in a zsh login shell in `dev`'s desktop session; `sudo` asks no password. Node 26 is in `/usr/local/bin`.
- **Apps:** `open -a <App>` starts one on the desktop (`open -n <path>.app --args …` for a second instance or arguments); `pkill -x <App>` stops it.
- **No `osascript` AppleEvents** (`tell app …`, `quit app …`): each puts an Automation privacy prompt on the desktop that blocks GUI work until someone answers it. Use `open` and `pkill`.
- **Packages:** Homebrew refuses Intel Macs. Install from vendor builds (nodejs.org tarballs, `uv`, app zips). Some Python packages ship no Intel-mac wheels any more (`cryptography` 49 and later) and fail to build: pin an older version; `--no-build` finds such packages fast.
- **Electron's postinstall under Node 26** can stop early. Extract `~/Library/Caches/electron/*/electron-v*-darwin-x64.zip` with `ditto -xk` (it keeps the framework's symlinks) into `node_modules/electron/dist`, then write `Electron.app/Contents/MacOS/Electron` to `path.txt`.
- **Spotlight stays on:** GUI agents open apps with Cmd+Space.
- Chrome is the default browser, pinned at one version (configuration profile `local.vmlab.chrome`).

## Privacy permissions

- SSH sessions have Accessibility, Screen Recording and full disk access, so `screencapture`, accessibility calls and `~/Desktop`, `~/Documents`, `~/share` work over `ssh`.
- **A new GUI tool** that needs a permission asks once in System Settings. Approve it with `vm gui mac` (screenshot, then clicks and typing; a password field takes only the real keyboard; the password is `vmlab`), and tell the user.
- Reinstalling or updating Cua Driver can drop its grants: `cua-driver permissions status` checks them.
