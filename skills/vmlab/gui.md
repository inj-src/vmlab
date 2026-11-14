# Driving a VM's GUI

The `vmlab` MCP tools are Cua Driver's computer-use tools for both VMs in one list, routed by the `machine` argument. Each agent session keeps its own connection per VM, so element tokens and Cua sessions last between calls until the VM reboots. While the VM is off, calls return `<name> is not running`. The first call after `vm start` can wait up to 90 s for the desktop.

## Steps that need a specific way

Found in the trials of 2026-11-14; each of these fails quietly the other way.

- **Typing into an Electron window:** pass `delivery_mode: "foreground"`. In the background `win` refuses the keys and `mac` drops them while reporting "sent, unverified".
- **A text field:** click it in the foreground first, then `type_text` in a second call. A `type_text` with `x, y`, which clicks and types at once, lost every key on `mac` while reporting them sent.
  - On `mac`, click a text field by `x, y`, not by `element_token`: the token path asks the field for a press action it does not have (`AXPress returned -25206`).
- **Read a field back** after typing into it. A tool's success is not proof.
- **The first `get_window_state` of an Electron window** may show only the frame and the menu: read it again after the first click.
- **A checkbox's ticked state** is not in the accessibility tree: check the screenshot or the app's own output.
- **A `<select>`:** on `win`, focus it and press the option's first letter (`press_key`, foreground); on `mac`, `set_value` on the select.
- **A save dialog:** set the file name with `set_value` on the field (`type_text` on `win` appends to the selected name while reporting that it replaced it). The folder: `set_value` on Where on `mac`; on `win`, click it in the sidebar in the foreground.
- **Closing a window:** a background click on Close can leave it open, and a foreground one can return `foreground_unavailable` after it closed. Check over `ssh` that the process is gone.

## The page inside an Electron app: Playwright

A second way, for checks of the page alone: start the app in the VM with `--remote-debugging-port=9222`, run `vm tunnel win 9222 9333`, and connect Playwright or playwright-mcp to `http://localhost:9333` (the user's Chrome often holds 9222 here). Run Playwright `_electron` tests inside the VM. The MCP tools stay the way for what is outside the page: the installer, native dialogs, the tray.

## Pixels and real input: `vm gui`

`vm gui` knows nothing of what is on the screen; it works in pixels.

- **The screen as it is:** `vm gui <name> shot <file.png>` shows a crash dialog, a prompt or the wrong window in front. Look at it before debugging a GUI test from logs.
- **Input that must be a person's:** `vm gui <name> click X Y [right|double]`, `type 'text'`, `key ctrl+s` (also `win`, `alt`, `shift`, `ret`, `esc`, `tab`, `f4`) use the VM's own keyboard and pointer at pixels of the screenshot. Use them to test a keyboard hook, a hotkey or a text expander: keys sent from inside Windows (Cua, SendKeys, SendInput) carry Windows' "injected" mark, and real ones never do.
- **Bring a window to the front first:** `ssh win-pwsh 'C:\vmlab\focus.ps1 notepad'` (part of the title, a process name or a pid; exit code 1 if that window is not in front). A script's own `SetForegroundWindow` fails most of the time, and the keys go to whatever was in front.

## Windows specifics

- **A tray icon:** Windows 11 hides a new icon under the "Show Hidden Icons" arrow. Once the app has shown it, `ssh win-pwsh 'C:\vmlab\tray.ps1 <part of its program name>'` puts it beside the clock.
- **Display scaling:** `/vmlab/tools/vmlab/gpu/win3d/win-venus.sh scale 125` (or 150, 100) sets it at once.
- `win` shows a "Test Mode" watermark: its GPU driver is test-signed.

## The VM window, when the user wants one

`vm start <name> --window` or `vm view <name>` opens it maximized and unscaled. While it is the active window every key goes to the guest, the desktop's shortcuts too. Copied text and pictures paste across, and files dropped on it land on the guest's desktop. Closing it shuts the guest down cleanly (the VM about 10 s after the window).
