//! x86sim-devapp: turn an .ipa / .xcarchive / device .app into a simulator .app (x86sim-core's devapp module).
//! `x86sim install` runs it before installing; on its own:
//!   x86sim-devapp convert INPUT [--work DIR] [--json]   prints the .app to install (the input for a simulator .app)
//!   x86sim-devapp inspect INPUT [--json]                what it is: platform, encryption, slices per binary
use x86sim_core::devapp;

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let json = a.iter().any(|x| x == "--json");
    let work = a.iter().position(|x| x == "--work").and_then(|i| a.get(i + 1)).map(std::path::PathBuf::from);
    let (Some(cmd), Some(input)) = (a.first(), a.iter().skip(1).find(|x| !x.starts_with("--") && Some(*x) != work.as_ref().map(|w| w.to_string_lossy().into_owned()).as_ref())) else {
        eprintln!("usage: x86sim-devapp convert|inspect INPUT(.ipa|.app|.xcarchive) [--work DIR] [--json]");
        std::process::exit(2);
    };
    let work = work.unwrap_or_else(|| devapp::work_dir().join(format!("{}-{}", if cmd == "inspect" { "inspect" } else { "convert" }, std::process::id())));
    let r = devapp::prepare(std::path::Path::new(input), &work);
    match r {
        Ok(p) => {
            if json {
                println!("{}", serde_json::to_string_pretty(&p).unwrap_or_default());
            } else if cmd == "inspect" {
                println!("{}: {}{}", input, p.kind, if p.converted { " (converted for the simulator)" } else { "" });
                for b in &p.binaries {
                    println!("  {:<50} {}{}{}", b.path, b.platform_name, if b.entitlements { ", entitlements" } else { "" }, if b.dropped_slices.is_empty() { String::new() } else { format!(", dropped {}", b.dropped_slices.join(" ")) });
                }
                for n in &p.notes {
                    println!("  note: {n}");
                }
            } else {
                for n in &p.notes {
                    eprintln!("devapp: {n}");
                }
                if p.converted {
                    eprintln!("devapp: {} -> simulator app ({} binaries retagged)", p.kind, p.binaries.iter().filter(|b| b.changed).count());
                }
                println!("{}", p.app.display());
            }
            if cmd == "inspect" && work.exists() {
                let _ = std::fs::remove_dir_all(&work);
            }
        }
        Err(e) => {
            let _ = std::fs::remove_dir_all(&work);
            eprintln!("x86sim install: {e:#}");
            std::process::exit(1);
        }
    }
}
