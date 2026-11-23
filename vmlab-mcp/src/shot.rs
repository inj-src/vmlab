//! `screenshot`: the VM's screen taken on the host, from QEMU's display (QMP `screendump`),
//! not by Cua Driver in the guest. It costs the guest nothing, so it stays fast when the guest
//! is busy (5-15 ms against Cua's 2-3 s on a loaded Windows), and works while the guest's
//! desktop is locked, at a UAC prompt or hung. It has no windows or elements: it is for
//! looking; Cua's get_window_state reads what is on the screen.
//!
//! Windows' picture reaches QMP through qemu-patches/0017 (egl-headless frames are read back
//! on demand); the Mac's QEMU (reims) has it already.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::catalog::Machine;

pub const NAME: &str = "screenshot";

/// Each VM's QMP socket (`VMLAB_QMP_WIN`, `VMLAB_QMP_MAC` override them).
pub fn qmp_socket(machine: Machine) -> PathBuf {
    let (var, default) = match machine {
        Machine::Win => ("VMLAB_QMP_WIN", "/vmlab/run/win-venus/qmp.sock"),
        Machine::Mac => ("VMLAB_QMP_MAC", "/vmlab/reims-dev/data/reims-ctl/vms/mac26d/qmp.sock"),
    };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| default.into())
}

/// The console to dump: Windows' only display is console 0; the Mac's display device is `gfx`
/// (as `vm gui mac` asks for it).
fn device(machine: Machine) -> Option<&'static str> {
    match machine {
        Machine::Win => None,
        Machine::Mac => Some("gfx"),
    }
}

pub fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "The VM's screen as QEMU shows it, taken on the host: 5-15 ms whatever the \
guest is doing, against seconds for Cua's capture on a busy guest, and it works on a locked \
desktop, a UAC or login screen, or a hung guest. Use it to look: what is in front, whether a \
dialog or crash appeared, whether a step took effect. It has no windows or elements; to act on \
an app read get_window_state. Its pixels are screen pixels (get_desktop_state's): a point of a \
full-size or `region` image is clicked with scope \"desktop\" at the x,y the result says. \
`region` gives a part of the screen at full size; `max_dimension` shrinks the image (cheaper to \
look at, but x,y must then be scaled back as the result says).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "machine": { "type": "string", "enum": ["win", "mac"], "description": "\"win\" or \"mac\"." },
                "region": {
                    "type": "object",
                    "description": "Only this part of the screen, in screen pixels: {x, y, width, height}. Kept at full size.",
                    "properties": {
                        "x": { "type": "integer", "minimum": 0 },
                        "y": { "type": "integer", "minimum": 0 },
                        "width": { "type": "integer", "minimum": 1 },
                        "height": { "type": "integer", "minimum": 1 }
                    },
                    "required": ["x", "y", "width", "height"],
                    "additionalProperties": false
                },
                "max_dimension": {
                    "type": "integer", "minimum": 0,
                    "description": "Long-edge limit for the image in pixels; omitted or 0 keeps the full size."
                },
                "format": {
                    "type": "string", "enum": ["png", "jpeg"],
                    "description": "\"png\" (default) or \"jpeg\" (smaller, for photos and video; blurs small text)."
                },
                "session": {
                    "type": "string",
                    "description": "The Cua session label your pixel clicks use, if any (see the result's note on get_desktop_state)."
                }
            },
            "required": ["machine"],
            "additionalProperties": false
        },
        "annotations": { "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
    })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Format {
    Png,
    Jpeg,
}

#[derive(Debug, PartialEq)]
pub struct Args {
    pub region: Option<Rect>,
    pub max_dimension: u32,
    pub format: Format,
    pub session: Option<String>,
}

pub fn parse_args(args: &serde_json::Map<String, Value>) -> Result<Args, String> {
    for k in args.keys() {
        if !["region", "max_dimension", "format", "session"].contains(&k.as_str()) {
            return Err(format!("screenshot: no argument `{k}` (region, max_dimension, format, session)"));
        }
    }
    let uint = |v: &Value, what: &str| -> Result<u32, String> {
        v.as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| format!("screenshot: {what} must be a whole number of pixels, 0 or more"))
    };
    let region = match args.get("region") {
        None | Some(Value::Null) => None,
        Some(Value::Object(r)) => {
            let get = |k: &str| r.get(k).ok_or_else(|| format!("screenshot: region needs x, y, width and height ({k} is missing)"));
            let rect = Rect {
                x: uint(get("x")?, "region.x")?,
                y: uint(get("y")?, "region.y")?,
                w: uint(get("width")?, "region.width")?,
                h: uint(get("height")?, "region.height")?,
            };
            if rect.w == 0 || rect.h == 0 {
                return Err("screenshot: region width and height must be 1 or more".into());
            }
            Some(rect)
        }
        Some(_) => return Err("screenshot: region is {x, y, width, height}".into()),
    };
    let max_dimension = match args.get("max_dimension") {
        None | Some(Value::Null) => 0,
        Some(v) => uint(v, "max_dimension")?,
    };
    let format = match args.get("format").and_then(Value::as_str) {
        None | Some("png") => Format::Png,
        Some("jpeg") | Some("jpg") => Format::Jpeg,
        Some(f) => return Err(format!("screenshot: format is \"png\" or \"jpeg\", not {f:?}")),
    };
    let session = args.get("session").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
    Ok(Args { region, max_dimension, format, session })
}

/// An RGB picture, 3 bytes a pixel, rows top to bottom.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub w: u32,
    pub h: u32,
    pub rgb: Vec<u8>,
}

/// A binary PPM (P6, max value 255), as QEMU writes it.
pub fn parse_ppm(data: &[u8]) -> Result<Frame, String> {
    let bad = || "screendump: not a PPM file".to_string();
    let mut fields = Vec::with_capacity(4);
    let mut pos = 0;
    while fields.len() < 4 {
        while data.get(pos).is_some_and(u8::is_ascii_whitespace) {
            pos += 1;
        }
        let start = pos;
        while data.get(pos).is_some_and(|b| !b.is_ascii_whitespace()) {
            pos += 1;
        }
        if start == pos {
            return Err(bad());
        }
        fields.push(std::str::from_utf8(&data[start..pos]).map_err(|_| bad())?);
    }
    pos += 1; // the one whitespace byte after the max value
    let num = |s: &str| s.parse::<u32>().map_err(|_| bad());
    if fields[0] != "P6" || num(fields[3])? != 255 {
        return Err(bad());
    }
    let (w, h) = (num(fields[1])?, num(fields[2])?);
    let len = w as usize * h as usize * 3;
    let px = data.get(pos..pos + len).ok_or_else(|| format!("screendump: PPM cut short ({w}x{h})"))?;
    Ok(Frame { w, h, rgb: px.to_vec() })
}

/// The part of `f` inside `r`, clipped to the frame. Err if `r` starts outside it.
pub fn crop(f: &Frame, r: Rect) -> Result<(Frame, Rect), String> {
    if r.x >= f.w || r.y >= f.h {
        return Err(format!(
            "screenshot: region {},{} {}x{} is outside the {}x{} screen",
            r.x, r.y, r.w, r.h, f.w, f.h
        ));
    }
    let w = r.w.min(f.w - r.x);
    let h = r.h.min(f.h - r.y);
    let mut rgb = Vec::with_capacity(w as usize * h as usize * 3);
    for row in r.y..r.y + h {
        let start = (row as usize * f.w as usize + r.x as usize) * 3;
        rgb.extend_from_slice(&f.rgb[start..start + w as usize * 3]);
    }
    Ok((Frame { w, h, rgb }, Rect { x: r.x, y: r.y, w, h }))
}

/// `f` shrunk so its long edge is at most `max` (area averaging: each output pixel is the mean
/// of the source pixels it covers, which keeps thin text lines visible). Unchanged if it fits.
pub fn shrink(f: Frame, max: u32) -> Frame {
    let long = f.w.max(f.h);
    if max == 0 || long <= max {
        return f;
    }
    let s = long as f64 / max as f64;
    let nw = ((f.w as f64 / s).round() as u32).max(1);
    let nh = ((f.h as f64 / s).round() as u32).max(1);
    // Source span [a, b) of output cell i along an axis, at least one pixel wide.
    let span = |i: u32, n: u32, full: u32| {
        let a = (i as u64 * full as u64 / n as u64) as u32;
        let b = (((i + 1) as u64 * full as u64).div_ceil(n as u64) as u32).clamp(a + 1, full);
        (a, b)
    };
    let mut rgb = vec![0u8; nw as usize * nh as usize * 3];
    for oy in 0..nh {
        let (y0, y1) = span(oy, nh, f.h);
        for ox in 0..nw {
            let (x0, x1) = span(ox, nw, f.w);
            let mut sum = [0u32; 3];
            for y in y0..y1 {
                let row = &f.rgb[(y as usize * f.w as usize + x0 as usize) * 3..(y as usize * f.w as usize + x1 as usize) * 3];
                for px in row.chunks_exact(3) {
                    sum[0] += px[0] as u32;
                    sum[1] += px[1] as u32;
                    sum[2] += px[2] as u32;
                }
            }
            let n = (x1 - x0) * (y1 - y0);
            let o = (oy as usize * nw as usize + ox as usize) * 3;
            for c in 0..3 {
                rgb[o + c] = ((sum[c] + n / 2) / n) as u8;
            }
        }
    }
    Frame { w: nw, h: nh, rgb }
}

pub fn encode(f: &Frame, format: Format) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    match format {
        Format::Png => {
            let mut e = png::Encoder::new(&mut out, f.w, f.h);
            e.set_color(png::ColorType::Rgb);
            e.set_depth(png::BitDepth::Eight);
            e.set_compression(png::Compression::Fast);
            let mut w = e.write_header().map_err(|e| format!("png: {e}"))?;
            w.write_image_data(&f.rgb).map_err(|e| format!("png: {e}"))?;
            w.finish().map_err(|e| format!("png: {e}"))?;
        }
        Format::Jpeg => {
            let (w, h) = (u16::try_from(f.w), u16::try_from(f.h));
            let (Ok(w), Ok(h)) = (w, h) else { return Err("jpeg: image too large".into()) };
            jpeg_encoder::Encoder::new(&mut out, 85)
                .encode(&f.rgb, w, h, jpeg_encoder::ColorType::Rgb)
                .map_err(|e| format!("jpeg: {e}"))?;
        }
    }
    Ok(out)
}

/// One QMP `screendump` to a PPM file under `dir`, read back and removed. QMP's socket takes
/// one client at a time (`vm gui` and the launcher's pinning use it too), so the connection is
/// held only for the dump.
pub async fn screendump(machine: Machine, dir: &Path, timeout: Duration) -> Result<Frame, String> {
    let sock = qmp_socket(machine);
    let file = dir.join(format!("shot-{}-{}.ppm", std::process::id(), next_id()));
    let run = async {
        let stream = UnixStream::connect(&sock).await.map_err(|e| {
            format!("cannot reach {machine}'s display at {} ({e}); is the VM running? (vm status)", sock.display())
        })?;
        let mut q = Qmp::new(stream);
        q.call(json!({ "execute": "qmp_capabilities" })).await?;
        let mut a = json!({ "filename": file.to_string_lossy(), "format": "ppm" });
        if let Some(d) = device(machine) {
            a["device"] = json!(d);
            a["head"] = json!(0);
        }
        q.call(json!({ "execute": "screendump", "arguments": a })).await?;
        Ok::<(), String>(())
    };
    let res = tokio::time::timeout(timeout, run).await;
    let out = match res {
        Err(_) => Err(format!(
            "{machine}'s display did not answer within {} s (another client may hold its QMP socket)",
            timeout.as_secs()
        )),
        Ok(Err(e)) if e.contains("no surface") => Err(format!(
            "{e}: this QEMU has no picture for QMP; on Windows it needs qemu-patches/0017 \
             (gpu/win3d/build-qemu.sh). `vm gui {machine} shot FILE.png` uses VNC instead"
        )),
        Ok(Err(e)) => Err(e),
        Ok(Ok(())) => {
            let f = file.clone();
            tokio::task::spawn_blocking(move || std::fs::read(&f))
                .await
                .map_err(|e| e.to_string())?
                .map_err(|e| format!("screendump file: {e}"))
                .and_then(|d| parse_ppm(&d))
        }
    };
    let _ = std::fs::remove_file(&file);
    out
}

/// A QMP connection. Lines that are neither a "return" nor an "error" (the greeting, events)
/// are skipped.
struct Qmp {
    lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    w: tokio::net::unix::OwnedWriteHalf,
}

impl Qmp {
    fn new(stream: UnixStream) -> Qmp {
        let (r, w) = stream.into_split();
        Qmp { lines: BufReader::new(r).lines(), w }
    }

    async fn call(&mut self, msg: Value) -> Result<Value, String> {
        self.w.write_all(format!("{msg}\n").as_bytes()).await.map_err(|e| format!("qmp: {e}"))?;
        loop {
            let line = self.lines.next_line().await.map_err(|e| format!("qmp: {e}"))?.ok_or("qmp: connection closed")?;
            let v: Value = serde_json::from_str(&line).map_err(|e| format!("qmp: {e}"))?;
            if let Some(e) = v.get("error") {
                return Err(format!("qmp: {}", e["desc"].as_str().unwrap_or("error")));
            }
            if let Some(r) = v.get("return") {
                return Ok(r.clone());
            }
        }
    }
}

fn next_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    N.fetch_add(1, Ordering::Relaxed)
}

/// Where the dumps go: a tmpfs (XDG_RUNTIME_DIR, else /dev/shm), never the disk.
pub fn dump_dir() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/dev/shm".into());
    base.join("vmlab-mcp")
}

pub struct Shot {
    pub bytes: Vec<u8>,
    pub mime: &'static str,
    pub text: String,
}

/// Dump, crop, shrink and encode, and the result's text: the image's mapping to screen pixels.
pub async fn take(machine: Machine, a: &Args, timeout: Duration) -> Result<Shot, String> {
    let t = Instant::now();
    let dir = dump_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let full = screendump(machine, &dir, timeout).await?;
    let (sw, sh) = (full.w, full.h);
    let (region, max, format) = (a.region, a.max_dimension, a.format);
    let (img, area) = tokio::task::spawn_blocking(move || -> Result<(Frame, Rect), String> {
        let (part, area) = match region {
            Some(r) => crop(&full, r)?,
            None => (full, Rect { x: 0, y: 0, w: sw, h: sh }),
        };
        Ok((shrink(part, max), area))
    })
    .await
    .map_err(|e| e.to_string())??;
    let (iw, ih) = (img.w, img.h);
    let bytes = tokio::task::spawn_blocking(move || encode(&img, format)).await.map_err(|e| e.to_string())??;
    let ms = t.elapsed().as_millis();
    let text = describe(sw, sh, area, iw, ih, ms);
    let mime = if format == Format::Png { "image/png" } else { "image/jpeg" };
    Ok(Shot { bytes, mime, text })
}

/// How a point of the image maps to the screen, in words an agent can follow.
pub fn describe(sw: u32, sh: u32, area: Rect, iw: u32, ih: u32, ms: u128) -> String {
    let whole = area == Rect { x: 0, y: 0, w: sw, h: sh };
    let mut s = format!("Screen {sw}x{sh}, taken on the host in {ms} ms. ");
    if whole && iw == sw {
        s += "The image is the whole screen at full size: its pixels are screen pixels.";
    } else if iw == area.w {
        s += &format!(
            "The image is the screen's region at {},{} ({}x{}), at full size: screen x = {} + image x, screen y = {} + image y.",
            area.x, area.y, area.w, area.h, area.x, area.y
        );
    } else {
        let k = area.w as f64 / iw as f64;
        let what = if whole { "the whole screen".to_string() } else { format!("the screen's region at {},{} ({}x{})", area.x, area.y, area.w, area.h) };
        let off = |o: u32| if o == 0 { String::new() } else { format!("{o} + ") };
        s += &format!(
            "The image ({iw}x{ih}) is {what}, shrunk: screen x = {}image x × {k:.4}, screen y = {}image y × {:.4}.",
            off(area.x),
            off(area.y),
            area.h as f64 / ih as f64
        );
    }
    s += " To click a screen point: click with scope \"desktop\", those x,y, no capture_id.";
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32) -> Frame {
        let mut rgb = Vec::new();
        for y in 0..h {
            for x in 0..w {
                rgb.extend_from_slice(&[x as u8, y as u8, 7]);
            }
        }
        Frame { w, h, rgb }
    }

    #[test]
    fn ppm_roundtrip() {
        let f = frame(4, 3);
        let mut data = b"P6\n4 3\n255\n".to_vec();
        data.extend_from_slice(&f.rgb);
        assert_eq!(parse_ppm(&data).unwrap(), f);
        assert!(parse_ppm(b"P5\n4 3\n255\n").is_err());
        assert!(parse_ppm(b"P6\n4 3\n255\n\x00").unwrap_err().contains("cut short"));
    }

    #[test]
    fn crop_clips_and_refuses_outside() {
        let f = frame(10, 8);
        let (c, r) = crop(&f, Rect { x: 6, y: 5, w: 10, h: 10 }).unwrap();
        assert_eq!((c.w, c.h), (4, 3));
        assert_eq!(r, Rect { x: 6, y: 5, w: 4, h: 3 });
        assert_eq!(&c.rgb[..3], &[6, 5, 7]);
        assert!(crop(&f, Rect { x: 10, y: 0, w: 1, h: 1 }).is_err());
    }

    #[test]
    fn shrink_averages_and_keeps_aspect() {
        let f = frame(1920, 1080);
        let s = shrink(f.clone(), 960);
        assert_eq!((s.w, s.h), (960, 540));
        // Output pixel 0 averages source x 0,1 and y 0,1.
        assert_eq!(&s.rgb[..3], &[1, 1, 7]);
        assert_eq!(shrink(f.clone(), 0), f);
        assert_eq!(shrink(f.clone(), 4000), f);
        let odd = shrink(frame(7, 3), 2);
        assert_eq!((odd.w, odd.h), (2, 1));
    }

    #[test]
    fn encodes() {
        let f = frame(16, 9);
        assert!(encode(&f, Format::Png).unwrap().starts_with(b"\x89PNG"));
        assert!(encode(&f, Format::Jpeg).unwrap().starts_with(&[0xff, 0xd8]));
    }

    #[test]
    fn args() {
        let m = |v: Value| v.as_object().unwrap().clone();
        let a = parse_args(&m(json!({}))).unwrap();
        assert_eq!(a, Args { region: None, max_dimension: 0, format: Format::Png, session: None });
        let a = parse_args(&m(json!({"region": {"x": 1, "y": 2, "width": 3, "height": 4}, "max_dimension": 800, "format": "jpeg", "session": "t"}))).unwrap();
        assert_eq!(a.region, Some(Rect { x: 1, y: 2, w: 3, h: 4 }));
        assert_eq!((a.max_dimension, a.format, a.session.as_deref()), (800, Format::Jpeg, Some("t")));
        assert!(parse_args(&m(json!({"region": {"x": 1}}))).is_err());
        assert!(parse_args(&m(json!({"max_dimension": -1}))).is_err());
        assert!(parse_args(&m(json!({"format": "gif"}))).is_err());
        assert!(parse_args(&m(json!({"scale": 2}))).is_err());
    }

    #[test]
    fn descriptions_map_points() {
        let full = Rect { x: 0, y: 0, w: 1920, h: 1080 };
        assert!(describe(1920, 1080, full, 1920, 1080, 9).contains("its pixels are screen pixels"));
        let r = Rect { x: 100, y: 50, w: 400, h: 300 };
        assert!(describe(1920, 1080, r, 400, 300, 9).contains("screen x = 100 + image x, screen y = 50 + image y"));
        let t = describe(1920, 1080, full, 960, 540, 9);
        assert!(t.contains("screen x = image x × 2.0000, screen y = image y × 2.0000"), "{t}");
        let t = describe(1920, 1080, r, 200, 150, 9);
        assert!(t.contains("screen x = 100 + image x × 2.0000"), "{t}");
    }

    #[test]
    fn tool_schema_is_a_valid_rmcp_tool() {
        let t: rmcp::model::Tool = serde_json::from_value(tool()).unwrap();
        assert_eq!(t.name, NAME);
    }
}
