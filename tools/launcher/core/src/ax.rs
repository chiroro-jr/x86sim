//! Agents' view of a phone: the screen as text (accessibility elements with stable refs) and actions on elements.
//!
//! The guest side is host/simax (libsimax.dylib, dlopened by libsimshim in every process with UIKit): each application
//! listens on `<ring dir>/x86sim-ax-<udid>-<pid>.sock` and keeps `<...>.fg` while it is on screen, so a snapshot asks
//! only the processes on screen (front app(s), SpringBoard, view services), in parallel, and never waits on a
//! suspended app. Protocol: docs/protocols/SIMAX.md.
//!
//! Refs (`@e12`) are kept per phone in `<state dir>/ax-refs.json`: an element keeps its ref across snapshots (and
//! across CLI invocations) while it is the same element (same object, else same app + role + id / label), so an agent
//! can act on a ref it saw several steps ago. Actions (tap, type, scroll, ...) settle on the frame ring (no new frame
//! for a moment) and answer with the screen that follows.
use crate::hid::{self, Hid};
use crate::instance::Instance;
use crate::ring::Ring;
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const SPRINGBOARD: &str = "com.apple.springboard";

fn is_false(b: &bool) -> bool {
    !*b
}
fn is_true(b: &bool) -> bool {
    *b
}
fn yes() -> bool {
    true
}

/// One element on screen. Frames are in screen points (UIKit's, of the current interface orientation).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct El {
    #[serde(rename = "ref")]
    pub r: String,
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub href: Option<String>,
    /// x, y, width, height
    pub frame: [f64; 4],
    #[serde(skip_serializing_if = "is_true", default = "yes")]
    pub enabled: bool,
    #[serde(skip_serializing_if = "is_false", default)]
    pub selected: bool,
    #[serde(skip_serializing_if = "is_false", default)]
    pub focused: bool,
    #[serde(skip_serializing_if = "is_false", default)]
    pub offscreen: bool,
    #[serde(skip_serializing_if = "is_false", default)]
    pub web: bool,
    /// the app (bundle id) whose process draws it
    pub app: String,
    pub pid: u32,
    /// where it is: "app", "system" (SpringBoard over everything: alerts, banners, Control Center, app switcher),
    /// "home" (home screen, dock, App Library), "status" (status bar)
    pub layer: String,
    /// the window it is in (class name)
    pub window: String,
    /// the process-local object (simax's oid): the same object keeps its ref
    pub oid: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub container: Option<String>,
}

impl El {
    pub fn center(&self, screen: (f64, f64)) -> (f64, f64) {
        // the visible part's center (a cell half under the toolbar is tapped where it shows)
        let [x, y, w, h] = self.frame;
        let (x0, y0) = (x.max(0.0), y.max(0.0));
        let (x1, y1) = ((x + w).min(screen.0), (y + h).min(screen.1));
        if x1 > x0 && y1 > y0 {
            ((x0 + x1) / 2.0, (y0 + y1) / 2.0)
        } else {
            (x + w / 2.0, y + h / 2.0)
        }
    }

    /// One line: `@e3 button "General" id=com.apple.settings.general (201,319)`
    pub fn line(&self, screen: (f64, f64)) -> String {
        let mut s = format!("@{} {}", self.r, self.role);
        if let Some(l) = &self.label {
            s += &format!(" {}", quote(l));
        }
        if let Some(v) = &self.value {
            if Some(v) != self.label.as_ref() {
                s += &format!(" value={}", quote(v));
            }
        }
        if let Some(i) = &self.id {
            if Some(i) != self.label.as_ref() {
                s += &format!(" id={i}");
            }
        }
        for (on, f) in [(!self.enabled, "disabled"), (self.selected, "selected"), (self.focused, "focused"), (self.offscreen, "offscreen")] {
            if on {
                s += &format!(" [{f}]");
            }
        }
        let (cx, cy) = self.center(screen);
        s += &format!(" ({:.0},{:.0})", cx, cy);
        s
    }
}

fn quote(s: &str) -> String {
    let t: String = s.chars().take(160).collect();
    let t = t.replace('\n', " ").replace('"', "\\\"");
    if s.chars().count() > 160 {
        format!("\"{t}…\"")
    } else {
        format!("\"{t}\"")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Snapshot {
    pub phone: String,
    /// screen size in points (the interface orientation's)
    pub screen: (f64, f64),
    /// apps on screen (bundle ids), front-most first; SpringBoard means the home screen
    pub front: Vec<String>,
    /// SpringBoard shows something over the apps (an alert, a banner, Control Center, the app switcher)
    pub overlay: bool,
    pub elements: Vec<El>,
    /// processes on screen that did not answer in time (busy main thread)
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub busy: Vec<String>,
    /// how long the snapshot took
    pub ms: u64,
    /// an app was in the middle of an animation (a push, a sheet coming up) when it answered
    #[serde(skip_serializing_if = "is_false", default)]
    pub animating: bool,
}

impl Snapshot {
    pub fn get(&self, r: &str) -> Option<&El> {
        let r = r.trim_start_matches('@');
        self.elements.iter().find(|e| e.r == r)
    }

    /// The compact text form an agent reads.
    pub fn text(&self) -> String {
        let mut out = format!(
            "phone {} · {:.0}x{:.0} pt · front {}{}\n",
            self.phone,
            self.screen.0,
            self.screen.1,
            if self.front.is_empty() { "?".into() } else { self.front.join(", ") },
            if self.overlay { " · system overlay on top" } else { "" }
        );
        let layer_rank = |l: &str| match l {
            "system" => 0,
            "app" => 1,
            "home" => 2,
            _ => 3,
        };
        let mut groups: Vec<(String, String)> = Vec::new();
        for e in &self.elements {
            let k = (e.layer.clone(), e.app.clone());
            if !groups.contains(&k) {
                groups.push(k);
            }
        }
        groups.sort_by_key(|g| layer_rank(&g.0));
        for (layer, app) in groups {
            let els: Vec<&El> = self.elements.iter().filter(|e| e.layer == layer && e.app == app).collect();
            if layer == "status" {
                let parts: Vec<String> = els
                    .iter()
                    .map(|e| match (&e.label, &e.value) {
                        (Some(l), Some(v)) => format!("{l}: {v}"),
                        (Some(l), None) => l.clone(),
                        (None, Some(v)) => v.clone(),
                        _ => String::new(),
                    })
                    .filter(|s| !s.is_empty())
                    .collect();
                out += &format!("status bar: {}\n", parts.join(" | "));
                continue;
            }
            out += &match layer.as_str() {
                "system" => format!("system ({}) on top:\n", els.first().map(|e| e.window.as_str()).unwrap_or("")),
                "home" => "home screen:\n".to_string(),
                _ => format!("app {app}:\n"),
            };
            for e in els {
                out += &e.line(self.screen);
                out.push('\n');
            }
        }
        if !self.busy.is_empty() {
            out += &format!("busy (no answer): {}\n", self.busy.join(", "));
        }
        out
    }

    /// What changed since `prev`: `+` new elements, `-` gone ones, `~` a changed label / value / state.
    pub fn diff(&self, prev: &Snapshot) -> String {
        let old: HashMap<&str, &El> = prev.elements.iter().map(|e| (e.r.as_str(), e)).collect();
        let new: HashSet<&str> = self.elements.iter().map(|e| e.r.as_str()).collect();
        let mut out = String::new();
        if self.front != prev.front {
            out += &format!("front {} -> {}\n", prev.front.join(", "), self.front.join(", "));
        }
        for e in &self.elements {
            match old.get(e.r.as_str()) {
                None => out += &format!("+ {}\n", e.line(self.screen)),
                Some(o) => {
                    let mut ch = Vec::new();
                    if o.label != e.label {
                        ch.push(format!("label {} -> {}", quote(o.label.as_deref().unwrap_or("")), quote(e.label.as_deref().unwrap_or(""))));
                    }
                    if o.value != e.value {
                        ch.push(format!("value {} -> {}", quote(o.value.as_deref().unwrap_or("")), quote(e.value.as_deref().unwrap_or(""))));
                    }
                    for (a, b, n) in [(o.enabled, e.enabled, "enabled"), (o.selected, e.selected, "selected"), (o.focused, e.focused, "focused"), (o.offscreen, e.offscreen, "offscreen")] {
                        if a != b {
                            ch.push(format!("{n} {a} -> {b}"));
                        }
                    }
                    if !ch.is_empty() {
                        out += &format!("~ @{} {} {}\n", e.r, e.role, ch.join(", "));
                    }
                }
            }
        }
        for e in &prev.elements {
            if !new.contains(e.r.as_str()) {
                out += &format!("- {}\n", e.line(prev.screen));
            }
        }
        if out.is_empty() {
            out = "no change\n".into();
        }
        out
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Talking to the guest

/// A process's reader: its socket and whether it is on screen (its .fg marker)
struct Endpoint {
    sock: PathBuf,
    fg: bool,
}

fn endpoints(inst: &Instance) -> Vec<Endpoint> {
    let dir = inst.ring.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("/tmp"));
    let pre = format!("x86sim-ax-{}-", if inst.udid.is_empty() { "phone" } else { &inst.udid });
    let mut v = Vec::new();
    for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        if let Some(rest) = n.strip_prefix(&pre).and_then(|r| r.strip_suffix(".sock")) {
            let fg = dir.join(format!("{pre}{rest}.fg")).exists();
            v.push(Endpoint { sock: e.path(), fg });
        }
    }
    v
}

fn forget(sock: &Path) {
    let _ = std::fs::remove_file(sock);
    let _ = std::fs::remove_file(sock.with_extension("fg"));
}

/// connect() that never blocks: a suspended process never accepts, and once its backlog is full a blocking connect
/// would wait forever (EAGAIN here instead)
fn connect_nb(sock: &Path) -> std::io::Result<UnixStream> {
    use std::os::fd::FromRawFd;
    use std::os::unix::ffi::OsStrExt;
    let b = sock.as_os_str().as_bytes();
    let mut a: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if b.len() >= a.sun_path.len() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "socket path too long"));
    }
    a.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (d, s) in a.sun_path.iter_mut().zip(b) {
        *d = *s as libc::c_char;
    }
    unsafe {
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let s = UnixStream::from_raw_fd(fd);
        if libc::connect(fd, &a as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t) != 0 {
            return Err(std::io::Error::last_os_error());
        }
        s.set_nonblocking(false)?;
        Ok(s)
    }
}

/// One request to one process; Ok(None): the process is gone (its socket removed)
fn ask(sock: &Path, req: &Value, timeout: Duration) -> Result<Option<Value>> {
    let mut s = match connect_nb(sock) {
        Ok(s) => s,
        Err(e) if matches!(e.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound) => {
            forget(sock);
            return Ok(None);
        }
        Err(e) => return Err(e.into()),
    };
    s.set_read_timeout(Some(timeout))?;
    s.set_write_timeout(Some(Duration::from_secs(1)))?;
    let mut r = req.clone();
    // the guest answers "busy" a little before we give up
    r["timeout"] = json!((timeout.as_secs_f64() - 0.3).max(0.2));
    s.write_all(format!("{r}\n").as_bytes())?;
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).context("no answer")?;
    if line.is_empty() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_str(&line)?))
}

/// The same request to every process on screen, in parallel
fn ask_fg(inst: &Instance, req: &Value, timeout: Duration, stuck: &HashSet<u32>) -> Vec<(PathBuf, Result<Value>)> {
    let eps: Vec<Endpoint> = endpoints(inst).into_iter().filter(|e| e.fg).collect();
    std::thread::scope(|sc| {
        let hs: Vec<_> = eps
            .iter()
            .map(|ep| {
                let req = req.clone();
                let t = if stuck.contains(&pid_of_sock(&ep.sock)) { Duration::from_millis(80) } else { timeout };
                sc.spawn(move || (ep.sock.clone(), ask(&ep.sock, &req, t)))
            })
            .collect();
        hs.into_iter()
            .filter_map(|h| h.join().ok())
            .filter_map(|(p, r)| match r {
                Ok(None) => None,
                Ok(Some(v)) => Some((p, Ok(v))),
                Err(e) => Some((p, Err(e))),
            })
            .collect()
    })
}

fn pid_of_sock(p: &Path) -> u32 {
    p.file_stem().and_then(|s| s.to_str()).and_then(|s| s.rsplit('-').next()).and_then(|s| s.parse().ok()).unwrap_or(0)
}

fn sock_of_pid(inst: &Instance, pid: u32) -> Option<PathBuf> {
    endpoints(inst).into_iter().map(|e| e.sock).find(|s| pid_of_sock(s) == pid)
}

// ---------------------------------------------------------------------------------------------------------------------
// Refs

#[derive(Serialize, Deserialize, Default)]
struct RefState {
    next: u32,
    /// the phone's boot (refs of another boot mean nothing)
    #[serde(default)]
    boot: String,
    last: Snapshot,
    /// processes on screen that did not answer last time (an extension RunningBoard suspended keeps its .fg: its
    /// threads never run); they get a short timeout until they answer again
    #[serde(default)]
    stuck: HashSet<u32>,
}

fn refs_path(inst: &Instance) -> PathBuf {
    inst.state_dir.join("ax-refs.json")
}

fn boot_id(inst: &Instance) -> String {
    // the frame ring is made anew at every boot (its ctime moves with every frame: inode and birth time)
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(&inst.ring).map(|m| format!("{}.{:?}", m.ino(), m.created().ok())).unwrap_or_default()
}

fn load_refs(inst: &Instance) -> RefState {
    let st: RefState = std::fs::read(refs_path(inst)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    if st.boot != boot_id(inst) {
        return RefState { next: 1, boot: boot_id(inst), ..Default::default() };
    }
    st
}

fn save_refs(inst: &Instance, st: &RefState) {
    let _ = std::fs::create_dir_all(&inst.state_dir);
    let tmp = refs_path(inst).with_extension("tmp");
    if std::fs::write(&tmp, serde_json::to_vec(st).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(tmp, refs_path(inst));
    }
}

/// Gives each element of `cur` the ref it had in `prev` when it is the same element: the same object (pid + oid, still
/// the same role and label or id), else the only previous element of the same app with the same role and id, else
/// with the same role and label (web content, recreated cells). New elements get new numbers.
fn assign_refs(cur: &mut [El], prev: &[El], next: &mut u32) {
    let mut used: HashSet<String> = HashSet::new();
    let key_obj = |e: &El| format!("{}|{}", e.pid, e.oid);
    let by_obj: HashMap<String, &El> = prev.iter().filter(|e| !e.web).map(|e| (key_obj(e), e)).collect();
    let mut pending = Vec::new();
    for (i, e) in cur.iter_mut().enumerate() {
        if e.web {
            pending.push(i);
            continue;
        }
        match by_obj.get(&key_obj(e)) {
            Some(p) if p.role == e.role && (p.label == e.label || (p.id.is_some() && p.id == e.id)) && !used.contains(&p.r) => {
                e.r = p.r.clone();
                used.insert(p.r.clone());
            }
            _ => pending.push(i),
        }
    }
    let unique = |cands: Vec<&El>| -> Option<String> { if cands.len() == 1 { Some(cands[0].r.clone()) } else { None } };
    let mut still = Vec::new();
    for i in pending {
        let e = &cur[i];
        let free: Vec<&El> = prev.iter().filter(|p| !used.contains(&p.r) && p.app == e.app && p.role == e.role && p.web == e.web).collect();
        let r = e
            .id
            .as_ref()
            .and_then(|id| unique(free.iter().copied().filter(|p| p.id.as_ref() == Some(id)).collect()))
            .or_else(|| {
                // the same label; when several, the nearest one
                // (two identifiers that differ are two elements: a back button named after the cell it came from)
                let same: Vec<&El> = free.iter().copied().filter(|p| p.label == e.label && p.label.is_some() && (p.id.is_none() || e.id.is_none() || p.id == e.id) && p.href == e.href).collect();
                let d = |p: &El| (p.frame[0] - e.frame[0]).abs() + (p.frame[1] - e.frame[1]).abs();
                same.into_iter().min_by(|a, b| d(a).total_cmp(&d(b))).map(|p| p.r.clone())
            });
        match r {
            Some(r) => {
                used.insert(r.clone());
                cur[i].r = r;
            }
            None => still.push(i),
        }
    }
    for i in still {
        cur[i].r = format!("e{next}");
        *next += 1;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Snapshot

#[derive(Clone, Copy, Default)]
pub struct SnapOpts {
    /// also elements scrolled out of view (in scroll views the app has loaded)
    pub all: bool,
    /// per process answer timeout
    pub timeout_ms: u64,
}

fn layer_of(bundle: &str, window: &str, class: &str) -> &'static str {
    if class.starts_with("STUIStatusBar") || class.starts_with("UIStatusBar") || window.contains("StatusBar") {
        return "status";
    }
    if bundle != SPRINGBOARD {
        return "app";
    }
    if window.contains("HomeScreen") || window.contains("Wallpaper") || window.contains("FloatingDock") || window.contains("Dock") {
        "home"
    } else {
        "system"
    }
}

fn s(v: &Value) -> Option<String> {
    v.as_str().filter(|s| !s.is_empty()).map(String::from)
}

pub fn snapshot(inst: &Instance, opt: SnapOpts) -> Result<Snapshot> {
    let t0 = Instant::now();
    let req = json!({"op": "tree", "fg": true, "all": opt.all});
    let timeout = Duration::from_millis(if opt.timeout_ms > 0 { opt.timeout_ms } else { 6000 });
    let mut st = load_refs(inst);
    let answers = ask_fg(inst, &req, timeout, &st.stuck);
    st.stuck.clear();
    if answers.is_empty() {
        bail!("{}: no app answers (is the phone running and booted to the home screen? its reader is host/simax)", inst.name);
    }
    let mut snap = Snapshot { phone: inst.name.clone(), ..Default::default() };
    let mut fronts: Vec<(u32, String, bool)> = Vec::new();
    for (sock, r) in answers {
        let v = match r {
            Ok(v) => v,
            Err(_) => {
                // no answer at all: suspended (or hung); not shown as busy, it draws nothing new either
                st.stuck.insert(pid_of_sock(&sock));
                if std::env::var_os("X86SIM_AX_DEBUG").is_some() {
                    eprintln!("ax: pid {} does not answer", pid_of_sock(&sock));
                }
                continue;
            }
        };
        let bundle = v["bundle"].as_str().unwrap_or("").to_string();
        if let Some(e) = v["error"].as_str() {
            snap.busy.push(format!("{bundle} ({e})"));
            continue;
        }
        if v["animating"].as_bool().unwrap_or(false) {
            snap.animating = true;
        }
        let state = v["state"].as_str().unwrap_or("");
        if state != "active" && state != "inactive" {
            continue;
        }
        if let Some(sc) = v["screen"].as_array() {
            snap.screen = (sc[0].as_f64().unwrap_or(0.0), sc[1].as_f64().unwrap_or(0.0));
        }
        let pid = v["pid"].as_u64().unwrap_or(0) as u32;
        let wins: Vec<String> = v["windows"].as_array().map(|a| a.iter().map(|w| w["class"].as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
        let els = v["elements"].as_array().cloned().unwrap_or_default();
        let mut has_app_content = false;
        for e in els {
            let win = e["win"].as_u64().unwrap_or(0) as usize;
            let window = wins.get(win).cloned().unwrap_or_default();
            let class = e["class"].as_str().unwrap_or("");
            let layer = layer_of(&bundle, &window, class).to_string();
            if layer == "app" || layer == "home" {
                has_app_content = true;
            }
            if layer == "system" {
                snap.overlay = true;
            }
            snap.elements.push(El {
                r: String::new(),
                role: e["role"].as_str().unwrap_or("element").to_string(),
                label: s(&e["label"]),
                value: s(&e["value"]),
                id: s(&e["id"]),
                hint: s(&e["hint"]),
                href: s(&e["href"]),
                frame: e["frame"].as_array().map(|f| [0, 1, 2, 3].map(|i| f.get(i).and_then(Value::as_f64).unwrap_or(0.0))).unwrap_or_default(),
                enabled: e["enabled"].as_bool().unwrap_or(true),
                selected: e["selected"].as_bool().unwrap_or(false),
                focused: e["focused"].as_bool().unwrap_or(false),
                offscreen: e["offscreen"].as_bool().unwrap_or(false),
                web: e["web"].as_bool().unwrap_or(false),
                app: bundle.clone(),
                pid,
                layer,
                window,
                oid: e["oid"].as_str().unwrap_or("").to_string(),
                container: s(&e["in"]),
            });
        }
        if bundle != SPRINGBOARD && has_app_content {
            fronts.push((pid, bundle.clone(), state == "active"));
        }
    }
    // active before inactive (an app under an alert)
    fronts.sort_by_key(|f| !f.2);
    snap.front = fronts.into_iter().map(|f| f.1).collect();
    if snap.front.is_empty() {
        snap.front.push(SPRINGBOARD.into());
    }
    if snap.screen.0 <= 0.0 {
        snap.screen = (inst.screen.0 as f64 / inst.scale as f64, inst.screen.1 as f64 / inst.scale as f64);
    }
    // reading order on the home screen: rows, then columns (SpringBoard lists icons by page model)
    let idx: Vec<usize> = (0..snap.elements.len()).filter(|&i| snap.elements[i].layer == "home").collect();
    let mut home: Vec<El> = idx.iter().map(|&i| snap.elements[i].clone()).collect();
    home.sort_by(|a, b| ((a.frame[1] / 20.0).round(), a.frame[0]).partial_cmp(&((b.frame[1] / 20.0).round(), b.frame[0])).unwrap_or(std::cmp::Ordering::Equal));
    for (i, e) in idx.into_iter().zip(home) {
        snap.elements[i] = e;
    }
    let mut next = st.next.max(1);
    assign_refs(&mut snap.elements, &st.last.elements, &mut next);
    snap.ms = t0.elapsed().as_millis() as u64;
    st.next = next;
    // the full picture is remembered (an --all snapshot's off-screen elements keep their refs too)
    st.last = snap.clone();
    save_refs(inst, &st);
    Ok(snap)
}

/// The last snapshot taken of the phone (for diffs and refs), if it is of this boot
pub fn last(inst: &Instance) -> Option<Snapshot> {
    let st = load_refs(inst);
    (!st.last.elements.is_empty()).then_some(st.last)
}

// ---------------------------------------------------------------------------------------------------------------------
// Finding elements

/// What an agent names: `@e3` / `e3` (a ref), `id:xyz` (an accessibility identifier), `x,y` / `x y` (a point), or
/// text (a label: exact, then prefix, then substring, case-insensitive; also matches values and identifiers)
pub enum Target {
    Ref(String),
    Id(String),
    Point(f64, f64),
    Text(String),
}

pub fn parse_target(t: &str) -> Target {
    let t = t.trim();
    if let Some(r) = t.strip_prefix('@') {
        return Target::Ref(r.to_string());
    }
    if t.len() > 1 && t.starts_with('e') && t[1..].chars().all(|c| c.is_ascii_digit()) {
        return Target::Ref(t.to_string());
    }
    if let Some(i) = t.strip_prefix("id:").or_else(|| t.strip_prefix("id=")) {
        return Target::Id(i.to_string());
    }
    let nums: Vec<f64> = t.split([',', ' ']).filter(|s| !s.is_empty()).filter_map(|s| s.parse().ok()).collect();
    if nums.len() == 2 && t.split([',', ' ']).filter(|s| !s.is_empty()).count() == 2 {
        return Target::Point(nums[0], nums[1]);
    }
    Target::Text(t.to_string())
}

fn layer_rank(l: &str) -> u8 {
    match l {
        "system" => 0,
        "app" => 1,
        "home" => 2,
        _ => 3,
    }
}

fn actionable(role: &str) -> bool {
    !matches!(role, "text" | "heading" | "image" | "element" | "webview")
}

/// Every element matching a target, best first: on screen, top layer (SpringBoard's alerts over the app), how well
/// the text matches, controls before text.
pub fn find_all<'a>(snap: &'a Snapshot, target: &Target) -> Vec<&'a El> {
    find_all_q(snap, target, u8::MAX)
}

/// find_all, text matches no worse than `worst` (0 exact label, 1 exact id / value, 2 label prefix, 3 substring)
pub fn find_all_q<'a>(snap: &'a Snapshot, target: &Target, worst: u8) -> Vec<&'a El> {
    let mut v: Vec<(u8, &El)> = Vec::new();
    for e in &snap.elements {
        let q = match target {
            Target::Ref(r) => (e.r == *r).then_some(0),
            Target::Id(i) => (e.id.as_deref() == Some(i.as_str())).then_some(0),
            Target::Point(..) => None,
            Target::Text(t) => {
                let t = t.to_lowercase();
                let l = e.label.as_deref().unwrap_or("").to_lowercase();
                let val = e.value.as_deref().unwrap_or("").to_lowercase();
                let id = e.id.as_deref().unwrap_or("").to_lowercase();
                if l == t {
                    Some(0)
                } else if id == t || val == t {
                    Some(1)
                } else if !l.is_empty() && l.starts_with(&t) {
                    Some(2)
                } else if l.contains(&t) {
                    Some(3)
                } else if val.contains(&t) {
                    Some(4)
                } else {
                    None
                }
            }
        };
        if let Some(q) = q.filter(|q| *q <= worst) {
            v.push((q, e));
        }
    }
    v.sort_by_key(|(q, e)| (e.offscreen, layer_rank(&e.layer), *q, !actionable(&e.role), e.role == "webview"));
    v.into_iter().map(|x| x.1).collect()
}

pub fn find<'a>(snap: &'a Snapshot, target: &str) -> Result<&'a El> {
    let t = parse_target(target);
    find_all(snap, &t).into_iter().next().ok_or_else(|| {
        if matches!(t, Target::Ref(_)) {
            anyhow!("no element {target} on screen now (refs come from the last snapshot; take a new one)")
        } else {
            anyhow!("nothing on screen matches {target:?}")
        }
    })
}

// ---------------------------------------------------------------------------------------------------------------------
// Acting

/// The touch / key channel to the phone, oriented like the screen the reader reports
fn hid_for(inst: &Instance) -> Hid {
    let mut h = Hid::new(&inst.sock);
    h.main_rot = inst.orientation().as_deref().and_then(hid::orientation_rot).unwrap_or(0);
    h
}

/// The newest frame's number, to settle on what a change draws (settle_since)
pub fn frame_seq(inst: &Instance) -> u64 {
    Ring::new(&inst.ring).seq()
}

/// After a change made when the newest frame was `seq0`: waits up to `first` for it to draw anything (a setting can
/// take a second before its first frame), then until the screen has been still for `quiet`, at most `max` in all
pub fn settle_since(inst: &Instance, seq0: u64, first: Duration, quiet: Duration, max: Duration) {
    let t0 = Instant::now();
    let mut ring = Ring::new(&inst.ring);
    if ring.seq() == seq0 {
        ring.wait(seq0, first);
    }
    settle(inst, quiet, max.saturating_sub(t0.elapsed()));
}

/// Waits until the screen has been still for `quiet` (no new frame), at most `max`
pub fn settle(inst: &Instance, quiet: Duration, max: Duration) {
    let mut ring = Ring::new(&inst.ring);
    let end = Instant::now() + max;
    let mut seq = ring.seq();
    // the first frame of a reaction can take a moment to come (a slow app under the translator)
    let mut q = quiet.max(Duration::from_millis(600));
    loop {
        let left = end.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        let n = ring.wait(seq, q.min(left));
        if n == seq {
            return;
        }
        seq = n;
        q = quiet;
    }
}

fn norm(snap_screen: (f64, f64), x: f64, y: f64) -> (f32, f32) {
    ((x / snap_screen.0.max(1.0)) as f32, (y / snap_screen.1.max(1.0)) as f32)
}

fn screen_of(inst: &Instance) -> (f64, f64) {
    if let Some(s) = last(inst).map(|s| s.screen).filter(|s| s.0 > 0.0) {
        return s;
    }
    let (w, h) = (inst.screen.0 as f64 / inst.scale as f64, inst.screen.1 as f64 / inst.scale as f64);
    match inst.orientation().as_deref() {
        Some("landscapeLeft" | "landscapeRight") => (h, w),
        _ => (w, h),
    }
}

/// A touch at a point (screen points), held `hold_ms` (80: a tap; 600+: a long press)
pub fn touch_at(inst: &Instance, x: f64, y: f64, hold_ms: u64) {
    let (nx, ny) = norm(screen_of(inst), x, y);
    let mut h = hid_for(inst);
    h.touch("down", nx, ny, None);
    if hold_ms > 200 {
        // a still finger keeps reporting (a digitizer does at its scan rate)
        let end = Instant::now() + Duration::from_millis(hold_ms);
        while Instant::now() < end {
            std::thread::sleep(Duration::from_millis(50));
            h.touch("move", nx, ny, None);
        }
    } else {
        std::thread::sleep(Duration::from_millis(hold_ms));
    }
    h.touch("up", nx, ny, None);
}

/// A drag from (x1, y1) to (x2, y2) in points over `ms`; `hold_ms` still at the end (no fling: a precise scroll)
pub fn drag(inst: &Instance, from: (f64, f64), to: (f64, f64), ms: u64, hold_ms: u64) {
    let scr = screen_of(inst);
    let (a, b) = (norm(scr, from.0, from.1), norm(scr, to.0, to.1));
    let mut h = hid_for(inst);
    let edge = hid::edge_at(a.0, a.1, scr.0 as u32, scr.1 as u32);
    let n = (ms / 16).max(2);
    h.touch("down", a.0, a.1, edge);
    for i in 1..=n {
        std::thread::sleep(Duration::from_millis(ms / n));
        // ease out into a hold, so UIKit sees the finger stop (no momentum)
        let f = i as f32 / n as f32;
        let f = if hold_ms > 0 { 1.0 - (1.0 - f).powi(3) } else { f };
        h.touch("move", a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, None);
    }
    let end = Instant::now() + Duration::from_millis(hold_ms);
    while Instant::now() < end {
        std::thread::sleep(Duration::from_millis(16));
        h.touch("move", b.0, b.1, None);
    }
    h.touch("up", b.0, b.1, None);
}

/// Resolves a target to an element of a fresh snapshot (a ref: of the last one, checked against the screen now)
pub fn resolve(inst: &Instance, target: &str) -> Result<(El, Snapshot)> {
    let snap = snapshot(inst, SnapOpts::default())?;
    let e = find(&snap, target)?.clone();
    Ok((e, snap))
}

#[derive(Debug, Clone, Serialize)]
pub struct Outcome {
    /// what was done, one line
    pub did: String,
    /// the screen after it settled (None when the action asked for none)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen: Option<Snapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
}

/// What an action answers with: the screen after it (full), only the changes (diff), or nothing (none)
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum After {
    Full,
    Diff,
    None,
}

impl After {
    pub fn parse(s: Option<&str>) -> After {
        match s {
            Some("diff") => After::Diff,
            Some("none") => After::None,
            _ => After::Full,
        }
    }
}

pub fn outcome(inst: &Instance, did: String, before: Option<Snapshot>, after: After) -> Outcome {
    if after == After::None {
        return Outcome { did, screen: None, diff: None };
    }
    let t0 = Instant::now();
    settle(inst, Duration::from_millis(350), Duration::from_millis(4000));
    let mut snap = snapshot(inst, SnapOpts::default());
    // still animating (a transition can pause drawing for longer than the quiet window): again, a few times
    while matches!(&snap, Ok(s) if s.animating) && t0.elapsed() < Duration::from_secs(6) {
        settle(inst, Duration::from_millis(200), Duration::from_millis(1500));
        snap = snapshot(inst, SnapOpts::default());
    }
    match snap {
        Ok(s) => {
            let diff = (after == After::Diff).then(|| before.map(|b| s.diff(&b)).unwrap_or_else(|| s.text()));
            Outcome { did, screen: Some(s), diff }
        }
        Err(e) => Outcome { did: format!("{did}; then no snapshot: {e:#}"), screen: None, diff: None },
    }
}

impl Outcome {
    pub fn text(&self) -> String {
        let mut s = self.did.clone();
        s.push('\n');
        if let Some(d) = &self.diff {
            s += d;
        } else if let Some(sc) = &self.screen {
            s += &sc.text();
        }
        s
    }
}

/// Tap an element (ref, id:, text) or a point ("x y")
pub fn tap(inst: &Instance, target: &str, hold_ms: u64, after: After) -> Result<Outcome> {
    let (x, y, what, before) = match parse_target(target) {
        Target::Point(x, y) => (x, y, format!("({x:.0},{y:.0})"), last(inst)),
        _ => {
            let (mut e, mut snap) = resolve(inst, target)?;
            if e.offscreen {
                scroll_into_view(inst, &e)?;
                let s2 = snapshot(inst, SnapOpts::default())?;
                e = find(&s2, &format!("@{}", e.r)).cloned().or_else(|_| find(&s2, target).cloned())?;
                snap = s2;
            }
            let (x, y) = e.center(snap.screen);
            (x, y, format!("@{} {} {}", e.r, e.role, e.label.as_deref().map(quote).unwrap_or_default()), Some(snap))
        }
    };
    touch_at(inst, x, y, hold_ms);
    let verb = if hold_ms >= 500 { "long-pressed" } else { "tapped" };
    if hold_ms < 500 && what.contains(" icon ") && after != After::None {
        // an app icon: the answer is the app, once it is in front (its first frames can take seconds to come)
        wait_front_change(inst, before.as_ref().map(|b| b.front.clone()).unwrap_or_default(), Duration::from_secs(10));
    }
    Ok(outcome(inst, format!("{verb} {what} at ({x:.0},{y:.0})"), before, after))
}

/// Waits (on new frames) until `bundle` is in front, showing something
fn wait_front_is(inst: &Instance, bundle: &str, timeout: Duration) {
    let t0 = Instant::now();
    let mut ring = Ring::new(&inst.ring);
    while t0.elapsed() < timeout {
        let seq = ring.seq();
        if let Ok(s) = snapshot(inst, SnapOpts::default()) {
            if s.front.first().map(|f| f.as_str()) == Some(bundle) && s.elements.iter().any(|e| e.app == bundle && e.layer == "app") {
                return;
            }
        }
        ring.wait(seq, Duration::from_millis(500));
    }
}

/// Waits (on new frames) until the apps in front differ from `front`
fn wait_front_change(inst: &Instance, front: Vec<String>, timeout: Duration) {
    let t0 = Instant::now();
    let mut ring = Ring::new(&inst.ring);
    while t0.elapsed() < timeout {
        let seq = ring.seq();
        if let Ok(s) = snapshot(inst, SnapOpts::default()) {
            if s.front != front && s.elements.iter().any(|e| e.layer == "app") {
                return;
            }
        }
        ring.wait(seq, Duration::from_millis(500));
    }
}

fn scroll_into_view(inst: &Instance, e: &El) -> Result<()> {
    let sock = sock_of_pid(inst, e.pid).ok_or_else(|| anyhow!("{} is gone", e.app))?;
    let r = ask(&sock, &json!({"op": "scroll", "oid": e.oid}), Duration::from_secs(3))?.ok_or_else(|| anyhow!("{} is gone", e.app))?;
    if let Some(err) = r["error"].as_str() {
        bail!("cannot scroll to @{}: {err}", e.r);
    }
    settle(inst, Duration::from_millis(200), Duration::from_millis(1500));
    Ok(())
}

/// Types text into the focused field as the software keyboard does (insertText: of its UIKeyInput: any Unicode, no
/// lost keys); `clear` empties it first, `submit` ends with return. `keys`: hardware key presses instead (US layout).
pub fn type_text(inst: &Instance, text: &str, clear: bool, submit: bool, keys: bool, after: After) -> Result<Outcome> {
    let before = last(inst);
    if keys {
        let mut h = hid_for(inst);
        for c in text.chars() {
            let (u, shift) = key_usage(c).ok_or_else(|| anyhow!("no US key for {c:?} (type without keys)"))?;
            if shift {
                h.key(true, 225);
            }
            h.key(true, u);
            h.key(false, u);
            if shift {
                h.key(false, 225);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if submit {
            h.key(true, 0x28);
            h.key(false, 0x28);
        }
        return Ok(outcome(inst, format!("typed {} keys", text.chars().count()), before, after));
    }
    let req = json!({"op": "type", "text": text, "clear": clear, "submit": submit});
    // the process with a focused text field takes it: apps first, SpringBoard (Spotlight, alerts' fields) last
    let mut eps: Vec<PathBuf> = endpoints(inst).into_iter().filter(|e| e.fg).map(|e| e.sock).collect();
    let sb_pid = last(inst).and_then(|s| s.elements.iter().find(|e| e.app == SPRINGBOARD).map(|e| e.pid));
    eps.sort_by_key(|p| Some(pid_of_sock(p)) == sb_pid);
    let mut why = String::from("no app on screen");
    for p in eps {
        match ask(&p, &req, Duration::from_secs(4)) {
            Ok(Some(v)) if v["error"].is_null() => {
                let did = format!(
                    "typed {} into {}{}",
                    quote(text),
                    v["field"].as_str().unwrap_or("the focused field"),
                    v["value"].as_str().map(|s| format!(" (now {})", quote(s))).unwrap_or_default()
                );
                return Ok(outcome(inst, did, before, after));
            }
            Ok(Some(v)) => why = v["error"].as_str().unwrap_or("").to_string(),
            _ => {}
        }
    }
    bail!("cannot type: {why}")
}

/// HID usage (keyboard page) and shift for a character, US layout
pub fn key_usage(c: char) -> Option<(u32, bool)> {
    let lower = "abcdefghijklmnopqrstuvwxyz";
    if let Some(i) = lower.find(c) {
        return Some((4 + i as u32, false));
    }
    if let Some(i) = lower.find(c.to_ascii_lowercase()) {
        return Some((4 + i as u32, true));
    }
    if let Some(i) = "1234567890".find(c) {
        return Some((0x1e + i as u32, false));
    }
    if let Some(i) = "!@#$%^&*()".find(c) {
        return Some((0x1e + i as u32, true));
    }
    let plain = [(' ', 0x2c), ('\n', 0x28), ('\t', 0x2b), ('-', 0x2d), ('=', 0x2e), ('[', 0x2f), (']', 0x30), ('\\', 0x31), (';', 0x33), ('\'', 0x34), ('`', 0x35), (',', 0x36), ('.', 0x37), ('/', 0x38)];
    let shifted = [('_', 0x2d), ('+', 0x2e), ('{', 0x2f), ('}', 0x30), ('|', 0x31), (':', 0x33), ('"', 0x34), ('~', 0x35), ('<', 0x36), ('>', 0x37), ('?', 0x38)];
    plain.iter().find(|k| k.0 == c).map(|k| (k.1, false)).or_else(|| shifted.iter().find(|k| k.0 == c).map(|k| (k.1, true)))
}

/// A named key (return, tab, escape, delete, space, up/down/left/right, home/end/pageup/pagedown) or a usage number
pub fn key_named(name: &str) -> Option<u32> {
    let n = name.to_lowercase();
    Some(match n.as_str() {
        "return" | "enter" => 0x28,
        "escape" | "esc" => 0x29,
        "delete" | "backspace" => 0x2a,
        "tab" => 0x2b,
        "space" => 0x2c,
        "right" => 0x4f,
        "left" => 0x50,
        "down" => 0x51,
        "up" => 0x52,
        "home" => 0x4a,
        "end" => 0x4d,
        "pageup" => 0x4b,
        "pagedown" => 0x4e,
        "forwarddelete" => 0x4c,
        _ => {
            if n.chars().count() == 1 {
                return key_usage(n.chars().next()?).map(|k| k.0);
            }
            return n.strip_prefix("0x").map(|h| u32::from_str_radix(h, 16).ok()).unwrap_or_else(|| n.parse().ok());
        }
    })
}

/// A key press with modifiers ("cmd+a", "shift+tab", "return")
pub fn key(inst: &Instance, combo: &str, after: After) -> Result<Outcome> {
    let before = last(inst);
    let parts: Vec<&str> = combo.split('+').collect();
    let (mods, k) = parts.split_at(parts.len() - 1);
    let mut mu = Vec::new();
    for m in mods {
        mu.push(match m.to_lowercase().as_str() {
            "cmd" | "command" | "meta" => 0xe3,
            "shift" => 0xe1,
            "ctrl" | "control" => 0xe0,
            "alt" | "option" | "opt" => 0xe2,
            o => bail!("unknown modifier {o} (cmd shift ctrl alt)"),
        });
    }
    let u = key_named(k[0]).ok_or_else(|| anyhow!("unknown key {:?}", k[0]))?;
    let mut h = hid_for(inst);
    for m in &mu {
        h.key(true, *m);
    }
    h.key(true, u);
    std::thread::sleep(Duration::from_millis(30));
    h.key(false, u);
    for m in mu.iter().rev() {
        h.key(false, *m);
    }
    Ok(outcome(inst, format!("pressed key {combo}"), before, after))
}

/// Scroll the content: `direction` is where the content goes into view (down = see what is below; the finger moves
/// up), `amount` in screens (1 = most of a screen), from the middle of the screen or of an element. No fling.
pub fn scroll(inst: &Instance, direction: &str, amount: f64, at: Option<&str>, after: After) -> Result<Outcome> {
    let before = last(inst);
    let scr = screen_of(inst);
    let (cx, cy, area) = match at {
        Some(t) => {
            let (e, s) = resolve(inst, t)?;
            let c = e.center(s.screen);
            (c.0, c.1, (e.frame[2].min(scr.0), e.frame[3].min(scr.1)))
        }
        None => (scr.0 / 2.0, scr.1 / 2.0, (scr.0, scr.1)),
    };
    let amount = amount.clamp(0.05, 2.0);
    let (dx, dy) = match direction {
        "down" => (0.0, -area.1 * 0.6 * amount),
        "up" => (0.0, area.1 * 0.6 * amount),
        "right" => (-area.0 * 0.6 * amount, 0.0),
        "left" => (area.0 * 0.6 * amount, 0.0),
        o => bail!("direction {o:?}: up, down, left or right"),
    };
    // centred on the point, kept off the screen edges (an edge touch is a system gesture)
    let m = 0.06 * scr.0;
    let cl = |v: f64, hi: f64| v.clamp(m, hi - m);
    let from = (cl(cx - dx / 2.0, scr.0), cl(cy - dy / 2.0, scr.1));
    let to = (cl(cx + dx / 2.0, scr.0), cl(cy + dy / 2.0, scr.1));
    drag(inst, from, to, 400, 150);
    Ok(outcome(inst, format!("scrolled {direction} {amount}"), before, after))
}

/// A swipe: a quick flick (momentum, page turns, dismissing) from one point to another, or in a direction from the
/// middle; a swipe that starts at a screen edge is a system gesture (bottom edge up: home)
pub fn swipe(inst: &Instance, from: (f64, f64), to: (f64, f64), ms: u64, after: After) -> Result<Outcome> {
    let before = last(inst);
    drag(inst, from, to, ms.max(50), 0);
    Ok(outcome(inst, format!("swiped ({:.0},{:.0}) -> ({:.0},{:.0})", from.0, from.1, to.0, to.1), before, after))
}

pub fn swipe_dir(inst: &Instance, direction: &str, after: After) -> Result<Outcome> {
    let s = screen_of(inst);
    let (cx, cy) = (s.0 / 2.0, s.1 / 2.0);
    let (from, to) = match direction {
        "up" => ((cx, s.1 * 0.75), (cx, s.1 * 0.25)),
        "down" => ((cx, s.1 * 0.25), (cx, s.1 * 0.75)),
        "left" => ((s.0 * 0.85, cy), (s.0 * 0.15, cy)),
        "right" => ((s.0 * 0.15, cy), (s.0 * 0.85, cy)),
        // system gestures from the edges
        "home" => ((cx, s.1 - 2.0), (cx, s.1 * 0.55)),
        "notifications" => ((s.0 * 0.25, 2.0), (s.0 * 0.25, s.1 * 0.6)),
        "controlcenter" => ((s.0 * 0.9, 2.0), (s.0 * 0.9, s.1 * 0.6)),
        "back" => ((2.0, cy), (s.0 * 0.7, cy)),
        o => bail!("direction {o:?}: up down left right, or home notifications controlcenter back"),
    };
    swipe(inst, from, to, 250, after)
}

/// Brings an element into view: scrolls its scroll view in the app (elements the app has loaded but are off
/// screen), else scrolls `direction` step by step until it shows or the content stops moving.
pub fn scroll_to(inst: &Instance, target: &str, direction: &str, max_steps: u32, after: After) -> Result<Outcome> {
    let before = last(inst);
    let t = parse_target(target);
    for step in 0..=max_steps {
        let snap = snapshot(inst, SnapOpts::default())?;
        if let Some(e) = find_all_q(&snap, &t, 2).into_iter().find(|e| !e.offscreen) {
            let did = format!("@{} {} {} is on screen after {step} scroll(s)", e.r, e.role, e.label.as_deref().map(quote).unwrap_or_default());
            return Ok(outcome(inst, did, before, after));
        }
        let all = snapshot(inst, SnapOpts { all: true, ..Default::default() })?;
        if let Some(e) = find_all_q(&all, &t, 2).into_iter().find(|e| e.offscreen && !e.web) {
            if scroll_into_view(inst, e).is_ok() {
                let s2 = snapshot(inst, SnapOpts::default())?;
                if find_all_q(&s2, &t, 2).into_iter().any(|e| !e.offscreen) {
                    let e = find_all_q(&s2, &t, 2)[0].clone();
                    return Ok(outcome(inst, format!("@{} {} {} scrolled into view", e.r, e.role, e.label.as_deref().map(quote).unwrap_or_default()), before, after));
                }
            }
        }
        if step == max_steps {
            break;
        }
        let seq = Ring::new(&inst.ring).seq();
        scroll(inst, direction, 0.8, None, After::None)?;
        settle(inst, Duration::from_millis(250), Duration::from_millis(2500));
        if Ring::new(&inst.ring).seq() == seq {
            bail!("{target:?} not found: the content stopped scrolling {direction}");
        }
    }
    bail!("{target:?} not found after {max_steps} scrolls {direction}")
}

/// Waits until a target is on screen (or, `gone`, no longer is). Wakes on new frames, not on a timer.
pub fn wait_for(inst: &Instance, target: &str, gone: bool, timeout: Duration) -> Result<Outcome> {
    let t0 = Instant::now();
    let t = parse_target(target);
    let mut ring = Ring::new(&inst.ring);
    loop {
        let seq = ring.seq();
        let snap = snapshot(inst, SnapOpts::default());
        if let Ok(snap) = &snap {
            let hit = find_all_q(snap, &t, 2).into_iter().find(|e| !e.offscreen).cloned();
            if hit.is_some() != gone {
                let ms = t0.elapsed().as_millis();
                let did = match hit {
                    Some(e) => format!("{target:?} appeared after {ms} ms: {}", e.line(snap.screen)),
                    None => format!("{target:?} gone after {ms} ms"),
                };
                return Ok(Outcome { did, screen: Some(snap.clone()), diff: None });
            }
        }
        let left = timeout.saturating_sub(t0.elapsed());
        if left.is_zero() {
            let st = snap.map(|s| s.text()).unwrap_or_else(|e| format!("{e:#}"));
            bail!("timed out after {:.1} s waiting for {target:?}{}\n{st}", timeout.as_secs_f64(), if gone { " to go" } else { "" });
        }
        // the next frame (or a second: a change in a process that draws nothing new is rare but possible)
        ring.wait(seq, left.min(Duration::from_secs(1)));
        std::thread::sleep(Duration::from_millis(60).min(left));
    }
}

/// A hardware button (home lock side volup voldown siri action ...), held `ms`
pub fn press(inst: &Instance, button: &str, ms: u64, after: After) -> Result<Outcome> {
    let before = last(inst);
    Hid::new(&inst.sock).press_for(button, ms);
    Ok(outcome(inst, format!("pressed {button}"), before, after))
}

/// Opens a URL as `simctl openurl` (host/openurl's queue file in the device)
pub fn open_url(inst: &Instance, url: &str, after: After) -> Result<Outcome> {
    let before = last(inst);
    let q = inst.dir.join("data/tmp/x86sim-openurl");
    let staging = q.with_extension(format!("new.{}", std::process::id()));
    std::fs::write(&staging, format!("{url}\n"))?;
    let lock = std::fs::OpenOptions::new().create(true).append(true).open(q.with_extension("lock"))?;
    use std::os::fd::AsRawFd;
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
    for _ in 0..100 {
        if !q.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let r = std::fs::rename(&staging, &q);
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
    r?;
    if after != After::None {
        // web pages open in Safari; other schemes in whichever app claims them (the front changes, or not at all)
        let l = url.to_lowercase();
        if l.starts_with("http:") || l.starts_with("https:") {
            wait_front_is(inst, "com.apple.mobilesafari", Duration::from_secs(20));
        } else {
            wait_front_change(inst, before.as_ref().map(|b| b.front.clone()).unwrap_or_default(), Duration::from_secs(5));
        }
    }
    Ok(outcome(inst, format!("opened {url}"), before, after))
}

pub fn launch(inst: &Instance, bundle: &str, args: &[String], after: After) -> Result<Outcome> {
    let before = last(inst);
    let a = crate::apps::launch(inst, bundle, args)?;
    if after != After::None {
        wait_front_is(inst, bundle, Duration::from_secs(20));
    }
    Ok(outcome(inst, format!("launched {a}"), before, after))
}

pub fn terminate(inst: &Instance, bundle: &str, after: After) -> Result<Outcome> {
    let before = last(inst);
    let a = crate::apps::terminate(inst, bundle)?;
    Ok(outcome(inst, format!("terminated {bundle}: {a}"), before, after))
}

// ---------------------------------------------------------------------------------------------------------------------
// Screenshots

/// The newest frame upright as PNG, scaled down by `div` (the device's scale gives a picture in points: the same
/// coordinates as the snapshot's)
pub fn screenshot(inst: &Instance, div: u32) -> Result<(Vec<u8>, u32, u32)> {
    let mut ring = Ring::new(&inst.ring);
    let f = ring.latest().ok_or_else(|| anyhow!("{}: no frame (is the phone running?)", inst.name))?;
    let rot = inst.orientation().as_deref().and_then(hid::orientation_rot).unwrap_or(0);
    let div = div.max(1) as usize;
    let (w, h, s) = (f.w as usize, f.h as usize, f.stride as usize);
    let (sw, sh) = (w / div, h / div);
    // box filter
    let mut small = vec![0u8; sw * sh * 3];
    for y in 0..sh {
        for x in 0..sw {
            let mut acc = [0u32; 3];
            for yy in 0..div {
                let row = (y * div + yy) * s;
                for xx in 0..div {
                    let o = row + (x * div + xx) * 4;
                    acc[0] += f.bgra[o + 2] as u32;
                    acc[1] += f.bgra[o + 1] as u32;
                    acc[2] += f.bgra[o] as u32;
                }
            }
            let n = (div * div) as u32;
            let o = (y * sw + x) * 3;
            small[o] = (acc[0] / n) as u8;
            small[o + 1] = (acc[1] / n) as u8;
            small[o + 2] = (acc[2] / n) as u8;
        }
    }
    // turn upright
    let (ow, oh) = if rot % 180 == 90 { (sh, sw) } else { (sw, sh) };
    let mut rgb = Vec::with_capacity(ow * oh * 3);
    for yo in 0..oh {
        for xo in 0..ow {
            let (x, y) = match rot % 360 {
                270 => (yo, sh - 1 - xo),
                90 => (sw - 1 - yo, xo),
                180 => (sw - 1 - xo, sh - 1 - yo),
                _ => (xo, yo),
            };
            let o = (y * sw + x) * 3;
            rgb.extend_from_slice(&small[o..o + 3]);
        }
    }
    let mut out = Vec::new();
    {
        let mut e = png::Encoder::new(&mut out, ow as u32, oh as u32);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.write_header()?.write_image_data(&rgb)?;
    }
    Ok((out, ow as u32, oh as u32))
}

pub fn base64(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        s.push(T[(n >> 18) as usize & 63] as char);
        s.push(T[(n >> 12) as usize & 63] as char);
        s.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        s.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn el(r: &str, pid: u32, oid: &str, role: &str, label: &str, y: f64) -> El {
        El { r: r.into(), pid, oid: oid.into(), role: role.into(), label: Some(label.into()), app: "a".into(), layer: "app".into(), frame: [0.0, y, 100.0, 40.0], enabled: true, ..Default::default() }
    }

    #[test]
    fn refs_stay_with_their_element() {
        let prev = vec![el("e1", 1, "10", "button", "General", 100.0), el("e2", 1, "20", "button", "Privacy", 150.0)];
        // the same objects, one relabelled cell (a different element now), a recreated element with the same label
        let mut cur = vec![el("", 1, "10", "button", "General", 90.0), el("", 1, "30", "button", "Privacy", 140.0), el("", 1, "40", "text", "New", 10.0)];
        let mut next = 3;
        assign_refs(&mut cur, &prev, &mut next);
        assert_eq!(cur[0].r, "e1");
        assert_eq!(cur[1].r, "e2");
        assert_eq!(cur[2].r, "e3");
        assert_eq!(next, 4);
        // a reused object with other content gets a new ref
        let mut cur = vec![el("", 1, "10", "button", "Sounds", 100.0)];
        assign_refs(&mut cur, &prev, &mut next);
        assert_eq!(cur[0].r, "e4");
    }

    #[test]
    fn targets() {
        assert!(matches!(parse_target("@e3"), Target::Ref(r) if r == "e3"));
        assert!(matches!(parse_target("e12"), Target::Ref(r) if r == "e12"));
        assert!(matches!(parse_target("id:com.x"), Target::Id(i) if i == "com.x"));
        assert!(matches!(parse_target("201 320"), Target::Point(x, y) if x == 201.0 && y == 320.0));
        assert!(matches!(parse_target("201,320"), Target::Point(..)));
        assert!(matches!(parse_target("General"), Target::Text(_)));
        assert!(matches!(parse_target("e mail"), Target::Text(_)));
        let snap = Snapshot {
            screen: (400.0, 800.0),
            elements: vec![
                El { layer: "app".into(), ..el("e1", 1, "1", "text", "General settings", 10.0) },
                El { layer: "app".into(), ..el("e2", 1, "2", "button", "General", 50.0) },
                El { layer: "system".into(), ..el("e3", 2, "3", "button", "Allow", 300.0) },
                El { layer: "app".into(), ..el("e4", 1, "4", "button", "Allow", 300.0) },
            ],
            ..Default::default()
        };
        assert_eq!(find(&snap, "general").unwrap().r, "e2");
        assert_eq!(find(&snap, "Allow").unwrap().r, "e3");
        assert_eq!(find(&snap, "@e4").unwrap().r, "e4");
        assert!(find(&snap, "nothing").is_err());
    }

    #[test]
    fn b64() {
        assert_eq!(base64(b"hello"), "aGVsbG8=");
        assert_eq!(base64(b"hi!"), "aGkh");
        assert_eq!(base64(b"h"), "aA==");
    }

    #[test]
    fn keys() {
        assert_eq!(key_usage('a'), Some((4, false)));
        assert_eq!(key_usage('Z'), Some((29, true)));
        assert_eq!(key_usage('@'), Some((0x1f, true)));
        assert_eq!(key_named("return"), Some(0x28));
        assert_eq!(key_named("0x2a"), Some(0x2a));
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Keyboard: Apple Simulator's I/O > Keyboard menu

/// The hardware keyboard's connection, as host/simhid remembers it (<data>/hwkeyboard; connected unless disconnected)
pub fn hw_keyboard_connected(inst: &Instance) -> bool {
    Hid::new(&inst.sock).hw_keyboard_connected()
}

/// host/simhid answers on the phone's input socket (the phone is up)
fn simhid_up(inst: &Instance) -> bool {
    let p = std::fs::canonicalize(&inst.sock).unwrap_or_else(|_| inst.sock.clone());
    std::os::unix::net::UnixStream::connect(p).is_ok()
}

/// The software keyboard is on screen: its keys are in the snapshot (role "key", UIKit's keyboard-key trait)
pub fn software_keyboard_up(s: &Snapshot) -> bool {
    s.elements.iter().filter(|e| e.role == "key" && !e.offscreen).count() >= 10
}

/// `keyboard software on|off|toggle` / `keyboard hardware connect|disconnect|toggle` / `keyboard status`, as Apple's
/// Toggle Software Keyboard (Cmd-K) and Connect Hardware Keyboard (Shift-Cmd-K)
pub fn keyboard(inst: &Instance, what: &str, how: &str, after: After) -> Result<Outcome> {
    let before = last(inst);
    let hw = hw_keyboard_connected(inst);
    let did = match (what, how) {
        ("status", _) | ("", _) => {
            let up = snapshot(inst, SnapOpts::default()).map(|s| software_keyboard_up(&s)).unwrap_or(false);
            format!("hardware keyboard {}; software keyboard {}", if hw { "connected" } else { "disconnected" }, if up { "shown" } else { "hidden" })
        }
        ("hardware" | "hw", "connect" | "on" | "disconnect" | "off" | "toggle") => {
            let on = match how {
                "connect" | "on" => true,
                "disconnect" | "off" => false,
                _ => !hw,
            };
            if simhid_up(inst) {
                Hid::new(&inst.sock).hw_keyboard(on);
                std::thread::sleep(Duration::from_millis(300));
            } else {
                // simhid applies it at the next boot
                std::fs::write(inst.sock.with_file_name("hwkeyboard"), if on { "connected\n" } else { "disconnected\n" })?;
            }
            format!("hardware keyboard {}", if on { "connected" } else { "disconnected" })
        }
        ("software" | "sw", "on" | "off" | "toggle" | "show" | "hide") => {
            anyhow::ensure!(simhid_up(inst), "{} is not running", inst.name);
            let want = match how {
                "on" | "show" => Some(true),
                "off" | "hide" => Some(false),
                _ => None,
            };
            let up = || snapshot(inst, SnapOpts::default()).map(|s| software_keyboard_up(&s)).unwrap_or(false);
            if want.is_some_and(|w| w == up()) {
                format!("software keyboard already {}", if want == Some(true) { "shown" } else { "hidden" })
            } else {
                hid_for(inst).soft_keyboard_toggle();
                std::thread::sleep(Duration::from_millis(600));
                let now = up();
                let mut d = format!("toggled the software keyboard: {}", if now { "shown" } else { "hidden" });
                if want.is_some_and(|w| w != now) {
                    d += if want == Some(true) {
                        " (it shows while a text field is focused: tap one first)"
                    } else {
                        " (still up: with the hardware keyboard disconnected it stays up while a field is focused)"
                    };
                }
                d
            }
        }
        _ => bail!("keyboard software on|off|toggle | hardware connect|disconnect|toggle | status"),
    };
    Ok(outcome(inst, did, before, after))
}
