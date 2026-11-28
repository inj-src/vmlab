//! Everything that runs `vm`, off the UI thread: a reader that keeps the snapshot fresh, and a
//! runner that does one action at a time. Both land their results with `AppHandle::update`.

use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rune::AppHandle;

use crate::model::{Cache, Saved, Snapshot, Status};
use crate::{App, Note};

/// An action: `vm` runs once per step, in order, and the first step that fails ends it.
pub struct Job {
    /// What the header says while it runs, and an error's title: `Starting`.
    pub label: String,
    pub steps: Vec<Vec<String>>,
    /// What the toast says when it is done.
    pub done: String,
}

pub struct Worker {
    jobs: Sender<Job>,
    kick: Sender<()>,
}

/// How often the reader looks at `vm status`; the states and caches, which take longer to read,
/// are read every `FULL` and after each action.
const QUICK: Duration = Duration::from_secs(4);
const FULL: Duration = Duration::from_secs(60);

impl Worker {
    pub fn start(handle: AppHandle<App>) -> Worker {
        let (kick, kicks) = mpsc::channel::<()>();
        let reader = handle.clone();
        thread::Builder::new()
            .name("vm-read".into())
            .spawn(move || {
                let offset = utc_offset();
                let mut last: Option<Snapshot> = None;
                let mut full_at = Instant::now();
                let mut full = true;
                loop {
                    match read(last.as_ref().filter(|_| !full), offset) {
                        Ok(snap) => {
                            if full {
                                full_at = Instant::now();
                            }
                            if last.as_ref() != Some(&snap) {
                                let first = last.is_none();
                                last = Some(snap.clone());
                                reader.update(move |s: &mut App, tx| {
                                    if first {
                                        tx.instant();
                                    }
                                    s.data = Some(snap);
                                    s.read_error = None;
                                });
                            }
                        }
                        Err(e) => reader.update_if(move |s: &mut App, _| {
                            let changed = s.read_error.as_deref() != Some(e.as_str());
                            s.read_error = Some(e);
                            changed
                        }),
                    }
                    full = match kicks.recv_timeout(QUICK) {
                        Ok(()) => true,
                        Err(RecvTimeoutError::Timeout) => full_at.elapsed() >= FULL,
                        Err(RecvTimeoutError::Disconnected) => return,
                    };
                    while kicks.try_recv().is_ok() {}
                }
            })
            .expect("a thread");
        let (jobs, queue) = mpsc::channel::<Job>();
        let kicker = kick.clone();
        thread::Builder::new()
            .name("vm-run".into())
            .spawn(move || {
                for job in queue {
                    let result = job.steps.iter().try_for_each(|args| {
                        let r = vm(args);
                        // Each step can change what the window shows: a VM stops, then starts.
                        kicker.send(()).ok();
                        r.map(|_| ())
                    });
                    let note = match result {
                        Ok(()) => Note::ok(job.done),
                        Err(e) => Note::failed(&job.label, e),
                    };
                    kicker.send(()).ok();
                    handle.update(move |s: &mut App, _| {
                        s.busy = None;
                        s.note(note);
                    });
                }
            })
            .expect("a thread");
        Worker { jobs, kick }
    }

    pub fn run(&self, job: Job) {
        self.jobs.send(job).ok();
    }

    /// Read everything again now.
    pub fn refresh(&self) {
        self.kick.send(()).ok();
    }
}

fn vm_path() -> PathBuf {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/bin/vm")).filter(|p| p.exists()).unwrap_or_else(|| "vm".into())
}

/// Runs `vm ARGS`: its output, or the last line it printed on stderr when it fails.
fn vm(args: &[String]) -> Result<String, String> {
    let out = Command::new(vm_path())
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("vm did not run: {e}"))?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    let line = err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    let line = line.strip_prefix("vm: ").unwrap_or(line);
    Err(if line.is_empty() { format!("vm {} failed", args.join(" ")) } else { line.to_owned() })
}

/// `vm status` every time; the states, the caches and the free space only when `quick` is None.
fn read(quick: Option<&Snapshot>, utc_offset: i64) -> Result<Snapshot, String> {
    let json = |args: &[&str]| -> Result<serde_json::Value, String> {
        let out = vm(&args.iter().map(|a| a.to_string()).collect::<Vec<_>>())?;
        serde_json::from_str(&out).map_err(|e| format!("vm {}: {e}", args.join(" ")))
    };
    let status: Vec<Status> = parse::<_>(json(&["status", "--json"])?)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    // A minute at a time: what the window shows of the clock changes no faster.
    let now = now - now % 60;
    if let Some(last) = quick {
        return Ok(Snapshot { status, now, ..last.clone() });
    }
    let states: Vec<Saved> = parse::<_>(json(&["states", "--json"])?)?;
    let cache: Vec<Cache> = parse::<_>(json(&["cache", "--json"])?)?;
    let (free_bytes, disk_bytes) = disk("/vmlab");
    Ok(Snapshot { status, states, cache, free_bytes, disk_bytes, now, utc_offset })
}

fn parse<T: serde::de::DeserializeOwned>(v: serde_json::Value) -> Result<T, String> {
    serde_json::from_value(v).map_err(|e| e.to_string())
}

/// Free and total bytes of the filesystem at `path`.
fn disk(path: &str) -> (u64, u64) {
    let out = Command::new("df").args(["-B1", "--output=avail,size", path]).output();
    let text = out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let mut nums = text.lines().nth(1).unwrap_or("").split_whitespace().filter_map(|n| n.parse::<u64>().ok());
    (nums.next().unwrap_or(0), nums.next().unwrap_or(0))
}

/// The local time's offset from UTC in seconds (`date +%z`: `+0600`).
fn utc_offset() -> i64 {
    let out = Command::new("date").arg("+%z").output();
    let z = out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
    let (sign, digits) = match z.as_bytes().first() {
        Some(b'-') => (-1, &z[1..]),
        Some(b'+') => (1, &z[1..]),
        _ => return 0,
    };
    let h: i64 = digits.get(0..2).and_then(|d| d.parse().ok()).unwrap_or(0);
    let m: i64 = digits.get(2..4).and_then(|d| d.parse().ok()).unwrap_or(0);
    sign * (h * 3600 + m * 60)
}
