//! The dialogs: what a switch does with unsaved changes, a delete you type the name for, a new
//! state's name and note, a note, the default, the build cache, the ports.

use rune::{El, ScrollSpec, TextEdit, col, row, text};
use rune_kit::{Button, ButtonVariant, ControlSize, Dialog as Modal, Field, Kit, TextInput};

use crate::model::{Vm, gb, valid_name};
use crate::{App, Dialog, How};

pub fn build(s: &App, k: &Kit, layer: &mut Vec<El>) {
    let Some(d) = &s.data else { return };
    let close = |s: &mut App| s.dialog = Dialog::None;
    let cancel = || button("Cancel", ButtonVariant::Ghost).on_press(close).build(k).key("cancel");
    let (key, title, desc, body): (&str, String, String, El) = match &s.dialog {
        Dialog::None => return,
        Dialog::Switch { vm, to } => {
            let (vm, to) = (*vm, to.clone());
            let Some(st) = d.status(vm) else { return };
            let then = if st.running { format!("It shuts down, then starts on {to}.") } else { format!("It starts on {to}.") };
            let (desc, actions) = if st.changed && st.state == "default" {
                (
                    format!("{} has unsaved changes on the default state, which is not saved over. Save them as a new state first, or discard them.", vm.title()),
                    vec![cancel(), discard(k, vm, &to), button("Save as new state…", ButtonVariant::Submit).on_press(move |s: &mut App| s.open_save_new(vm)).build(k).key("save-new")],
                )
            } else if st.changed {
                let t = to.clone();
                (
                    format!("{} is on {} with unsaved changes. {then}", vm.title(), st.state),
                    vec![cancel(), discard(k, vm, &to), button("Save and switch", ButtonVariant::Submit).on_press(move |s: &mut App| s.switch(vm, &t, How::Save)).build(k).key("save")],
                )
            } else {
                let t = to.clone();
                (
                    format!("{} {}", vm.title(), then.trim_start_matches("It ")),
                    vec![cancel(), button("Switch", ButtonVariant::Submit).on_press(move |s: &mut App| s.switch(vm, &t, How::Keep)).build(k).key("switch")],
                )
            };
            ("switch", format!("Switch to {to}?"), desc, form(vec![actions_row(actions)]))
        }
        Dialog::Delete { vm, state, size, typed } => {
            let (vm, name) = (*vm, state.clone());
            let ok = typed.text.trim() == name;
            let input = TextInput::new(typed).label("Type its name to confirm").placeholder(name.clone()).width(None).on_edit(field).on_submit(move |s: &mut App, _| delete_if_typed(s, vm)).build(k);
            let field = Field::new().label("Type its name to confirm").control(input).build(k).key("typed");
            let go = button(format!("Delete {name}"), ButtonVariant::Danger).disabled(!ok).on_press(move |s: &mut App| delete_if_typed(s, vm)).build(k).key("delete");
            ("delete", format!("Delete {name}?"), format!("Frees {}. A deleted state can’t be brought back.", gb(*size)), form(vec![field, actions_row(vec![cancel(), go])]))
        }
        Dialog::SaveNew { vm, name, note } => {
            let vm = *vm;
            let running = d.status(vm).is_some_and(|st| st.running);
            let taken = d.states(vm).iter().any(|st| st.state == name.text.trim());
            let problem = valid_name(name.text.trim()).err().map(str::to_owned).or_else(|| taken.then(|| format!("{} has a state of that name", vm.title())));
            let typed = !name.text.is_empty();
            let name_in = TextInput::new(name).label("Name").placeholder("lab-setup").width(None).invalid(typed && problem.is_some()).on_edit(field).on_submit(save_new).build(k);
            let hint = match &problem {
                Some(p) if typed => p.clone(),
                _ => "Up to 16 lower-case letters, digits and . _ -".into(),
            };
            let name_in = Field::new().label("Name").suffix(hint).control(name_in);
            let note_in = TextInput::new(note).label("Note").placeholder("What it has").width(None).on_edit(second_field).on_submit(save_new).build(k);
            let note_in = Field::new().label("Note (optional)").control(note_in).build(k).key("note");
            let save = button("Save", ButtonVariant::Submit).disabled(problem.is_some()).on_press_tx(save_new).build(k).key("save");
            let desc = if running {
                format!("Saves {0}’s disk as it is now. {0} keeps running; the new state boots fresh when you switch to it.", vm.title())
            } else {
                format!("Saves {}’s disk as it is now.", vm.title())
            };
            ("save-new", "Save as a new state".into(), desc, form(vec![name_in.build(k).key("name"), note_in, actions_row(vec![cancel(), save])]))
        }
        Dialog::Note { vm: _, state, note } => {
            let input = TextInput::new(note).label("Note").placeholder("What it has").width(None).on_edit(field).on_submit(|s: &mut App, _| save_note(s)).build(k);
            let input = Field::new().label("Note").control(input).build(k).key("note");
            let save = button("Save", ButtonVariant::Submit).on_press(save_note).build(k).key("save");
            ("note", format!("Note on {state}"), "Shown under its name, and in vm states.".into(), form(vec![input, actions_row(vec![cancel(), save])]))
        }
        Dialog::MakeDefault { vm, state } => {
            let vm = *vm;
            let go = button("Make it the default", ButtonVariant::Submit).on_press(move |s: &mut App| s.make_default(vm)).build(k).key("commit");
            (
                "default",
                format!("Make {state} the default?"),
                format!("Reset returns to {state} from now on. The default it has now is replaced; the other states are kept."),
                form(vec![actions_row(vec![cancel(), go])]),
            )
        }
        Dialog::ClearCache { vm } => {
            let vm = *vm;
            let go = button("Clear", ButtonVariant::Danger).on_press(move |s: &mut App| s.clear_cache(vm)).build(k).key("clear");
            (
                "cache",
                "Clear the build cache?".into(),
                format!("Empties {}: the checkouts, build output and downloads builds keep there.", vm.cache_path()),
                form(vec![actions_row(vec![cancel(), go])]),
            )
        }
        Dialog::Ports { vm } => {
            let vm = *vm;
            let Some(st) = d.status(vm) else { return };
            let mut rows = Vec::new();
            for t in &st.tunnels {
                let laptop = t.laptop;
                rows.push(port_row(k, &format!("t{laptop}"), &format!("localhost:{laptop}"), &format!("to {}’s port {}", vm.title(), t.vm), "Close", move |s: &mut App| s.close_tunnel(vm, laptop)));
            }
            if !st.forwards.is_empty() {
                // The address alone in the code font; where it is, in words under it.
                let one = st.forwards.len() == 1;
                let list = st.forwards.iter().map(|f| f.laptop.to_string()).collect::<Vec<_>>().join(", ");
                let at = st.forwards.iter().map(|f| format!("127.0.0.1:{}", f.vm)).collect::<Vec<_>>().join(", ");
                let to = format!("on {}, to this laptop’s port{} {list}", vm.title(), if one { "" } else { "s" });
                rows.push(port_row(k, "fwd", &at, &to, if one { "Close" } else { "Close all" }, move |s: &mut App| s.close_forwards(vm)));
            }
            // The connections scroll when there are more than the window holds; the footnote and
            // Done stay put under them. The 3 pt pad, taken back by the margin, keeps the scroll
            // view from clipping the buttons' edges and shadows.
            let list = col().key("list").shrink().min_h(0.0).gap(12.0).mx(-3.0).px(3.0).my(-3.0).py(3.0).scroll(ScrollSpec { stick_bottom: false }).children(rows);
            let more = text("vm tunnel and vm forward open more.").key("more").font(k.ty.small).color(k.c.text_faint);
            let done = actions_row(vec![button("Done", ButtonVariant::Neutral).on_press(close).build(k).key("done")]);
            ("ports", "Ports".into(), format!("What reaches {} and what it reaches, besides SSH.", vm.title()), form(vec![list, more, done]).shrink().min_h(0.0))
        }
    };
    let busy = s.busy.is_some();
    Modal::new(key, title).description(desc).width(440.0).fit().open(true).close_disabled(busy).on_close(close).child(body).build(k, layer);
}

fn discard(k: &Kit, vm: Vm, to: &str) -> El {
    let to = to.to_owned();
    button("Discard and switch", ButtonVariant::Danger).on_press(move |s: &mut App| s.switch(vm, &to, How::Discard)).build(k).key("discard")
}

/// A dialog's button, as tall as the window's (28 points).
fn button(label: impl Into<String>, variant: ButtonVariant) -> Button {
    Button::new(label).variant(variant).control_size(ControlSize::Large)
}

fn actions_row(buttons: Vec<El>) -> El {
    row().key("actions").w_full().pt(4.0).gap(8.0).justify_end().children(buttons)
}

fn form(children: Vec<El>) -> El {
    col().key("form").w_full().px(16.0).pb(16.0).gap(12.0).children(children)
}

fn port_row(k: &Kit, key: &str, what: &str, to: &str, label: &str, f: impl Fn(&mut App) + 'static) -> El {
    let c = &k.c;
    row()
        .key(key.to_owned())
        .w_full()
        .gap(12.0)
        .center_y()
        .child(
            col()
                .key("t")
                .grow(1.0)
                .shrink()
                .min_w(0.0)
                .gap(1.0)
                .child(text(what.to_owned()).key("a").font(k.ty.mono).color(c.text_base).truncate())
                .child(text(to.to_owned()).key("b").font(k.ty.small).color(c.text_muted).truncate()),
        )
        .child(button(label.to_owned(), ButtonVariant::Neutral).on_press(f).build(k).key("close"))
}

/// The dialog's first text field.
fn field(s: &mut App) -> &mut TextEdit {
    match &mut s.dialog {
        Dialog::SaveNew { name, .. } => name,
        Dialog::Note { note, .. } => note,
        Dialog::Delete { typed, .. } => typed,
        _ => &mut s.spare,
    }
}

fn second_field(s: &mut App) -> &mut TextEdit {
    match &mut s.dialog {
        Dialog::SaveNew { note, .. } => note,
        _ => &mut s.spare,
    }
}

fn delete_if_typed(s: &mut App, vm: Vm) {
    if let Dialog::Delete { state, typed, .. } = &s.dialog
        && typed.text.trim() == state
    {
        let name = state.clone();
        s.delete(vm, &name);
    }
}

fn save_new(s: &mut App, _: &mut rune::Tx) {
    let Dialog::SaveNew { vm, name, note } = &s.dialog else { return };
    let (vm, name, note) = (*vm, name.text.trim().to_owned(), note.text.clone());
    let taken = s.data.as_ref().is_some_and(|d| d.states(vm).iter().any(|st| st.state == name));
    if valid_name(&name).is_ok() && !taken {
        s.save_new(vm, &name, &note);
    }
}

fn save_note(s: &mut App) {
    if let Dialog::Note { vm, state, note } = &s.dialog {
        let (vm, state, note) = (*vm, state.clone(), note.text.clone());
        s.set_note(vm, &state, &note);
    }
}
