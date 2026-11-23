//! The lab's own tool descriptions (descriptions.md), served in place of Cua's two per-OS texts.
//!
//! Each tool entry carries a fingerprint of Cua's definitions it was written against. When Cua
//! changes a tool, its fingerprint stops matching and that tool falls back to Cua's own text, so
//! an override never describes a tool that has since changed.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde_json::{Value, json};

const SOURCE: &str = include_str!("../descriptions.md");

/// The parsed file, built once.
pub static OVERRIDES: LazyLock<Overrides> = LazyLock::new(|| Overrides::parse(SOURCE));

#[derive(Debug, Default)]
pub struct Override {
    pub fp: String,
    /// `None` keeps Cua's description.
    pub desc: Option<String>,
    /// Parameter texts. An empty text keeps Cua's, and shadows a shared one.
    pub params: HashMap<String, String>,
}

#[derive(Debug, Default)]
pub struct Overrides {
    /// `## (every tool)`: parameter texts for every listed tool that has the parameter.
    pub shared: HashMap<String, String>,
    pub tools: HashMap<String, Override>,
}

impl Overrides {
    pub fn parse(text: &str) -> Overrides {
        enum At {
            Preamble,
            Shared,
            Tool(String),
        }
        let mut out = Overrides::default();
        let mut at = At::Preamble;
        let mut param: Option<String> = None;
        let mut buf = String::new();

        let flush = |out: &mut Overrides, at: &At, param: &Option<String>, buf: &mut String| {
            let text = buf.trim().to_string();
            buf.clear();
            match (at, param) {
                (At::Preamble, _) => {}
                (At::Shared, Some(p)) => {
                    out.shared.insert(p.clone(), text);
                }
                (At::Shared, None) => {}
                (At::Tool(t), None) => {
                    let o = out.tools.get_mut(t).expect("tool entry exists");
                    o.desc = (!text.is_empty()).then_some(text);
                }
                (At::Tool(t), Some(p)) => {
                    let o = out.tools.get_mut(t).expect("tool entry exists");
                    o.params.insert(p.clone(), text);
                }
            }
        };

        for line in text.lines() {
            if let Some(head) = line.strip_prefix("## ") {
                flush(&mut out, &at, &param, &mut buf);
                param = None;
                let head = head.trim();
                if head == "(every tool)" {
                    at = At::Shared;
                } else {
                    let mut words = head.split_whitespace();
                    let name = words.next().unwrap_or_default().to_string();
                    let fp = words
                        .find_map(|w| w.strip_prefix("fp="))
                        .unwrap_or_default()
                        .to_string();
                    out.tools.insert(name.clone(), Override { fp, ..Default::default() });
                    at = At::Tool(name);
                }
            } else if let Some(p) = line.strip_prefix("### ") {
                if matches!(at, At::Preamble) {
                    continue;
                }
                flush(&mut out, &at, &param, &mut buf);
                param = Some(p.trim().to_string());
            } else if !matches!(at, At::Preamble) {
                buf.push_str(line);
                buf.push('\n');
            }
        }
        flush(&mut out, &at, &param, &mut buf);
        out
    }

    /// Apply the entry for a tool to both VMs' definitions (before they are merged), when its
    /// fingerprint matches. Returns whether it was applied.
    pub fn apply(&self, name: &str, win: &mut Option<Value>, mac: &mut Option<Value>) -> bool {
        let Some(o) = self.tools.get(name) else { return false };
        let fp = fingerprint(win.as_ref(), mac.as_ref());
        if o.fp != fp {
            tracing::warn!(tool = name, expected = %o.fp, found = %fp,
                "Cua changed this tool since descriptions.md was written; serving Cua's text");
            return false;
        }
        for def in [win.as_mut(), mac.as_mut()].into_iter().flatten() {
            let Some(obj) = def.as_object_mut() else { continue };
            if let Some(d) = &o.desc {
                obj.insert("description".into(), json!(d));
            }
            let Some(schema) = obj.get_mut("inputSchema").and_then(Value::as_object_mut) else {
                continue;
            };
            let removed = self.apply_props(o, schema, "");
            if let Some(Value::Array(req)) = schema.get_mut("required") {
                req.retain(|r| !r.as_str().is_some_and(|r| removed.contains(&r.to_string())));
            }
        }
        true
    }

    /// Set the texts of a schema's properties, and of their own properties one level down
    /// (`target.pid`). Returns the properties removed with `(remove)`.
    fn apply_props(&self, o: &Override, schema: &mut serde_json::Map<String, Value>, prefix: &str) -> Vec<String> {
        let mut removed = Vec::new();
        let Some(props) = schema.get_mut("properties").and_then(Value::as_object_mut) else {
            return removed;
        };
        for (pname, prop) in props.iter_mut() {
            let path = if prefix.is_empty() { pname.clone() } else { format!("{prefix}.{pname}") };
            let text = o.params.get(&path).or_else(|| self.shared.get(&path));
            let Some(p) = prop.as_object_mut() else { continue };
            match text.map(String::as_str) {
                Some(REMOVE) => removed.push(pname.clone()),
                Some(t) if !t.is_empty() => {
                    p.insert("description".into(), json!(t));
                }
                _ => {}
            }
            if prefix.is_empty() {
                self.apply_props(o, p, &path);
            }
        }
        props.retain(|k, _| !removed.contains(k));
        removed
    }
}

/// A parameter text that leaves the parameter out of the schema (for one Cua ignores).
pub const REMOVE: &str = "(remove)";

/// FNV-1a 64 of the canonical JSON (keys sorted) of what an override depends on: each VM's
/// description and input schema, `null` for a VM without the tool.
pub fn fingerprint(win: Option<&Value>, mac: Option<&Value>) -> String {
    let part = |t: Option<&Value>| match t {
        Some(t) => json!({
            "description": t.get("description").cloned().unwrap_or(Value::Null),
            "inputSchema": t.get("inputSchema").cloned().unwrap_or(Value::Null),
        }),
        None => Value::Null,
    };
    let mut s = String::new();
    canonical(&json!([part(win), part(mac)]), &mut s);
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// JSON with object keys sorted, whatever order the map keeps them in.
fn canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                canonical(&m[k], out);
            }
            out.push('}');
        }
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Machine, normalize, seed};

    const SAMPLE: &str = "intro\n### ignored\n\n## (every tool)\n\n### session\nShared session.\n\n\
        ## click fp=FP\nClick it.\n\nTwo lines.\n\n### x\nX text.\n\n### session\n\n\
        ## list_apps fp=FP\n\n### pid\nPid.\n";

    #[test]
    fn parses_entries() {
        let o = Overrides::parse(SAMPLE);
        assert_eq!(o.shared["session"], "Shared session.");
        let c = &o.tools["click"];
        assert_eq!(c.fp, "FP");
        assert_eq!(c.desc.as_deref(), Some("Click it.\n\nTwo lines."));
        assert_eq!(c.params["x"], "X text.");
        assert_eq!(c.params["session"], "");
        assert_eq!(o.tools["list_apps"].desc, None);
        assert!(!o.shared.contains_key("ignored"));
    }

    fn def(desc: &str) -> Value {
        json!({"name": "click", "description": desc, "inputSchema": {"type": "object",
            "properties": {"x": {"type": "number", "description": "cua x"},
                           "session": {"type": "string", "description": "cua session"},
                           "pid": {"type": "integer", "description": "cua pid"}}}})
    }

    #[test]
    fn applies_only_on_matching_fingerprint() {
        let (w, m) = (def("win text"), def("mac text"));
        let fp = fingerprint(Some(&w), Some(&m));
        let o = Overrides::parse(&SAMPLE.replace("click fp=FP", &format!("click fp={fp}")));
        let (mut win, mut mac) = (Some(w.clone()), Some(m.clone()));
        assert!(o.apply("click", &mut win, &mut mac));
        for t in [win.unwrap(), mac.unwrap()] {
            assert_eq!(t["description"], "Click it.\n\nTwo lines.");
            let p = &t["inputSchema"]["properties"];
            assert_eq!(p["x"]["description"], "X text.");
            // An empty tool-level text keeps Cua's, even over a shared one.
            assert_eq!(p["session"]["description"], "cua session");
            assert_eq!(p["pid"]["description"], "cua pid");
        }
        // Nested texts and (remove).
        let nested = json!({"name": "t", "inputSchema": {"type": "object", "required": ["old", "pid"],
            "properties": {"old": {"type": "string"}, "pid": {"type": "integer"},
                "target": {"type": "object", "properties": {"kind": {"type": "string", "description": "cua kind"}}}}}});
        let fp2 = fingerprint(Some(&nested), None);
        let o2 = Overrides::parse(&format!(
            "## (every tool)\n### target.kind\nKind.\n## t fp={fp2}\n### old\n(remove)\n"
        ));
        let (mut t, mut none) = (Some(nested), None);
        assert!(o2.apply("t", &mut t, &mut none));
        let s = &t.unwrap()["inputSchema"];
        assert_eq!(s["properties"]["target"]["properties"]["kind"]["description"], "Kind.");
        assert!(s["properties"].get("old").is_none());
        assert_eq!(s["required"], json!(["pid"]));
        // Cua changed the tool: nothing applied.
        let (mut win, mut mac) = (Some(def("new win text")), Some(m));
        assert!(!o.apply("click", &mut win, &mut mac));
        assert_eq!(win.unwrap()["description"], "new win text");
    }

    #[test]
    fn fingerprint_ignores_key_order() {
        let a = json!({"description": "d", "inputSchema": {"a": 1, "b": 2}});
        let b = json!({"inputSchema": {"b": 2, "a": 1}, "description": "d"});
        assert_eq!(fingerprint(Some(&a), None), fingerprint(Some(&b), None));
        assert_ne!(fingerprint(Some(&a), None), fingerprint(None, Some(&a)));
    }

    /// Every entry in descriptions.md must match the seeds (refresh them from the cache with
    /// `vmlab-mcp --fingerprints`'s advice) and name only parameters the tool has.
    #[test]
    fn descriptions_match_seeds() {
        let (win, mac) = (normalize(seed(Machine::Win)), normalize(seed(Machine::Mac)));
        let find = |l: &[Value], n: &str| l.iter().find(|t| t["name"] == n).cloned();
        let mut problems = Vec::new();
        for (name, o) in &OVERRIDES.tools {
            let (w, m) = (find(&win, name), find(&mac, name));
            if w.is_none() && m.is_none() {
                problems.push(format!("{name}: no such tool"));
                continue;
            }
            let fp = fingerprint(w.as_ref(), m.as_ref());
            if o.fp != fp {
                problems.push(format!("{name}: fp={} but Cua's is {fp}", o.fp));
            }
            for p in o.params.keys() {
                let has = [&w, &m].iter().any(|t| {
                    t.as_ref().is_some_and(|t| {
                        // A literal name (Cua's set_config has `cursor.badges`), or `a.b` one
                        // level down.
                        let props = &t["inputSchema"]["properties"];
                        let nested = p.split_once('.').map(|(a, b)| &props[a]["properties"][b]);
                        props.get(p).is_some() || nested.is_some_and(|n| !n.is_null())
                    })
                });
                if !has {
                    problems.push(format!("{name}: no parameter {p}"));
                }
            }
        }
        problems.sort();
        assert!(problems.is_empty(), "descriptions.md is stale:\n{}", problems.join("\n"));
    }
}
