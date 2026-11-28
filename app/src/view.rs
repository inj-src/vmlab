//! The window: the VMs down the side, the chosen one's header, its states, its build cache and
//! how to reach it. Every press asks `App` to act; nothing here runs `vm`.

use rune::{Color, Cursor, Cx, El, Icon, ScrollSpec, col, el, icon, row, spacer, text};
use rune_kit::{Button, ButtonVariant, ControlSize, IconButton, IconButtonVariant, Kit, Loader, Menu, MenuItem, Toast, ToastRegion};
use rune_theme_opencode::icons as oc;

use crate::model::{Saved, Snapshot, Status, Vm, for_how_long, gb, parse_utc, when};
use crate::{App, Dialog, dialogs, icons};

/// The page: the VM list and the chosen VM side by side, centred, no wider than `MAX_W`, as a
/// documentation site's table of contents and article.
const MAX_W: f32 = 1080.0;
const TOC_W: f32 = 164.0;
/// Where the brand and the header sit, so their lines meet across the gap.
const TOP: f32 = 36.0;
const BAR_H: f32 = 36.0;

/// Running: a calmer green than the theme's success token, which is drawn for small icons.
pub fn ok(k: &Kit) -> Color {
    let hex = if k.dark { "#3ecf8e" } else { "#1f9d61" };
    rune::color::hex(hex).unwrap_or(k.c.success.icon)
}

/// Unsaved changes, a busy VM, a nearly full gauge: one amber for the dot and its words. The
/// theme's light warning text is too pale to read on a card (2.4:1); this one is 5:1.
pub fn warn(k: &Kit) -> Color {
    if k.dark { k.c.warning.fg } else { rune::color::hex("#a16207").unwrap_or(k.c.warning.icon) }
}

/// Below this width (the window opens at it) the header's ports button keeps only its icon and the page's margins
/// shrink, so the state's name stays in the header down to the smallest window (680).
const COMPACT_W: f32 = 780.0;

pub fn view(s: &App, cx: &mut Cx<App>) -> El {
    let k = rune_theme_opencode::kit(cx.system_dark());
    let hair = 1.0 / cx.env().scale;
    let c = &k.c;
    let compact = cx.layout_with("window", |r| r[2] < COMPACT_W).unwrap_or(false);
    let mut layer = Vec::new();
    let panel = match &s.data {
        Some(d) => panel(s, d, k, hair, compact, &mut layer),
        None => waiting(s, k),
    };
    dialogs::build(s, k, &mut layer);
    // Errors stay in the page (`problem`) until closed; the corner only says what went well.
    if let Some(t) = s.toast.as_ref().filter(|t| !t.error) {
        let toast = Toast::new(format!("toast{}", t.id), t.text.clone())
            .lead(icon(&oc::CIRCLE_CHECK, 16.0).color(ok(k)))
            .on_close(|s: &mut App| s.toast = None)
            .build(k);
        layer.push(ToastRegion::new().toast(toast).build(k));
    }
    let (px, gap) = if compact { (20.0, 28.0) } else { (28.0, 36.0) };
    let frame = row().key("frame").w_full().max_w(MAX_W).h_full().px(px).gap(gap).child(toc(s, k)).child(panel);
    let base = row().key("window").w_full().h_full().fill(c.bg_base).justify_center().child(frame);
    rune_kit::root(base, layer)
}

fn waiting(s: &App, k: &Kit) -> El {
    let c = &k.c;
    let panel = col().key("panel").grow(1.0).h_full().center().gap(12.0);
    match &s.read_error {
        // The reader tries again every few seconds by itself.
        Some(e) => panel
            .child(icon(&oc::CIRCLE_EXCLAMATION, 20.0).key("failed").color(c.danger.icon))
            .child(text("vm did not answer").key("waiting").font(k.ty.ui_medium).color(c.text_base))
            .child(text(e.clone()).key("why").font(k.ty.mono).color(c.text_muted).wrap().max_w(420.0).align(rune::Align::Center))
            .child(text("Trying again every few seconds").key("retry").font(k.ty.small).color(c.text_faint)),
        None => panel.child(Loader::new().size(18.0).build(k).key("spin")).child(text("Reading the VMs…").key("waiting").font(k.ty.ui).color(c.text_muted)),
    }
}

// ---------------------------------------------------------------- sidebar

fn logo(vm: Vm) -> &'static Icon {
    match vm {
        Vm::Win => &icons::WINDOWS,
        Vm::Mac => &icons::APPLE,
    }
}

/// The status dot: green while it runs, amber while an action runs on it, hollow when off.
fn dot(k: &Kit, key: &str, running: bool, busy: bool) -> El {
    let c = &k.c;
    let (glyph, tint) = if busy {
        (&icons::DOT, warn(k))
    } else if running {
        (&icons::DOT, ok(k))
    } else {
        (&icons::RING, c.icon_faint)
    };
    icon(glyph, 8.0).key(key).color(tint)
}

/// The VMs as a table of contents: links on a thin track, the chosen one lit, with the brand
/// above and the free space under them (together, however tall the window). No panel of its own: it shares the page.
fn toc(s: &App, k: &Kit) -> El {
    let c = &k.c;
    let brand = row()
        .key("brand")
        .h(BAR_H)
        .gap(9.0)
        .center_y()
        .child(icon(&icons::VMLAB, 20.0).key("mark"))
        .child(text("vmlab").key("name").font(k.ty.body_medium).color(c.text_base));
    let mut nav = col().key("nav").w_full().role("tablist").label("VMs").focus_group();
    for vm in Vm::ALL {
        let on = s.sel == vm;
        // No dot until `vm` has answered: a ring would claim it is off.
        let known = s.data.as_ref().and_then(|d| d.status(vm));
        let running = known.is_some_and(|st| st.running);
        let busy = s.busy.as_ref().is_some_and(|b| b.vm == vm);
        let said = match known {
            _ if busy => format!("{}, busy", vm.title()),
            Some(st) if st.running => format!("{}, running", vm.title()),
            Some(_) => format!("{}, stopped", vm.title()),
            None => vm.title().to_owned(),
        };
        let mut link = row()
            .key("link")
            .grow(1.0)
            .shrink()
            .min_w(0.0)
            .h_full()
            .ml(4.0)
            .px(8.0)
            .gap(8.0)
            .center_y()
            .radius(6.0)
            .hover(if on { Color::TRANSPARENT } else { c.hover })
            .child(icon(logo(vm), 14.0).key("logo").color(if on { c.icon_base } else { c.icon_muted }))
            .child(
                text(vm.title())
                    .key("title")
                    .font(if on { k.ty.ui_medium } else { k.ty.ui })
                    .color(if on { c.text_base } else { c.text_muted })
                    .truncate()
                    .grow(1.0)
                    .shrink(),
            );
        if known.is_some() {
            link = link.child(dot(k, "dot", running, busy));
        }
        nav = nav.child(
            row()
                .key(format!("nav-{}", vm.id()))
                .role("tab")
                .label(said)
                .checked(on)
                .focusable(true)
                .focus_selected(on)
                .press_on_return()
                .w_full()
                .h(32.0)
                .cursor(Cursor::Pointer)
                .on_press(move |s: &mut App| {
                    s.sel = vm;
                    s.menu = None;
                })
                .child(el().key("track").w(if on { 2.0 } else { 1.0 }).h_full().fill(if on { c.text_base } else { c.border_base }))
                .child(link),
        );
    }
    let list = col()
        .key("contents")
        .w_full()
        .gap(10.0)
        .child(text("Machines").key("label").font(k.ty.small_medium).color(c.text_faint))
        .child(nav);
    let mut side = col().key("toc").w(TOC_W).h_full().pt(TOP).pb(24.0).gap(28.0).child(brand).child(list);
    if let Some(d) = &s.data
        && d.disk_bytes > 0
    {
        // The bar is the disk's used part, as every disk gauge; the words say both.
        let used = 1.0 - d.free_bytes as f32 / d.disk_bytes as f32;
        side = side.child(
            col()
                .key("disk")
                .w_full()
                .gap(8.0)
                .child(
                    row()
                        .key("free")
                        .gap(4.0)
                        .child(text(gb(d.free_bytes)).key("n").font(k.ty.small_medium).color(c.text_base).nowrap())
                        .child(text(format!("free of {}", gb(d.disk_bytes))).key("on").font(k.ty.small).color(c.text_muted).truncate().shrink()),
                )
                .child(
                    meter(k, "disk-meter", used, used > 0.9)
                        .role("meter")
                        .label(format!("/vmlab: {} free of {}", gb(d.free_bytes), gb(d.disk_bytes)))
                        .help("Space on /vmlab, where the VMs and their states live"),
                ),
        );
    }
    side
}

fn meter(k: &Kit, key: &str, frac: f32, warning: bool) -> El {
    let c = &k.c;
    let frac = frac.clamp(0.0, 1.0);
    let tint = if warning { warn(k) } else { c.icon_muted };
    el().key(key)
        .w_full()
        .h(4.0)
        .radius(2.0)
        .fill(if k.dark { c.layer_03 } else { c.border_base })
        .child(el().key("fill").w_frac(frac).h_full().radius(2.0).fill(tint))
}

// ---------------------------------------------------------------- the chosen VM

fn panel(s: &App, d: &Snapshot, k: &Kit, hair: f32, compact: bool, layer: &mut Vec<El>) -> El {
    let vm = s.sel;
    let Some(st) = d.status(vm) else {
        return col().key("panel").grow(1.0).h_full().center().child(text("vm does not list this VM").font(k.ty.ui).color(k.c.text_muted));
    };
    // A failed action sits between the header and the scroller, so it shows at any scroll.
    let failed = s.toast.as_ref().filter(|t| t.error);
    let mut body = col().key(format!("body-{}", vm.id())).w_full().px(1.0).pt(if failed.is_some() { 12.0 } else { 20.0 }).pb(28.0).gap(12.0);
    if let Some(other) = d.running()
        && other != vm
    {
        body = body.child(info(
            k,
            &format!("{} is running. Starting {} shuts it down first, about a minute.", other.title(), vm.title()),
        ));
    }
    // The cache first: a fixed-height summary that a growing list of states never pushes away.
    body = body
        .child(cache(s, d, st, k))
        .child(text("States").key("states-title").font(k.ty.ui_medium).color(k.c.text_base).mt(8.0))
        .child(states(s, d, st, k, hair, layer))
        .child(under(s, st, k));
    let mut panel = col().key("panel").grow(1.0).shrink().min_w(0.0).h_full().child(header(s, st, k, hair, compact));
    if let Some(t) = failed {
        // The body's 1 pt inset, so the strip's edges meet the cards' below it.
        panel = panel.child(col().key("problem-wrap").w_full().px(1.0).pt(20.0).child(problem(k, t)));
    }
    panel
        .child(col().key("scroll").w_full().grow(1.0).shrink().min_h(0.0).scroll(ScrollSpec { stick_bottom: false }).child(body))
}

fn info(k: &Kit, line: &str) -> El {
    let c = &k.c;
    row()
        .key("info")
        .w_full()
        .px(12.0)
        .py(9.0)
        .gap(9.0)
        .radius(8.0)
        .fill(c.layer_02)
        .border(0.5, c.border_muted)
        .center_y()
        .child(icon(&icons::INFO, 16.0).key("i").color(c.icon_muted))
        .child(text(line.to_owned()).key("t").font(k.ty.ui).color(c.text_muted).wrap().grow(1.0).shrink())
}

/// An action that failed: what, and `vm`'s own words (in its own type, flags and all), until
/// it is closed or the next action starts. Above everything else, so it is seen.
fn problem(k: &Kit, t: &crate::Note) -> El {
    let c = &k.c;
    let mut copy = col()
        .key("copy")
        .grow(1.0)
        .shrink()
        .min_w(0.0)
        .gap(4.0)
        .child(text(t.text.clone()).key("t").font(k.ty.ui_medium).color(c.text_base).wrap());
    if let Some(d) = &t.detail {
        copy = copy.child(text(d.clone()).key("d").font(k.ty.mono).color(c.text_muted).wrap());
    }
    row()
        .key("problem")
        .role("alert")
        .label(t.text.clone())
        .description(t.detail.clone().unwrap_or_default())
        .w_full()
        .pl(12.0)
        .pr(6.0)
        .py(6.0)
        .gap(9.0)
        .radius(8.0)
        .fill(c.danger.bg)
        .border(0.5, c.danger.border)
        .child(icon(&oc::CIRCLE_EXCLAMATION, 16.0).key("i").color(c.danger.icon).mt(3.0))
        .child(copy.py(3.0))
        .child(
            IconButton::new(&oc::CLOSE)
                .variant(IconButtonVariant::Ghost)
                .label("Dismiss")
                .help("Dismiss")
                .on_press(|s: &mut App| s.toast = None)
                .build(k)
                .key("dismiss"),
        )
}

fn header(s: &App, st: &Status, k: &Kit, hair: f32, compact: bool) -> El {
    let c = &k.c;
    let vm = s.sel;
    let idle = s.busy.is_none();
    // The state gives way last: it keeps a few letters however narrow the window.
    let crumb = row()
        .key("crumb")
        .gap(8.0)
        .center_y()
        .shrink()
        .min_w(0.0)
        .child(icon(logo(vm), 16.0).key("logo").color(c.icon_base))
        .child(text(vm.title()).key("vm").font(k.ty.ui_medium).color(c.text_base).nowrap())
        .child(text("/").key("sep").font(k.ty.ui).color(c.text_faint))
        .child(text(st.state.clone()).key("state").font(k.ty.ui).color(c.text_muted).truncate().shrink().min_w(48.0).help_when_truncated(st.state.clone()));
    let mut bar = row().key("top").w_full().h(BAR_H).gap(6.0).center_y().child(crumb).child(spacer());
    if let Some(b) = s.busy.as_ref().filter(|b| b.vm == vm) {
        bar = bar
            .child(Loader::new().size(14.0).build(k).key("spin"))
            .child(text(format!("{}…", b.label)).key("busy").font(k.ty.ui).color(c.text_muted).nowrap().ml(4.0));
    } else if st.running {
        // Tunnels and forwards, when there are any: what reaches the VM besides SSH.
        let ports = st.tunnels.len() + st.forwards.len();
        if ports > 0 {
            let words = if ports == 1 { "1 port".to_owned() } else { format!("{ports} ports") };
            let open = move |s: &mut App| s.dialog = Dialog::Ports { vm };
            // A narrow window keeps the icon and leaves the room to the state's name.
            let button = if !compact {
                Button::new(words).variant(ButtonVariant::Ghost).control_size(ControlSize::Large).icon(&icons::ARROWS).help("Tunnels and forwards").disabled(!idle).on_press(open).build(k)
            } else {
                IconButton::new(&icons::ARROWS).variant(IconButtonVariant::Ghost).control_size(ControlSize::Large).label(words.clone()).help(format!("{words}: tunnels and forwards")).disabled(!idle).on_press(open).build(k)
            };
            bar = bar.child(button.key("ports").mr(if compact { 0.0 } else { 4.0 }));
        }
        bar = bar
            .child(
                IconButton::new(&icons::RESTART)
                    .variant(IconButtonVariant::Ghost)
                    .control_size(ControlSize::Large)
                    .label("Restart")
                    .help("Restart")
                    .disabled(!idle)
                    .on_press(move |s: &mut App| s.restart(vm))
                    .build(k)
                    .key("restart"),
            )
            .child(
                IconButton::new(&icons::POWER)
                    .variant(IconButtonVariant::Ghost)
                    .control_size(ControlSize::Large)
                    .label("Shut down")
                    .help("Shut down")
                    .disabled(!idle)
                    .on_press(move |s: &mut App| s.stop(vm))
                    .build(k)
                    .key("stop"),
            )
            .child(
                Button::new("Show window")
                    .variant(ButtonVariant::Submit)
                    .control_size(ControlSize::Large)
                    .icon(&icons::OPEN)
                    .disabled(!idle)
                    .on_press(move |s: &mut App| s.show(vm))
                    .build(k)
                    .key("show")
                    .ml(4.0),
            );
    } else {
        bar = bar
            .child(dot(k, "off", false, false))
            .child(text("Stopped").key("stopped").font(k.ty.ui).color(c.text_muted).mr(8.0))
            .child(
                Button::new("Start")
                    .variant(ButtonVariant::Submit)
                    .control_size(ControlSize::Large)
                    .icon(&icons::PLAY)
                    .disabled(!idle)
                    .on_press(move |s: &mut App| s.start(vm))
                    .build(k)
                    .key("start"),
            );
    }
    col().key("head").w_full().pt(TOP).child(bar).child(el().key("rule").w_full().h(hair).mt(14.0).fill(c.border_base))
}

// ---------------------------------------------------------------- states

fn states(s: &App, d: &Snapshot, st: &Status, k: &Kit, hair: f32, layer: &mut Vec<El>) -> El {
    let c = &k.c;
    let list = d.states(s.sel);
    let n = list.len();
    let mut group = col().key("states").w_full().radius(8.0).fill(c.layer_01).border(0.5, c.border_muted).clip_rounded(8.0);
    for (i, saved) in list.into_iter().enumerate() {
        group = group.child(state_row(s, d, st, saved, k, layer));
        if i + 1 < n {
            group = group.child(el().key(format!("sep{i}")).w_full().h(hair).fill(c.border_muted));
        }
    }
    group
}

fn state_row(s: &App, d: &Snapshot, st: &Status, saved: &Saved, k: &Kit, layer: &mut Vec<El>) -> El {
    let c = &k.c;
    let vm = s.sel;
    let name = saved.state.clone();
    let cur = saved.state == st.state;
    let idle = s.busy.is_none();
    let mut title = row().key("title").gap(8.0).center_y().child(text(name.clone()).key("name").font(k.ty.ui_medium).color(c.text_base).nowrap());
    if cur && st.running {
        let since = st.since.as_deref().and_then(parse_utc).map(|t| for_how_long(d.now - t));
        let line = since.map_or("Running".into(), |h| format!("Running for {h}"));
        title = title.child(
            row()
                .key("tag")
                .gap(5.0)
                .center_y()
                .child(icon(&icons::DOT, 6.0).key("d").color(ok(k)))
                .child(text(line).key("t").font(k.ty.small).color(c.text_muted).nowrap()),
        );
    } else if cur {
        title = title.child(
            el().key("tag")
                .px(6.0)
                .py(2.0)
                .radius(4.0)
                .fill(c.layer_03)
                .child(text("Current").key("t").font(k.ty.small_medium).color(c.text_muted)),
        );
    }
    let note = if saved.note.is_empty() {
        text("No note").font(k.ty.ui).color(c.text_faint)
    } else {
        text(saved.note.clone()).font(k.ty.ui).color(c.text_muted).help_when_truncated(saved.note.clone())
    };
    let mut copy = col().key("copy").grow(1.0).shrink().min_w(0.0).gap(2.0).child(title).child(note.key("note").truncate().w_full());
    if cur && st.changed {
        copy = copy.child(
            row()
                .key("changed")
                .gap(6.0)
                .center_y()
                .pt(2.0)
                .child(icon(&icons::DOT, 6.0).key("d").color(warn(k)))
                .child(text("Unsaved changes").key("t").font(k.ty.small_medium).color(warn(k))),
        );
    }
    // What a press does: the state it is on shows the window (or starts the VM on it); another
    // one switches, which starts a stopped VM too.
    let does = match (cur, st.running) {
        (true, true) => format!("{name}, the current state: show {}", vm.title()),
        (true, false) => format!("{name}, the current state: start {} on it", vm.title()),
        (false, true) => format!("Switch to {name}"),
        (false, false) => format!("Start {} on {name}", vm.title()),
    };
    let mut r = row()
        .key(format!("state-{name}"))
        .role("button")
        .label(does)
        .description(saved.note.clone())
        .focusable(idle)
        .disabled(!idle)
        .press_on_return()
        .w_full()
        .min_h(58.0)
        .px(14.0)
        .py(10.0)
        .gap(12.0)
        .center_y()
        .child(copy);
    if idle {
        let n2 = name.clone();
        r = r.hover(c.hover).cursor(Cursor::Pointer).on_press(move |s: &mut App| s.pick(vm, &n2));
    }
    if cur && st.changed && name != "default" {
        r = r.child(
            Button::new("Save")
                .variant(ButtonVariant::Neutral)
                .control_size(ControlSize::Large)
                .icon(&oc::DOWNLOAD)
                .disabled(!idle)
                .on_press(move |s: &mut App| s.save(vm))
                .build(k)
                .key("save"),
        );
    } else {
        let mut meta = col().key("meta").items_end().gap(2.0).child(text(gb(saved.size_bytes)).key("size").font(k.ty.small).color(c.text_muted).nowrap());
        if let Some(at) = saved.saved.as_deref().and_then(parse_utc) {
            meta = meta.child(text(when(at, d.now, d.utc_offset)).key("at").font(k.ty.small).color(c.text_muted).nowrap());
        }
        r = r.child(meta);
    }
    r.child(more(s, st, saved, k, layer))
}

/// The ⋯ menu of one state.
fn more(s: &App, st: &Status, saved: &Saved, k: &Kit, layer: &mut Vec<El>) -> El {
    let vm = s.sel;
    let name = saved.state.clone();
    let cur = saved.state == st.state;
    let open = s.menu.as_deref() == Some(name.as_str());
    let idle = s.busy.is_none();
    let n = name.clone();
    let trigger = IconButton::new(&oc::OUTLINE_DOTS)
        .variant(IconButtonVariant::Ghost)
        .control_size(ControlSize::Large)
        .label(format!("More for {name}"))
        .expanded(open)
        .disabled(!idle)
        .on_press(move |s: &mut App| s.menu = if s.menu.as_deref() == Some(n.as_str()) { None } else { Some(n.clone()) })
        .build(k);
    let mut menu = Menu::new(format!("menu-{name}")).label(format!("{name} actions")).placement(rune_kit::Placement::BottomEnd).min_width(200.0).trigger(trigger).open(open).on_close(|s: &mut App| s.menu = None);
    if !cur {
        let n = name.clone();
        let words = if st.running { "Switch to this state" } else { "Start on this state" };
        menu = menu.item(MenuItem::new(words).key("m-switch").icon(&icons::SWITCH).on_select(move |s: &mut App| s.pick(vm, &n)));
    }
    if cur && st.changed && name != "default" {
        menu = menu.item(MenuItem::new("Save changes").key("m-save").icon(&oc::DOWNLOAD).on_select(move |s: &mut App| s.save(vm)));
    }
    let (n, note) = (name.clone(), saved.note.clone());
    menu = menu.item(MenuItem::new("Edit note").key("m-note").icon(&oc::EDIT).on_select(move |s: &mut App| {
        s.menu = None;
        s.dialog = Dialog::Note { vm, state: n.clone(), note: rune::TextEdit::new(&note) };
    }));
    if cur && !st.running && name != "default" {
        let n = name.clone();
        menu = menu.item(MenuItem::new("Make it the default").key("m-default").icon(&icons::STAR).on_select(move |s: &mut App| {
            s.menu = None;
            s.dialog = Dialog::MakeDefault { vm, state: n.clone() };
        }));
    }
    if !cur && name != "default" {
        let (n, size) = (name.clone(), saved.size_bytes);
        menu = menu.separator().item(MenuItem::new("Delete").key("m-delete").icon(&oc::OUTLINE_TRASH).danger(true).on_select(move |s: &mut App| {
            s.menu = None;
            s.dialog = Dialog::Delete { vm, state: n.clone(), size, typed: rune::TextEdit::default() };
        }));
    }
    // build() keys the trigger as the menu's anchor: re-keying it would leave the popup unanchored.
    menu.build(k, layer)
}

fn under(s: &App, st: &Status, k: &Kit) -> El {
    let vm = s.sel;
    let pristine = st.state == "default" && !st.changed;
    let only = s.data.as_ref().is_some_and(|d| d.states(vm).len() < 2);
    // Nothing to click while an action runs; with one state, nothing to switch to.
    let hint = if s.busy.is_some() {
        String::new()
    } else if pristine && only {
        format!("Set {} up, then save it as a state", vm.title())
    } else if st.running {
        "Choose a state to switch to it".into()
    } else {
        format!("Choose a state to start {} on it", vm.title())
    };
    row()
        .key("under")
        .w_full()
        .center_y()
        .justify_between()
        .gap(12.0)
        // While busy there is no hint: a spacer keeps Save on the right without an empty label.
        .child(if hint.is_empty() { spacer().key("hint") } else { text(hint).key("hint").font(k.ty.small).color(k.c.text_muted).truncate().shrink() })
        .child(
            Button::new("Save as new state")
                .variant(ButtonVariant::Neutral)
                .control_size(ControlSize::Large)
                .icon(&oc::PLUS)
                .disabled(s.busy.is_some() || pristine)
                .on_press(move |s: &mut App| s.open_save_new(vm))
                .build(k)
                .key("save-new"),
        )
}

// ---------------------------------------------------------------- cards

/// The build cache: a section like the states, its fill as a row of segments.
fn cache(s: &App, d: &Snapshot, st: &Status, k: &Kit) -> El {
    let c = &k.c;
    let vm = s.sel;
    let idle = s.busy.is_none();
    let fill = d.cache(vm).and_then(|c| Some((c.used_bytes?, c.size_bytes?)));
    // One line: what it is and where the guest sees it, then how full, then Clear.
    let mut top = row()
        .key("top")
        .w_full()
        .h(28.0)
        .gap(8.0)
        .center_y()
        .child(text("Build cache").key("t").font(k.ty.ui_medium).color(c.text_base).nowrap())
        .child(text(vm.cache_path()).key("path").font(k.ty.small).color(c.text_faint).truncate().shrink())
        .child(spacer());
    let (frac, warn) = match fill {
        Some((used, size)) => {
            let frac = used as f32 / size.max(1) as f32;
            top = top.child(
                row()
                    .key("figure")
                    .gap(4.0)
                    .center_y()
                    .child(text(gb(used)).key("n").font(k.ty.ui_medium).color(c.text_base).nowrap())
                    .child(text(format!("of {}", gb(size))).key("of").font(k.ty.ui).color(c.text_muted).nowrap()),
            );
            (frac, frac > 0.9)
        }
        None => {
            top = top.child(text("Empty, made at the next start").key("figure").font(k.ty.ui).color(c.text_muted).nowrap());
            (0.0, false)
        }
    };
    if fill.is_some_and(|(used, _)| used > 0) {
        top = top.child(
            Button::new("Clear")
                .variant(ButtonVariant::Neutral)
                .control_size(ControlSize::Large)
                .disabled(!idle || st.running)
                .help(if st.running { "Shut it down to clear it" } else { "Empty the build cache, which every state shares" })
                .on_press(move |s: &mut App| s.dialog = Dialog::ClearCache { vm })
                .build(k)
                .key("clear")
                .ml(4.0),
        );
    }
    col()
        .key("cache")
        .w_full()
        .radius(8.0)
        .fill(c.layer_01)
        .border(0.5, c.border_muted)
        .px(14.0)
        .pt(12.0)
        .pb(12.0)
        .gap(10.0)
        .child(top)
        .child(segments(k, frac, warn))
}

/// A gauge in `SEGMENTS` steps: lit up to `frac`, amber when nearly full.
fn segments(k: &Kit, frac: f32, warn: bool) -> El {
    const SEGMENTS: usize = 40;
    let c = &k.c;
    let lit = (frac.clamp(0.0, 1.0) * SEGMENTS as f32).round() as usize;
    // Anything in it at all shows one segment, so a nearly empty cache doesn't read as empty.
    let lit = if frac > 0.0 { lit.max(1) } else { 0 };
    // Lit in the muted ink the disk meter uses (white would be the loudest thing on a dark
    // page); unlit a step darker than the card in light, where layer_03 all but vanishes.
    let on = if warn { self::warn(k) } else if k.dark { c.icon_muted } else { c.icon_base };
    let off = if k.dark { c.layer_03 } else { c.border_base };
    let mut bar = row().key("segments").w_full().h(10.0).gap(3.0).role("meter").label(format!("Build cache {:.0}% full", frac * 100.0));
    for i in 0..SEGMENTS {
        bar = bar.child(el().key(format!("s{i}")).grow(1.0).shrink().min_w(0.0).h_full().radius(2.0).fill(if i < lit { on } else { off }));
    }
    bar
}
