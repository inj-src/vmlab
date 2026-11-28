//! What the app shows: the `vm` command's JSON (`vm status --json`, `vm states --json`,
//! `vm cache --json`) and the free space on /vmlab, read together as one `Snapshot`.

use serde::Deserialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Vm {
    #[default]
    Win,
    Mac,
}

impl Vm {
    pub const ALL: [Vm; 2] = [Vm::Win, Vm::Mac];
    /// The name `vm` takes.
    pub fn id(self) -> &'static str {
        match self {
            Vm::Win => "win",
            Vm::Mac => "mac",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Vm::Win => "Windows 11",
            Vm::Mac => "macOS 26",
        }
    }
    /// Where the guest sees its build cache.
    pub fn cache_path(self) -> &'static str {
        match self {
            Vm::Win => "C:\\cache",
            Vm::Mac => "~/cache",
        }
    }
    pub fn other(self) -> Vm {
        match self {
            Vm::Win => Vm::Mac,
            Vm::Mac => Vm::Win,
        }
    }
    fn from_id(id: &str) -> Option<Vm> {
        match id {
            "win" => Some(Vm::Win),
            "mac" => Some(Vm::Mac),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Tunnel {
    pub laptop: u16,
    pub vm: u16,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Status {
    pub vm: String,
    pub running: bool,
    /// When it started, UTC (`2026-11-28T06:42:01Z`).
    pub since: Option<String>,
    /// `shown`, `hidden` or `none`.
    pub window: String,
    pub ssh_port: u16,
    /// The saved state its disk is on.
    pub state: String,
    /// Its disk has changed since that state was saved or loaded.
    pub changed: bool,
    pub defender: bool,
    pub tunnels: Vec<Tunnel>,
    /// `vm forward`: this machine's ports on the VM's own 127.0.0.1.
    pub forwards: Vec<Tunnel>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Saved {
    pub vm: String,
    pub state: String,
    pub size_bytes: u64,
    pub saved: Option<String>,
    pub loaded: bool,
    pub changed: bool,
    pub note: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Cache {
    pub vm: String,
    pub used_bytes: Option<u64>,
    pub size_bytes: Option<u64>,
}

/// One read of everything, made off the UI thread.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Snapshot {
    pub status: Vec<Status>,
    pub states: Vec<Saved>,
    pub cache: Vec<Cache>,
    pub free_bytes: u64,
    pub disk_bytes: u64,
    /// Seconds since the epoch when it was read, and the local time's offset from UTC.
    pub now: i64,
    pub utc_offset: i64,
}

impl Snapshot {
    pub fn status(&self, vm: Vm) -> Option<&Status> {
        self.status.iter().find(|s| Vm::from_id(&s.vm) == Some(vm))
    }
    /// The VM's states: the one it is on first, `default` last, the rest newest first.
    pub fn states(&self, vm: Vm) -> Vec<&Saved> {
        let cur = self.status(vm).map(|s| s.state.as_str());
        let mut v: Vec<&Saved> = self.states.iter().filter(|s| Vm::from_id(&s.vm) == Some(vm)).collect();
        let rank = |s: &Saved| (Some(s.state.as_str()) != cur, s.state == "default");
        v.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| b.saved.cmp(&a.saved)));
        v
    }
    pub fn cache(&self, vm: Vm) -> Option<&Cache> {
        self.cache.iter().find(|c| Vm::from_id(&c.vm) == Some(vm))
    }
    pub fn running(&self) -> Option<Vm> {
        Vm::ALL.into_iter().find(|v| self.status(*v).is_some_and(|s| s.running))
    }
}

/// `21.7 GB`, in the decimal units the desktop's file manager uses.
pub fn gb(bytes: u64) -> String {
    let g = bytes as f64 / 1e9;
    if g >= 100.0 { format!("{g:.0} GB") } else if g >= 0.1 { format!("{g:.1} GB") } else { format!("{:.0} MB", bytes as f64 / 1e6) }
}

/// Seconds since the epoch for `YYYY-MM-DDTHH:MM:SSZ`.
pub fn parse_utc(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    Some(days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se)
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 of a proleptic Gregorian date.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The inverse: (year, month, day) of a day number.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// When a state was saved, in local time: `Today 06:42`, `Yesterday`, `Nov 25`, or `Nov 25, 2025`
/// in another year.
pub fn when(at: i64, now: i64, offset: i64) -> String {
    let (day, today) = ((at + offset).div_euclid(86_400), (now + offset).div_euclid(86_400));
    let secs = (at + offset).rem_euclid(86_400);
    if day == today {
        return format!("Today {:02}:{:02}", secs / 3600, secs % 3600 / 60);
    }
    if day + 1 == today {
        return "Yesterday".into();
    }
    let (y, m, d) = civil_from_days(day);
    let (ty, _, _) = civil_from_days(today);
    let month = MONTHS[(m - 1) as usize];
    if y == ty { format!("{month} {d}") } else { format!("{month} {d}, {y}") }
}

/// How long it has run: `2 min`, `42 min`, `3 h 5 min`, `2 days`.
pub fn for_how_long(secs: i64) -> String {
    let m = (secs / 60).max(0);
    match m {
        0 => "under a minute".into(),
        1..=59 => format!("{m} min"),
        60..=1439 if m % 60 == 0 => format!("{} h", m / 60),
        60..=1439 => format!("{} h {} min", m / 60, m % 60),
        _ if m < 2880 => "a day".into(),
        _ => format!("{} days", m / 1440),
    }
}

/// A name `vm save` takes: up to 16 of a-z 0-9 . _ -, starting with a letter or digit, and not
/// one of the names the lab keeps for itself.
pub fn valid_name(name: &str) -> Result<(), &'static str> {
    let ok_char = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-');
    if name.is_empty() {
        return Err("Give it a name");
    }
    if name.len() > 16 {
        return Err("Up to 16 characters");
    }
    if !name.chars().all(ok_char) {
        return Err("Lower-case letters, digits and . _ - only");
    }
    if !name.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit()) {
        return Err("Start with a letter or a digit");
    }
    if name == "default" || name == "clean" {
        return Err("That name is the lab's own");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_round_trip() {
        let t = parse_utc("2026-11-28T06:42:01Z").unwrap();
        assert_eq!(t, 1_795_848_121);
        assert_eq!(civil_from_days(t.div_euclid(86_400)), (2026, 11, 28));
        assert_eq!(when(t, t + 3600, 6 * 3600), "Today 12:42");
        assert_eq!(when(t - 3 * 86_400, t, 0), "Nov 25");
        assert_eq!(when(t - 86_400, t, 0), "Yesterday");
        assert_eq!(when(t - 400 * 86_400, t, 0), "Oct 24, 2025");
    }

    #[test]
    fn sizes_and_spans() {
        assert_eq!(gb(21_748_219_904), "21.7 GB");
        assert_eq!(gb(38_932_480), "39 MB");
        assert_eq!(gb(255_934_087_168), "256 GB");
        assert_eq!(for_how_long(42 * 60 + 5), "42 min");
        assert_eq!(for_how_long(185 * 60), "3 h 5 min");
    }

    #[test]
    fn names() {
        assert!(valid_name("pebble-2").is_ok());
        assert!(valid_name("Pebble").is_err());
        assert!(valid_name("default").is_err());
        assert!(valid_name("-x").is_err());
        assert!(valid_name("abcdefghijklmnopq").is_err());
    }
}
