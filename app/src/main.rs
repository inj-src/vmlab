//! vmlab: the lab's two VMs and their saved states in one window. Everything it does, it does
//! through the `vm` command, off the UI thread (`worker.rs`); the window only shows what `vm`
//! says and asks it to act.

#![forbid(unsafe_code)]

mod dialogs;
mod icons;
mod model;
mod sample;
mod view;
mod worker;

use rune::{App as RuneApp, AppSpec, TextEdit};

use model::{Snapshot, Vm};
use worker::{Job, Worker};

/// An open dialog, with the fields it edits.
pub enum Dialog {
    None,
    /// Switch `vm` to the state `to`; the VM is running, or it has unsaved changes, or both.
    Switch { vm: Vm, to: String },
    SaveNew { vm: Vm, name: TextEdit, note: TextEdit },
    Note { vm: Vm, state: String, note: TextEdit },
    Delete { vm: Vm, state: String, size: u64, typed: TextEdit },
    MakeDefault { vm: Vm, state: String },
    ClearCache { vm: Vm },
    Ports { vm: Vm },
}

/// What the corner says after an action: done, or why not.
#[derive(Clone)]
pub struct Note {
    pub text: String,
    /// What `vm` said, under an error's title.
    pub detail: Option<String>,
    pub error: bool,
    pub id: u64,
}

impl Note {
    pub fn ok(text: String) -> Note {
        Note { text, detail: None, error: false, id: 0 }
    }
    pub fn error(text: String) -> Note {
        Note { text, detail: None, error: true, id: 0 }
    }
    /// `what` failed, and `vm` said `why`.
    pub fn failed(what: &str, why: String) -> Note {
        Note { text: format!("{what} failed"), detail: Some(why), error: true, id: 0 }
    }
}

/// The action that runs now: one at a time, and the window waits for it.
pub struct Busy {
    pub vm: Vm,
    pub label: String,
}

pub struct App {
    pub data: Option<Snapshot>,
    pub read_error: Option<String>,
    pub sel: Vm,
    pub busy: Option<Busy>,
    pub dialog: Dialog,
    /// The state whose ⋯ menu is open.
    pub menu: Option<String>,
    pub toast: Option<Note>,
    /// What a text field edits when its dialog has gone (never shown).
    pub spare: TextEdit,
    toasts: u64,
    worker: Option<Worker>,
    handle: Option<rune::AppHandle<App>>,
}

impl App {
    fn new() -> App {
        App {
            data: None,
            read_error: None,
            sel: Vm::Win,
            busy: None,
            dialog: Dialog::None,
            menu: None,
            toast: None,
            spare: TextEdit::default(),
            toasts: 0,
            worker: None,
            handle: None,
        }
    }

    pub fn note(&mut self, mut note: Note) {
        self.toasts += 1;
        note.id = self.toasts;
        let id = note.id;
        self.toast = Some(note);
        // It goes away by itself after a while, unless a newer one took its place.
        if let Some(handle) = self.handle.clone() {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(6));
                handle.update_if(move |s: &mut App, _| {
                    let mine = s.toast.as_ref().is_some_and(|t| t.id == id);
                    if mine {
                        s.toast = None;
                    }
                    mine
                });
            });
        }
    }

    fn run(&mut self, vm: Vm, label: &str, done: String, steps: Vec<Vec<String>>) {
        self.menu = None;
        self.dialog = Dialog::None;
        let Some(worker) = &self.worker else {
            self.note(Note::error("vmlab is not connected to vm yet".into()));
            return;
        };
        self.busy = Some(Busy { vm, label: label.into() });
        worker.run(Job { label: label.into(), steps, done });
    }

    fn cur(&self, vm: Vm) -> Option<(String, bool, bool)> {
        let s = self.data.as_ref()?.status(vm)?;
        Some((s.state.clone(), s.changed, s.running))
    }

    /// The other VM, when it runs: one VM at a time, so it shuts down first.
    fn stop_other(&self, vm: Vm) -> Vec<Vec<String>> {
        let other = vm.other();
        let runs = self.data.as_ref().and_then(|d| d.status(other)).is_some_and(|s| s.running);
        if runs { vec![args(&["stop", other.id()])] } else { vec![] }
    }

    pub fn start(&mut self, vm: Vm) {
        let mut steps = self.stop_other(vm);
        steps.push(args(&["start", vm.id(), "--window"]));
        self.run(vm, "Starting", format!("{} is running", vm.title()), steps);
    }

    pub fn show(&mut self, vm: Vm) {
        self.run(vm, "Opening its window", format!("{} is in front", vm.title()), vec![args(&["view", vm.id()])]);
    }

    pub fn stop(&mut self, vm: Vm) {
        self.run(vm, "Shutting down", format!("{} is shut down", vm.title()), vec![args(&["stop", vm.id()])]);
    }

    pub fn restart(&mut self, vm: Vm) {
        self.run(vm, "Restarting", format!("{} restarted", vm.title()), vec![args(&["restart", vm.id()])]);
    }

    /// A click on a state: the one it is on opens (or starts) the VM; another one switches,
    /// asking first when the VM runs or has changes a switch would lose.
    pub fn pick(&mut self, vm: Vm, state: &str) {
        self.menu = None;
        let Some((cur, changed, running)) = self.cur(vm) else { return };
        if state == cur {
            if running { self.show(vm) } else { self.start(vm) }
        } else if running || changed {
            self.dialog = Dialog::Switch { vm, to: state.into() };
        } else {
            self.switch(vm, state, How::Keep);
        }
    }

    pub fn switch(&mut self, vm: Vm, to: &str, how: How) {
        let Some((cur, _, running)) = self.cur(vm) else { return };
        let mut steps = Vec::new();
        if running {
            steps.push(args(&["stop", vm.id()]));
        }
        steps.extend(self.stop_other(vm));
        match how {
            How::Keep => {}
            How::Save => steps.push(args(&["save", vm.id(), &cur, "--replace"])),
            // Back to the default state, dropping the changes; the start below loads `to`.
            How::Discard => steps.push(args(&["reset", vm.id(), "--discard"])),
        }
        steps.push(args(&["start", vm.id(), to, "--window"]));
        self.run(vm, &format!("Switching to {to}"), format!("{} is running on {to}", vm.title()), steps);
    }

    /// Saves over the state it is on (a running VM's disk as it is now: the state starts with
    /// a fresh boot).
    pub fn save(&mut self, vm: Vm) {
        let Some((cur, _, running)) = self.cur(vm) else { return };
        if cur == "default" {
            return self.open_save_new(vm);
        }
        let mut a = args(&["save", vm.id(), &cur, "--replace"]);
        if running {
            a.push("--live".into());
        }
        self.run(vm, &format!("Saving {cur}"), format!("Saved {cur}"), vec![a]);
    }

    pub fn open_save_new(&mut self, vm: Vm) {
        self.menu = None;
        self.dialog = Dialog::SaveNew { vm, name: TextEdit::default(), note: TextEdit::default() };
    }

    pub fn save_new(&mut self, vm: Vm, name: &str, note: &str) {
        let running = self.cur(vm).is_some_and(|c| c.2);
        let mut a = args(&["save", vm.id(), name]);
        if running {
            a.push("--live".into());
        }
        if !note.trim().is_empty() {
            a.push(note.trim().into());
        }
        self.run(vm, &format!("Saving {name}"), format!("Saved {name}"), vec![a]);
    }

    pub fn set_note(&mut self, vm: Vm, state: &str, note: &str) {
        let a = args(&["note", vm.id(), state, note.trim()]);
        self.run(vm, "Saving the note", format!("Note on {state} saved"), vec![a]);
    }

    pub fn delete(&mut self, vm: Vm, state: &str) {
        self.run(vm, &format!("Deleting {state}"), format!("Deleted {state}"), vec![args(&["clear", vm.id(), state, "-y"])]);
    }

    pub fn make_default(&mut self, vm: Vm) {
        let a = args(&["commit", vm.id(), "--keep-states"]);
        self.run(vm, "Making it the default", "Reset now returns here".into(), vec![a]);
    }

    pub fn clear_cache(&mut self, vm: Vm) {
        let a = args(&["cache", "clear", vm.id()]);
        self.run(vm, "Clearing the build cache", "Build cache cleared".into(), vec![a]);
    }

    pub fn close_tunnel(&mut self, vm: Vm, laptop: u16) {
        let a = args(&["untunnel", &laptop.to_string()]);
        self.run(vm, "Closing the tunnel", format!("Closed localhost:{laptop}"), vec![a]);
    }

    pub fn close_forwards(&mut self, vm: Vm) {
        self.run(vm, "Closing the forwards", "Forwards closed".into(), vec![args(&["unforward", vm.id()])]);
    }
}

/// What a switch does with the changes on the state the VM leaves.
#[derive(Clone, Copy)]
pub enum How {
    Keep,
    Save,
    Discard,
}

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

fn main() {
    rune::set_app_id("vmlab");
    // One window: a second launch brings the first forward. Headless runs (`--snap`) skip it.
    let tooling = std::env::args().skip(1).any(|a| a.starts_with("--"));
    if !tooling && !rune::single_instance("lab.vmlab.app") {
        return;
    }
    let spec = AppSpec {
        min_size: Some((680.0, 460.0)),
        fonts: rune_theme_opencode::FONTS,
        families: rune_theme_opencode::FAMILIES,
        scenes: sample::SCENES,
        ..AppSpec::new("vmlab", (780.0, 560.0), App::new, view::view)
    };
    let app = RuneApp::new(spec);
    let handle = app.handle();
    app.on_ready(move |_| {
        let h = handle.clone();
        handle.update(move |s: &mut App, _| {
            s.worker = Some(Worker::start(h.clone()));
            s.handle = Some(h);
        });
    })
    // Back in the window: read everything now, in case `vm` was used elsewhere meanwhile.
    .on_focus(|s: &mut App, focused, _| {
        if focused && let Some(w) = &s.worker {
            w.refresh();
        }
    })
    .run();
}
