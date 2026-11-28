//! The dialogs: what a switch does with unsaved changes, a delete you type the name for, a new
//! state's name and note, a note, the default, the build cache, the ports.

use rune::{El, TextEdit, col, row, text};
use rune_kit::{Button, ButtonVariant, Dialog as Modal, Field, Kit, TextInput};

use crate::model::{Vm, gb, valid_name};
use crate::{App, Dialog, How};

pub fn build(s: &App, k: &Kit, layer: &mut Vec<El>) {
    let Some(d) = &s.data else { return };
    let close = |s: &mut App| s.dialog = Dialog::None;
    let cancel = || Button::new("Cancel").variant(ButtonVariant::Ghost).on_press(close).build(k).key("cancel");
    let (key, title, desc, body): (&str, String, String, El) = match &s.dialog {
        Dialog::None => return,
        Dialog::Switch { vm, to } => {
            let (vm, to) = (*vm, to.clone());
            let Some(st) = d.status(vm) else { return };
            let then = if st.running { format!("It shuts down, then starts on {to}.") } else { format!("It starts on {to}.") };
            let (desc, actions) = if st.changed && st.state == "default" {
                (
                    format!("{} has unsaved changes on the default state, which is not saved over. Save them as a new state first, or discard them.", vm.title()),
                    vec![cancel(), discard(k, vm, &to), Button::new("Save as new state…").variant(ButtonVariant::Contrast).on_press(move |s: &mut App| s.open_save_new(vm)).build(k).key("save-new")],
                )
            } else if st.changed {
                let t = to.clone();
                (
                    format!("{} is on {} with unsaved changes. {then}", vm.title(), st.state),
                    vec![cancel(), discard(k, vm, &to), Button::new("Save and switch").variant(ButtonVariant::Contrast).on_press(move |s: &mut App| s.switch(vm, &t, How::Save)).build(k).key("save")],
                )
            } else {
                let t = to.clone();
                (
                    format!("{} {}", vm.title(), then.trim_start_matches("It ")),
                    vec![cancel(), Button::new("Switch").variant(ButtonVariant::Contrast).on_press(move |s: &mut App| s.switch(vm, &t, How::Keep)).build(k).key("switch")],
                )
            };
            ("switch", format!("Switch to {to}?"), desc, form(vec![actions_row(actions)]))
        }
        Dialog::Delete { vm, state, size, typed } => {
            let (vm, name) = (*vm, state.clone());
            let ok = typed.text.trim() == name;
            let input = TextInput::new(typed).label("Type its name to confirm").placeholder(name.clone()).width(None).on_edit(field).on_submit(move |s: &mut App, _| delete_if_typed(s, vm)).build(k);
            let field = Field::new().label("Type its name to confirm").control(input).build(k).key("typed");
            let go = Button::new(format!("Delete {name}")).variant(ButtonVariant::Danger).disabled(!ok).on_press(move |s: &mut App| delete_if_typed(s, vm)).build(k).key("delete");
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
            let note_in = Field::new().label("Note, optional").control(note_in).build(k).key("note");
            let save = Button::new("Save").variant(ButtonVariant::Contrast).disabled(problem.is_some()).on_press_tx(save_new).build(k).key("save");
            let desc = if running {
                format!("Keeps {} as it is now. It keeps running; the state starts with a fresh boot.", vm.title())
            } else {
                format!("Keeps {}’s disk as it is now.", vm.title())
            };
            ("save-new", "Save as a new state".into(), desc, form(vec![name_in.build(k).key("name"), note_in, actions_row(vec![cancel(), save])]))
        }
        Dialog::Note { vm: _, state, note } => {
            let input = TextInput::new(note).label("Note").placeholder("What it has").width(None).on_edit(field).on_submit(|s: &mut App, _| save_note(s)).build(k);
            let input = Field::new().label("Note").control(input).build(k).key("note");
            let save = Button::new("Save").variant(ButtonVariant::Contrast).on_press(save_note).build(k).key("save");
            ("note", format!("Note on {state}"), "Shown under its name, and in vm states.".into(), form(vec![input, actions_row(vec![cancel(), save])]))
        }
        Dialog::MakeDefault { vm, state } => {
            let vm = *vm;
            let go = Button::new("Make it the default").variant(ButtonVariant::Contrast).on_press(move |s: &mut App| s.make_default(vm)).build(k).key("commit");
            (
                "default",
                format!("Make {state} the default?"),
                format!("Reset returns to {state} from now on. The default it has now is replaced; the other states are kept."),
                form(vec![actions_row(vec![cancel(), go])]),
            )
        }
        Dialog::ClearCache { vm } => {
            let vm = *vm;
            let go = Button::new("Clear").variant(ButtonVariant::Danger).on_press(move |s: &mut App| s.clear_cache(vm)).build(k).key("clear");
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
                rows.push(port_row(k, &format!("t{laptop}"), &format!("localhost:{laptop}"), &format!("{}’s port {}", vm.title(), t.vm), "Close", move |s: &mut App| s.close_tunnel(vm, laptop)));
            }
            if !st.forwards.is_empty() {
                let list = st.forwards.iter().map(|f| f.laptop.to_string()).collect::<Vec<_>>().join(", ");
                rows.push(port_row(k, "fwd", &format!("{} on the VM", st.forwards.iter().map(|f| format!("127.0.0.1:{}", f.vm)).collect::<Vec<_>>().join(", ")), &format!("this laptop’s port {list}"), "Close all", move |s: &mut App| s.close_forwards(vm)));
            }
            rows.push(text("vm tunnel and vm forward open more.").key("more").font(k.ty.small).color(k.c.text_faint));
            rows.push(actions_row(vec![Button::new("Done").variant(ButtonVariant::Neutral).on_press(close).build(k).key("done")]));
            ("ports", "Ports".into(), format!("What reaches {} and what it reaches, besides SSH.", vm.title()), form(rows))
        }
    };
    let busy = s.busy.is_some();
    Modal::new(key, title).description(desc).width(440.0).fit().open(true).close_disabled(busy).on_close(close).child(body).build(k, layer);
}

fn discard(k: &Kit, vm: Vm, to: &str) -> El {
    let to = to.to_owned();
    Button::new("Discard").variant(ButtonVariant::Ghost).on_press(move |s: &mut App| s.switch(vm, &to, How::Discard)).build(k).key("discard")
}

fn actions_row(buttons: Vec<El>) -> El {
    row().key("actions").w_full().pt(4.0).gap(8.0).justify_end().children(buttons)
}

fn form(children: Vec<El>) -> El {
    col().key("form").w_full().px(20.0).pb(16.0).gap(12.0).children(children)
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
                .child(text(format!("to {to}")).key("b").font(k.ty.small).color(c.text_muted).truncate()),
        )
        .child(Button::new(label.to_owned()).variant(ButtonVariant::Ghost).on_press(f).build(k).key("close"))
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
