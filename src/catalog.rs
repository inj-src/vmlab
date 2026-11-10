//! Tool catalog: per-VM Cua tool lists (cache + seed), the unified tool list served to the
//! agent, and routing of a call to one VM.
//!
//! Everything here is pure or touches only the cache directory, so it is unit-tested.

use std::path::{Path, PathBuf};

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

/// Round-trip tools through rmcp's `Tool`, the form they are served in. Non-standard fields
/// (Cua adds `capabilities` and `risk`) drop out, so lists from different sources compare equal.
pub fn normalize(tools: Vec<Value>) -> Vec<Value> {
    tools
        .into_iter()
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

/// Both VMs' tool lists, indexed by `Machine::index`.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    pub lists: [Vec<Value>; 2],
}

impl Catalog {
    pub fn load(dir: &Path) -> Catalog {
        Catalog {
            lists: [load(dir, Machine::Win), load(dir, Machine::Mac)],
        }
    }

    pub fn has(&self, machine: Machine, tool: &str) -> bool {
        self.lists[machine.index()].iter().any(|t| tool_name(t) == tool)
    }

    /// The unified list served to the agent: every tool once, each with a required `machine`
    /// argument. Order: the win list, then tools only mac has.
    pub fn unified(&self) -> Vec<Value> {
        let [win, mac] = &self.lists;
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
    let schema = if ws == ms { ws.clone() } else { merge_schemas(ws, ms) };

    let obj = tool.as_object_mut().expect("tool is an object");
    obj.insert("description".into(), json!(desc));
    obj.insert("inputSchema".into(), add_machine(&schema, None));
    tool
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

fn merge_schemas(ws: &Value, ms: &Value) -> Value {
    let mut out = ws.as_object().cloned().unwrap_or_default();
    let wp = ws.get("properties").and_then(Value::as_object).cloned().unwrap_or_default();
    let mp = ms.get("properties").and_then(Value::as_object).cloned().unwrap_or_default();
    let wr = str_set(ws.get("required"));
    let mr = str_set(ms.get("required"));

    let mut props = Map::new();
    for (k, v) in &wp {
        let v = if mp.contains_key(k) { v.clone() } else { mark(v, "(win only)") };
        props.insert(k.clone(), v);
    }
    for (k, v) in &mp {
        if !wp.contains_key(k) {
            props.insert(k.clone(), mark(v, "(mac only)"));
        }
    }
    // A field required on one VM only cannot be required for both; say so in its description.
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
    let required: Vec<Value> = required.into_iter().map(Value::String).collect();
    out.insert("properties".into(), Value::Object(props));
    out.insert("required".into(), Value::Array(required));
    // Strict on either side stays strict; every property of both sides is listed above.
    let strict = |s: &Value| s.get("additionalProperties") == Some(&json!(false));
    if strict(ws) || strict(ms) {
        out.insert("additionalProperties".into(), json!(false));
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
        Catalog { lists: [win, mac] }
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
    }

    #[test]
    fn seeds_parse_and_unify() {
        let c = Catalog { lists: [seed(Machine::Win), seed(Machine::Mac)] };
        for t in c.unified() {
            let s = &t["inputSchema"];
            assert_eq!(s["required"][0], "machine", "{}", t["name"]);
            assert!(s["properties"]["machine"].is_object());
            // Every tool must still deserialize as an rmcp Tool.
            serde_json::from_value::<rmcp::model::Tool>(t.clone()).unwrap();
        }
    }
}
