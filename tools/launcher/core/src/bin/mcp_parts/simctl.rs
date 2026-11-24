//! x86sim-mcp: simctl-parity tools (deleting an OS version, ui / status bar / pasteboard / keychain / language / time
//! zone / fidelity, erase / clone, app logs, video recording). Kept apart from mcp.rs's own tools so the two merge
//! easily; mcp.rs adds `tools()` to its list and asks `call()` first.
//! Phone commands run cli/x86sim (cli/libexec/devctl.py, simctl.py) with the phone's dir, as apps.rs does.
use serde_json::{json, Value};
use std::process::Command;
use x86sim_core::{aot::repo_root, instance, rtdelete};

pub fn tools(phone: &Value) -> Vec<Value> {
    vec![
        json!({"name": "runtime_delete", "description": "Delete an installed OS version (see sim_devices runtimes; name it by build, e.g. \"24K150\"). Without confirm=true it only reports what would go: sizes of the version's files (all=false) and of everything (all=true: also its pre-translated code jc-<build>, its files in shared caches, its download log; data other versions use is kept), the phones on it, and what blocks it. A running phone on it blocks the delete unless stop_running=true (it is stopped first). Phones on a deleted version show \"Files missing\" until it is downloaded again. A build deleted earlier with all=false can be named again to remove its leftover pre-translated code.",
               "inputSchema": {"type": "object", "properties": {"build": {"type": "string"}, "all": {"type": "boolean"}, "confirm": {"type": "boolean"}, "stop_running": {"type": "boolean"}}, "required": ["build"]}}),
        json!({"name": "sim_ui", "description": "As simctl ui: appearance (light|dark), content_size (Dynamic Type: extra-small, small, medium, large, extra-large, extra-extra-large, extra-extra-extra-large, accessibility-medium .. accessibility-extra-extra-extra-large, increment, decrement), increase_contrast / reduce_transparency / reduce_motion (enabled|disabled). Without value: reads it; without setting: every setting. A running phone changes at once; one that is off at its next boot.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "setting": {"type": "string", "enum": ["appearance", "content_size", "increase_contrast", "reduce_transparency", "reduce_motion"]}, "value": {"type": "string"}}}}),
        json!({"name": "sim_status_bar", "description": "As simctl status_bar (clean screenshots) on a running phone: override (only the fields given change; overrides add up), clear, or list. time is shown as given (\"9:41\") or an ISO 8601 date.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "action": {"type": "string", "enum": ["override", "clear", "list"]},
                   "time": {"type": "string"}, "dataNetwork": {"type": "string", "enum": ["hide", "wifi", "3g", "4g", "lte", "lte-a", "lte+", "5g", "5g+", "5g-uwb", "5g-uc"]},
                   "wifiMode": {"type": "string", "enum": ["searching", "failed", "active"]}, "wifiBars": {"type": "integer", "minimum": 0, "maximum": 3},
                   "cellularMode": {"type": "string", "enum": ["notSupported", "searching", "failed", "active"]}, "cellularBars": {"type": "integer", "minimum": 0, "maximum": 4},
                   "operatorName": {"type": "string"}, "batteryState": {"type": "string", "enum": ["charging", "charged", "discharging"]}, "batteryLevel": {"type": "integer", "minimum": 0, "maximum": 100}}, "required": ["action"]}}),
        json!({"name": "sim_pasteboard", "description": "The running phone's pasteboard (simctl pbcopy / pbpaste): get, set (text), from_host (the host clipboard onto the phone), to_host (the phone's onto the host clipboard).",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "action": {"type": "string", "enum": ["get", "set", "from_host", "to_host"]}, "text": {"type": "string"}}, "required": ["action"]}}),
        json!({"name": "sim_erase", "description": "Erase a phone that is off back to a new one (simctl erase): apps, data and settings go; model, name, version and features stay. Its next start is a first boot.",
               "inputSchema": {"type": "object", "properties": {"phone": phone}, "required": ["phone"]}}),
        json!({"name": "sim_clone", "description": "Copy a phone that is off as a new phone with the given name (simctl clone): same model, version, apps and data (reflinked: no space until it changes).",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "name": {"type": "string"}}, "required": ["phone", "name"]}}),
        json!({"name": "app_logs", "description": "An app's logs in one answer: the crash report of its last run that crashed (the translator's guest backtrace, symbolicated against the dyld cache and the app) and the tail of its os_log file (recorded when it was launched with os_log on: relaunch=true restarts it that way and returns what it logs in the next `secs` seconds).",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "bundle_id": {"type": "string"}, "lines": {"type": "integer"}, "relaunch": {"type": "boolean"}, "secs": {"type": "number"}}, "required": ["bundle_id"]}}),
        json!({"name": "sim_keychain_reset", "description": "Delete every keychain item (simctl keychain reset).", "inputSchema": {"type": "object", "properties": {"phone": phone}}}),
        json!({"name": "sim_locale", "description": "The phone's language order and region (Settings > Language & Region): languages e.g. [\"fr-CA\", \"en\"], locale e.g. \"fr_CA\". Without either: reads them. Apps take it at their next start.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "languages": {"type": "array", "items": {"type": "string"}}, "locale": {"type": "string"}}}}),
        json!({"name": "sim_timezone", "description": "The phone's time zone (an Olson name such as Europe/Paris, or \"host\" for the computer's); applies at its next boot. Without zone: reads it.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "zone": {"type": "string"}}}}),
        json!({"name": "sim_fidelity", "description": "Speed vs looks per phone: fast = a 3x iPhone drawn at 2x (same layout, 4/9 of the pixels) plus Reduce Transparency and Reduce Motion; high = native scale and every effect. Effects change at once on a running phone, the scale at its next boot (sim_restart). Without preset: reads it.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "preset": {"type": "string", "enum": ["fast", "high"]}}}}),
        json!({"name": "sim_record_video", "description": "Record the running phone's screen to an MP4 (simctl io recordVideo) for secs seconds (default 5, max 300); returns the file's path and size.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "path": {"type": "string"}, "secs": {"type": "number"}, "codec": {"type": "string", "enum": ["h264", "hevc"]}}, "required": ["path"]}}),
        json!({"name": "sim_screenshot", "description": "The running phone's newest frame as a PNG (simctl io screenshot); returns the path.",
               "inputSchema": {"type": "object", "properties": {"phone": phone, "path": {"type": "string"}}, "required": ["path"]}}),
    ]
}

fn x86sim(dev: &std::path::Path, cmd: &str, args: &[String]) -> anyhow::Result<String> {
    let out = Command::new(repo_root().join("cli/x86sim")).arg(cmd).arg(dev).args(args).current_dir(repo_root()).stdin(std::process::Stdio::null()).output()?;
    let text = String::from_utf8_lossy(&out.stdout).trim_end().to_string();
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    anyhow::ensure!(out.status.success(), "{}", if err.is_empty() { text } else { err });
    Ok(text)
}

fn s(a: &Value, k: &str) -> Option<String> {
    a[k].as_str().map(String::from).or_else(|| a[k].as_i64().map(|n| n.to_string()))
}

/// Some(result) for the tools of this module, None for others.
pub fn call(name: &str, a: &Value, phone: &dyn Fn() -> anyhow::Result<instance::Instance>) -> Option<anyhow::Result<Value>> {
    let r = match name {
        "runtime_delete" => (|| {
            let r = rtdelete::find(a["build"].as_str().unwrap_or(""))?;
            let mut plan = rtdelete::plan(&r);
            let all = a["all"].as_bool().unwrap_or(false);
            if !a["confirm"].as_bool().unwrap_or(false) {
                return Ok(json!({"plan": plan, "would_free_bytes": plan.runtime_bytes + if all { plan.caches_bytes } else { 0 }, "note": "nothing deleted: call again with confirm=true"}));
            }
            if a["stop_running"].as_bool().unwrap_or(false) && !plan.running_devices().is_empty() {
                rtdelete::stop_devices(&plan, 120)?;
                plan = rtdelete::plan(&r);
            }
            let freed = rtdelete::delete(&plan, all)?;
            Ok(json!({"deleted": plan.dir, "label": plan.label, "all": all, "freed_bytes": freed, "phones_on_it": plan.devices}))
        })(),
        // destructive: only on a phone the caller named, never the "only running phone" / configured default
        "sim_erase" | "sim_clone" | "sim_keychain_reset" if a["phone"].as_str().or(a["device"].as_str()).is_none_or(|s| s.is_empty()) => {
            Err(anyhow::anyhow!("{name} needs phone: name the phone it acts on (phones_list)"))
        }
        _ => {
            let inst = match phone() {
                Ok(i) => i,
                Err(e) if is_ours(name) => return Some(Err(e)),
                Err(_) => return None,
            };
            let d = inst.dir.clone();
            let opt = |k: &str| s(a, k);
            let seq0 = x86sim_core::ax::frame_seq(&inst);
            let res = match name {
                "sim_ui" => {
                    let mut v = vec![];
                    v.extend(opt("setting"));
                    v.extend(opt("value"));
                    x86sim(&d, "ui", &v).map(|t| json!({"phone": inst.name, "ui": t}))
                }
                "sim_status_bar" => {
                    let mut v = vec![opt("action").unwrap_or_default()];
                    for k in ["time", "dataNetwork", "wifiMode", "wifiBars", "cellularMode", "cellularBars", "operatorName", "batteryState", "batteryLevel"] {
                        if let Some(x) = opt(k) {
                            v.push(format!("--{k}"));
                            v.push(x);
                        }
                    }
                    x86sim(&d, "status_bar", &v).map(|t| json!({"phone": inst.name, "overrides": t}))
                }
                "sim_pasteboard" => match a["action"].as_str().unwrap_or("") {
                    "get" => x86sim(&d, "pbpaste", &[]).map(|t| json!({"phone": inst.name, "text": t})),
                    "to_host" => x86sim(&d, "pbpaste", &["--host".into()]).map(|t| json!({"phone": inst.name, "text": t, "host": true})),
                    "from_host" => x86sim(&d, "pbcopy", &["--host".into()]).map(|_| json!({"phone": inst.name, "from_host": true})),
                    "set" => x86sim(&d, "pbcopy", &[opt("text").unwrap_or_default()]).map(|_| json!({"phone": inst.name, "set": true})),
                    o => Err(anyhow::anyhow!("action {o:?}: get, set, from_host or to_host")),
                },
                "sim_erase" => x86sim(&d, "erase", &[]).map(|t| json!({"phone": inst.name, "erased": t})),
                "sim_clone" => x86sim(&d, "clone", &[opt("name").unwrap_or_default()]).map(|t| json!({"phone": inst.name, "clone": t, "name": opt("name")})),
                "app_logs" => {
                    let bid = opt("bundle_id").unwrap_or_default();
                    let mut v = vec![bid, "--lines".into(), a["lines"].as_u64().unwrap_or(60).to_string()];
                    if a["relaunch"].as_bool().unwrap_or(false) {
                        // devctl follows after a relaunch: let it run for `secs`, then stop it (SIGINT ends the follow)
                        v.push("--relaunch".into());
                        let secs = a["secs"].as_f64().unwrap_or(8.0).clamp(1.0, 120.0);
                        let child = Command::new(repo_root().join("cli/x86sim"))
                            .arg("logs")
                            .arg(&d)
                            .args(&v)
                            .current_dir(repo_root())
                            .stdin(std::process::Stdio::null())
                            .stdout(std::process::Stdio::piped())
                            .stderr(std::process::Stdio::piped())
                            .spawn();
                        return Some(child.map_err(anyhow::Error::from).and_then(|c| {
                            let pid = c.id() as i32;
                            std::thread::sleep(std::time::Duration::from_secs_f64(secs));
                            unsafe {
                                libc::kill(pid, libc::SIGINT);
                            }
                            let o = c.wait_with_output()?;
                            Ok(json!({"phone": inst.name, "log": String::from_utf8_lossy(&o.stdout), "stderr": String::from_utf8_lossy(&o.stderr)}))
                        }));
                    }
                    x86sim(&d, "logs", &v).map(|t| json!({"phone": inst.name, "log": t}))
                }
                "sim_keychain_reset" => x86sim(&d, "keychain", &["reset".into()]).map(|_| json!({"phone": inst.name, "keychain": "reset"})),
                "sim_locale" => {
                    let mut v = vec![];
                    if let Some(l) = a["languages"].as_array() {
                        v.push("--language".into());
                        v.push(l.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(","));
                    }
                    if let Some(l) = opt("locale") {
                        v.push("--locale".into());
                        v.push(l);
                    }
                    x86sim(&d, "locale", &v).map(|t| json!({"phone": inst.name, "locale": t}))
                }
                "sim_timezone" => x86sim(&d, "timezone", &opt("zone").into_iter().collect::<Vec<_>>()).map(|t| json!({"phone": inst.name, "timezone": t})),
                "sim_fidelity" => x86sim(&d, "fidelity", &opt("preset").into_iter().collect::<Vec<_>>()).map(|t| json!({"phone": inst.name, "fidelity": t})),
                "sim_record_video" => {
                    let path = opt("path").unwrap_or_default();
                    let secs = a["secs"].as_f64().unwrap_or(5.0).clamp(0.5, 300.0);
                    let v = vec!["recordVideo".into(), "--codec".into(), opt("codec").unwrap_or_else(|| "h264".into()), "--secs".into(), secs.to_string(), path.clone()];
                    x86sim(&d, "io", &v).and_then(|_| {
                        let len = std::fs::metadata(&path)?.len();
                        Ok(json!({"phone": inst.name, "path": path, "bytes": len, "secs": secs}))
                    })
                }
                "sim_screenshot" => {
                    let path = opt("path").unwrap_or_default();
                    x86sim(&d, "io", &["screenshot".into(), path.clone()]).map(|_| json!({"phone": inst.name, "path": path}))
                }
                _ => return None,
            };
            // what changes the screen answers once it shows: a screenshot taken right after has the new look
            if res.is_ok() && matches!(name, "sim_ui" | "sim_status_bar" | "sim_locale" | "sim_timezone") {
                use std::time::Duration;
                x86sim_core::ax::settle_since(&inst, seq0, Duration::from_secs(3), Duration::from_millis(350), Duration::from_secs(6));
            }
            res
        }
    };
    Some(r)
}

fn is_ours(name: &str) -> bool {
    matches!(
        name,
        "sim_ui" | "sim_status_bar" | "sim_pasteboard" | "sim_erase" | "sim_clone" | "app_logs" | "sim_keychain_reset" | "sim_locale" | "sim_timezone" | "sim_fidelity" | "sim_record_video" | "sim_screenshot"
    )
}
