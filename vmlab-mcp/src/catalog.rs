//! Tool catalog: per-VM Cua tool lists (cache + seed), the unified tool list served to the
//! agent, and routing of a call to one VM.
//!
//! Everything here is pure or touches only the cache directory, so it is unit-tested.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use serde_json::{Map, Value, json};

/// The VMs this server routes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Machine {
    Win,
    Mac,
}

impl Machine {

    pub fn name(self) -> &'static str {
        match self {
            Machine::Win => "win",
            Machine::Mac => "mac",
        }
    }

    pub fn parse(s: &str) -> Option<Machine> {
        match s {
            "win" => Some(Machine::Win),
            "mac" => Some(Machine::Mac),
            _ => None,
        }
    }

    pub fn other(self) -> Machine {
        match self {
            Machine::Win => Machine::Mac,
            Machine::Mac => Machine::Win,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Machine::Win => "Windows 11",
            Machine::Mac => "macOS",
        }
    }

    pub fn index(self) -> usize {
        match self {
            Machine::Win => 0,
            Machine::Mac => 1,
        }
    }
}

impl std::fmt::Display for Machine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// The argument added to every tool. It is removed again before the call is forwarded.
pub const MACHINE_ARG: &str = "machine";

/// Tool lists that shipped with the binary, used when the cache has no entry for a VM yet.
const SEED_WIN: &str = include_str!("../seed/cua-tools-win.json");
const SEED_MAC: &str = include_str!("../seed/cua-tools-mac.json");

pub fn seed(machine: Machine) -> Vec<Value> {
    let raw = match machine {
        Machine::Win => SEED_WIN,
        Machine::Mac => SEED_MAC,
    };
    serde_json::from_str(raw).expect("seed tool list is valid JSON")
}

pub fn cache_path(dir: &Path, machine: Machine) -> PathBuf {
    dir.join(format!("cua-tools-{}.json", machine.name()))
}

/// Read a VM's cached tools/list. `None` if the file is missing or unreadable.
pub fn read_cache(dir: &Path, machine: Machine) -> Option<Vec<Value>> {
    let path = cache_path(dir, machine);
    let raw = std::fs::read_to_string(&path).ok()?;
    match serde_json::from_str::<Vec<Value>>(&raw) {
        Ok(tools) if tools.iter().all(is_tool_object) => Some(tools),
        Ok(_) | Err(_) => {
            tracing::warn!(path = %path.display(), "ignoring malformed tool cache");
            None
        }
    }
}

/// Write a VM's tools/list atomically (temp file + rename), so a concurrent reader in another
/// session never sees a half-written file.
pub fn write_cache(dir: &Path, machine: Machine, tools: &[Value]) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let path = cache_path(dir, machine);
    let tmp = dir.join(format!(
        ".cua-tools-{}.json.{}.tmp",
        machine.name(),
        std::process::id()
    ));
    let body = serde_json::to_vec_pretty(tools).map_err(std::io::Error::other)?;
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// The cached list, or the seed if there is no usable cache, in normalized form.
pub fn load(dir: &Path, machine: Machine) -> Vec<Value> {
    normalize(read_cache(dir, machine).unwrap_or_else(|| seed(machine)))
}

/// Cua tools a test agent has no use for, left out of the list: driver upkeep (updates,
/// extensions, ffmpeg), deprecated or legacy tools, the agent cursor's styling, and replaying a
/// recording. Fewer names to scan under tool search. A call to one is refused as unknown.
pub const HIDDEN: &[&str] = &[
    "check_for_update",
    "install_extension",
    "install_ffmpeg",
    "escalate_session",
    "get_session_state",
    "page",
    "set_agent_cursor_enabled",
    "set_agent_cursor_motion",
    "set_agent_cursor_theme",
    "replay_trajectory",
];

/// Round-trip tools through rmcp's `Tool`, the form they are served in. Non-standard fields
/// (Cua adds `capabilities` and `risk`) drop out, so lists from different sources compare equal.
/// The `HIDDEN` tools drop out here too.
pub fn normalize(tools: Vec<Value>) -> Vec<Value> {
    tools
        .into_iter()
        .filter(|t| !HIDDEN.contains(&tool_name(t)))
        .filter_map(|t| match serde_json::from_value::<rmcp::model::Tool>(t) {
            Ok(tool) => serde_json::to_value(tool).ok(),
            Err(e) => {
                tracing::warn!("skipping malformed tool definition: {e}");
                None
            }
        })
        .collect()
}

fn is_tool_object(v: &Value) -> bool {
    v.get("name").and_then(Value::as_str).is_some()
}

fn tool_name(v: &Value) -> &str {
    v.get("name").and_then(Value::as_str).unwrap_or_default()
}

/// The cache files' lists in memory, re-read only when a file changes (size or mtime), for
/// example because another session reconnected and refreshed it.
pub struct DiskCache {
    dir: PathBuf,
    entries: Mutex<[Option<(Stamp, Arc<Vec<Value>>)>; 2]>,
}

type Stamp = Option<(SystemTime, u64)>;

fn stamp(path: &Path) -> Stamp {
    let m = std::fs::metadata(path).ok()?;
    Some((m.modified().unwrap_or(SystemTime::UNIX_EPOCH), m.len()))
}

impl DiskCache {
    pub fn new(dir: PathBuf) -> DiskCache {
        DiskCache { dir, entries: Mutex::new([None, None]) }
    }

    /// The cached list for `machine` (or the seed), in normalized form.
    pub fn get(&self, machine: Machine) -> Arc<Vec<Value>> {
        let now = stamp(&cache_path(&self.dir, machine));
        let mut entries = self.entries.lock().unwrap();
        if let Some((s, list)) = &entries[machine.index()] {
            if *s == now {
                return list.clone();
            }
        }
        let list = Arc::new(load(&self.dir, machine));
        entries[machine.index()] = Some((now, list.clone()));
        list
    }
}

/// Both VMs' tool lists, indexed by `Machine::index`.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    pub lists: [Arc<Vec<Value>>; 2],
}

impl Catalog {

    pub fn has(&self, machine: Machine, tool: &str) -> bool {
        self.lists[machine.index()].iter().any(|t| tool_name(t) == tool)
    }

    /// The unified list served to the agent: every tool once, each with a required `machine`
    /// argument. Order: the win list, then tools only mac has.
    pub fn unified(&self) -> Vec<Value> {
        let [win, mac] = [&self.lists[0][..], &self.lists[1][..]];
        let find = |list: &[Value], name: &str| list.iter().find(|t| tool_name(t) == name).cloned();
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for t in win.iter().chain(mac.iter()) {
            let name = tool_name(t);
            if !seen.insert(name.to_string()) {
                continue;
            }
            out.push(match (find(win, name), find(mac, name)) {
                (Some(w), Some(m)) => merge_both(w, m),
                (Some(w), None) => only_on(w, Machine::Win),
                (None, Some(m)) => only_on(m, Machine::Mac),
                (None, None) => unreachable!(),
            });
        }
        out
    }
}

fn machine_property(only: Option<Machine>) -> Value {
    let desc = match only {
        None => "Which VM to run this on: \"win\" (Windows 11) or \"mac\" (macOS). The VM must already be running (`vm start <name>`).".to_string(),
        Some(m) => format!(
            "Which VM to run this on. This tool exists only on {} (\"{}\"); \"{}\" returns an error.",
            m.label(),
            m.name(),
            m.other().name()
        ),
    };
    json!({"type": "string", "enum": ["win", "mac"], "description": desc})
}

/// Add the required `machine` property to an input schema. Existing properties keep their order
/// after `machine`; an existing `machine` property (none today) would be replaced.
fn add_machine(schema: &Value, only: Option<Machine>) -> Value {
    let mut schema = schema.as_object().cloned().unwrap_or_default();
    schema.insert("type".into(), json!("object"));
    let mut props = Map::new();
    props.insert(MACHINE_ARG.into(), machine_property(only));
    if let Some(Value::Object(old)) = schema.get("properties") {
        if old.contains_key(MACHINE_ARG) {
            tracing::warn!("upstream tool already has a `machine` property; it is shadowed");
        }
        for (k, v) in old {
            if k != MACHINE_ARG {
                props.insert(k.clone(), v.clone());
            }
        }
    }
    schema.insert("properties".into(), Value::Object(props));
    let mut required = vec![json!(MACHINE_ARG)];
    if let Some(Value::Array(old)) = schema.get("required") {
        required.extend(old.iter().filter(|r| r.as_str() != Some(MACHINE_ARG)).cloned());
    }
    schema.insert("required".into(), Value::Array(required));
    Value::Object(schema)
}

fn only_on(mut tool: Value, machine: Machine) -> Value {
    let note = format!("[{} only: call with machine=\"{}\".]", machine.label(), machine.name());
    let desc = match tool.get("description").and_then(Value::as_str) {
        Some(d) if !d.is_empty() => format!("{note} {d}"),
        _ => note,
    };
    let schema = add_machine(tool.get("inputSchema").unwrap_or(&json!({})), Some(machine));
    let obj = tool.as_object_mut().expect("tool is an object");
    obj.insert("description".into(), json!(desc));
    obj.insert("inputSchema".into(), schema);
    tool
}

/// A tool both VMs have. The win definition is the base. Where mac differs:
/// - description: mac's text is appended under "On macOS:" (Cua's descriptions name the OS).
/// - input properties only one VM has are added and marked "(win only)" / "(mac only)".
/// - `required` keeps only the fields both VMs require; the rest say who requires them.
fn merge_both(win: Value, mac: Value) -> Value {
    let mut tool = win.clone();
    let wd = win.get("description").and_then(Value::as_str).unwrap_or_default();
    let md = mac.get("description").and_then(Value::as_str).unwrap_or_default();
    let desc = if wd == md || md.is_empty() {
        wd.to_string()
    } else if wd.is_empty() {
        md.to_string()
    } else {
        format!("On Windows: {wd}\n\nOn macOS: {md}")
    };

    let empty = json!({});
    let ws = win.get("inputSchema").unwrap_or(&empty);
    let ms = mac.get("inputSchema").unwrap_or(&empty);
    let schema = merge_schema(ws, ms);

    let obj = tool.as_object_mut().expect("tool is an object");
    obj.insert("description".into(), json!(desc));
    obj.insert("inputSchema".into(), add_machine(&schema, None));
    match merge_annotations(win.get("annotations"), mac.get("annotations")) {
        Some(a) => obj.insert("annotations".into(), a),
        None => obj.remove("annotations"),
    };
    tool
}

/// Behaviour hints that hold on both VMs. A hint is only as safe as its riskier side: read-only
/// and idempotent only if both say so, destructive and open-world if either does. A side that
/// leaves a hint out has the MCP default (readOnly false, destructive true, idempotent false,
/// openWorld true).
fn merge_annotations(w: Option<&Value>, m: Option<&Value>) -> Option<Value> {
    if w == m {
        return w.cloned();
    }
    let empty = Map::new();
    let wo = w.and_then(Value::as_object).unwrap_or(&empty);
    let mo = m.and_then(Value::as_object).unwrap_or(&empty);
    let hint = |o: &Map<String, Value>, k: &str, default: bool| {
        o.get(k).and_then(Value::as_bool).unwrap_or(default)
    };
    let mut out = Map::new();
    if let Some(t) = wo.get("title").or_else(|| mo.get("title")) {
        out.insert("title".into(), t.clone());
    }
    for (key, default, both) in [
        ("readOnlyHint", false, true),
        ("idempotentHint", false, true),
        ("destructiveHint", true, false),
        ("openWorldHint", true, false),
    ] {
        if wo.contains_key(key) || mo.contains_key(key) {
            let (a, b) = (hint(wo, key, default), hint(mo, key, default));
            out.insert(key.into(), json!(if both { a && b } else { a || b }));
        }
    }
    (!out.is_empty()).then_some(Value::Object(out))
}

fn str_set(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

fn mark(prop: &Value, note: &str) -> Value {
    let mut p = prop.clone();
    if let Some(o) = p.as_object_mut() {
        let d = o.get("description").and_then(Value::as_str).unwrap_or_default();
        let d = if d.is_empty() { note.to_string() } else { format!("{note} {d}") };
        o.insert("description".into(), json!(d));
    }
    p
}

fn os_texts(w: Option<&str>, m: Option<&str>) -> Option<String> {
    match (w.filter(|s| !s.is_empty()), m.filter(|s| !s.is_empty())) {
        (Some(w), Some(m)) if w == m => Some(w.to_string()),
        (Some(w), Some(m)) => Some(format!("On Windows: {w} On macOS: {m}")),
        (Some(w), None) => Some(format!("On Windows: {w}")),
        (None, Some(m)) => Some(format!("On macOS: {m}")),
        (None, None) => None,
    }
}

/// Merge two JSON schemas (a tool's input schema, or one property's) into one both VMs accept:
/// - `properties`: the union. A property only one VM has is marked "(win only)" / "(mac only)";
///   one both have is merged recursively.
/// - `required`: only what both require; the rest say who requires them.
/// - `description`: both texts when they differ. `enum`: the union.
/// - any other keyword the two disagree on (or only one has) is dropped, which loosens the
///   schema: Cua on the target VM still validates the call.
/// - `additionalProperties: false` stays if either side has it (every property is listed).
fn merge_schema(w: &Value, m: &Value) -> Value {
    if w == m {
        return w.clone();
    }
    let (Some(wo), Some(mo)) = (w.as_object(), m.as_object()) else {
        return json!({});
    };
    let mut out = Map::new();
    for (k, wv) in wo {
        if matches!(k.as_str(), "properties" | "required" | "description" | "additionalProperties") {
            continue;
        }
        let Some(mv) = mo.get(k) else { continue };
        let merged = if wv == mv {
            wv.clone()
        } else {
            match (k.as_str(), wv, mv) {
                ("enum", Value::Array(a), Value::Array(b)) => {
                    let mut u = a.clone();
                    u.extend(b.iter().filter(|x| !a.contains(x)).cloned());
                    Value::Array(u)
                }
                ("items", _, _) => merge_schema(wv, mv),
                _ => continue,
            }
        };
        out.insert(k.clone(), merged);
    }
    let text = |o: &Map<String, Value>| o.get("description").and_then(Value::as_str).map(str::to_owned);
    if let Some(d) = os_texts(text(wo).as_deref(), text(mo).as_deref()) {
        out.insert("description".into(), json!(d));
    }

    let wp = wo.get("properties").and_then(Value::as_object);
    let mp = mo.get("properties").and_then(Value::as_object);
    if wp.is_some() || mp.is_some() {
        let empty = Map::new();
        let (wp, mp) = (wp.unwrap_or(&empty), mp.unwrap_or(&empty));
        let mut props = Map::new();
        for (k, v) in wp {
            let v = match mp.get(k) {
                Some(mv) => merge_schema(v, mv),
                None => mark(v, "(win only)"),
            };
            props.insert(k.clone(), v);
        }
        for (k, v) in mp {
            if !wp.contains_key(k) {
                props.insert(k.clone(), mark(v, "(mac only)"));
            }
        }
        // A field required on one VM only cannot be required for both; say so in its description.
        let (wr, mr) = (str_set(wo.get("required")), str_set(mo.get("required")));
        let mut required = Vec::new();
        for k in wr.iter().chain(mr.iter()) {
            if required.contains(k) {
                continue;
            }
            match (wr.contains(k), mr.contains(k)) {
                (true, true) => required.push(k.clone()),
                (true, false) | (false, true) => {
                    let who = if wr.contains(k) { "win" } else { "mac" };
                    if let Some(p) = props.get(k).cloned() {
                        props.insert(k.clone(), mark(&p, &format!("(required on {who})")));
                    }
                }
                (false, false) => {}
            }
        }
        out.insert("properties".into(), Value::Object(props));
        if !required.is_empty() || wo.contains_key("required") || mo.contains_key("required") {
            out.insert("required".into(), json!(required));
        }
    }
    let strict = |o: &Map<String, Value>| o.get("additionalProperties") == Some(&json!(false));
    if strict(wo) || strict(mo) {
        out.insert("additionalProperties".into(), json!(false));
    } else if let (Some(a), Some(b)) = (wo.get("additionalProperties"), mo.get("additionalProperties")) {
        if a == b {
            out.insert("additionalProperties".into(), a.clone());
        }
    }
    Value::Object(out)
}

/// Split a call's arguments into the target VM and the arguments to forward (without `machine`).
pub fn route(
    args: Option<Map<String, Value>>,
) -> Result<(Machine, Map<String, Value>), String> {
    let mut args = args.unwrap_or_default();
    let machine = match args.remove(MACHINE_ARG) {
        Some(Value::String(s)) => Machine::parse(&s)
            .ok_or_else(|| format!("invalid `machine` \"{s}\": use \"win\" or \"mac\""))?,
        Some(other) => {
            return Err(format!(
                "invalid `machine` {other}: use \"win\" or \"mac\""
            ));
        }
        None => {
            return Err(
                "missing required argument `machine`: use \"win\" or \"mac\"".to_string(),
            );
        }
    };
    Ok((machine, args))
}

/// Check that `tool` exists on `machine`, with an error message an agent can act on.
/// An empty list means "unknown" (no cache, empty seed): the call is forwarded and Cua decides.
pub fn check_tool(catalog: &Catalog, machine: Machine, tool: &str) -> Result<(), String> {
    if catalog.has(machine, tool) || catalog.lists[machine.index()].is_empty() {
        return Ok(());
    }
    if catalog.has(machine.other(), tool) {
        return Err(format!(
            "tool `{tool}` exists only on {other}, not on {machine}: call it with machine=\"{other}\"",
            other = machine.other()
        ));
    }
    Err(format!("unknown tool `{tool}`"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(name: &str, desc: &str, schema: Value) -> Value {
        json!({"name": name, "description": desc, "inputSchema": schema})
    }

    fn catalog(win: Vec<Value>, mac: Vec<Value>) -> Catalog {
        Catalog { lists: [Arc::new(win), Arc::new(mac)] }
    }

    fn by_name<'a>(list: &'a [Value], name: &str) -> &'a Value {
        list.iter().find(|t| t["name"] == name).unwrap()
    }

    #[test]
    fn machine_is_added_required_and_first() {
        let schema = json!({"type": "object", "additionalProperties": false,
            "properties": {"pid": {"type": "integer"}}, "required": ["pid"]});
        let c = catalog(vec![tool("click", "Click.", schema.clone())], vec![tool("click", "Click.", schema)]);
        let u = c.unified();
        assert_eq!(u.len(), 1);
        let s = &u[0]["inputSchema"];
        assert_eq!(s["required"], json!(["machine", "pid"]));
        assert_eq!(s["properties"]["machine"]["enum"], json!(["win", "mac"]));
        assert_eq!(s["properties"].as_object().unwrap().keys().next().unwrap(), "machine");
        assert_eq!(s["additionalProperties"], json!(false));
        assert_eq!(u[0]["description"], "Click.");
    }

    #[test]
    fn schema_without_properties_gets_machine() {
        let c = catalog(vec![tool("health_report", "", json!({"type": "object"}))], vec![]);
        let s = &c.unified()[0]["inputSchema"];
        assert_eq!(s["required"], json!(["machine"]));
        assert!(s["properties"]["machine"].is_object());
    }

    #[test]
    fn union_marks_os_only_tools_and_keeps_order() {
        let e = json!({"type": "object", "properties": {}});
        let c = catalog(
            vec![tool("a", "A.", e.clone()), tool("win_only", "W.", e.clone())],
            vec![tool("a", "A.", e.clone()), tool("mac_only", "M.", e.clone())],
        );
        let u = c.unified();
        let names: Vec<_> = u.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["a", "win_only", "mac_only"]);
        let w = by_name(&u, "win_only")["description"].as_str().unwrap();
        assert!(w.starts_with("[Windows 11 only: call with machine=\"win\".] W."), "{w}");
        let m = by_name(&u, "mac_only")["description"].as_str().unwrap();
        assert!(m.starts_with("[macOS only"), "{m}");
        let mp = &by_name(&u, "mac_only")["inputSchema"]["properties"]["machine"]["description"];
        assert!(mp.as_str().unwrap().contains("exists only on macOS"));
        assert!(by_name(&u, "a")["description"] == "A.");
    }

    #[test]
    fn differing_definitions_are_merged() {
        let ws = json!({"type": "object", "additionalProperties": false,
            "properties": {"pid": {"type": "integer"}, "hwnd": {"type": "integer", "description": "Window handle."}},
            "required": ["pid", "hwnd"]});
        let ms = json!({"type": "object", "properties": {"pid": {"type": "integer"}, "bundle_id": {"type": "string"}},
            "required": ["pid"]});
        let c = catalog(vec![tool("t", "Windows text.", ws)], vec![tool("t", "Mac text.", ms)]);
        let t = &c.unified()[0];
        assert_eq!(t["description"], "On Windows: Windows text.\n\nOn macOS: Mac text.");
        let s = &t["inputSchema"];
        assert_eq!(s["required"], json!(["machine", "pid"]));
        assert_eq!(s["properties"]["hwnd"]["description"], "(required on win) (win only) Window handle.");
        assert_eq!(s["properties"]["bundle_id"]["description"], "(mac only)");
        assert_eq!(s["additionalProperties"], json!(false));
    }

    #[test]
    fn annotations_merge_conservatively() {
        let e = json!({"type": "object"});
        let with = |a: Value| json!({"name": "t", "inputSchema": e, "annotations": a});
        let c = catalog(
            vec![with(json!({"title": "T", "readOnlyHint": true, "idempotentHint": false}))],
            vec![with(json!({"readOnlyHint": false, "idempotentHint": true, "destructiveHint": false}))],
        );
        let a = &c.unified()[0]["annotations"];
        assert_eq!(a, &json!({"title": "T", "readOnlyHint": false, "idempotentHint": false, "destructiveHint": true}));
        // A side without annotations has the defaults: not read-only.
        let c = catalog(vec![with(json!({"readOnlyHint": true}))], vec![json!({"name": "t", "inputSchema": e})]);
        assert_eq!(c.unified()[0]["annotations"], json!({"readOnlyHint": false}));
        // Equal annotations are kept as they are.
        let c = catalog(vec![with(json!({"readOnlyHint": true}))], vec![with(json!({"readOnlyHint": true}))]);
        assert_eq!(c.unified()[0]["annotations"], json!({"readOnlyHint": true}));
    }

    #[test]
    fn shared_properties_merge_loosely() {
        let ws = json!({"type": "object", "properties": {
            "x": {"type": "number", "description": "Pixels.", "minimum": 0, "default": 1},
            "mode": {"type": "string", "enum": ["a", "b"]},
            "opts": {"type": "object", "properties": {"k": {"type": "string"}, "w": {"type": "string"}}, "required": ["k", "w"]},
            "same": {"type": "string", "description": "Same."}}});
        let ms = json!({"type": "object", "properties": {
            "x": {"type": "number", "description": "Points.", "minimum": 0, "default": 2},
            "mode": {"type": "string", "enum": ["b", "c"]},
            "opts": {"type": "object", "properties": {"k": {"type": "string"}}, "required": ["k"]},
            "same": {"type": "string", "description": "Same."}}});
        let c = catalog(vec![tool("t", "", ws)], vec![tool("t", "", ms)]);
        let p = &c.unified()[0]["inputSchema"]["properties"];
        assert_eq!(p["x"], json!({"type": "number", "minimum": 0, "description": "On Windows: Pixels. On macOS: Points."}));
        assert_eq!(p["mode"]["enum"], json!(["a", "b", "c"]));
        assert_eq!(p["opts"]["required"], json!(["k"]));
        assert_eq!(p["opts"]["properties"]["w"]["description"], "(required on win) (win only)");
        assert_eq!(p["same"], json!({"type": "string", "description": "Same."}));
    }

    #[test]
    fn route_strips_machine() {
        let args = json!({"machine": "mac", "pid": 3}).as_object().cloned();
        let (m, rest) = route(args).unwrap();
        assert_eq!(m, Machine::Mac);
        assert_eq!(Value::Object(rest), json!({"pid": 3}));
        let (m, rest) = route(json!({"machine": "win"}).as_object().cloned()).unwrap();
        assert_eq!(m, Machine::Win);
        assert!(rest.is_empty());
    }

    #[test]
    fn route_rejects_bad_machine() {
        assert!(route(None).unwrap_err().contains("missing required argument `machine`"));
        assert!(route(json!({"machine": "linux"}).as_object().cloned()).unwrap_err().contains("invalid `machine` \"linux\""));
        assert!(route(json!({"machine": 1}).as_object().cloned()).unwrap_err().contains("invalid `machine` 1"));
    }

    #[test]
    fn check_tool_errors() {
        let e = json!({"type": "object"});
        let c = catalog(vec![tool("a", "", e.clone()), tool("w", "", e.clone())], vec![tool("a", "", e)]);
        assert!(check_tool(&c, Machine::Mac, "a").is_ok());
        assert_eq!(
            check_tool(&c, Machine::Mac, "w").unwrap_err(),
            "tool `w` exists only on win, not on mac: call it with machine=\"win\""
        );
        assert_eq!(check_tool(&c, Machine::Win, "nope").unwrap_err(), "unknown tool `nope`");
        // Unknown list for mac (no cache, empty seed): forward and let Cua decide.
        let c = catalog(vec![tool("w", "", json!({"type": "object"}))], vec![]);
        assert!(check_tool(&c, Machine::Mac, "w").is_ok());
    }

    #[test]
    fn cache_roundtrip_and_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("sub");
        assert!(read_cache(&p, Machine::Win).is_none());
        // Fallback is the seed shipped in the binary.
        assert_eq!(load(&p, Machine::Win), normalize(seed(Machine::Win)));
        let tools = vec![tool("x", "X.", json!({"type": "object"}))];
        write_cache(&p, Machine::Win, &tools).unwrap();
        assert_eq!(read_cache(&p, Machine::Win).unwrap(), tools);
        assert!(read_cache(&p, Machine::Mac).is_none());
        // No temp files are left behind.
        let names: Vec<_> = std::fs::read_dir(&p).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names, vec![std::ffi::OsString::from("cua-tools-win.json")]);
        // A corrupt cache falls back to the seed.
        std::fs::write(cache_path(&p, Machine::Win), "{not json").unwrap();
        assert!(read_cache(&p, Machine::Win).is_none());
        assert_eq!(load(&p, Machine::Win), normalize(seed(Machine::Win)));
    }

    #[test]
    fn normalize_drops_nonstandard_fields() {
        let t = json!({"name": "a", "inputSchema": {"type": "object"}, "risk": "low", "capabilities": ["x"]});
        assert_eq!(normalize(vec![t, json!({"no": "name"})]), vec![json!({"name": "a", "inputSchema": {"type": "object"}})]);
        let hidden = json!({"name": "install_ffmpeg", "inputSchema": {"type": "object"}});
        assert_eq!(normalize(vec![hidden]), Vec::<Value>::new());
    }

    #[test]
    fn seeds_parse_and_unify() {
        let c = catalog(seed(Machine::Win), seed(Machine::Mac));
        for t in c.unified() {
            let s = &t["inputSchema"];
            assert_eq!(s["required"][0], "machine", "{}", t["name"]);
            assert!(s["properties"]["machine"].is_object());
            // Every tool must still deserialize as an rmcp Tool.
            serde_json::from_value::<rmcp::model::Tool>(t.clone()).unwrap();
        }
    }
}
