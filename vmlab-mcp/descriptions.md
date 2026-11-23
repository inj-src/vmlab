# Tool descriptions served by vmlab-mcp

vmlab-mcp serves Cua Driver's tools for both VMs as one list. Cua writes a description per OS,
and the server used to serve both, one after the other. The text below replaces them with one
description per tool, written for the lab's agents, with the differences between the two OSes
marked where they matter.

How the server reads this file (built into the binary; `cargo build` after editing):

- `## name fp=<16 hex>` starts a tool. Its text, up to the first `### `, is the tool's
  description; an empty text keeps the merged Cua description. `### param` gives a parameter's
  description (its type, enum and limits stay Cua's); an empty text keeps Cua's. The server
  adds the marks "(win only)", "(mac only)" and "(required on win)" itself. `### a.b` is
  property `b` of object parameter `a` (one level down). The text `(remove)` leaves the
  parameter out of the schema: only for one Cua ignores.
- `fp` is the fingerprint of Cua's definitions of the tool on both VMs (description and input
  schema). When Cua changes the tool, the fingerprint no longer matches, and the server serves
  Cua's own text for that tool and logs a warning: a description that is long but true beats
  one that is short and stale. `vmlab-mcp --fingerprints` prints the current fingerprints, and
  `cargo test` fails while one here is stale; read Cua's new text before updating it.
- `## (every tool)` gives parameter texts used by every tool listed here that has that
  parameter, unless the tool gives its own. A tool listed with an empty body gets only these.
  The browser tools give their own `session` and `delivery_mode`, which mean something else
  there. Tools not listed (the opt-in session tools) keep Cua's texts.
- Lines before the first `## ` (this preamble) are ignored.

Sources for how these are written: Anthropic's tool-definition guidance ("what the tool does,
when to use it, what each parameter means, caveats"; 3–4 sentences or more), and the lab's own
trials of 2026-11-14 for the keyboard and focus rules (`skills/vmlab/gui.md`).

## (every tool)

### session
Optional Cua session label: the same one on every call of a task, or none.

### element_token
Element handle `<snapshot_id>:<N>` for row `[N]` of a get_window_state read (for example "s0000002a:11"). It goes stale once a newer read of the same window replaces that snapshot; the error then names the current one.

### post_action_wait
"default" waits up to 300 ms to report a new window, menu, dialog or focus change caused by the action; "none" returns at once and reports such a change on the next action.

### delivery_mode
"background" (default) acts without raising the window; "foreground" raises it for the action and then restores the front window: use it after a `background_unavailable` answer, and for keys into Electron.

### target
Where x,y belong: {"kind": "window", "pid", "window_id"} or {"kind": "desktop", "display_id": "primary"}. pid and window_id (or scope "desktop") say the same, shorter.

### target.kind
"window" or "desktop".

### target.display_id
"primary" (kind "desktop").

### target.pid
Kind "window".

### target.window_id
Kind "window".

### target_id
From get_browser_state's bind.

### tab_id
From get_browser_state's bind.

### ref
A `p<snapshot>:<index>` ref from the tab's latest get_browser_state; navigation or a newer snapshot stales it.

### scope
"window" (default): x,y are pixels of the get_window_state screenshot of pid/window_id. "desktop": no pid or window_id, and x,y are pixels of the get_desktop_state screenshot.

### from_zoom
True when x,y are pixels of the last zoom image of this pid; the driver maps them back to the window.

### modifier
Modifier keys held during the action: cmd, shift, option (alt), ctrl.

## list_apps fp=9656197b1ac4945b
Lists the VM's apps, both running and installed, with per-app flags: `running` (pid is 0 when false), `active` (the frontmost app), `kind`, `launch_path` and `last_used`. Use it to answer "is X installed?" or "is X running?". For window-level state (titles, on-screen, minimized) and the pid and window_id other tools need, call list_windows; to open an app, call launch_app directly, without listing first.

On Windows, `kind` is "desktop" (an .exe from a Start-menu shortcut) or "uwp" (a packaged app, launch_path `shell:appsFolder\<PackageFamilyName>!<AppId>`). On macOS, launch_path is the .app bundle's path, and apps come from /Applications, ~/Applications and /System/Applications; menu-bar apps report their pid too.

## list_windows fp=befca03f3335b433
Lists top-level windows, each with its app: window_id, pid, app_name, title, bounds, z_index, is_on_screen and minimized. Use it to find the pid and window_id that get_window_state and the input tools need, and to check whether an app has a window. Always filter with `app` or `pid`: an unfiltered call lists every window on the VM. For the frontmost window take the highest integer z_index; null means the stacking order is unknown, so don't infer it from the array order.

On macOS the list includes minimized, hidden and other-Space windows (with space_ids and on_current_space); with `pid` it includes every layer, not just layer 0.

### pid
Only this process's windows.

### on_screen_only
Drop windows that are not on screen (on macOS: not on the current Space). Default false.

## get_window_state fp=2f5df705f9f898b6
Reads one window: its accessibility tree and a screenshot. Call it before any element action on a window, and again after each action that changes the window. Each actionable row is tagged `[N]`; its element_token is `<snapshot_id>:N`, with snapshot_id in the response header. A new read of the same window replaces the previous snapshot and stales its tokens.

- Size: a read stops at 250 elements by default (`truncated: true` and a "Tree truncated" line say so). Narrow with `query` (case-insensitive substring: matching rows plus their ancestors, indices kept) or `max_depth`, or raise `max_elements`.
- Re-reads: pass `since: "latest"` (or an earlier snapshot_id) to get only the changes: `+` added, `~` changed, `-` removed rows. The response has a new snapshot_id; use it in tokens.
- Cross-check the tree against the screenshot: it can be wrong or incomplete (Electron, custom-drawn and virtualized surfaces). Use pixel x,y from the screenshot only for elements missing from the tree.
- `include_accessibility_tree: false` returns just the screenshot and keeps the current tokens valid; `include_screenshot: false` returns just the tree.
- `window_id` must belong to `pid`, or the call fails (macOS names the real owner_pid; a sandboxed Open/Save panel belongs to a panel service). On macOS an empty tree with `degraded_reason` `ax_app_launching` or `ax_window_unresolved` means read again, or act in the foreground; `screen_locked` means the screen is locked or asleep.

### since
On a re-read after acting: "latest" (or an earlier snapshot_id of this window) returns only the changes, rows `+` added, `~` changed, `-` removed, or "no change". It falls back to a full read when that snapshot is gone or was read with another query, max_elements or max_depth (`since_status` says so). The response has a new snapshot_id; unlisted rows keep their [N].

### timeout_ms
Time limit for the tree walk in milliseconds (default 1000). When it runs out the partial tree comes back with `truncated: true`; retry with more (e.g. 5000) or narrow with query or max_depth.

### capture_mode
(remove)

### pid
Process ID of the window's app (from list_windows or launch_app).

### window_id
The window to read (from list_windows or launch_app); it must belong to pid.

### tree_format
"markdown" (default): the compact tree, rows `[N]`. "elements": a structured array (element_token, role, label, value, actions, frame per row). "both": both, about twice the size.

### max_elements
Most elements to walk (default 250; 5,000 on Windows and 2,000 on macOS with full_output). The response says when the tree was cut.

### max_depth
Deepest level of the tree to walk (default 25). Lower it for deep menu or Electron trees.

### query
Case-insensitive substring: returns matching rows plus their ancestors, keeping their indices. Try it before a full read of a large window.

### include_accessibility_tree
Default true. False skips the tree and returns only the screenshot and window metadata, keeping the current snapshot's tokens valid. Not together with include_screenshot false.

### include_screenshot
Default true. False returns the tree only, which is cheaper when you only need fresh tokens.

### max_dimension
Older cap on the screenshot's long edge in pixels; the tighter of this and the configured limit wins.

### max_image_dimension
Long-edge limit for this call's screenshot in pixels; 0 returns full resolution. Omit for the configured default.

### screenshot_out_file
Write the screenshot to this path in the VM instead of returning it inline; the result gives screenshot_file_path.

## launch_app fp=537269be8b274c72
Opens an app without bringing it to the front, and returns its pid, name and a `windows` array (the list_windows shape), so the next call can be get_window_state. Name the app with `name` (its display name, e.g. "Calculator") or `bundle_id`. If `windows` comes back empty, the window has not appeared yet: call list_windows with the pid a moment later.

On Windows, Notepad, Calculator, Paint and the other built-in apps are packaged (Store) apps: launch them by `name` or `aumid`, never by the .exe in System32, which is a stub that exits at once. Precedence there is launch_path, path, aumid, bundle_id, name, and `urls` open in the default browser. On macOS, `bundle_id` (e.g. com.apple.calculator) wins over `name`, and `urls` are opened by the app itself (a folder path opens a Finder window there). For a browser that agents drive through DevTools, use browser_prepare.

### name
The app's display name, e.g. "Calculator". On macOS it may also be the absolute path of a .app bundle (list_apps' launch_path).

### bundle_id
Windows: a packaged app's AUMID, `<PackageFamilyName>!<AppId>` (e.g. `Microsoft.WindowsNotepad_8wekyb3d8bbwe!App`); without a `!` it is treated as a name. macOS: the bundle identifier, e.g. com.apple.calculator; preferred over name.

### aumid
A packaged app's AUMID; wins over bundle_id and name. It returns the real pid of the packaged process.

### path
Full path of an executable to run; wins over name, bundle_id and aumid.

### launch_path
The launch_path value from list_apps, run unchanged; wins over everything else.

### urls
Windows: URLs to open in the default browser. macOS: files, folders or URLs for the app to open.

### additional_arguments
Extra command-line arguments for the app (on macOS, passed after --args).

### start_minimized
Launch minimized to the taskbar. Accessibility reads and background input still work; screenshots and foreground delivery need the window restored.

### creates_new_application_instance
(mac only; ignored on Windows) Start a new instance even when one is running (open -n), so each session gets its own window of a single-instance app.

### webkit_inspector_port
(mac only; ignored on Windows) Open a WebKit inspector server on this port, for Tauri and other WebKit apps.

## kill_app fp=d693dee70475f978
Force-terminates a process by pid: taskkill /F on Windows, kill -9 on macOS. Unsaved work is lost. Close politely first (the window's close button on Windows, cmd+q on macOS), and kill only when the process stays. On Windows, packaged apps (Calculator, Photos, Notepad) often stay resident after their window closes, which is the usual reason to kill.

### pid
The process to terminate.

## bring_to_front fp=b105955d77c0e3e0
Brings an app's window to the front and leaves it there; the previous front window is not restored. Ordinary input never needs it: when a tool answers `background_unavailable`, retry that call with delivery_mode "foreground", which raises the window, acts and restores the front window by itself. Use bring_to_front only for a surface that must stay in front across several calls, such as a remote-desktop window. Windows returns previous_fg_hwnd and now_fg_hwnd; on macOS with window_id, success means that exact window became the focused front window, and a "partial" result means the request was only accepted.

### pid
The process whose window to raise.

### window_id
The window to raise. If omitted, Windows takes pid's first visible window and macOS activates the app without checking a window.

## click fp=7cfd099af320fc4f
Clicks an element or a point in a window. Prefer `element_token` from get_window_state: it acts through the accessibility API, works on background, minimized and hidden windows, and moves neither the pointer nor the focus. Use `x`,`y` (pixels of the get_window_state screenshot) only for what the tree lacks, such as a canvas, video or custom-drawn control; a pixel click needs the window on screen. Give exactly one of element_token or x and y.

- `button` is left (default), right or middle; `count` 2 or 3 makes a double or triple click (on macOS, pixel clicks only).
- `action` picks the accessibility action for an element_token (see its parameter).
- A popup button opens its menu and leaves it open. To choose an option in one call use set_value; on macOS a background click on a web `<select>` (Chrome, Electron) is refused with `select_menu_would_raise_window` for that reason.
- On Windows a background pixel click first tries the accessibility element under the point, so pixel clicks on Store and WinUI apps work without raising the window.
- For several actions in a row, run_steps sends them in one call.

### action
Accessibility action for an element_token. Windows: "expand" opens a dropdown or the arrow half of a split button; omit it to invoke. macOS: press (default), show_menu, pick, confirm, cancel, open, show_alternate_ui (reveals hover-only controls without the pointer), show_default_ui.

### button
Mouse button, default left. On macOS with an element_token, right opens the element's menu and middle clicks its center.

### capture_id
The id of the get_window_state or get_desktop_state capture that x,y were read from. A stale or mismatched capture is refused, rather than clicking whatever is there now. Used once.

### count
1 (default), 2 for a double click, 3 for a triple click. On macOS, pixel clicks only.

### pid
Process ID of the window's app. Optional with element_token (the token carries it); omit it with scope "desktop".

### window_id
The window x,y were measured in. Omit it with element_token.

### x
X in pixels of the get_window_state screenshot, from its top-left corner; with scope "desktop", of the get_desktop_state screenshot. Give y too.

### y
Y in pixels of the same screenshot as x.

### debug_image_out
Write a screenshot with a crosshair at x,y to this path in the VM. Needs window_id; not with from_zoom.

## double_click fp=9a8baa54ffc7ddfc
Double-clicks an element or a point: to open a file, a folder or a list row. With an element_token, macOS performs the element's open action when it has one (Finder items, list rows) and otherwise double-clicks its center; Windows double-clicks the element's center. With x,y it sends two clicks at that point. Give exactly one of element_token or x and y; pid is needed with x,y.

### window_id
The window x,y were measured in. Omit it with element_token.

### from_zoom
x,y are pixels of the last zoom image of this pid.

### modifier
Accepted but ignored: background clicks on Windows carry no modifier keys.

## right_click fp=2a69bf8e168a8323
Right-clicks an element or a point, usually to open a context menu; read the window again afterwards to find the menu's items. On macOS an element_token shows the element's menu through the accessibility API, in the background and without moving the pointer; on Windows it right-clicks the element's center. Give exactly one of element_token or x and y (pixels of the get_window_state screenshot); pid is needed with x,y.

### window_id
The window x,y were measured in. Omit it with element_token.

### from_zoom
x,y are pixels of the last zoom image of this pid.

### modifier
Keys held during the right-click: cmd, shift, option, ctrl. macOS only, and only with x,y; Windows ignores it.

## drag fp=21966061bf300528
Presses, moves and releases the mouse from (from_x, from_y) to (to_x, to_y), in pixels of the get_window_state screenshot. Use it for drag and drop, marquee selection, sliders, resize handles and moving panels. `duration_ms` (default 500) and `steps` (default 20 intermediate moves) set the pace: raise both for a slower drag. The result is not verified: check the screenshot or tree, and retry with delivery_mode "foreground" only if nothing changed. `get_guide({topic: "drag"})` has the limits.

In the background some drags cannot work and answer `background_unavailable`; use "foreground" for them:
- Windows: dragging a title bar or a resize border (moving or resizing the window itself), and any drag with `modifier` keys held.
- macOS: a drag that starts a system drag-and-drop session (moving a file, reordering a list, HTML5 draggable content), except inside Electron apps, where the driver delivers it. For a browser tab bound with get_browser_state, browser_pointer with action "drag" is the better way.

### from_x
Start X, in pixels of the window's screenshot from its top-left corner.

### from_y
Start Y, in pixels of the window's screenshot.

### button
Mouse button held during the drag. Default left.

### duration_ms
Time from press to release in milliseconds, 0–10000. Default 500.

### steps
Intermediate pointer moves along the path, 1–200. Default 20.

### window_id
The window the coordinates were measured in. Windows picks pid's front window when omitted; macOS needs it unless pid has exactly one window (otherwise `ambiguous_window_target`).

### modifier
Keys held from press to release: cmd, shift, option (alt), ctrl. On Windows only in the foreground or with scope "desktop".

### scope
"window" (default): coordinates are pixels of the window's screenshot. "desktop": no pid or window_id, and coordinates are pixels of the get_desktop_state screenshot.

### from_zoom
True when the coordinates are pixels of the last zoom image of this pid.

## type_text fp=dc4fac0eae84c32c
Inserts text into an element (`element_token`) or into the focused element of pid's window. It types characters only: Return, Tab, Escape and arrows go through press_key or hotkey. To replace a field's whole value, set_value is more reliable; on Windows type_text into a save dialog's selected file name appends to it while reporting it replaced. On macOS a save dialog's name field takes a name only: a path typed there (`/Users/dev/bench/note.txt`) saves a file named `Users:dev:bench:note.txt` in the folder the dialog shows. Choose the folder first (cmd+shift+G, Go to Folder, or set_value on Where), then give the name. Read the field back (get_window_state) before trusting the result: for web content the tool cannot verify what the page received.

From the lab's trials: in an Electron or Chromium window (VS Code, Slack, browsers), pass delivery_mode "foreground": in the background Windows refuses the keys and macOS drops them while reporting "sent, unverified". Click the field first in its own call, then type; the `x`,`y` form, which clicks and types in one call, lost every key on macOS while reporting them sent. On Windows, Store and WinUI apps need an element_token (background keystrokes don't reach them). `delay_ms` paces one key per character, for search boxes that debounce.

### text
The text to insert.

### pid
Process ID of the window's app. Optional with element_token.

### window_id
The window to type into. Omit it with element_token.

### scope
"window" (default): type into pid's window. "desktop": no pid or window_id; type into the front app.

### delay_ms
Milliseconds between characters, 0–200. 0 (default) sends characters in fast batches; a positive value sends one key per character with that pause. Ignored when the text is set through the accessibility API.

### x
X of the field in pixels of the get_window_state screenshot. With y and no element_token, the tool clicks there to focus the field, then types (unreliable on macOS: see above).

### y
Y of the field, in the same screenshot as x.

## press_key fp=b0364ab62aa1fee1
Presses and releases one key, optionally with `modifiers` held, in pid's window without raising it. Keys: return, tab, escape, up, down, left, right, space, delete, home, end, pageup, pagedown, f1–f12, and any letter or digit. For a combination such as ctrl+s, hotkey is the clearer tool. With an `element_token` the element is focused first; a focus that cannot be confirmed is refused with `target_focus_unconfirmed`, and no key is sent.

A key is reported as confirmed only when a value or selection read back changed; "unverifiable" is not a failure, so check the window. From the lab's trials: keys into an Electron or Chromium window need delivery_mode "foreground" (on macOS it needs `window_id`); and on Windows a web `<select>` is set by focusing it and pressing its option's first letter in the foreground.

### key
Key name: return, tab, escape, up, down, left, right, space, delete, home, end, pageup, pagedown, f1–f12, a letter or a digit.

### modifiers
Keys held while the key is pressed. Windows: ctrl, shift, alt, win. macOS: cmd, shift, option (alt), ctrl, fn.

### pid
Process ID of the window's app. Optional with element_token.

### window_id
The window to send the key to. Windows takes pid's first visible window when omitted; macOS needs it for foreground delivery.

### x
X in pixels of the get_window_state screenshot: the tool clicks there to focus, then sends the key. With y, no element_token.

### y
Y in the same screenshot as x.

## hotkey fp=02eea90313b7efdb
Presses a key combination: modifiers first, then one other key, e.g. ["ctrl", "s"] on Windows or ["cmd", "s"] on macOS. Modifiers are ctrl, shift, alt and win on Windows; cmd, shift, option (alt), ctrl and fn on macOS; other keys are press_key's. A combination is never verified by the driver: check the result in a screenshot or the tree. A combination does not focus a text field: click the field first.

How it is delivered differs by OS. On Windows, Store and WinUI apps get the matching accelerator invoked through UI Automation, and classic Win32 apps get real key events with a brief swap to the front that is undone afterwards. On macOS the default background delivery reaches Chromium and Electron windows; a combination that is a menu item's shortcut (cmd+s, cmd+w) runs that menu item through accessibility when the app is in the background, and is refused with `background_unavailable` when macOS disables the item there; then use delivery_mode "foreground" (needs `window_id`). To paste text, put it on the clipboard with clipboard_write, check it with clipboard_read, then send ctrl+v or cmd+v.

### keys
Modifiers and one other key, e.g. ["ctrl", "c"] (Windows) or ["cmd", "c"] (macOS).

### pid
Process ID of the window's app. On macOS optional with element_token, required with x,y.

### window_id
The window to send the combination to, when pid has several. macOS needs it for foreground delivery; it does not raise the window by itself.

### x
X in pixels of the get_window_state screenshot: the tool clicks there to focus, then sends the combination (so ctrl+v or cmd+v pastes into that field). With y.

### y
Y in the same screenshot as x.

## set_value fp=194885feb4fbc994
Sets an element's value in one call, by `element_token`: a text field, slider, stepper, date picker, or the option of a dropdown. Prefer it over typing when a field's whole value should change, for example a save dialog's file name. On macOS that field takes a name only: a path given there becomes a file named `Users:dev:…:name` in the folder the dialog shows, so set the folder first (set_value on Where, or cmd+shift+G). Some web inputs ignore it: then use type_text and read the field back.

- Dropdowns: give the option's text as `value`. An unknown value is refused with the list of options. On Windows this works for native Win32 combo boxes (dialogs, WinForms); other combo boxes get a plain value write the app may not treat as a choice (for a web `<select>` there, see press_key). On macOS it works for popup buttons and `<select>` in Safari, Chrome and Electron, in the background.
- macOS Finder: on a file name cell (list or icon view) it renames the file; give the full new name with its extension. Finder's Get Info Name field is refused with `file_name_needs_rename`.

### value
The new value, coerced to the element's type; for a dropdown, the option's text.

### pid
Process ID of the window's app. Optional with element_token.

### window_id
The element's window. Omit it with element_token.

## scroll fp=31f9081bc6ec2a35
Scrolls pid's window up, down, left or right by `amount` lines or pages (`by`, default line; amount default 3), without raising it. To scroll a particular pane, pass `element_token` or x,y (pixels of the get_window_state screenshot): on macOS this sends wheel events at that point, the only way to scroll a nested scrolling region of a web page. Without a target the focused scroller moves. Read the window again to see the new content.

On Windows the scroll is sent as scrollbar messages, which any standard scrollable window follows; `element_token` is accepted but ignored there, and x,y target a nested surface only in the foreground. On macOS, Electron and Chromium windows ignore background wheel events: a background scroll there reveals content through accessibility instead, and "foreground" is the fallback.

### amount
Lines, pages or wheel notches to scroll, 1–50. Default 3.

### by
"line" (default) or "page".

### direction
up, down, left or right.

### pid
Process ID of the window's app. Optional with element_token; omit it with scope "desktop".

### window_id
The window to scroll. On macOS needed with x,y.

### x
X of the point to scroll at, in pixels of the get_window_state screenshot (of the get_desktop_state screenshot with scope "desktop"). With y.

### y
Y of the point, in the same screenshot as x.

## get_screen_size fp=cc156725831046ee
Returns the main display's size and scale factor. On Windows the size is in physical pixels, the space screenshots and pixel clicks use. On macOS it is in points (logical pixels), with scale_factor 2.0 on a Retina display. Coordinates for the input tools come from screenshots, so this is rarely needed.

## get_desktop_state fp=ce01083d400efae4
Captures the whole screen as a PNG and returns the true screen size (and on macOS the scale factor). Use it when the thing to act on is not inside one app's window, then act with scope "desktop" (or target {kind: "desktop", display_id: "primary"}) and x,y read off this image. It reads no accessibility tree; for an app's window, get_window_state is better. The result carries a capture_id to pass with those x,y.

### max_image_dimension
Long-edge limit for the PNG in pixels; omitted or 0 gives the full size. x,y read off a reduced image are mapped back to the screen automatically.

### screenshot_out_file
Write the PNG to this path in the VM instead of returning it inline.

## move_cursor fp=9d5e80817e859071
Moves the agent's cursor overlay, a drawn pointer that shows where the agent acts, to x,y; the real mouse pointer stays where it is. On macOS, with pid and window_id (x,y in window screenshot pixels), it also hovers a background app where a route exists that leaves the real pointer alone, and says whether it did; most native hover and tooltips follow the real pointer only, and for a page in Chrome, Edge or Brave browser_pointer with action "hover" works better. With scope "desktop" on macOS it moves the real pointer, in get_desktop_state pixels, and over a background app's window only with delivery_mode "foreground".

### delivery_mode
With scope "desktop": "background" (default) refuses to move the real pointer over a window of an app that is not in front; "foreground" moves it anyway.

### cursor_id
Which cursor overlay to move. Default "default".

### x
Destination X. Windows: screen coordinates (get_desktop_state pixels with scope "desktop"). macOS: window screenshot pixels with a window target, screen points without one, get_desktop_state pixels with scope "desktop".

### y
Destination Y, in the same space as x.

## check_permissions fp=28a1f0fb2868e36b
Reports whether Cua Driver has the permissions it needs. On macOS these are the Accessibility and Screen Recording grants (TCC), plus whether a direct screen capture works (`direct_capture_status`). Windows has no permission prompts, so there it only reports the driver's state. Call it when reads come back empty or input does nothing on every app; `get_guide({topic: "permissions"})` explains how to grant what is missing. In the lab the VMs' states already carry the grants.

### prompt
(mac; ignored on Windows) Raise the system's permission dialogs for missing grants. Default false, a read-only check; true is for the person setting the VM up.

### probe_direct_capture
With prompt true and Screen Recording granted, also run a live capture probe, which may raise macOS's direct-capture consent. Default true.

## get_config fp=132ec8c87147390e
Returns Cua Driver's persistent settings, as set_config writes them: the screenshot size limit (`max_image_dimension`, 0 for none), the agent cursor's look and motion, the experimental picture-in-picture preview, and the driver's version and platform. It only reads and is safe to call at any time. `capture_mode` is obsolete: get_window_state always returns both the tree and a screenshot.

## set_config fp=7c6712e220feb7bd
Changes Cua Driver's persistent settings, one field per setting, and returns the whole config as get_config does. The setting agents use is `max_image_dimension`, the long-edge limit of screenshots (0 for none), which applies at once. The rest set the look of the agent's cursor overlay (applied at once), the default cursor motion of sessions started later, and the experimental picture-in-picture preview (applied at the driver's next restart). These settings are shared by every session on that VM, so change them only when the task needs it.

### capture_mode
Obsolete and ignored: get_window_state always returns both the tree and a screenshot.

### max_image_dimension
Long-edge limit of screenshots in pixels; 0 means no limit.

### fast_path
Experimental, default off, not saved. "shadow" reports which actions would be refused because their target changed since it was read; "guard" refuses them (`target_changed`); "on" also adds a small delta to each result.

### experimental_pip
Turn on the experimental picture-in-picture preview window, at the driver's next restart.

### experimental_pip_geometry
The preview window's size and position, `WxH` or `WxH+X+Y` (e.g. `320x200+24+24`), at the next restart.

### cursor.badges
Agent cursor badge: "minimal" (default), "verbose" (session and delivery on every action) or "off".

### cursor.float
Agent cursor's slow sway at rest and while moving: "on" (default) or "off".

### cursor.halo
Soft glow behind the agent cursor: "on" (default) or "off".

### cursor.marks
Small mark beside the agent cursor showing the kind of action: "off" (default) or "on".

### cursor.rotate
Agent cursor rotation while moving: "heading" (default), "lean" or "off".

### cursor.motion
"default" clears every saved cursor motion default.

### cursor.motion.style
Default cursor motion style for sessions started later (built-in default signature_arc).

### cursor.motion.timing
Default cursor move timing for sessions started later (built-in default steady, at least 600 ms per move).

### cursor.motion.effects.glow
Default for the glow effect: on, off, or default (the style's own).

### cursor.motion.effects.magnet
Default for the magnet effect: on, off, or default (the style's own).

### cursor.motion.effects.ripple
Default for the ripple effect: on, off, or default (the style's own).

### cursor.motion.effects.squish
Default for the squish effect: on, off, or default (the style's own).

### cursor.motion.effects.trail
Default for the trail effect: on, off, or default (the style's own).

## get_accessibility_tree fp=d9e28f3a8c6b8ff8
Returns a quick overview of the desktop: the running apps and the visible windows, with their bounds and owner pid (and z-order on macOS). Use it to discover what is open in one cheap call. It does not return any window's elements: for those, and for element tokens to act on, call get_window_state on one window. list_windows gives the same windows with filters by app or pid.

## zoom fp=ff41a36f1ad48b3d
Returns a full-resolution crop of a region of a window's last screenshot, to read small text, tell icons apart or check a detail when get_window_state's image was scaled down. Give the corners x1,y1 (top-left) and x2,y2 (bottom-right) in pixels of that screenshot; 20% padding is added on every side, and the output is at most 500 px wide. Afterwards, click, type_text and drag take `from_zoom: true` with x,y read off the zoom image. It needs a current get_window_state read of the window from this session (`screenshot_context_missing` otherwise), and a from_zoom action refused with `zoom_context_missing` means: read the window and zoom again.

### pid
Optional; by default the window's current snapshot from this session is used.

### window_id
The window whose screenshot to crop.

### x1
Left edge of the region, in pixels of the get_window_state screenshot.

### y1
Top edge of the region, in pixels of the get_window_state screenshot.

### x2
Right edge of the region, in pixels of the get_window_state screenshot.

### y2
Bottom edge of the region, in pixels of the get_window_state screenshot.

## run_steps fp=5ff54454f9d37b95
Runs several actions in one call, in order, stops at the first failure, and with `observe` returns what changed in the window in the same response. Use it whenever the next actions are known: fill three fields, click Submit and see the result in one call instead of five; even one step plus `observe: {}` saves the get_window_state call after it. A step is `{"tool": "click", "args": {...}}` or `{"click": {...}}`, for click, double_click, right_click, set_value, type_text, press_key, hotkey, scroll, drag or move_cursor, with that tool's own arguments. All steps are validated before the first runs, and each passes the same checks as a direct call.

- Targets: a step's args may carry an element_token from an earlier read, or name the element instead: `role` (button, textfield, link, checkbox, menuitem…), `name` (its label; exact match beats substring, case-insensitive), `nth` (0-based, among several matches), and `app` (name or bundle id) or `window` (title substring) instead of pid and window_id. A named target is looked up fresh, waiting up to `timeout_ms` (default 3 s), so one batch can cross into a dialog that opens on top. Later steps inherit the window. Name later targets when an earlier step reshuffles the window, since that stales its tokens.
- Checks: a step may add `wait_for` (before its action, default 5 s) and `expect` (up to 4, after it, default 2 s), or be only a check. A check is {role?, name?, text?, gone?, value?, value_contains?, enabled?, selected?, app?, window?, timeout_ms?}; `text` matches any row, `gone: true` waits for it to disappear. The report names the failed step, its phase (wait_for, find, action, expect) and what was found.
- `delivery_mode` here is every step's default; `foreground_fallback: true` retries once in the foreground a step its app refused in the background. At most 64 steps, `delay_ms` up to 2000 between them, 60 s for the whole batch. `get_guide({topic: "batching"})` has more.

Example: {"steps": [{"set_value": {"app": "Safari", "role": "textfield", "name": "Email", "value": "ada@example.com"}}, {"click": {"role": "button", "name": "Submit"}, "expect": [{"text": "Thanks"}]}], "observe": {}}

### steps
The actions in order, 1–64: {tool, args} or {<tool>: args}, each with optional wait_for, expect and timeout_ms; a step may be only a check.

### observe
Arguments for one get_window_state read after the last step; {} reads the last step's window. By default only what changed since your last read of it (since "latest"), without a screenshot, at most 250 elements; pass include_screenshot true to see it, since null for a full read. Omit it to read nothing.

### app
Default app (name or bundle id) for steps that name no window.

### window
Default window title substring for steps that name no window.

### pid
Default pid for steps that name no window; a step's own target wins.

### window_id
Default window_id, with pid, for steps that name no window.

### delay_ms
Pause between steps in milliseconds, 0–2000 (not after the last). Default 0.

### delivery_mode
Default delivery_mode for the steps that set none.

### foreground_fallback
Retry once, in the foreground (the window is activated), a step its app refused in the background. Default false.

## start_recording fp=3a5dde64bfb51fb1
Starts recording this session's actions to `output_dir` in the VM: every click, right_click, scroll, type_text, press_key, hotkey and set_value writes a folder turn-00001, turn-00002… Each holds before.png and after.png (window screenshots), before_state.json and after_state.json (the accessibility tree around the action), action.json (tool, arguments, result, time), click.png (the click point marked) and evidence.json (what could not be captured, and why). Use it to keep a record of a test run; stop_recording ends it, and get_recording_state reports it.

- Video is off by default; `record_video: true` also records the screen to output_dir/recording.mp4. On Windows that needs ffmpeg on the VM's PATH (without it only the turn folders are written, and the error is in last_error); on macOS it uses ScreenCaptureKit, and macOS 26 may ask once for capture consent.
- Without `session`, every call on this connection is recorded. Recording ends when the driver restarts.
- Pass any secret the session will type in `redact_values`: it is replaced with `[redacted]` in the text files (screenshots and video are not altered).

### output_dir
Directory in the VM (absolute or ~-rooted) for the turn folders and the video.

### record_video
Also record the screen to output_dir/recording.mp4. Default false. Windows needs ffmpeg on PATH; macOS 26 may ask for capture consent on first use.

### redact_values
Secrets (passwords, tokens) to replace with `[redacted]` in every turn's text files; such turns are never replayed. Held in memory only. Screenshots and video are not altered.

### include_accessibility_tree
Default true. False skips the before and after tree reads; screenshots and action.json are still written.

### state_timeout_ms
Time limit in milliseconds for each before or after tree read (default 1000); a read that runs out records the partial tree.

## browser_prepare fp=c4a201cf6deeafef
Connects the browser_* tools (get_browser_state, browser_click, browser_type, browser_pointer and the rest) to a Chromium browser through DevTools. Two ways:

- An already running Chrome, Edge or Brave: when get_browser_state refuses with `browser_consent_required` or `browser_requires_setup`, call this once with pid, window_id and strategy {"kind": "existing_profile"}, then call get_browser_state again. The driver may open the browser's remote-debugging page, tick its checkbox and close the tab, and reports each visible step. Where attaching would bring the browser to the front (macOS Chrome shows its own prompt), it refuses with `background_unavailable` unless delivery_mode is "foreground"; the approval then lasts for that browser for up to 8 hours.
- A separate browser the driver owns: allow_launch true with profile {"mode": "isolated_new"} (a throwaway profile, gone after the session) or {"mode": "isolated_named", "name": …} (kept). It never touches an existing profile, and the browser ends with the session.

Either attaches or refuses with nothing changed and says why; existing-profile attachment also depends on the driver's permission mode. `get_guide({topic: "browser"})` covers setup and recovery.

### session
Session label. The browser binding, its tabs and refs belong to this session: pass the same label to get_browser_state and the browser_* tools.

### delivery_mode
Only for attaching to a running browser: "background" (default) refuses with background_unavailable where attaching would bring the browser to the front; "foreground" accepts that and brings the previous front app back afterwards.

### pid
The browser process. Required except for a launch with allow_launch true.

### window_id
The browser window to attach; required with strategy existing_profile.

### strategy
{"kind": "existing_profile"} (an object, not a string): attach to the running browser at pid and window_id.

### allow_launch
Allow launching a separate driver-owned browser with `profile`. Default false.

### profile
The driver-owned profile to launch with allow_launch: {"mode": "isolated_new"} for a fresh one, or {"mode": "isolated_named", "name": "…"} to reuse a named one.

## get_browser_state fp=8ad7b4867082b903
Reads a web page in Chrome, Edge or Brave through DevTools, without moving the pointer or raising the window; use it, not the desktop tools, for any page in those browsers. First bind: pid and window_id of the browser window return a target_id and tab ids (the browser_* tools refuse heuristic bindings). Then read: target_id and tab_id return the page's elements with refs `p<snapshot>:<index>` for the browser_* tools. snapshot_format "semantic_v2" returns an outline with visible content first, typed action refs, scoped reads (query, scope_ref) and a continuation. A browser not attached yet refuses with `browser_consent_required` or `browser_requires_setup`, and detail.next_call names the browser_prepare call to make. Setup and recovery: `get_guide({topic: "browser"})`.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

### pid
The browser process (bind).

### window_id
The browser window, owned by pid (bind).

### snapshot_format
"dom_refs_v1" (default) or "semantic_v2".

### include_screenshot
Also capture the tab's viewport as PNG, without selecting the tab or raising the window; refuses if it cannot. Default false.

### query
semantic_v2: only content whose role, name or visible text matches.

### scope_ref
semantic_v2: only the subtree of this ref.

### continuation
semantic_v2: the continuation of an earlier response, to read on.

## browser_navigate fp=0e3009e22443ed4d
Loads a URL (http, https or about) in a bound tab. It stales every ref of that tab.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

## browser_click fp=38c422e7691daab1
Clicks a page element (`ref`) or viewport x,y (CSS pixels) in a bound tab. The default route sends trusted mouse events through DevTools and refuses where that would raise the browser window, unless delivery_mode is "foreground". input_route "dom_event" sends a synthetic DOM click at the ref's center instead; it proves the dispatch, not that the control acted (controls that check for trusted input ignore it). If the click opens a JavaScript dialog, the call returns at once with a dialog block (present, kind, dialog_id) for browser_dialog; clicks in that tab are refused while it is open.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

### delivery_mode
"background" (default) refuses trusted input where it would raise the browser window; "foreground" accepts that.

### input_route
"trusted" (default) or "dom_event" (synthetic, needs ref; read the page again to check it worked).

### x
Viewport x in CSS pixels, instead of ref.

### y
Viewport y in CSS pixels, instead of ref.

## browser_type fp=fa0af00654a16cd1
Types text at the caret of an editable element (`ref`, required) in a bound tab, through DevTools. It appends to what the field holds; replace true replaces that (with an empty text: clears the field), and the page's input events still fire. mode "insert_text" (default) inserts the text at once; "keystrokes" sends a key event per character.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

### mode
"insert_text" (default) or "keystrokes".

### replace
True: select the field's content first, so the text replaces it. Default false: append.

## browser_select fp=3ffab79d13eb5e1f
Selects one option of a native `<select>` (`ref`) in a bound tab without opening its popup. Pass label or value, not both; exactly one option must equal it. Non-native, multiple and disabled selects, disabled options and no or several matches are refused with nothing changed. The input and change events it fires are synthetic: check that the page took the selection.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

## browser_dialog fp=f4ce68f68af769a7
Inspects or answers a page's JavaScript alert, confirm, prompt or beforeunload dialog in a bound tab; not permission prompts, extension UI, native dialogs or file pickers. action "inspect" returns the dialog and its dialog_id; "accept" and "dismiss" need that current dialog_id.

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

### delivery_mode
For accept and dismiss. Default "background".

### dialog_id
From action "inspect".

### prompt_text
The answer to a prompt dialog, with "accept".

## browser_set_input_files fp=804510515bb99709
Sets the files of an `<input type=file>` (`ref`) in a bound tab through DevTools, without the file picker. The paths are absolute paths of regular files in the VM (no symlinks).

### session
Session label: the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call (browser_pointer and browser_download require one).

### files
1 to 32 absolute paths of files in the VM.

## browser_download fp=c874a02015272101
Starts a download by activating a page element (`ref`) in a bound tab and saves the file in `destination_root`, an existing folder in the VM. It needs the MCP host's approval for destructive tools and refuses stale or ambiguous refs. It never returns the URL, file name or path: look in the folder.

### session
Session label (required here): the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call.

### ref
The element that starts the download.

### destination_root
Absolute path of an existing folder in the VM.

## browser_pointer fp=dcdb12d2eb8f0fa5
Hovers, right-clicks, double-clicks, scrolls or drags in a bound tab, without raising it. Start at `ref` or x,y (viewport CSS pixels). scroll takes delta_x or delta_y; drag takes destination_ref or to_x,to_y. A ref must offer pointer actions (scroll also takes a scroll ref). The trusted route sends DevTools input events and refuses where that would raise the window; input_route "dom_event" synthesizes DOM events and needs a ref.

### session
Session label (required here): the browser binding, its tabs and refs belong to it. Pass the same label to get_browser_state and every browser_* call.

### action
The gesture.

### delivery_mode
"background" (default) refuses trusted input where it would raise the browser window; "foreground" accepts that.

### input_route
"trusted" (default) or "dom_event" (needs ref).

### ref
Where the gesture starts, instead of x,y.

## run_script fp=f7fe1ea7c7f2ee09
Runs a JavaScript program that drives apps through Cua Driver in one call, returning only its result: for flows that need logic, such as a loop over rows, a branch on what the app shows, or a retry. For a fixed list of actions, run_steps is simpler. The script is the body of an async function (`await`, `return` a JSON value), in a sandbox without filesystem, network, processes or timers; its only API is `cua`:

- `await cua.getApp("Calculator" | "com.apple.calculator" | {pid, windowId})` → app (follows its front window); `cua.launch(nameOrBundleId)` → app; `cua.listApps()`, `cua.listWindows({pid?})`, `cua.sleep(ms)`.
- app.getState(opts?) (get_window_state), app.query({role?, name?, text?}) → elements {element_token, role, label, value, enabled, selected, frame} and text rows (read their `value`), app.waitFor({role?, name?, text?, gone?, value?, timeout_ms?}), app.verify(predicates).
- app.click(t), doubleClick(t), rightClick(t), typeText(text, t?), pressKey("return" | "cmd+s", t?), hotkey(["cmd", "s"]), scroll(t, direction, amount?), setValue(t, value), drag([x, y], [x, y]), zoom([x1, y1, x2, y2]); a target `t` is {role, name, nth?} (found fresh, waits up to 3 s), an element_token, a row number of the last getState(), or [x, y] window pixels.
- `cua.call(tool, args)` for click, double_click, right_click, set_value, type_text, press_key, hotkey, scroll, drag, launch_app, list_apps, list_windows, get_window_state, verify_state or zoom.

A failed call throws a CuaError, which the script may catch. The response has the return value, console output and a log of calls; an error names the script line, the call and the reason. Example: `const app = await cua.getApp("Calculator"); for (const k of ["7", "multiply", "6", "equals"]) await app.click({role: "button", name: k}); return (await app.query({role: "statictext"}))[0].value;`

### script
JavaScript, the body of an async function; `return` the result.

### timeout_ms
Wall-time limit in milliseconds, 100–120000. Default 30000.

### max_calls
Most driver calls the script may make, 1–500. Default 100.

## health_report fp=36654ef37a32e51d
Runs Cua Driver's self-checks in one call and returns `overall` ("ok", "degraded" or "failed") with a list of checks, each with a status (pass, fail or skip), a one-line message, and a hint when it failed. Call it when the tools misbehave on every app, before digging further: it covers the driver's version, platform support, the active session, accessibility and screen capture, and on macOS the TCC grants, bundle identity and WindowServer connection. "failed" means a core check failed (binary_version, platform_supported, session_active) and the driver is unusable; "degraded" means another check failed. `include` or `skip` limit the checks by name.

### include
Run only these checks, by name (e.g. ax_capability, screen_capture_capability, tcc_accessibility). Wins over skip.

### skip
Skip these checks, by name.

<!-- Tools Cua describes once for both VMs: listed only for the shared parameter texts. -->

## verify_state fp=8e6de57505512a2b

## set_window_frame fp=738705f503bf8929

## invoke_menu fp=35b207422e101ba3

## debug_window_info fp=6499a65ec42de19f

## clipboard_read fp=06b4827da0a90f81

## clipboard_write fp=4d3920bf1db74b77

## get_cursor_position fp=913b7b59fcb630d9

## stop_recording fp=9d3126b5122bee5b

## get_recording_state fp=9b5721eb5b95ce7d

## get_guide fp=5182d5931080e7f7

## parse_visual_regions fp=5ec3cfbfa0ba2fa1
