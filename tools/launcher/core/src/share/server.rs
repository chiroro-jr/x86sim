//! Share: the HTTP + WebSocket server behind `x86sim serve`. A thread a connection (a handful of viewers), no TLS of its
//! own: remote access goes through tailscale / cloudflared (tunnel.rs), which bring HTTPS.
//!
//! Access: a token (control: watch and drive, start / stop phones, make links; view: watch only), optionally limited
//! to one phone and expiring, from `?t=`, a cookie set from it, or `Authorization: Bearer`. Without a token only a
//! plain local browser gets in (loopback peer, a loopback Host, no proxy headers, a same-origin Origin): a tunnel's
//! requests arrive from loopback too but carry forwarding headers and their own Host, and a web page elsewhere can
//! neither name a loopback Host through DNS rebinding nor pass the Origin check on the WebSocket.
use super::tunnel::{self, Kind, Tunnel};
use super::video::{self, Codec, Out, StreamKey};
use super::ws;
use super::{now_s, random_token, Options, Role, State, TokenRec};
use crate::hid::{self, Hid};
use crate::instance::{self, Instance};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

const INDEX: &str = include_str!("web/index.html");
const APP_JS: &str = include_str!("web/app.js");
const APP_CSS: &str = include_str!("web/app.css");

pub struct Server {
    pub opts: Options,
    pub port: u16,
    tokens: Mutex<Vec<TokenRec>>,
    tunnels: Mutex<Vec<Tunnel>>,
    phones_cache: Mutex<(Option<Instant>, Value)>,
    thumbs: Mutex<HashMap<(String, u32), (Instant, Vec<u8>)>>,
    started: u64,
    pub stop: AtomicBool,
}

pub struct Req {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
    pub peer: SocketAddr,
}

#[derive(Clone, Debug)]
pub struct Grant {
    pub role: Role,
    pub phone: Option<String>,
    pub token: Option<String>,
    pub expires: Option<u64>,
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() && hex(b[i + 1]).is_some() && hex(b[i + 2]).is_some() => {
                out.push(hex(b[i + 1]).unwrap() * 16 + hex(b[i + 2]).unwrap());
                i += 2;
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn pct_encode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

fn read_req(s: &mut TcpStream, peer: SocketAddr) -> Option<Req> {
    s.set_read_timeout(Some(Duration::from_secs(15))).ok()?;
    let mut r = BufReader::new(s.try_clone().ok()?);
    let mut line = String::new();
    r.read_line(&mut line).ok()?;
    let mut it = line.split_whitespace();
    let method = it.next()?.to_string();
    let target = it.next()?.to_string();
    let mut headers = HashMap::new();
    let mut total = 0;
    loop {
        let mut l = String::new();
        let n = r.read_line(&mut l).ok()?;
        total += n;
        if n == 0 || total > 32 * 1024 {
            return None;
        }
        let l = l.trim_end();
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    if len > 256 * 1024 {
        return None;
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).ok()?;
    // the BufReader may hold bytes past the request only for a pipelining client; we answer one request a connection
    let (path, q) = target.split_once('?').unwrap_or((&target, ""));
    let query = q.split('&').filter(|p| !p.is_empty()).map(|p| {
        let (k, v) = p.split_once('=').unwrap_or((p, ""));
        (pct_decode(k), pct_decode(v))
    });
    Some(Req { method, path: pct_decode(path), query: query.collect(), headers, body, peer })
}

fn respond(s: &mut TcpStream, code: u16, ctype: &str, extra: &[(&str, String)], body: &[u8]) {
    let reason = match code {
        200 => "OK",
        204 => "No Content",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        _ => "Error",
    };
    let mut h = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n",
        body.len()
    );
    for (k, v) in extra {
        h.push_str(&format!("{k}: {v}\r\n"));
    }
    h.push_str("\r\n");
    let _ = s.write_all(h.as_bytes());
    let _ = s.write_all(body);
}

fn json_resp(s: &mut TcpStream, code: u16, v: &Value) {
    respond(s, code, "application/json", &[], v.to_string().as_bytes());
}

fn host_only(h: &str) -> &str {
    // "[::1]:7380" -> "[::1]", "localhost:7380" -> "localhost"
    if h.starts_with('[') {
        return h.split_inclusive(']').next().unwrap_or(h);
    }
    h.rsplit_once(':').map(|(a, _)| a).unwrap_or(h)
}

fn is_loopback_name(h: &str) -> bool {
    let h = host_only(h).to_ascii_lowercase();
    h == "localhost" || h == "127.0.0.1" || h == "[::1]" || h.ends_with(".localhost")
}

/// A plain local browser (see the module doc)
pub fn local_trusted(req: &Req) -> bool {
    if !req.peer.ip().is_loopback() {
        return false;
    }
    const PROXY: [&str; 7] = ["x-forwarded-for", "forwarded", "x-real-ip", "cf-connecting-ip", "cf-ray", "tailscale-user-login", "x-forwarded-host"];
    if PROXY.iter().any(|h| req.headers.contains_key(*h)) {
        return false;
    }
    let host = req.headers.get("host").map(String::as_str).unwrap_or("");
    if !is_loopback_name(host) {
        return false;
    }
    match req.headers.get("origin") {
        None => true,
        Some(o) => o.strip_prefix("http://").or(o.strip_prefix("https://")).is_some_and(|oh| oh.eq_ignore_ascii_case(host)),
    }
}

fn ct_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn cookie(req: &Req, name: &str) -> Option<String> {
    req.headers.get("cookie")?.split(';').find_map(|c| c.trim().strip_prefix(&format!("{name}=")).map(String::from))
}

impl Server {
    pub fn new(opts: Options, port: u16) -> Arc<Server> {
        let exp = opts.ttl_s.map(|t| now_s() + t);
        let tokens = vec![
            TokenRec { token: random_token(), role: Role::Control, phone: None, expires: exp, label: "control".into() },
            TokenRec { token: random_token(), role: Role::View, phone: None, expires: exp, label: "view".into() },
        ];
        Arc::new(Server {
            opts,
            port,
            tokens: Mutex::new(tokens),
            tunnels: Mutex::new(vec![]),
            phones_cache: Mutex::new((None, Value::Null)),
            thumbs: Mutex::new(HashMap::new()),
            started: now_s(),
            stop: AtomicBool::new(false),
        })
    }

    pub fn grant(&self, req: &Req) -> Option<Grant> {
        let given = req.query.get("t").cloned().or_else(|| req.headers.get("authorization").and_then(|a| a.strip_prefix("Bearer ").map(|s| s.trim().to_string())));
        // a cookie left by an earlier server is no reason to turn a local browser away
        let from_cookie = given.is_none();
        if let Some(t) = given.or_else(|| cookie(req, "x86sim_t")) {
            let now = now_s();
            let mut toks = self.tokens.lock().unwrap();
            toks.retain(|r| r.expires.is_none_or(|e| e > now) || r.label == "control" || r.label == "view");
            match toks.iter().find(|r| ct_eq(&r.token, &t)) {
                Some(r) if r.expires.is_none_or(|e| e > now) => return Some(Grant { role: r.role, phone: r.phone.clone(), token: Some(t), expires: r.expires }),
                _ if !from_cookie => return None,
                _ => {}
            }
        }
        if !self.opts.require_token && local_trusted(req) {
            return Some(Grant { role: Role::Control, phone: None, token: None, expires: None });
        }
        None
    }

    pub fn state(&self) -> State {
        let toks = self.tokens.lock().unwrap();
        let tok = |l: &str| toks.iter().find(|r| r.label == l).map(|r| r.token.clone()).unwrap_or_default();
        State {
            pid: std::process::id(),
            port: self.port,
            listen: self.opts.listen.clone(),
            started: self.started,
            local_url: format!("http://127.0.0.1:{}/", self.port),
            control_token: tok("control"),
            view_token: tok("view"),
            expires: toks.iter().find(|r| r.label == "control").and_then(|r| r.expires),
            tunnels: self.tunnels.lock().unwrap().iter().map(|t| t.info.lock().unwrap().clone()).collect(),
            require_token: self.opts.require_token,
            links: toks.iter().filter(|r| r.label != "control" && r.label != "view").count(),
        }
    }

    pub fn write_state(&self) {
        if self.port == 0 {
            return;
        }
        let p = super::state_path();
        let tmp = p.with_extension("tmp");
        if let Ok(mut f) = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode_0600().open(&tmp) {
            let _ = f.write_all(serde_json::to_string_pretty(&self.state()).unwrap_or_default().as_bytes());
            let _ = std::fs::rename(&tmp, &p);
        }
    }

    pub fn add_tunnel(self: &Arc<Self>, kind: Kind) -> Value {
        {
            let mut ts = self.tunnels.lock().unwrap();
            // tailscale serve and funnel share the port mapping: one of them at a time
            let same = |k: &Kind| *k == kind || (matches!(kind, Kind::Tailscale | Kind::Funnel) && matches!(k, Kind::Tailscale | Kind::Funnel));
            ts.retain_mut(|t| {
                let i = t.info.lock().unwrap().clone();
                if same(&i.kind) && (i.state == "failed" || i.kind != kind) {
                    t.stop();
                    return false;
                }
                true
            });
            if let Some(t) = ts.iter().find(|t| t.info.lock().unwrap().kind == kind) {
                return serde_json::to_value(t.info.lock().unwrap().clone()).unwrap_or_default();
            }
        }
        let named = if kind == Kind::Cloudflared { self.opts.cf_named.clone() } else { None };
        let t = Tunnel::start(kind, self.port, self.opts.ts_port, named);
        t.wait(Duration::from_secs(25));
        let info = t.info.lock().unwrap().clone();
        self.tunnels.lock().unwrap().push(t);
        self.write_state();
        // cloudflared may print its URL after we stop waiting: keep the state file current
        let me = self.clone();
        std::thread::spawn(move || {
            for _ in 0..60 {
                std::thread::sleep(Duration::from_secs(1));
                me.write_state();
            }
        });
        serde_json::to_value(info).unwrap_or_default()
    }

    pub fn remove_tunnel(&self, kind: &Kind) {
        self.tunnels.lock().unwrap().retain_mut(|t| {
            if t.info.lock().unwrap().kind == *kind {
                t.stop();
                false
            } else {
                true
            }
        });
        self.write_state();
    }

    pub fn shutdown(&self) {
        for mut t in self.tunnels.lock().unwrap().drain(..) {
            t.stop();
        }
        let p = super::state_path();
        if super::read_state().is_some_and(|s| s.pid == std::process::id()) {
            let _ = std::fs::remove_file(p);
        }
    }

    /// Every phone for the page: the hub's summary plus what the page needs to draw controls
    fn phones(&self) -> Value {
        let mut c = self.phones_cache.lock().unwrap();
        if c.0.is_some_and(|t| t.elapsed() < Duration::from_millis(1500)) {
            return c.1.clone();
        }
        let insts = instance::list();
        let sums = instance::summaries(0);
        let v: Vec<Value> = insts
            .iter()
            .map(|i| {
                let s = sums.iter().find(|s| s.id == i.id);
                let mut o = 0;
                let t = video::target(i, &mut o);
                json!({
                    "id": i.id, "name": i.name, "model": i.model, "os": i.ios, "platform": i.platform,
                    "installed": i.runtime_present,
                    "state": s.map(|s| s.state.clone()).unwrap_or_else(|| "off".into()),
                    "home": s.is_some_and(|s| s.home),
                    "memory_mb": s.map(|s| s.memory_mb), "cpu_pct": s.map(|s| s.cpu_pct), "uptime_s": s.and_then(|s| s.uptime_s),
                    "screen": [t.size.0, t.size.1], "two_screens": i.inner.is_some(), "inner_active": i.inner_active(),
                    "orientation": i.orientation(), "hinge": i.hinge(),
                    "ipad": i.model.contains("iPad"),
                })
            })
            .collect();
        *c = (Some(Instant::now()), Value::Array(v));
        c.1.clone()
    }

    fn visible(&self, g: &Grant, id: &str) -> bool {
        g.phone.as_deref().is_none_or(|p| p == id)
    }

    fn mint(&self, role: Role, phone: Option<String>, ttl_s: Option<u64>, label: &str) -> TokenRec {
        let r = TokenRec { token: random_token(), role, phone, expires: ttl_s.map(|t| now_s() + t), label: format!("link:{label}") };
        self.tokens.lock().unwrap().push(r.clone());
        self.write_state();
        r
    }

    fn urls_for(&self, token: &str, phone: Option<&str>) -> Vec<Value> {
        let st = self.state();
        super::urls(&st, token, phone).into_iter().map(|(kind, reach, url)| json!({"kind": kind, "reach": reach, "url": url})).collect()
    }
}

trait Mode0600 {
    fn mode_0600(&mut self) -> &mut Self;
}
impl Mode0600 for std::fs::OpenOptions {
    fn mode_0600(&mut self) -> &mut Self {
        use std::os::unix::fs::OpenOptionsExt;
        self.mode(0o600)
    }
}

pub fn run(srv: Arc<Server>, listener: TcpListener) {
    for c in listener.incoming() {
        if srv.stop.load(Ordering::Relaxed) {
            break;
        }
        let Ok(s) = c else { continue };
        let srv = srv.clone();
        std::thread::spawn(move || {
            let peer = s.peer_addr().unwrap_or_else(|_| "0.0.0.0:0".parse().unwrap());
            handle(&srv, s, peer);
        });
    }
}

fn handle(srv: &Arc<Server>, mut s: TcpStream, peer: SocketAddr) {
    let _ = s.set_nodelay(true);
    let Some(req) = read_req(&mut s, peer) else { return };
    let p = req.path.clone();
    // static files: the page itself carries no data, the token check comes with the API / socket
    match p.as_str() {
        "/" | "/index.html" => {
            let mut extra = vec![("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' ws: wss:; style-src 'self'; script-src 'self'; frame-ancestors 'none'".to_string())];
            // the token moves into a cookie (SameSite=Strict, HttpOnly) so the page's later requests carry it
            if let (Some(t), Some(_)) = (req.query.get("t"), srv.grant(&req)) {
                let secure = req.headers.contains_key("x-forwarded-proto") || req.headers.contains_key("cf-ray") || req.headers.contains_key("tailscale-user-login");
                extra.push(("Set-Cookie", format!("x86sim_t={t}; Path=/; HttpOnly; SameSite=Strict{}", if secure { "; Secure" } else { "" })));
            }
            return respond(&mut s, 200, "text/html; charset=utf-8", &extra, INDEX.as_bytes());
        }
        "/app.js" => return respond(&mut s, 200, "text/javascript; charset=utf-8", &[], APP_JS.as_bytes()),
        "/app.css" => return respond(&mut s, 200, "text/css; charset=utf-8", &[], APP_CSS.as_bytes()),
        "/favicon.ico" => return respond(&mut s, 204, "image/x-icon", &[], b""),
        _ => {}
    }
    let Some(g) = srv.grant(&req) else {
        return json_resp(&mut s, 401, &json!({"error": "a token is needed: open the link x86sim serve printed (…?t=…)"}));
    };
    // a page elsewhere can't post here: state changes need our header (a cross-origin request with it is preflighted
    // and refused) or a WebSocket from our own origin
    if req.method == "POST" && req.headers.get("x-x86sim").is_none() {
        return json_resp(&mut s, 403, &json!({"error": "missing X-X86sim header"}));
    }
    let seg: Vec<&str> = p.trim_matches('/').split('/').collect();
    let control = g.role == Role::Control;
    match (req.method.as_str(), seg.as_slice()) {
        ("GET", ["api", "me"]) => json_resp(&mut s, 200, &json!({"role": g.role, "phone": g.phone, "expires": g.expires, "local": g.token.is_none(), "server": {"started": srv.started, "version": env!("CARGO_PKG_VERSION")}})),
        ("GET", ["api", "phones"]) => {
            let all = srv.phones();
            let v: Vec<Value> = all.as_array().into_iter().flatten().filter(|p| srv.visible(&g, p["id"].as_str().unwrap_or(""))).cloned().collect();
            json_resp(&mut s, 200, &Value::Array(v))
        }
        ("GET", ["api", "status"]) if control => {
            let streams: Vec<Value> = video::streams().into_iter().map(|(k, st)| json!({"phone": k.phone, "codec": format!("{:?}", k.codec), "width": k.width, "quality": k.quality, "fps": k.fps, "stats": st})).collect();
            let mut st = serde_json::to_value(srv.state()).unwrap_or_default();
            st["control_token"] = Value::Null;
            st["view_token"] = Value::Null;
            json_resp(&mut s, 200, &json!({"server": st, "streams": streams, "available": tunnel::available()}))
        }
        ("GET", ["api", "phones", id, what]) if srv.visible(&g, id) => {
            let Some(inst) = instance::find(id) else { return json_resp(&mut s, 404, &json!({"error": "no such phone"})) };
            match *what {
                "thumb.jpg" => {
                    let w: u32 = req.query.get("w").and_then(|v| v.parse().ok()).unwrap_or(240).clamp(64, 720);
                    let key = (inst.id.clone(), w);
                    let cached = srv.thumbs.lock().unwrap().get(&key).filter(|(t, _)| t.elapsed() < Duration::from_millis(900)).map(|(_, b)| b.clone());
                    let jpg = cached.or_else(|| {
                        let j = video::snapshot_jpeg(&inst, w, 70)?;
                        srv.thumbs.lock().unwrap().insert(key, (Instant::now(), j.clone()));
                        Some(j)
                    });
                    match jpg {
                        Some(j) => respond(&mut s, 200, "image/jpeg", &[], &j),
                        None => respond(&mut s, 204, "image/jpeg", &[], b""),
                    }
                }
                "screenshot.png" => match video::snapshot_png(&inst) {
                    Some(png) => {
                        let name = format!("{}-{}.png", inst.name.replace(|c: char| !c.is_ascii_alphanumeric(), "-"), now_s());
                        respond(&mut s, 200, "image/png", &[("Content-Disposition", format!("attachment; filename=\"{name}\""))], &png)
                    }
                    None => json_resp(&mut s, 409, &json!({"error": "no frame: is the phone running?"})),
                },
                _ => json_resp(&mut s, 404, &json!({"error": "not found"})),
            }
        }
        ("POST", ["api", "phones", id, act]) if control && srv.visible(&g, id) => {
            let Some(inst) = instance::find(id) else { return json_resp(&mut s, 404, &json!({"error": "no such phone"})) };
            let r = match *act {
                "start" => crate::sim::start(&inst.dir).map(|pid| json!({"starting": true, "pid": pid})),
                "stop" => {
                    // a stop waits for the phone to go down: answer at once
                    let dir = inst.dir.clone();
                    std::thread::spawn(move || {
                        let _ = crate::sim::stop(&dir);
                    });
                    Ok(json!({"stopping": true}))
                }
                _ => Err(anyhow::anyhow!("unknown action")),
            };
            srv.phones_cache.lock().unwrap().0 = None;
            match r {
                Ok(v) => json_resp(&mut s, 200, &v),
                Err(e) => json_resp(&mut s, 400, &json!({"error": format!("{e:#}")})),
            }
        }
        ("GET", ["api", "links"]) if control => {
            let toks = srv.tokens.lock().unwrap();
            let v: Vec<Value> = toks.iter().filter(|r| r.label.starts_with("link:")).map(|r| json!({"id": &r.token[..6], "role": r.role, "phone": r.phone, "expires": r.expires, "label": r.label})).collect();
            json_resp(&mut s, 200, &Value::Array(v))
        }
        ("POST", ["api", "links"]) if control => {
            let b: Value = serde_json::from_slice(&req.body).unwrap_or_default();
            let role = if b["role"].as_str() == Some("control") { Role::Control } else { Role::View };
            // a link made through a limited token stays within its phone
            let phone = g.phone.clone().or_else(|| b["phone"].as_str().filter(|p| !p.is_empty()).map(String::from));
            if let Some(p) = &phone {
                if instance::find(p).is_none() {
                    return json_resp(&mut s, 404, &json!({"error": "no such phone"}));
                }
            }
            let ttl = b["ttl_s"].as_u64().filter(|t| *t > 0).or(Some(3600)).map(|t| t.min(30 * 86400));
            // a link never outlives the token that made it
            let ttl = match (ttl, g.expires) {
                (Some(t), Some(e)) => Some(t.min(e.saturating_sub(now_s()))),
                (t, _) => t,
            };
            let r = srv.mint(role, phone.clone(), ttl, b["label"].as_str().unwrap_or(""));
            json_resp(&mut s, 200, &json!({"role": r.role, "phone": r.phone, "expires": r.expires, "token": r.token, "urls": srv.urls_for(&r.token, phone.as_deref())}))
        }
        ("POST", ["api", "links", "revoke"]) if control => {
            let b: Value = serde_json::from_slice(&req.body).unwrap_or_default();
            let id = b["id"].as_str().unwrap_or("-");
            let mut toks = srv.tokens.lock().unwrap();
            let before = toks.len();
            toks.retain(|r| !(r.label.starts_with("link:") && (r.token.starts_with(id) || id == "all")));
            let n = before - toks.len();
            drop(toks);
            srv.write_state();
            json_resp(&mut s, 200, &json!({"revoked": n}))
        }
        ("GET", ["api", "urls"]) if control => {
            let st = srv.state();
            let tok = match req.query.get("role").map(String::as_str) {
                Some("view") => st.view_token,
                _ => st.control_token,
            };
            json_resp(&mut s, 200, &json!({"urls": srv.urls_for(&tok, req.query.get("phone").map(String::as_str)), "tunnels": st.tunnels, "available": tunnel::available()}))
        }
        ("POST", ["api", "tunnel"]) if control => {
            let b: Value = serde_json::from_slice(&req.body).unwrap_or_default();
            let Some(kind) = b["kind"].as_str().and_then(Kind::parse) else { return json_resp(&mut s, 400, &json!({"error": "kind: tailscale, funnel or cloudflared"})) };
            if b["on"].as_bool() == Some(false) {
                srv.remove_tunnel(&kind);
                json_resp(&mut s, 200, &json!({"kind": kind, "state": "stopped"}))
            } else {
                let info = srv.add_tunnel(kind);
                json_resp(&mut s, 200, &info)
            }
        }
        ("GET", ["api", "qr.svg"]) => {
            let text = req.query.get("text").cloned().unwrap_or_default();
            match qrcode::QrCode::new(text.as_bytes()) {
                Ok(q) => respond(&mut s, 200, "image/svg+xml", &[], super::qr_svg(&q).as_bytes()),
                Err(_) => json_resp(&mut s, 400, &json!({"error": "too long for a QR code"})),
            }
        }
        ("GET", ["ws", id]) if srv.visible(&g, id) => {
            let Some(inst) = instance::find(id) else { return json_resp(&mut s, 404, &json!({"error": "no such phone"})) };
            // the socket must come from this page's own origin (a token in the URL could be replayed by another site's
            // script otherwise, a local browser has no token at all)
            let host = req.headers.get("host").cloned().unwrap_or_default();
            if let Some(o) = req.headers.get("origin") {
                let oh = o.split("://").nth(1).unwrap_or("");
                let fwd = req.headers.get("x-forwarded-host").cloned().unwrap_or_default();
                if !oh.eq_ignore_ascii_case(&host) && !oh.eq_ignore_ascii_case(&fwd) {
                    return json_resp(&mut s, 403, &json!({"error": "cross-origin socket"}));
                }
            }
            let Some(key) = req.headers.get("sec-websocket-key") else { return json_resp(&mut s, 400, &json!({"error": "not a websocket"})) };
            let resp = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n", ws::accept_key(key));
            if s.write_all(resp.as_bytes()).is_err() {
                return;
            }
            session(srv, s, inst, g, &req.query);
        }
        _ => json_resp(&mut s, if control { 404 } else { 403 }, &json!({"error": "not found or not allowed"})),
    }
}

/// One viewer's socket: video out (from the shared stream), input in (control role only), phone state changes out
fn session(_srv: &Arc<Server>, s: TcpStream, inst: Instance, g: Grant, q: &HashMap<String, String>) {
    let codec = if q.get("codec").map(String::as_str) == Some("jpeg") { Codec::Jpeg } else { Codec::H264 };
    let width = q.get("w").and_then(|v| v.parse::<u32>().ok()).unwrap_or(720).clamp(160, 2048) / 16 * 16;
    let quality = q.get("q").and_then(|v| v.parse::<u8>().ok()).unwrap_or(1).min(2);
    let fps = q.get("fps").and_then(|v| v.parse::<u32>().ok()).unwrap_or(30).clamp(5, 60);
    let (tx, rx) = mpsc::sync_channel::<Out>(6);
    let mut w = match s.try_clone() {
        Ok(w) => w,
        Err(_) => return,
    };
    let _ = w.set_write_timeout(Some(Duration::from_secs(10)));
    let writer = std::thread::spawn(move || {
        for m in rx {
            let r = match m {
                Out::Video(p, _) => ws::write(&mut w, 2, &p),
                Out::Bin(b) => ws::write(&mut w, 2, &b),
                Out::Text(t) => ws::write(&mut w, 1, t.as_bytes()),
                Out::Pong(p) => ws::write(&mut w, 0xa, &p),
                Out::Close => {
                    let _ = ws::write(&mut w, 8, &[]);
                    break;
                }
            };
            if r.is_err() {
                break;
            }
        }
        let _ = w.shutdown(std::net::Shutdown::Both);
    });
    let control = g.role == Role::Control;
    let state = |inst: &Instance| json!({"t": "state", "orientation": inst.orientation(), "hinge": inst.hinge(), "inner_active": inst.inner_active(), "running": crate::ring::Ring::new(&inst.ring).seq() != 0});
    let _ = tx.send(Out::Text(
        json!({"t": "hello", "role": g.role, "phone": inst.id, "name": inst.name, "model": inst.model, "platform": inst.platform, "two_screens": inst.inner.is_some(),
               "codec": if codec == Codec::H264 { "h264" } else { "jpeg" }, "expires": g.expires, "poses": hid::HINGE_POSES.iter().map(|p| json!({"key": p.key, "label": p.label})).collect::<Vec<_>>()})
        .to_string(),
    ));
    let (streamer, sub) = video::join(&inst, StreamKey { phone: inst.id.clone(), codec, width, quality, fps }, tx.clone());
    let mut r = s;
    let _ = r.set_read_timeout(Some(Duration::from_millis(1000)));
    let mut input = Input::new(&inst);
    let mut last_state = Value::Null;
    let mut last_check = Instant::now() - Duration::from_secs(5);
    loop {
        if last_check.elapsed() >= Duration::from_millis(900) {
            last_check = Instant::now();
            let st = state(&inst);
            if st != last_state {
                last_state = st.clone();
                if tx.send(Out::Text(st.to_string())).is_err() {
                    break;
                }
            }
            if g.expires.is_some_and(|e| e <= now_s()) {
                let _ = tx.send(Out::Text(json!({"t": "expired"}).to_string()));
                break;
            }
        }
        match ws::read(&mut r) {
            Ok(ws::Msg::Text(t)) => {
                let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                match v["t"].as_str() {
                    Some("key-frame") => streamer.request_key(),
                    Some("ping") => {
                        let _ = tx.send(Out::Text(json!({"t": "pong", "c": v["c"]}).to_string()));
                    }
                    _ if control => {
                        if let Err(e) = input.handle(&v) {
                            let _ = tx.send(Out::Text(json!({"t": "error", "error": e}).to_string()));
                        }
                    }
                    _ => {
                        let _ = tx.send(Out::Text(json!({"t": "error", "error": "this link can only watch"}).to_string()));
                    }
                }
            }
            Ok(ws::Msg::Ping(p)) => {
                let _ = tx.send(Out::Pong(p));
            }
            Ok(ws::Msg::Close) => break,
            Ok(_) => {}
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
            Err(_) => break,
        }
    }
    input.release();
    streamer.leave(sub);
    let _ = tx.send(Out::Close);
    drop(tx);
    let _ = writer.join();
}

/// Input from a browser to the phone (the launcher viewer's rules: touches upright, turned to the panel; the edge rule)
struct Input {
    inst: Instance,
    hid: Hid,
    orient: u32,
    size: (u32, u32),
    down_buttons: Vec<String>,
    down_keys: Vec<u32>,
}

const BUTTONS: [&str; 14] = ["home", "lock", "side", "volup", "voldown", "siri", "action", "wallet", "playpause", "tv", "select", "menu", "back", "mute"];

impl Input {
    fn new(inst: &Instance) -> Input {
        let mut i = Input { inst: inst.clone(), hid: Hid::new(&inst.sock), orient: 0, size: inst.screen, down_buttons: vec![], down_keys: vec![] };
        i.aim();
        i
    }

    fn aim(&mut self) {
        let t = video::target(&self.inst, &mut self.orient);
        self.hid.display = t.display;
        self.hid.main_rot = t.main_rot;
        self.size = t.size;
    }

    /// lets go of anything held when the viewer goes away (a closed tab must not leave a button pressed)
    fn release(&mut self) {
        for b in std::mem::take(&mut self.down_buttons) {
            self.hid.button(&b, false);
        }
        for k in std::mem::take(&mut self.down_keys) {
            self.hid.key(false, k);
        }
    }

    fn handle(&mut self, v: &Value) -> Result<(), String> {
        let f = |k: &str| v[k].as_f64().unwrap_or(0.0) as f32;
        let phase = |v: &Value| -> Result<&'static str, String> {
            match v["p"].as_str() {
                Some("down") => Ok("down"),
                Some("move") => Ok("move"),
                Some("up") => Ok("up"),
                _ => Err("p: down, move or up".into()),
            }
        };
        match v["t"].as_str().unwrap_or("") {
            "touch" => {
                let p = phase(v)?;
                if p == "down" {
                    self.aim();
                }
                let (x, y) = (f("x"), f("y"));
                let edge = if p == "down" && v["edge"].as_bool() != Some(false) { hid::edge_at(x, y, self.size.0, self.size.1) } else { None };
                self.hid.touch(p, x, y, edge);
            }
            "touch2" => {
                let p = phase(v)?;
                if p == "down" {
                    self.aim();
                }
                self.hid.touch2(p, f("x1"), f("y1"), f("x2"), f("y2"));
            }
            "key" => {
                let u = v["u"].as_u64().ok_or("u: HID usage")? as u32;
                if !(4..=0xe7).contains(&u) {
                    return Err("usage out of range".into());
                }
                let down = v["d"].as_bool().unwrap_or(true);
                self.down_keys.retain(|k| *k != u);
                if down {
                    self.down_keys.push(u);
                }
                self.hid.key(down, u);
            }
            "text" => {
                let s = v["s"].as_str().unwrap_or("");
                let mut skipped = 0;
                for c in s.chars().take(4000) {
                    match char_usage(c) {
                        Some((u, sh)) => {
                            if sh {
                                self.hid.key(true, 225);
                            }
                            self.hid.key(true, u);
                            self.hid.key(false, u);
                            if sh {
                                self.hid.key(false, 225);
                            }
                        }
                        None => skipped += 1,
                    }
                }
                if skipped > 0 {
                    return Err(format!("{skipped} characters have no key on a US keyboard and were left out"));
                }
            }
            "button" => {
                let n = v["n"].as_str().unwrap_or("");
                if !BUTTONS.contains(&n) {
                    return Err(format!("unknown button {n}"));
                }
                match v["d"].as_bool() {
                    Some(d) => {
                        self.down_buttons.retain(|b| b != n);
                        if d {
                            self.down_buttons.push(n.to_string());
                        }
                        self.hid.button(n, d);
                    }
                    None => self.hid.hold(n, v["ms"].as_u64().unwrap_or(100).min(10_000)),
                }
            }
            "crown" => self.hid.crown(f("d").clamp(-2000.0, 2000.0)),
            // the system pointer (Vision Pro: the mouse is the pointer there, touches reach nothing; an iPad's mouse):
            // a place on the screen as shown (0..1), the button, a scroll
            "pointer" => {
                let line = match v["a"].as_str().unwrap_or("") {
                    "at" => format!("pointer at {:.5} {:.5}", f("x").clamp(0.0, 1.0), f("y").clamp(0.0, 1.0)),
                    "down" => "pointer button down".into(),
                    "up" => "pointer button up".into(),
                    "click" => "pointer click".into(),
                    "scroll" => format!("pointer scroll {:.2} {:.2}", f("dx").clamp(-2000.0, 2000.0), f("dy").clamp(-2000.0, 2000.0)),
                    a => return Err(format!("pointer: at, down, up, click or scroll, not {a:?}")),
                };
                self.hid.send(&line);
            }
            "rotate" => self.hid.rotate(v["dir"].as_str() == Some("left")),
            "shake" => self.hid.shake(),
            "hinge" => {
                self.inst.inner.as_ref().ok_or("this phone has one screen")?;
                let k = v["pose"].as_str().unwrap_or("");
                let pose = hid::HINGE_POSES.iter().find(|p| p.key == k).ok_or("unknown pose")?;
                self.hid.hinge_pose(pose);
            }
            "sys" => {
                let line = match v["a"].as_str().unwrap_or("") {
                    "app_switcher" => "appswitcher",
                    "memory_warning" => {
                        self.inst.memory_warning().map_err(|e| e.to_string())?;
                        return Ok(());
                    }
                    "soft_keyboard" => {
                        self.hid.soft_keyboard_toggle();
                        return Ok(());
                    }
                    "hw_keyboard" => {
                        let on = !self.hid.hw_keyboard_connected();
                        self.hid.hw_keyboard(on);
                        return Ok(());
                    }
                    "double_tap" => "gesture doubletap",
                    "wrist_flick" => "gesture wristflick",
                    a => return Err(format!("unknown action {a}")),
                };
                self.hid.send(line);
            }
            "usage" => {
                // consumer-page buttons the Siri Remote has (page 0x0c only)
                let u = v["u"].as_u64().unwrap_or(0) as u32;
                self.hid.usage(0x0c, u, true);
                self.hid.usage(0x0c, u, false);
            }
            t => return Err(format!("unknown input {t}")),
        }
        Ok(())
    }
}

/// A typed character -> (HID usage, needs shift), US layout (as the launcher viewer types a paste)
pub fn char_usage(c: char) -> Option<(u32, bool)> {
    const SHIFTED: &str = "!@#$%^&*()";
    Some(match c {
        'a'..='z' => (4 + (c as u32 - 'a' as u32), false),
        'A'..='Z' => (4 + (c as u32 - 'A' as u32), true),
        '1'..='9' => (0x1e + (c as u32 - '1' as u32), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        '\t' => (0x2b, false),
        ' ' => (0x2c, false),
        '-' => (0x2d, false),
        '_' => (0x2d, true),
        '=' => (0x2e, false),
        '+' => (0x2e, true),
        '[' => (0x2f, false),
        '{' => (0x2f, true),
        ']' => (0x30, false),
        '}' => (0x30, true),
        '\\' => (0x31, false),
        '|' => (0x31, true),
        ';' => (0x33, false),
        ':' => (0x33, true),
        '\'' => (0x34, false),
        '"' => (0x34, true),
        '`' => (0x35, false),
        '~' => (0x35, true),
        ',' => (0x36, false),
        '<' => (0x36, true),
        '.' => (0x37, false),
        '>' => (0x37, true),
        '/' => (0x38, false),
        '?' => (0x38, true),
        c if SHIFTED.contains(c) => (0x1e + SHIFTED.find(c).unwrap() as u32, true),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(peer: &str, headers: &[(&str, &str)]) -> Req {
        Req {
            method: "GET".into(),
            path: "/".into(),
            query: HashMap::new(),
            headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            body: vec![],
            peer: peer.parse().unwrap(),
        }
    }

    #[test]
    fn only_a_plain_local_browser_goes_without_a_token() {
        assert!(local_trusted(&req("127.0.0.1:5000", &[("host", "127.0.0.1:7380")])));
        assert!(local_trusted(&req("127.0.0.1:5000", &[("host", "localhost:7380"), ("origin", "http://localhost:7380")])));
        // a LAN peer, a tunnel (loopback peer with forwarding headers), DNS rebinding (foreign Host), another origin
        assert!(!local_trusted(&req("192.168.1.9:5000", &[("host", "127.0.0.1:7380")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[("host", "desktop.tail.ts.net"), ("x-forwarded-for", "100.1.2.3")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[("host", "abc.trycloudflare.com"), ("cf-connecting-ip", "1.2.3.4")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[("host", "127.0.0.1:7380"), ("cf-ray", "x")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[("host", "evil.example:7380")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[("host", "127.0.0.1:7380"), ("origin", "http://evil.example")])));
        assert!(!local_trusted(&req("127.0.0.1:5000", &[])));
    }

    #[test]
    fn tokens_roles_and_expiry() {
        let srv = Server::new(Options::default(), 0);
        let st = srv.state();
        let with = |t: &str| {
            let mut r = req("10.0.0.2:1", &[("host", "x")]);
            r.query.insert("t".into(), t.into());
            r
        };
        assert_eq!(srv.grant(&with(&st.control_token)).unwrap().role, Role::Control);
        assert_eq!(srv.grant(&with(&st.view_token)).unwrap().role, Role::View);
        assert!(srv.grant(&with("nope")).is_none());
        assert!(srv.grant(&req("10.0.0.2:1", &[("host", "x")])).is_none());
        let l = srv.mint(Role::View, Some("device-a64-x".into()), Some(0), "t");
        assert!(srv.grant(&with(&l.token)).is_none(), "a link with no time left is refused");
        let l = srv.mint(Role::View, Some("device-a64-x".into()), Some(60), "t");
        let g = srv.grant(&with(&l.token)).unwrap();
        assert_eq!(g.phone.as_deref(), Some("device-a64-x"));
        assert!(!srv.visible(&g, "device-a64-y"));
    }

    #[test]
    fn typing_maps_us_keys() {
        assert_eq!(char_usage('a'), Some((4, false)));
        assert_eq!(char_usage('Z'), Some((29, true)));
        assert_eq!(char_usage('!'), Some((0x1e, true)));
        assert_eq!(char_usage(')'), Some((0x27, true)));
        assert_eq!(char_usage('@'), Some((0x1f, true)));
        assert_eq!(char_usage('é'), None);
        assert_eq!(pct_decode("a%20b+c%2F"), "a b c/");
        assert_eq!(host_only("[::1]:7380"), "[::1]");
        assert!(is_loopback_name("localhost:1"));
    }
}
