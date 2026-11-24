# Driving a VM's GUI

The `vmlab` MCP tools are Cua Driver's computer-use tools for both VMs in one list, routed by the `machine` argument. Each agent session keeps its own connection per VM, so element tokens and Cua sessions last between calls until the VM reboots. While the VM is off, calls return `<name> is not running`. The first call after `vm start` can wait up to 90 s for the desktop. Cua's session, recording and admin tools are left out of the list; `VMLAB_MCP_EXTRA_TOOLS=recording` (a group, a tool's name, or `all`) in the MCP server's environment brings them back.

## Looking at the screen: `screenshot`

`screenshot` (machine `win` or `mac`) takes the screen on the host, from QEMU: 15–50 ms however busy the guest is, against hundreds of milliseconds to seconds for Cua's `get_desktop_state` or a `get_window_state` screenshot, and it works on a locked desktop, a UAC prompt or a hung guest. Use it to look; read a window with `get_window_state` and `include_screenshot: false`, and act on its element tokens.

- `region: {x, y, width, height}` gives a part at full size (small text, a tray icon); `max_dimension: 800` a cheap whole-screen look.
- Its pixels are screen pixels: click a point with scope `"desktop"` at the x,y the result's text gives (it says how to undo a `region` or `max_dimension`).

## Steps that need a specific way

Found in the trials of 2026-11-14; each of these fails quietly the other way.

- **Typing into an Electron window:** pass `delivery_mode: "foreground"`. In the background `win` refuses the keys and `mac` drops them while reporting "sent, unverified".
- **A text field:** click it in the foreground first, then `type_text` in a second call. A `type_text` with `x, y`, which clicks and types at once, lost every key on `mac` while reporting them sent.
  - On `mac`, click a text field by `x, y`, not by `element_token`: the token path asks the field for a press action it does not have (`AXPress returned -25206`).
- **Read a field back** after typing into it. A tool's success is not proof.
- **The first `get_window_state` of an Electron window** may show only the frame and the menu: read it again after the first click.
- **A checkbox's ticked state** is not in the accessibility tree: check the screenshot or the app's own output.
- **A `<select>`:** on `win`, focus it and press the option's first letter (`press_key`, foreground); on `mac`, `set_value` on the select.
- **A save dialog:** choose the folder first, then give only the file name: on `mac` a path in the name field (`/Users/dev/x/a.txt`) saves a file named `Users:dev:x:a.txt` where the dialog already is. Set the file name with `set_value` on the field (`type_text` on `win` appends to the selected name while reporting that it replaced it). The folder: `set_value` on Where on `mac`; on `win`, click it in the sidebar in the foreground.
- **Closing a window:** a background click on Close can leave it open, and a foreground one can return `foreground_unavailable` after it closed. Check over `ssh` that the process is gone.

## A browser tab: the `browser_*` tools

- **`get_browser_state`** leaves the screenshot out unless asked. Keep it out to check or poll a page: 4 ms on `win` against 73 with `include_screenshot: true`, 13 against 47 on `mac`.
- **`browser_click`:** keep its default `input_route: "trusted"`. On `win` it takes 40–60 ms and `"dom_event"` 440; on `mac` both take about 33.

## The page inside an Electron app: Playwright

A second way, for checks of the page alone: start the app in the VM with `--remote-debugging-port=9222`, run `vm tunnel win 9222 9333`, and connect Playwright or playwright-mcp to `http://localhost:9333` (the user's Chrome often holds 9222 here). Run Playwright `_electron` tests inside the VM. The MCP tools stay the way for what is outside the page: the installer, native dialogs, the tray.

## Pixels and real input: `vm gui`

`vm gui` knows nothing of what is on the screen; it works in pixels.

- **The screen as a file:** `vm gui <name> shot <file.png>` (`--crop X,Y,W,H`, `--max-dim N`) for a shot to keep or compare; to look, the MCP tool `screenshot` is the same picture. Give each shot a new file name: a chat that shows a read image by its path shows every earlier read of a reused file as its latest picture. Look before debugging a GUI test from logs: a crash dialog, a prompt or the wrong window in front shows at once.
  - **Part of it:** `shot <file.png> --crop X,Y,W,H` saves only that region; `--max-dim N` shrinks the picture so neither side is over N pixels. Then the printed line gives the crop and the scale: the screen's x is X + x / scale. No PIL script of your own is needed.
- **Input that must be a person's:** `vm gui <name> click X Y [right|double]`, `move X Y`, `drag X1 Y1 X2 Y2`, `type 'text'`, `key ctrl+s` use the VM's own keyboard and pointer at pixels of the screen (not of a cropped or shrunk shot). Use them to test a keyboard hook, a hotkey or a text expander: keys sent from inside Windows (Cua, SendKeys, SendInput) carry Windows' "injected" mark, and real ones never do.
  - **Key names:** QEMU's (`ret`, `esc`, `spc`, `tab`, `backspace`, `delete`, `up`, `pgdn`, `f4`, `meta_l`) and the common ones (`enter`, `escape`, `space`, `del`, `bs`, `pageup`, `cmd`, `win`, `option`, `alt`, `ctrl`, `shift`), in chords such as `ctrl+shift+escape` or `cmd+,`. `delete` is forward delete; the Mac's delete key is `backspace`. A wrong name stops the command before any key is sent.
  - **`type` sends ASCII only.** For other text (é, —, emoji), put it on the clipboard with the MCP tool `clipboard_write`, then `vm gui win key ctrl+v` or `vm gui mac key cmd+v`.
- **Several steps in one run:** `vm gui win batch "click 100 200" "sleep 0.3" "key ctrl+a" "type 'hello'" "shot out.png"` runs them in one process on one connection, with no start-up or reconnect between steps. Each step is split like a shell line, so quote inside it. All steps are checked before the first runs. Nothing waits between steps: add a `sleep` where the app needs time, for example before a `shot`.
- **Bring a window to the front first:** `ssh win-pwsh 'C:\vmlab\focus.ps1 notepad'` (part of the title, a process name or a pid; exit code 1 if that window is not in front). A script's own `SetForegroundWindow` fails most of the time, and the keys go to whatever was in front.

## Windows specifics

- **A tray icon:** Windows 11 hides a new icon under the "Show Hidden Icons" arrow. Once the app has shown it, `ssh win-pwsh 'C:\vmlab\tray.ps1 <part of its program name>'` puts it beside the clock.
- **Display scaling:** `/vmlab/tools/vmlab/gpu/win3d/win-venus.sh scale 125` (or 150, 100) sets it at once. It holds until the user shows or hides the window, which sets the screen's scaling (shown) or 100% (hidden).
- `win` shows a "Test Mode" watermark: its GPU driver is test-signed.

## The VM window, when the user wants one

Every run has a window, hidden unless asked, and a tray icon on the user's desktop (show or hide it, restart, shut down). `vm start <name> --window` or `vm view <name>` shows it maximized and unscaled: the guest takes the window's pixels, and on `win` the screen's scaling. `vm hide <name>` hides it again; the guest goes back to 1920×1080 at 100% and keeps running. While it is the active window every key goes to the guest, the desktop's shortcuts too. Copied text and pictures paste across, and files dropped on it land on the guest's desktop. Closing it shuts the guest down cleanly (the VM about 10 s after the window).
