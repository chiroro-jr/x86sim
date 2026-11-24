//! x86sim-mcp: a small MCP server (JSON-RPC 2.0 over stdio, one message per line) for the x86Sim arm64 simulator:
//! feature toggles (list / get / set / preset), sim control (status / start / stop / restart to apply) and the AOT
//! image status. Uses x86sim-core like the CLI and the GUI.
//!
//! Register it with an MCP client, e.g. `claude mcp add x86sim -- /path/to/x86sim-mcp`.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use x86sim_core::{aot, apps, features, instance, sim};

fn tools() -> Value {
    let phone = json!({"type": "string", "description": "the phone: its name (as in the hub, e.g. \"QA\"), folder (device-a64-qa) or path. Default: the only running phone, else the configured one"});
    let mut t = json!([
        {"name": "phones_list", "description": "Every phone, as the hub shows it: name, model, iOS version and whether it is installed, state (off / starting / running / stopping), home screen reached, memory (MB), CPU %, processes, uptime.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "sim_status", "description": "Same as phones_list (kept for older clients).",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "features_list", "description": "List a phone's optional features: id, title, on/off, default, measured memory cost (MB) and whether it is paid every boot or only when used. Changes apply at the next boot.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "feature_get", "description": "Whether one feature is on.",
         "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "phone": phone}, "required": ["id"]}},
        {"name": "feature_set", "description": "Turn a feature on or off (wallpaper, spotlight, keyboard, siri, maps, photos, files, wallet, health, widgets). Applies at the next boot: call sim_restart.",
         "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "enabled": {"type": "boolean"}, "phone": phone}, "required": ["id", "enabled"]}},
        {"name": "features_preset", "description": "Apply a preset: full (the default set), lean, minimal. Applies at the next boot.",
         "inputSchema": {"type": "object", "properties": {"name": {"type": "string", "enum": ["full", "lean", "minimal"]}, "phone": phone}, "required": ["name"]}},
        {"name": "sim_devices", "description": "Phones (folder, label with phone model, iOS), the phone models a new phone can be and the installed iOS versions.",
         "inputSchema": {"type": "object", "properties": {}}},
        {"name": "sim_add_device", "description": "Make a new phone of a model (see sim_devices models), optional name and version (ios, e.g. \"27.2\": iOS for an iPhone or iPad, tvOS for an Apple TV, watchOS for an Apple Watch, or a build such as \"24B91016s\"; see sim_devices runtimes; a model with a runtime of its own, the iPhone Duo's 24B91016s, gets that one). Start it with sim_start phone=<name>. Its first start can take a few minutes.",
         "inputSchema": {"type": "object", "properties": {"model": {"type": "string"}, "name": {"type": "string"}, "ios": {"type": "string"}}, "required": ["model"]}},
        {"name": "sim_start", "description": "Start a phone (its own container, so other phones keep running). Returns at once; poll phones_list for state running.", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_fold", "description": "Fold or unfold a two-screen phone (iPhone Duo): open=true opens it flat (the large inner screen takes over), open=false closes it (the outer screen); or angle in degrees (0 closed .. 180 flat; SpringBoard swaps screens at 85); or pose, a preset as in Xcode's DeviceHub: closed, half-portrait (90 degrees, portrait), half-landscape (90 degrees, landscape), open. The hinge moves over ms (default 600) as a hand would.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "open": {"type": "boolean"}, "angle": {"type": "number"}, "pose": {"type": "string", "enum": ["closed", "half-portrait", "half-landscape", "open"]}, "ms": {"type": "integer"}}}},
        {"name": "sim_button", "description": "Press a hardware button as Apple's simulator does (DeviceHub's Home, Lock, Side Button, Volume, Siri, Action Button, Apple Pay; an Apple TV's Siri Remote: select, menu (back), tv, playpause, siri). Per platform: on a watch home is the Digital Crown's press and side its side button. ms: how long it is held (default 100; e.g. 2500 on lock = Siri on an iPhone).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "name": {"type": "string", "enum": ["home", "lock", "side", "volup", "voldown", "siri", "action", "wallet", "playpause", "tv", "select", "menu", "back", "mute"]}, "ms": {"type": "integer"}}, "required": ["name"]}},
        {"name": "sim_crown", "description": "Turn the Digital Crown (Apple Watch, Vision Pro): delta per step (positive = down / towards the bottom; ~120 scrolls a watch list one row), steps (default 8, 30 ms apart).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "delta": {"type": "number"}, "steps": {"type": "integer"}}, "required": ["delta"]}},
        {"name": "sim_shake", "description": "Device > Shake: the app in front gets a shake motion event (e.g. Undo Typing).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_orientation", "description": "The device orientation (iPhone, iPad), as Rotate Left / Right or devicectl device orientation: set one (portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown) or rotate left / right; with neither, just reports it. The screen image stays in the panel's own orientation (as Apple's framebuffer): landscape content is drawn sideways.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "set": {"type": "string", "enum": ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight", "faceUp", "faceDown"]}, "rotate": {"type": "string", "enum": ["left", "right"]}}}},
        {"name": "sim_biometric", "description": "Face ID / Touch ID / Optic ID as Apple's simulator: enroll or unenroll (Features > Face ID > Enrolled), then match / nomatch to answer an authentication the app asked for (LAContext.evaluatePolicy). kind: face, touch or optic (default: the device's).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "action": {"type": "string", "enum": ["enroll", "unenroll", "match", "nomatch"]}, "kind": {"type": "string", "enum": ["face", "touch", "optic"]}}, "required": ["action"]}},
        {"name": "sim_gamepad", "description": "The simulated game controller (\"Gamepad\", an extended gamepad; iPhone, iPad, Apple TV, Vision Pro; GCController.controllers() lists it): press a button (or hold it down / let it up), or set a thumbstick (stick left|right, x, y in -1..1, y up).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "button": {"type": "string", "enum": ["up", "down", "left", "right", "a", "b", "x", "y", "l1", "r1", "l2", "r2"]}, "action": {"type": "string", "enum": ["press", "down", "up"]}, "stick": {"type": "string", "enum": ["left", "right"]}, "x": {"type": "number"}, "y": {"type": "number"}}}},
        {"name": "sim_pointer", "description": "An iPad's mouse, as Apple's simulator's pointer capture (the iPad gets a mouse at the first call and draws its pointer; remove takes it away), or a Vision Pro's pointer: move by dx, dy points (the iPad speeds large moves up), at: put it at x, y (0..1 of the screen as shown, exact), click, button down / up, scroll by dx, dy (positive dy: down the page).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "action": {"type": "string", "enum": ["move", "at", "click", "down", "up", "scroll", "remove"]}, "dx": {"type": "number"}, "dy": {"type": "number"}, "x": {"type": "number"}, "y": {"type": "number"}}, "required": ["action"]}},
        {"name": "sim_system", "description": "Apple simulator controls without a button of their own: app_switcher (iPhone / iPad: the home button pressed twice), standby_show / standby_hide (iPhone StandBy; SpringBoard shows it when the phone is locked and in landscape: sim_orientation, sim_button lock then home), double_tap / wrist_flick (Apple Watch hand gestures: the Smart Stack opens / closes on the watch face), trackpad_on / trackpad_off (an iPad's trackpad device, as Apple's Simulate Trackpad; its gestures are not simulated).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "action": {"type": "string", "enum": ["app_switcher", "standby_show", "standby_hide", "double_tap", "wrist_flick", "trackpad_on", "trackpad_off"]}}, "required": ["action"]}},
        {"name": "sim_memory_warning", "description": "Simulate Memory Warning: every process gets the memory-pressure event (apps: didReceiveMemoryWarning).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_stop", "description": "Stop a phone (only that phone).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "sim_restart", "description": "Restart a phone (stop, then start with its current features and the pre-translated code). Returns at once; poll phones_list.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "app_install", "description": "Install an iOS Simulator app (.app bundle built for arm64 iphonesimulator) on a running phone, as simctl install: installd installs it and the home screen shows its icon. Returns the bundle id.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "path": {"type": "string", "description": "the .app directory on this machine"}}, "required": ["path"]}},
        {"name": "app_uninstall", "description": "Uninstall an app from a running phone (simctl uninstall).",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "bundle_id": {"type": "string"}}, "required": ["bundle_id"]}},
        {"name": "app_launch", "description": "Open an app on a running phone by bundle id (simctl launch); args are passed to the app. Returns the pid.",
         "inputSchema": {"type": "object", "properties": {"phone": phone, "bundle_id": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}}}, "required": ["bundle_id"]}},
        {"name": "app_list", "description": "Installed apps on a running phone (simctl listapps).", "inputSchema": {"type": "object", "properties": {"phone": phone}}},
        {"name": "aot_status", "description": "Pre-translated code of a phone's iOS version: parts up to date / stale (with reasons) / missing, and the translator's codegen version.",
         "inputSchema": {"type": "object", "properties": {"phone": phone}}}
    ]);
    // ---- Share (browser streaming): share_start / share_stop / share_status / share_link, x86sim_core::share ----
    if let Value::Array(v) = &mut t {
        v.extend(x86sim_core::share::mcp_tools());
    }
    // ---- end Share ----
    t
}

/// The phone a call is about: phone / device argument, else the only running phone, else the configured one.
fn phone_of(a: &Value, cfg: &aot::Config) -> anyhow::Result<instance::Instance> {
    let key = a["phone"].as_str().or(a["device"].as_str());
    if let Some(k) = key {
        return instance::find(k).ok_or_else(|| {
            anyhow::anyhow!("no phone {k:?} (phones: {})", instance::list().iter().map(|i| i.name.clone()).collect::<Vec<_>>().join(", "))
        });
    }
    let running: Vec<_> = instance::summaries(0).into_iter().filter(|s| s.state != "off").collect();
    if running.len() == 1 {
        return instance::find(&running[0].id).ok_or_else(|| anyhow::anyhow!("phone vanished"));
    }
    let d = cfg.device.clone().ok_or_else(|| anyhow::anyhow!("say which phone (phone: name)"))?;
    Ok(instance::load(&d))
}

fn call(name: &str, a: &Value) -> anyhow::Result<Value> {
    // ---- Share (browser streaming) ----
    if let Some(r) = x86sim_core::share::mcp_call(name, a) {
        return r;
    }
    // ---- end Share ----
    let cfg = aot::Paths::new(&aot::Paths::default_jc()).load_config();
    if matches!(name, "phones_list" | "sim_status") {
        return Ok(json!({"phones": instance::summaries(1000)}));
    }
    if name == "sim_devices" {
        return Ok(json!({"devices": instance::list().into_iter().map(|i| json!({"name": i.name, "id": i.id, "label": format!("{} · {}", i.model, i.name), "path": i.dir, "ios": i.ios, "installed": i.runtime_present})).collect::<Vec<_>>(),
                         "models": sim::models().into_iter().map(|m| m.0).collect::<Vec<_>>(),
                         "runtimes": sim::runtimes().into_iter().map(|r| r.0).collect::<Vec<_>>()}));
    }
    if name == "sim_add_device" {
        let want = a["ios"].as_str().unwrap_or("27.2");
        // Models 2: a runtime limited to some models (iOS 27.2 24B91016s: iPhone Duo only) is taken for those models
        // first and never for others
        let model = a["model"].as_str().unwrap_or("");
        let model_id = sim::models().into_iter().find(|m| m.0 == model || m.1 == model).map(|m| m.1).unwrap_or_default();
        // Platforms 1: only runtimes of the model's platform (an Apple TV takes tvOS, an Apple Watch watchOS)
        let pname = sim::platform_name(sim::model_platform(&model_id));
        let cands: Vec<_> = sim::runtimes()
            .into_iter()
            .filter(|r| r.0.starts_with(&format!("{pname} ")))
            .filter(|r| r.0.starts_with(&format!("{pname} {want} ")) || r.0.contains(want))
            .filter(|r| sim::runtime_allows(&r.1, &model_id))
            .collect();
        let rt = cands
            .iter()
            .find(|r| !sim::runtime_restricted_to(&r.1).is_empty())
            .or(cands.first())
            .map(|r| r.1.clone())
            .ok_or_else(|| anyhow::anyhow!("no {pname} {want} installed for {model} (see sim_devices runtimes)"))?;
        return Ok(json!({"device": sim::create_device(a["model"].as_str().unwrap_or(""), a["name"].as_str().unwrap_or(""), &rt)?}));
    }
    let inst = phone_of(a, &cfg)?;
    let device = inst.dir.clone();
    Ok(match name {
        "features_list" => json!({"phone": inst.name, "preset": features::preset_of(&features::load(&device)), "features": features::list(&device)}),
        "feature_get" => {
            let id = a["id"].as_str().unwrap_or("");
            json!({"id": id, "enabled": features::load(&device).enabled(id)})
        }
        "feature_set" => {
            let id = a["id"].as_str().unwrap_or("");
            let on = a["enabled"].as_bool().ok_or_else(|| anyhow::anyhow!("enabled: boolean required"))?;
            features::set(&device, id, on)?;
            json!({"phone": inst.name, "id": id, "enabled": on, "note": "applies at the next boot (sim_restart)"})
        }
        "features_preset" => {
            let n = a["name"].as_str().unwrap_or("");
            features::apply_preset(&device, n)?;
            json!({"phone": inst.name, "preset": n, "features": features::list(&device), "note": "applies at the next boot (sim_restart)"})
        }
        "app_install" => json!({"phone": inst.name, "installed": apps::install(&inst, std::path::Path::new(a["path"].as_str().unwrap_or("")))?}),
        "app_uninstall" => json!({"phone": inst.name, "answer": apps::uninstall(&inst, a["bundle_id"].as_str().unwrap_or(""))?}),
        "app_launch" => {
            let args: Vec<String> = a["args"].as_array().map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            json!({"phone": inst.name, "answer": apps::launch(&inst, a["bundle_id"].as_str().unwrap_or(""), &args)?})
        }
        "app_list" => json!({"phone": inst.name, "answer": apps::list(&inst)?}),
        "sim_restart" => json!({"phone": inst.name, "restarting": true, "pid": sim::restart(&device)?}),
        "sim_start" => json!({"phone": inst.name, "starting": true, "pid": sim::start(&device)?}),
        "sim_fold" => {
            anyhow::ensure!(inst.inner.is_some(), "{} has one screen", inst.name);
            let pose = match a["pose"].as_str() {
                Some(k) => Some(x86sim_core::hid::HINGE_POSES.iter().find(|p| p.key == k).ok_or_else(|| anyhow::anyhow!("unknown pose {k}: closed, half-portrait, half-landscape, open"))?),
                None => None,
            };
            let deg = pose.map(|p| p.angle).or(a["angle"].as_f64()).unwrap_or(if a["open"].as_bool().unwrap_or(true) { 180.0 } else { 0.0 }).clamp(0.0, 180.0);
            let ms = a["ms"].as_u64().unwrap_or(600) as u32;
            let mut hid = x86sim_core::hid::Hid::new(&inst.sock);
            if let Some(o) = pose.and_then(|p| p.orientation) {
                hid.orientation(o);
            }
            hid.hinge(deg, ms);
            std::thread::sleep(std::time::Duration::from_millis(ms as u64 + 300));
            json!({"phone": inst.name, "hinge": inst.hinge(), "state": inst.hinge().map(x86sim_core::hid::hinge_state), "orientation": inst.orientation(), "screen": if inst.inner_active() { "inner" } else { "outer" }})
        }
        // Inputs 2: the inputs Apple's simulator offers besides touches and keys (host/simhid)
        "sim_button" => {
            let n = a["name"].as_str().unwrap_or("");
            anyhow::ensure!(!n.is_empty(), "name required");
            x86sim_core::hid::Hid::new(&inst.sock).press_for(n, a["ms"].as_u64().unwrap_or(100));
            json!({"phone": inst.name, "pressed": n})
        }
        "sim_crown" => {
            let d = a["delta"].as_f64().unwrap_or(0.0) as f32;
            let mut h = x86sim_core::hid::Hid::new(&inst.sock);
            for _ in 0..a["steps"].as_u64().unwrap_or(8) {
                h.crown(d);
                std::thread::sleep(std::time::Duration::from_millis(30));
            }
            json!({"phone": inst.name, "crown": d})
        }
        "sim_shake" => {
            x86sim_core::hid::Hid::new(&inst.sock).shake();
            json!({"phone": inst.name, "shaken": true})
        }
        "sim_orientation" => {
            let before = std::fs::metadata(inst.dir.join("data/orientation")).and_then(|m| m.modified()).ok();
            let mut h = x86sim_core::hid::Hid::new(&inst.sock);
            match (a["set"].as_str(), a["rotate"].as_str()) {
                (Some(o), _) => h.orientation(o),
                (None, Some(r)) => h.rotate(r == "left"),
                _ => h.orientation(""),
            }
            // simhid writes the orientation it ends up in
            for _ in 0..40 {
                std::thread::sleep(std::time::Duration::from_millis(50));
                if std::fs::metadata(inst.dir.join("data/orientation")).and_then(|m| m.modified()).ok() != before {
                    break;
                }
            }
            json!({"phone": inst.name, "orientation": inst.orientation()})
        }
        "sim_biometric" => {
            let act = a["action"].as_str().unwrap_or("");
            anyhow::ensure!(matches!(act, "enroll" | "unenroll" | "match" | "nomatch"), "action: enroll, unenroll, match or nomatch");
            x86sim_core::hid::Hid::new(&inst.sock).biometric(act, a["kind"].as_str().unwrap_or(""));
            json!({"phone": inst.name, "biometric": act})
        }
        "sim_gamepad" => {
            let mut h = x86sim_core::hid::Hid::new(&inst.sock);
            if let Some(st) = a["stick"].as_str() {
                h.gamepad_stick(st == "right", a["x"].as_f64().unwrap_or(0.0) as f32, a["y"].as_f64().unwrap_or(0.0) as f32);
            } else {
                let b = a["button"].as_str().ok_or_else(|| anyhow::anyhow!("button or stick required"))?;
                h.gamepad(b, a["action"].as_str().unwrap_or("press"));
                std::thread::sleep(std::time::Duration::from_millis(150));
            }
            json!({"phone": inst.name, "gamepad": a})
        }
        "sim_pointer" => {
            let (dx, dy) = (a["dx"].as_f64().unwrap_or(0.0), a["dy"].as_f64().unwrap_or(0.0));
            let line = match a["action"].as_str().unwrap_or("") {
                "move" => format!("pointer move {dx:.2} {dy:.2}"),
                "at" => format!("pointer at {:.5} {:.5}", a["x"].as_f64().unwrap_or(0.5), a["y"].as_f64().unwrap_or(0.5)),
                "scroll" => format!("pointer scroll {dx:.2} {dy:.2}"),
                "click" => "pointer click".into(),
                "down" => "pointer button down".into(),
                "up" => "pointer button up".into(),
                "remove" => "pointer remove".into(),
                o => anyhow::bail!("action {o:?}: move, at, click, down, up, scroll or remove"),
            };
            x86sim_core::hid::Hid::new(&inst.sock).send(&line);
            std::thread::sleep(std::time::Duration::from_millis(100));
            json!({"phone": inst.name, "pointer": line})
        }
        "sim_system" => {
            let line = match a["action"].as_str().unwrap_or("") {
                "app_switcher" => "appswitcher",
                "standby_show" => "standby show",
                "standby_hide" => "standby hide",
                "double_tap" => "gesture doubletap",
                "wrist_flick" => "gesture wristflick",
                "trackpad_on" => "trackpad on",
                "trackpad_off" => "trackpad off",
                o => anyhow::bail!("action {o:?}: app_switcher, standby_show, standby_hide, double_tap, wrist_flick, trackpad_on or trackpad_off"),
            };
            x86sim_core::hid::Hid::new(&inst.sock).send(line);
            std::thread::sleep(std::time::Duration::from_millis(300));
            // StandBy's backdrop comes from PosterBoard, which runs only with the "wallpaper" feature
            if line == "standby show" && !features::load(&device).enabled("wallpaper") {
                json!({"phone": inst.name, "done": line, "note": "the backdrop stays black: turn on feature wallpaper (PosterBoard) and sim_restart for the blurred widgets"})
            } else {
                json!({"phone": inst.name, "done": line})
            }
        }
        "sim_memory_warning" => {
            inst.memory_warning()?;
            json!({"phone": inst.name, "memory_warning": true})
        }
        "sim_stop" => {
            sim::stop(&device)?;
            json!({"phone": inst.name, "stopped": true})
        }
        "aot_status" => {
            // the phone's iOS version decides the image and its cache dir
            let rt = sim::device_runtime(&device);
            let p = aot::Paths::new(&sim::jc_for(&rt));
            let mut cfg = p.load_config();
            cfg.runtime_root = rt;
            cfg.device = Some(device.clone());
            let st = aot::plan(&p, &cfg)?.status(&p);
            let attention: Vec<_> = st.chunks.iter().filter(|c| c.state != "up-to-date").take(50).collect();
            json!({"phone": inst.name, "ios": inst.ios, "image": st.image, "image_current": st.image_current, "total": st.total, "up_to_date": st.up_to_date,
                   "stale": st.stale, "missing": st.missing, "codegen": format!("{:#x}", st.codegen), "codegen_source": st.codegen_source, "need_rebuild": attention})
        }
        _ => anyhow::bail!("unknown tool {name}"),
    })
}

fn main() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(req) = serde_json::from_str::<Value>(&line) else { continue };
        let id = req.get("id").cloned();
        let method = req["method"].as_str().unwrap_or("");
        let result: Result<Value, (i64, String)> = match method {
            "initialize" => Ok(json!({
                "protocolVersion": req["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "x86sim", "version": env!("CARGO_PKG_VERSION")}
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": tools()})),
            "tools/call" => {
                let name = req["params"]["name"].as_str().unwrap_or("");
                let args = req["params"].get("arguments").cloned().unwrap_or(json!({}));
                Ok(match call(name, &args) {
                    Ok(v) => json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default()}], "structuredContent": v}),
                    Err(e) => json!({"content": [{"type": "text", "text": format!("{e:#}")}], "isError": true}),
                })
            }
            m if m.starts_with("notifications/") => continue,
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        let Some(id) = id else { continue };
        let resp = match result {
            Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
            Err((c, m)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": c, "message": m}}),
        };
        let _ = writeln!(out, "{resp}");
        let _ = out.flush();
    }
}
