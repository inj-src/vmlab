//! Made-up data for headless renders (`vmlab --snap out.png --scene <name>`): the window as it
//! looks in each case, without asking `vm`.

use rune::TextEdit;

use crate::model::{Cache, Saved, Snapshot, Status, Tunnel, Vm};
use crate::{App, Busy, Dialog, Note};

type Scene = (&'static str, fn(&mut App));

pub const SCENES: &[Scene] = &[
    ("win", |s| s.data = Some(snapshot(true, true))),
    ("stopped", |s| s.data = Some(snapshot(false, false))),
    ("mac", |s| {
        s.data = Some(snapshot(true, true));
        s.sel = Vm::Mac;
    }),
    ("menu", |s| {
        s.data = Some(snapshot(true, true));
        s.menu = Some("webdev".into());
    }),
    ("switch", |s| {
        s.data = Some(snapshot(true, true));
        s.dialog = Dialog::Switch { vm: Vm::Win, to: "webdev".into() };
    }),
    ("delete", |s| {
        s.data = Some(snapshot(false, false));
        s.dialog = Dialog::Delete { vm: Vm::Win, state: "webdev".into(), size: 21_748_219_904, typed: TextEdit::new("webd") };
    }),
    ("save-new", |s| {
        s.data = Some(snapshot(true, true));
        s.dialog = Dialog::SaveNew { vm: Vm::Win, name: TextEdit::new("database"), note: TextEdit::default() };
    }),
    ("ports", |s| {
        s.data = Some(snapshot(true, true));
        s.dialog = Dialog::Ports { vm: Vm::Win };
    }),
    ("busy", |s| {
        s.data = Some(snapshot(false, false));
        s.busy = Some(Busy { vm: Vm::Win, label: "Switching to webdev".into() });
    }),
    ("toast", |s| {
        s.data = Some(snapshot(true, false));
        s.toast = Some(Note::failed("Switching to webdev", "win has changes on embedded that were not saved: save them, or start with --discard".into()));
    }),
    ("loading", |_| {}),
];

const NOW: i64 = 1_795_869_600; // 2026-11-28 12:40 UTC

fn snapshot(running: bool, changed: bool) -> Snapshot {
    let status = |vm: &str, running: bool, state: &str, changed: bool, port: u16| Status {
        vm: vm.into(),
        running,
        since: running.then(|| "2026-11-28T11:58:00Z".into()),
        window: if running { "shown".into() } else { "none".into() },
        ssh_port: port,
        state: state.into(),
        changed,
        defender: false,
        tunnels: if running { vec![Tunnel { laptop: 5173, vm: 5173 }] } else { vec![] },
        forwards: if running { vec![Tunnel { laptop: 5800, vm: 5800 }] } else { vec![] },
    };
    let saved = |vm: &str, state: &str, size: u64, at: Option<&str>, note: &str| Saved {
        vm: vm.into(),
        state: state.into(),
        size_bytes: size,
        saved: at.map(Into::into),
        loaded: false,
        changed: false,
        note: note.into(),
    };
    Snapshot {
        status: vec![status("win", running, "embedded", changed, 2222), status("mac", false, "default", false, 2227)],
        states: vec![
            saved("win", "default", 52_742_393_856, None, "what vm reset win returns to"),
            saved("win", "embedded", 22_354_079_744, Some("2026-11-28T06:42:01Z"),
                "USB passthrough. Keil MDK 5.39 + STM32F1 DFP, ST-LINK drivers, STM32CubeProgrammer 2.18, Arduino IDE 2.3.11"),
            saved("win", "webdev", 21_748_219_904, Some("2026-11-25T06:39:19Z"),
                "Every tool to build and test a desktop app: fnm/Node 24/pnpm 12, Go 1.27.4, Rust MSVC"),
            saved("mac", "default", 57_691_471_872, None, "what vm reset mac returns to"),
        ],
        cache: vec![
            Cache { vm: "win".into(), used_bytes: Some(15_200_000_000), size_bytes: Some(26_843_545_600) },
            Cache { vm: "mac".into(), used_bytes: None, size_bytes: None },
        ],
        free_bytes: 66_095_448_064,
        disk_bytes: 255_934_087_168,
        now: NOW,
        utc_offset: 6 * 3600,
    }
}

