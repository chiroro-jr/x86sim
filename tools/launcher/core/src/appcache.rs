//! AOT cache 1: the AOT cache manages itself. Nothing here needs a user command; it runs from the normal flows:
//!
//! - app install / uninstall (`x86sim install|uninstall` -> `x86sim-aot app install|prune`): a transaction under the
//!   cache dir's lock. placeapp.py edits a *staged* copy of the placement table (stale app rows pruned, the new app
//!   in the first free gap, least recently used apps evicted when the window is full; system rows never move), the
//!   app's chunks are built against it, the image for the staged table is assembled, and only then is the table
//!   committed (a rename). Until that moment every phone keeps the last good table and the image named for it; if
//!   the build fails nothing is committed. A chunk that fails twice is left out of an image that is otherwise
//!   complete (aot::build_locked), so a failed app chunk never takes the system tier's image with it.
//! - every finished `x86sim-aot update` / `build`, and each boot (`x86sim-aot maintain`, from boot-a64.sh once the
//!   phone is idle): `collect` below, and at boot first a heal: if the image the current table names is missing it
//!   is assembled from the chunks that are up to date (seconds), instead of every process translating live.
//!
//! `collect` bounds what the cache dir keeps:
//! - images (and their .map / .idx / .prelude) of keys no table names any more;
//! - manifest records and chunk files of apps no longer placed, chunk files no record references (rebuilt, evicted
//!   or dropped chunks: 16 GB of 18 GB in aot/chunks on 2026-11-14), aot/evicted, leftover staging / work dirs;
//! - per-process caches of old keys: every placement change (each app install) is a new key, and the old key's
//!   `<key>.<exe>.bin` (translated code, up to 100+ MB each, never loaded again) and `.live` files stayed forever
//!   (20 GB of .bin, 1.5 GB of .live). Their block descriptors are training (hot.rs reads every key's files), so they
//!   are folded into one descriptor-only archive per program (`<uuid>-archive.<exe>.bin` / `.live`, read by hot.rs
//!   like any training file, never loaded by libarm64jit) and then deleted: the hot set stays the same, minus blocks
//!   at addresses no placed system file has any more (old app slots, which a new app may now occupy);
//! - files of other dyld caches (a replaced runtime), stale temp files, and (thorough mode) whole cache dirs of
//!   runtimes that are gone, unused by any phone and untouched for 30 days.
use crate::aot::{self, BuildOpts, Config, Lock, Paths, Progress};
use crate::discover;
use crate::key;
use anyhow::{bail, Context, Result};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// files of a superseded key younger than this stay (processes started under it may still be writing them)
const GRACE: Duration = Duration::from_secs(15 * 60);
const TMP_AGE: Duration = Duration::from_secs(3600);
const STALE_DIR_AGE: Duration = Duration::from_secs(30 * 86400);
const WINDOW_LO: u64 = 0x2_AC00_0000;
const STUB_BASE: u64 = 0x2_FFF0_0000;
const PC_MASK: u64 = (1 << 56) - 1;
pub const ARCHIVE: &str = "archive";

fn progress_printer() -> impl FnMut(&Progress) {
    let mut last = std::time::Instant::now() - Duration::from_secs(10);
    let mut last_state = String::new();
    move |pr: &Progress| {
        if last.elapsed().as_secs() >= 5 || pr.state != last_state {
            last = std::time::Instant::now();
            last_state = pr.state.clone();
            println!("[{}] {} {}/{} chunks ({} skipped)", pr.state, pr.message, pr.chunks_done, pr.chunks_total, pr.chunks_skipped);
        }
    }
}

fn image_for(cfg: &Config, placement: &Path) -> Result<String> {
    let uuid = crate::dyldcache::Cache::open(&cfg.runtime_root).context("opening the dyld cache")?.uuid_hex();
    Ok(key::image_name(&uuid, key::build_id(placement)))
}

/// The table every phone reads; the shipped one when the cache dir has none yet (as boot-a64.sh and aot::plan do).
fn ensure_table(p: &Paths) -> Result<()> {
    if p.placement().exists() {
        return Ok(());
    }
    let build = p.jc.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_prefix("jc-")).unwrap_or("");
    let shipped = aot::repo_root().join(format!("cli/libexec/arm64/placement-{build}.txt"));
    if !build.is_empty() && shipped.exists() {
        std::fs::create_dir_all(&p.jc)?;
        std::fs::copy(&shipped, p.placement())?;
    }
    Ok(())
}

/// Install: place `apps` (an installed .app dir each, or a single Mach-O) and build their chunks, committed together.
pub fn app_install(p: &Paths, cfg: &Config, apps: &[PathBuf], workers: usize) -> Result<String> {
    // the app's chunks only (its container UUID); library feedback stays with the boot-time / explicit update
    let only: Vec<String> = apps
        .iter()
        .map(|a| {
            let rp = std::fs::canonicalize(a).unwrap_or_else(|_| a.clone());
            if rp.to_string_lossy().contains("/Containers/") && rp.is_dir() {
                rp.parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            } else {
                rp.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            }
        })
        .filter(|s| !s.is_empty())
        .collect();
    let args: Vec<String> = apps.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    transact(p, cfg, &[], &args, only, workers)
}

/// Uninstall: drop the rows of apps that exist on no phone (`data`: the uninstalling phone's data dir).
pub fn app_prune(p: &Paths, cfg: &Config, data: Option<&Path>, workers: usize) -> Result<String> {
    let args: Vec<String> = data.map(|d| d.to_string_lossy().into_owned()).into_iter().collect();
    transact(p, cfg, &["--prune"], &args, vec![], workers)
}

fn transact(p: &Paths, cfg: &Config, flags: &[&str], args: &[String], only: Vec<String>, workers: usize) -> Result<String> {
    let _lock = Lock::acquire(&aot::jc_lock_path(p), "the AOT cache")?;
    ensure_table(p)?;
    let stage = p.aot.join("stage");
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage)?;
    let staged = stage.join("placement.txt");
    if p.placement().exists() {
        std::fs::copy(p.placement(), &staged)?;
    }
    let st = std::process::Command::new("python3")
        .arg("-I")
        .arg(aot::repo_root().join("cli/libexec/arm64/placeapp.py"))
        .args(flags)
        .arg("--jc")
        .arg(&p.jc)
        .arg(&stage)
        .args(args)
        .stdout(std::process::Stdio::from(std::io::stderr())) // into the install log (stdout's last line is the result)
        .status()
        .context("running placeapp.py")?;
    let same = std::fs::read(&staged).ok() == std::fs::read(p.placement()).ok();
    if st.code() == Some(3) || (st.success() && same) {
        let _ = std::fs::remove_dir_all(&stage);
        let _ = collect(p, cfg, false);
        return Ok("placement unchanged".into());
    }
    if !st.success() {
        let _ = std::fs::remove_dir_all(&stage);
        bail!("placeapp.py failed ({st}); placement and image unchanged");
    }
    let sp = Paths::staged(&p.jc, &stage);
    let name = image_for(cfg, &staged)?;
    let opts = BuildOpts { workers, only: Some(only), ..Default::default() };
    let r = aot::build_locked(&sp, cfg, &opts, &mut progress_printer());
    let ok = matches!(&r, Ok(r) if r.state == "done") && p.jc.join(&name).exists();
    if !ok {
        let why = match r {
            Ok(r) => format!("{}: {}", r.state, r.message),
            Err(e) => format!("{e:#}"),
        };
        let _ = std::fs::remove_dir_all(&stage);
        bail!("no image for the new placement ({why}); placement and image unchanged: the app runs live");
    }
    // the apps whose rows changed (installed again, replaced, pruned): their old builds' files go now
    let old_rows: HashSet<String> = discover::read_placement(&p.placement()).into_iter().map(|x| format!("{:x} {}", x.addr, x.key)).collect();
    let new_rows: HashSet<String> = discover::read_placement(&staged).into_iter().map(|x| format!("{:x} {}", x.addr, x.key)).collect();
    let changed: HashSet<String> = old_rows
        .symmetric_difference(&new_rows)
        .filter(|r| r.contains(" Containers/"))
        .filter_map(|r| r.rsplit('/').next().map(String::from))
        .collect();
    // commit: from here on every process that starts finds the new table and the image named for it
    std::fs::rename(&staged, p.placement()).context("committing the placement table")?;
    aot::drop_other_images(p, &name);
    let _ = std::fs::remove_dir_all(&stage);
    let r = r.unwrap();
    match collect_with(p, cfg, false, &changed) {
        Ok(c) => eprintln!("x86sim-aot: {c}"),
        Err(e) => eprintln!("x86sim-aot: cache cleanup: {e:#}"),
    }
    Ok(r.message)
}

/// Boot-time upkeep (boot-a64.sh, once the phone is idle): skipped while another build / install holds the cache.
pub fn maintain(p: &Paths, cfg: &Config) -> Result<String> {
    let Some(_lock) = Lock::try_acquire(&aot::jc_lock_path(p))? else {
        return Ok("busy: another build or install holds the cache".into());
    };
    let mut out = vec![];
    if p.placement().exists() {
        let name = image_for(cfg, &p.placement())?;
        if !p.jc.join(&name).exists() {
            eprintln!("x86sim-aot: no image {name} for the current placement: assembling it from the chunks that are up to date");
            let opts = BuildOpts { workers: 1, assemble_only: true, ..Default::default() };
            match aot::build_locked(p, cfg, &opts, &mut progress_printer()) {
                Ok(r) => out.push(format!("heal: {}: {}", r.state, r.message)),
                Err(e) => out.push(format!("heal failed: {e:#}")),
            }
        }
    }
    // this phone's app chunks that a failed install left out (or an app placed without an image): built now, into
    // the image of the current placement (its key does not change)
    if cfg.device.is_some() && p.placement().exists() {
        let plan = aot::plan(p, cfg)?;
        let st = plan.status(p);
        let apps: Vec<String> = st.chunks.iter().filter(|c| c.kind == crate::discover::Kind::App && c.state != "up-to-date").map(|c| c.name.clone()).collect();
        if !apps.is_empty() {
            let opts = BuildOpts { workers: 1, only: Some(apps.clone()), ..Default::default() };
            match aot::build_locked(p, cfg, &opts, &mut progress_printer()) {
                Ok(r) => out.push(format!("app chunks ({}): {}: {}", apps.len(), r.state, r.message)),
                Err(e) => out.push(format!("app chunks: {e:#}")),
            }
        }
    }
    let g = collect(p, cfg, true)?;
    out.push(g.to_string());
    Ok(out.join("\n"))
}

#[derive(Default, Debug)]
pub struct Collected {
    pub freed: u64,
    pub files: usize,
    pub folded: usize,
    pub records: usize,
    pub dirs: Vec<String>,
    pub kept: u64,
}

impl std::fmt::Display for Collected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "cache cleanup: freed {:.1} GB ({} files, {} folded into training archives, {} manifest records){}; cache dir now {:.1} GB",
            self.freed as f64 / 1e9,
            self.files,
            self.folded,
            self.records,
            if self.dirs.is_empty() { String::new() } else { format!(", removed {}", self.dirs.join(", ")) },
            self.kept as f64 / 1e9
        )
    }
}

fn disk(m: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    m.blocks() * 512
}

fn older(m: &std::fs::Metadata, age: Duration) -> bool {
    m.modified().ok().and_then(|t| SystemTime::now().duration_since(t).ok()).is_some_and(|d| d > age)
}

fn rm(path: &Path, c: &mut Collected) {
    if let Ok(m) = std::fs::symlink_metadata(path) {
        let r = if m.is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) };
        if r.is_ok() {
            c.freed += if m.is_dir() { dir_size(path).max(disk(&m)) } else { disk(&m) };
            c.files += 1;
        }
    }
}

fn dir_size(p: &Path) -> u64 {
    let mut n = 0;
    if let Ok(rd) = std::fs::read_dir(p) {
        for e in rd.flatten() {
            if let Ok(m) = e.metadata() {
                n += if m.is_dir() { dir_size(&e.path()) } else { disk(&m) };
            }
        }
    }
    n
}

/// `<32 hex uuid>-<key>.<rest>` -> (uuid, key, rest)
fn split_name(n: &str) -> Option<(&str, &str, &str)> {
    if n.len() < 35 || n.as_bytes()[32] != b'-' || !n[..32].bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let rest = &n[33..];
    let dot = rest.find('.')?;
    Some((&n[..32], &rest[..dot], &rest[dot + 1..]))
}

/// The cache dir's cleanup (see the module doc). The caller holds the cache dir's lock. `thorough`: also fold old
/// keys' training into the archives and remove other runtimes' stale cache dirs (boot upkeep, finished updates).
pub fn collect(p: &Paths, cfg: &Config, thorough: bool) -> Result<Collected> {
    collect_with(p, cfg, thorough, &HashSet::new())
}

/// `now`: programs (executable names) whose old-key per-process files go right away, without the grace period: an
/// app that was just installed again (its previous build's .bin / .live describe code at its old slot)
pub fn collect_with(p: &Paths, cfg: &Config, thorough: bool, now: &HashSet<String>) -> Result<Collected> {
    let mut c = Collected::default();
    let size0 = dir_size(&p.jc);
    let table = p.jc.join("placement.txt");
    let uuid = crate::dyldcache::Cache::open(&cfg.runtime_root).context("opening the dyld cache")?.uuid_hex();
    let build = key::build_id(&table);
    let cur_key = format!("{build:016x}");
    let cur_image = key::image_name(&uuid, build);
    let placements = discover::read_placement(&table);
    let placed: HashSet<&str> = placements.iter().map(|pl| pl.key.as_str()).collect();

    // aot/: leftovers of interrupted runs (nothing else uses them while the lock is held)
    for d in ["stage", "work", "evicted"] {
        rm(&p.aot.join(d), &mut c);
    }
    // manifest: apps no longer placed (uninstalled, replaced, evicted from the table): their records and chunk files
    let mut man = p.load_manifest();
    let before = man.chunks.len();
    let gone: Vec<String> = man.chunks.keys().filter(|n| n.starts_with("Containers/") && !placed.contains(n.as_str())).cloned().collect();
    for n in &gone {
        if let Some(f) = man.chunks.remove(n).and_then(|r| r.file) {
            rm(&p.chunks().join(f), &mut c);
        }
    }
    if man.chunks.len() != before {
        c.records += before - man.chunks.len();
        aot::write_json(&p.manifest(), &man)?;
    }
    // chunk files no record references
    let referenced: HashSet<String> = man.chunks.values().filter_map(|r| r.file.clone()).collect();
    if let Ok(rd) = std::fs::read_dir(p.chunks()) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if referenced.contains(&n) {
                continue;
            }
            if n.contains(".tmp.") && !e.metadata().is_ok_and(|m| older(&m, TMP_AGE)) {
                continue;
            }
            rm(&e.path(), &mut c);
        }
    }
    // images of other keys: only once the current one exists (it is the one every process looks for)
    if p.jc.join(&cur_image).exists() {
        let before = c.freed;
        let sizes: u64 = std::fs::read_dir(&p.jc)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| {
                let n = e.file_name().to_string_lossy().into_owned();
                !n.starts_with(&cur_image) && !n.contains(".tmp.") && split_name(&n).is_some() && (n.ends_with(".aot") || n.contains(".aot."))
            })
            .filter_map(|e| e.metadata().ok().map(|m| disk(&m)))
            .sum();
        aot::drop_other_images(p, &cur_image);
        c.freed = before + sizes;
    }
    // the cache dir's own files
    let mut fold: BTreeMap<(String, String), Vec<PathBuf>> = BTreeMap::new(); // (exe, ext) -> old keys' files
    let mut keys_left: HashSet<String> = HashSet::new();
    let mut stubs: Vec<(PathBuf, String, std::fs::Metadata)> = vec![];
    for e in std::fs::read_dir(&p.jc)?.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let Ok(m) = e.metadata() else { continue };
        if !m.is_file() {
            continue;
        }
        if n == "placement.txt.pre-install" || n == "placement.txt.pre-uninstall" {
            rm(&e.path(), &mut c); // the backups of the install / uninstall scripts before the staged table
            continue;
        }
        if n.contains(".tmp.") {
            if older(&m, TMP_AGE) {
                rm(&e.path(), &mut c);
            }
            continue;
        }
        let Some((u, k, rest)) = split_name(&n) else { continue };
        if u != uuid {
            // another dyld cache (a replaced runtime): nothing of it is read again
            if older(&m, GRACE) {
                rm(&e.path(), &mut c);
            }
            continue;
        }
        if k == cur_key || k == ARCHIVE {
            continue;
        }
        if rest == "stubs" {
            stubs.push((e.path(), k.to_string(), m));
            continue;
        }
        let ext = rest.rsplit('.').next().unwrap_or("");
        let exe = rest[..rest.len().saturating_sub(ext.len() + 1)].to_string();
        let fold_now = now.contains(&exe);
        if !(ext == "bin" || ext == "live") || !(fold_now || thorough && older(&m, GRACE)) {
            keys_left.insert(k.to_string());
            continue;
        }
        fold.entry((exe, ext.to_string())).or_default().push(e.path());
    }
    if !fold.is_empty() {
        let keep = |d: u64| {
            let pc = d & PC_MASK;
            pc < WINDOW_LO || pc >= STUB_BASE || placements.iter().any(|pl| !pl.key.starts_with("Containers/") && pc >= pl.addr && pc < pl.addr + pl.slot)
        };
        for ((exe, ext), files) in &fold {
            let arch = p.jc.join(format!("{uuid}-{ARCHIVE}.{exe}.{ext}"));
            let mut descs: Vec<u64> = crate::hot::read_descs(&arch).unwrap_or_default();
            let mut newest = std::fs::metadata(&arch).and_then(|m| m.modified()).ok();
            for f in files {
                let Some(v) = crate::hot::read_descs(f) else { continue };
                descs.extend(v);
                let t = std::fs::metadata(f).and_then(|m| m.modified()).ok();
                newest = newest.max(t);
            }
            descs.retain(|&d| keep(d));
            descs.sort_unstable();
            descs.dedup();
            write_archive(&arch, &uuid, &descs, newest)?;
            for f in files {
                rm(f, &mut c);
                c.folded += 1;
            }
        }
    }
    for (path, k, m) in stubs {
        if !keys_left.contains(&k) && older(&m, GRACE) {
            rm(&path, &mut c);
        }
    }
    if thorough {
        stale_dirs(p, &mut c);
    }
    c.kept = dir_size(&p.jc);
    // what the directory shrank by (the per-file sums count shared extents and the new archives twice)
    c.freed = size0.saturating_sub(c.kept);
    Ok(c)
}

/// A descriptor-only training file in the layout hot::read_descs reads (A64JC06 header: uuid at 8, count at 40;
/// 24-byte entries from 160, the descriptor first). Build 0: libarm64jit never takes it for one of its caches.
fn write_archive(path: &Path, uuid: &str, descs: &[u64], mtime: Option<SystemTime>) -> Result<()> {
    let mut b = vec![0u8; 160 + descs.len() * 24];
    b[..8].copy_from_slice(b"A64JC06\0");
    for i in 0..16 {
        b[8 + i] = u8::from_str_radix(&uuid[2 * i..2 * i + 2], 16).unwrap_or(0);
    }
    b[40..48].copy_from_slice(&(descs.len() as u64).to_le_bytes());
    for (i, d) in descs.iter().enumerate() {
        b[160 + i * 24..168 + i * 24].copy_from_slice(&d.to_le_bytes());
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp, &b)?;
    // as old as what it holds: "each program's newest .live" (export-training) stays the current session's
    if let Some(t) = mtime {
        let _ = std::fs::File::options().write(true).open(&tmp).and_then(|f| f.set_modified(t));
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Cache dirs (`jc-<build>`, `jitcache` = 24A434) next to this one whose runtime is gone from runtimes/, that no
/// phone's sim.env names, and that nothing touched for 30 days.
fn stale_dirs(p: &Paths, c: &mut Collected) {
    let Some(parent) = p.jc.parent() else { return };
    let root = aot::repo_root();
    let runtimes: Vec<String> =
        std::fs::read_dir(root.join("runtimes")).into_iter().flatten().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    let envs: String = std::fs::read_dir(root.join("var"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| std::fs::read_to_string(e.path().join("sim.env")).ok())
        .collect::<Vec<_>>()
        .join("\n");
    let Ok(rd) = std::fs::read_dir(parent) else { return };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let build = if n == "jitcache" { "24A434".to_string() } else if let Some(b) = n.strip_prefix("jc-") { b.to_string() } else { continue };
        // a runtime build ("24B8117"); experiment dirs (jc-plat-<env>) are not runtimes' caches
        if build.is_empty() || !build.bytes().all(|b| b.is_ascii_alphanumeric()) {
            continue;
        }
        let d = e.path();
        if d == p.jc || !d.join("placement.txt").exists() && !d.join("aot").is_dir() {
            continue;
        }
        if runtimes.iter().any(|r| r.split('-').any(|f| f == build)) || envs.contains(&d.to_string_lossy().into_owned()) {
            continue;
        }
        let newest = [d.clone(), d.join("aot")]
            .iter()
            .filter_map(|x| std::fs::read_dir(x).ok())
            .flatten()
            .flatten()
            .filter_map(|e| e.metadata().ok()?.modified().ok())
            .max();
        if newest.and_then(|t| SystemTime::now().duration_since(t).ok()).is_some_and(|age| age > STALE_DIR_AGE) {
            let before = c.freed;
            rm(&d, c);
            if c.freed > before {
                c.dirs.push(n);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_split_into_uuid_key_rest() {
        let u = "c54ad6fa9ff23edb9c8a53a82682d342";
        assert_eq!(split_name(&format!("{u}-d4940e8e00060040.sdkcov.live")), Some((u, "d4940e8e00060040", "sdkcov.live")));
        assert_eq!(split_name(&format!("{u}-archive.com.apple.WebKit.WebContent.bin")), Some((u, "archive", "com.apple.WebKit.WebContent.bin")));
        assert_eq!(split_name("placement.txt"), None);
        assert_eq!(split_name("mrc.113"), None);
    }

    #[test]
    fn archives_read_back_as_training() {
        let d = std::env::temp_dir().join(format!("x86sim-appcache-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("c54ad6fa9ff23edb9c8a53a82682d342-archive.sdkcov.live");
        write_archive(&f, "c54ad6fa9ff23edb9c8a53a82682d342", &[1, 5, 9], None).unwrap();
        assert_eq!(crate::hot::read_descs(&f), Some(vec![1, 5, 9]));
        let _ = std::fs::remove_dir_all(&d);
    }
}
