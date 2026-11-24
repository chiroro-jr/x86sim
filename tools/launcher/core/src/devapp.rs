//! Device builds on a simulator phone: an .ipa, an .xcarchive or a device .app becomes a simulator .app that
//! `apps::install` installs like any other (simctl install takes only simulator builds; Apple's simulator refuses a
//! device binary at exec: "built for iOS" vs "iOS Simulator").
//!
//! The arm64 code of a device build is the code a simulator build would have (both are arm64; x86Sim translates either
//! way), so the conversion is metadata:
//!   - every Mach-O in the bundle (the app, Frameworks/, PlugIns/ and Extensions/ appexes, a Watch/ app, nested
//!     bundles): LC_BUILD_VERSION's platform becomes the matching simulator one (iOS 2 -> 7, tvOS 3 -> 8, watchOS 4 -> 9,
//!     visionOS 11 -> 12). An old binary's LC_VERSION_MIN_* (which has no simulator variant on arm64) is rewritten as
//!     an LC_BUILD_VERSION in the header's padding. A fat file keeps only its arm64 slice (armv7 / arm64e / x86_64
//!     slices go; the translator runs plain arm64 only).
//!   - FairPlay: a binary whose LC_ENCRYPTION_INFO has cryptid != 0 (App Store downloads) is encrypted for one device
//!     and cannot run anywhere else: refused with a message naming it.
//!   - Info.plists of every bundle: CFBundleSupportedPlatforms / DTPlatformName / DTSDKName name the simulator.
//!   - signature: each binary's entitlements are read from its signature (the entitlements slot) before the change and
//!     put back in an ad-hoc signature (rcodesign, the tool build/linux-bin/codesign wraps). Darling's csops serves the
//!     signature's entitlements when a binary has no __TEXT,__entitlements section (a device build never has one).
//!     The provisioning profile is left in the bundle (inert in the simulator).
//!
//! The input is never changed: an .app is copied (reflink where the file system can) to a work dir, and that copy is
//! converted. A simulator .app passes through untouched.
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const LC_ENCRYPTION_INFO: u32 = 0x21;
const LC_ENCRYPTION_INFO_64: u32 = 0x2c;
const LC_VERSION_MIN_IPHONEOS: u32 = 0x25;
const LC_VERSION_MIN_TVOS: u32 = 0x2f;
const LC_VERSION_MIN_WATCHOS: u32 = 0x30;
const LC_BUILD_VERSION: u32 = 0x32;

/// (device platform, its simulator platform, CFBundleSupportedPlatforms device / simulator name, DTPlatformName)
const PLATFORMS: [(u32, u32, &str, &str, &str); 4] = [
    (2, 7, "iPhoneOS", "iPhoneSimulator", "iphonesimulator"),
    (3, 8, "AppleTVOS", "AppleTVSimulator", "appletvsimulator"),
    (4, 9, "WatchOS", "WatchSimulator", "watchsimulator"),
    (11, 12, "XROS", "XRSimulator", "xrsimulator"),
];

pub fn platform_label(p: u32) -> &'static str {
    match p {
        1 => "macOS",
        2 => "iOS",
        3 => "tvOS",
        4 => "watchOS",
        6 => "Mac Catalyst",
        7 => "iOS Simulator",
        8 => "tvOS Simulator",
        9 => "watchOS Simulator",
        11 => "visionOS",
        12 => "visionOS Simulator",
        _ => "unknown platform",
    }
}

fn simulator_of(p: u32) -> Option<u32> {
    PLATFORMS.iter().find(|x| x.0 == p).map(|x| x.1)
}

fn is_simulator(p: u32) -> bool {
    PLATFORMS.iter().any(|x| x.1 == p)
}

fn rd32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn wr32(b: &mut [u8], o: usize, v: u32) {
    b[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn rd32be(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes(b[o..o + 4].try_into().unwrap())
}

/// What one Mach-O file is and what the conversion did to it.
#[derive(Debug, Clone, Serialize, Default)]
pub struct Binary {
    /// path inside the bundle
    pub path: String,
    /// platform before (LC_BUILD_VERSION / LC_VERSION_MIN_*), 0 = none recorded
    pub platform: u32,
    pub platform_name: String,
    /// FairPlay: cryptid != 0
    pub encrypted: bool,
    /// slices of a fat file other than arm64 that were dropped (armv7, arm64e, x86_64)
    pub dropped_slices: Vec<String>,
    /// has entitlements in its signature (kept)
    pub entitlements: bool,
    pub changed: bool,
}

fn cpu_name(cpu: u32, sub: u32) -> String {
    match (cpu, sub & 0xff) {
        (CPU_TYPE_ARM64, 2) => "arm64e".into(),
        (CPU_TYPE_ARM64, _) => "arm64".into(),
        (0x0200_000c, _) => "arm64_32".into(),
        (12, _) => "armv7".into(),
        (0x0100_0007, _) => "x86_64".into(),
        (7, _) => "i386".into(),
        _ => format!("cpu {cpu:#x}"),
    }
}

/// Load-command facts of a thin 64-bit image.
#[derive(Debug, Default)]
struct Scan {
    platform: u32,
    encrypted: bool,
    /// the signature's entitlements plist (XML)
    entitlements: Option<Vec<u8>>,
}

fn scan_thin(b: &[u8]) -> Result<Scan> {
    anyhow::ensure!(b.len() >= 32 && rd32(b, 0) == MH_MAGIC_64, "not a 64-bit Mach-O");
    let (ncmds, sizeofcmds) = (rd32(b, 16) as usize, rd32(b, 20) as usize);
    anyhow::ensure!(32 + sizeofcmds <= b.len(), "truncated load commands");
    let mut s = Scan::default();
    let mut off = 32;
    for _ in 0..ncmds {
        let (cmd, cs) = (rd32(b, off), rd32(b, off + 4) as usize);
        anyhow::ensure!(cs >= 8 && off + cs <= 32 + sizeofcmds, "bad load command at {off:#x}");
        match cmd {
            LC_BUILD_VERSION => s.platform = rd32(b, off + 8),
            LC_VERSION_MIN_IPHONEOS if s.platform == 0 => s.platform = 2,
            LC_VERSION_MIN_TVOS if s.platform == 0 => s.platform = 3,
            LC_VERSION_MIN_WATCHOS if s.platform == 0 => s.platform = 4,
            LC_ENCRYPTION_INFO | LC_ENCRYPTION_INFO_64 if cs >= 20 => s.encrypted |= rd32(b, off + 16) != 0,
            LC_CODE_SIGNATURE if cs >= 16 => s.entitlements = signature_entitlements(b, rd32(b, off + 8) as usize, rd32(b, off + 12) as usize),
            _ => {}
        }
        off += cs;
    }
    Ok(s)
}

/// The entitlements blob (slot 5, magic 0xfade7171) of an embedded signature superblob (0xfade0cc0), big-endian.
fn signature_entitlements(b: &[u8], off: usize, size: usize) -> Option<Vec<u8>> {
    let sig = b.get(off..off.checked_add(size)?)?;
    if sig.len() < 12 || rd32be(sig, 0) != 0xfade_0cc0 {
        return None;
    }
    let count = rd32be(sig, 8) as usize;
    for i in 0..count {
        let e = 12 + i * 8;
        if e + 8 > sig.len() {
            break;
        }
        if rd32be(sig, e) != 5 {
            continue;
        }
        let o = rd32be(sig, e + 4) as usize;
        if o + 8 > sig.len() || rd32be(sig, o) != 0xfade_7171 {
            return None;
        }
        let len = rd32be(sig, o + 4) as usize;
        let body = sig.get(o + 8..o + len)?.to_vec();
        // an empty plist (<dict/>) is no entitlements
        let txt = String::from_utf8_lossy(&body);
        return (txt.contains("<key>")).then_some(body);
    }
    None
}

/// Retags a thin 64-bit image in place for the simulator. Returns whether anything changed.
fn retag_thin(b: &mut [u8]) -> Result<bool> {
    let (ncmds, sizeofcmds) = (rd32(b, 16) as usize, rd32(b, 20) as usize);
    let mut off = 32;
    let mut changed = false;
    let mut vmin: Option<(usize, u32)> = None;
    let mut has_bv = false;
    // the lowest file offset any section's (or non-zero-offset segment's) data starts at: the header padding ends there
    let mut first_data = b.len();
    for _ in 0..ncmds {
        let (cmd, cs) = (rd32(b, off), rd32(b, off + 4) as usize);
        match cmd {
            LC_BUILD_VERSION => {
                has_bv = true;
                let p = rd32(b, off + 8);
                if let Some(sim) = simulator_of(p) {
                    wr32(b, off + 8, sim);
                    changed = true;
                }
            }
            LC_VERSION_MIN_IPHONEOS | LC_VERSION_MIN_TVOS | LC_VERSION_MIN_WATCHOS => {
                let p = match cmd {
                    LC_VERSION_MIN_IPHONEOS => 2,
                    LC_VERSION_MIN_TVOS => 3,
                    _ => 4,
                };
                vmin = Some((off, p));
            }
            LC_SEGMENT_64 => {
                let nsects = rd32(b, off + 64) as usize;
                for i in 0..nsects {
                    let s = off + 72 + i * 80;
                    let (soff, flags) = (rd32(b, s + 48) as usize, rd32(b, s + 64));
                    // zerofill sections (S_ZEROFILL 1, S_GB_ZEROFILL 0xc, S_THREAD_LOCAL_ZEROFILL 0x12) have no file data
                    if soff != 0 && !matches!(flags & 0xff, 0x1 | 0xc | 0x12) {
                        first_data = first_data.min(soff);
                    }
                }
                let fileoff = u64::from_le_bytes(b[off + 40..off + 48].try_into().unwrap()) as usize;
                let filesize = u64::from_le_bytes(b[off + 48..off + 56].try_into().unwrap());
                if fileoff != 0 && filesize != 0 {
                    first_data = first_data.min(fileoff);
                }
            }
            _ => {}
        }
        off += cs;
    }
    if let (Some((at, p)), false) = (vmin, has_bv) {
        // LC_VERSION_MIN_* {cmd, size 16, version, sdk} -> LC_BUILD_VERSION {cmd, size 24, platform, minos, sdk, ntools 0}:
        // 8 more bytes, taken from the padding after the load commands
        let end = 32 + sizeofcmds;
        anyhow::ensure!(end + 8 <= first_data, "no room in the Mach-O header to add LC_BUILD_VERSION (old LC_VERSION_MIN binary linked without header padding)");
        let (ver, sdk) = (rd32(b, at + 8), rd32(b, at + 12));
        b.copy_within(at + 16..end, at + 24);
        let sim = simulator_of(p).unwrap();
        for (i, v) in [LC_BUILD_VERSION, 24, sim, ver, sdk, 0].into_iter().enumerate() {
            wr32(b, at + i * 4, v);
        }
        wr32(b, 20, (sizeofcmds + 8) as u32);
        changed = true;
    }
    Ok(changed)
}

fn is_macho(head: &[u8]) -> bool {
    head.len() >= 4 && {
        let le = rd32(head, 0);
        let be = rd32be(head, 0);
        le == MH_MAGIC_64 || le == 0xfeed_face || be == FAT_MAGIC || be == FAT_MAGIC_64
    }
}

/// Reads a Mach-O file: the arm64 image (from a fat file: its arm64 slice), dropped slices, and an error for a file
/// without one.
fn arm64_image(bytes: &[u8]) -> Result<(Vec<u8>, Vec<String>, bool)> {
    let be = rd32be(bytes, 0);
    if be == FAT_MAGIC || be == FAT_MAGIC_64 {
        let n = rd32be(bytes, 4) as usize;
        let w = if be == FAT_MAGIC_64 { 32 } else { 20 };
        let mut slices = vec![];
        for i in 0..n {
            let e = 8 + i * w;
            anyhow::ensure!(e + w <= bytes.len(), "truncated fat header");
            let (cpu, sub) = (rd32be(bytes, e), rd32be(bytes, e + 4));
            let (o, s) = if w == 32 {
                (u64::from_be_bytes(bytes[e + 8..e + 16].try_into().unwrap()) as usize, u64::from_be_bytes(bytes[e + 16..e + 24].try_into().unwrap()) as usize)
            } else {
                (rd32be(bytes, e + 8) as usize, rd32be(bytes, e + 12) as usize)
            };
            slices.push((cpu, sub, o, s));
        }
        let pick = slices.iter().find(|s| s.0 == CPU_TYPE_ARM64 && s.1 & 0xff != 2);
        let names: Vec<String> = slices.iter().map(|s| cpu_name(s.0, s.1)).collect();
        let Some(&(_, _, o, s)) = pick else { bail!("no arm64 slice (has {})", names.join(", ")) };
        anyhow::ensure!(o + s <= bytes.len(), "truncated fat slice");
        let dropped = names.into_iter().filter(|n| n != "arm64").collect();
        return Ok((bytes[o..o + s].to_vec(), dropped, true));
    }
    if rd32(bytes, 0) == 0xfeed_face {
        bail!("32-bit Mach-O ({}): only arm64 runs", cpu_name(rd32(bytes, 4), rd32(bytes, 8)));
    }
    let (cpu, sub) = (rd32(bytes, 4), rd32(bytes, 8));
    if cpu != CPU_TYPE_ARM64 || sub & 0xff == 2 {
        bail!("built for {}: only arm64 runs", cpu_name(cpu, sub));
    }
    Ok((bytes.to_vec(), vec![], false))
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for e in std::fs::read_dir(dir).with_context(|| dir.display().to_string())? {
        let e = e?;
        let t = e.file_type()?;
        if t.is_dir() {
            walk(&e.path(), out)?;
        } else if t.is_file() {
            out.push(e.path());
        }
    }
    Ok(())
}

fn machos(app: &Path) -> Result<Vec<PathBuf>> {
    let mut files = vec![];
    walk(app, &mut files)?;
    files.sort();
    Ok(files
        .into_iter()
        .filter(|p| {
            let mut h = [0u8; 4];
            std::fs::File::open(p).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut h)).is_ok() && is_macho(&h)
        })
        .collect())
}

/// The result of `prepare`.
#[derive(Debug, Clone, Serialize)]
pub struct Prepared {
    /// the .app to install (the input itself for a simulator .app)
    pub app: PathBuf,
    /// what the input was: "simulator app", "device app", "ipa", "xcarchive"
    pub kind: String,
    /// a device build was turned into a simulator one
    pub converted: bool,
    pub binaries: Vec<Binary>,
    pub notes: Vec<String>,
}

/// Is `p` something `prepare` takes (an .app / .ipa / .xcarchive)?
pub fn accepts(p: &Path) -> bool {
    let e = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    matches!(e.as_str(), "app" | "ipa" | "xcarchive" | "zip")
}

/// Work dir for conversions: $X86SIM_SCRATCH/devapp/<n> (never /tmp: it is RAM on this host).
pub fn work_dir() -> PathBuf {
    crate::aot::scratch().join("devapp")
}

/// The single .app in `dir` (Payload/ of an ipa, Products/Applications/ of an archive)
fn only_app(dir: &Path, what: &str) -> Result<PathBuf> {
    let apps: Vec<PathBuf> = std::fs::read_dir(dir)
        .with_context(|| format!("{what}: no {}", dir.display()))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "app") && p.is_dir())
        .collect();
    match apps.len() {
        1 => Ok(apps[0].clone()),
        0 => bail!("{what}: no .app in {}", dir.display()),
        _ => bail!("{what}: more than one .app in {}", dir.display()),
    }
}

/// Turns `input` (.app, .ipa, .xcarchive) into a simulator .app. `work`: a fresh dir for the unpacked / converted copy
/// (made; its old contents removed).
pub fn prepare(input: &Path, work: &Path) -> Result<Prepared> {
    let input = input.canonicalize().with_context(|| input.display().to_string())?;
    let ext = input.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mut notes = vec![];
    let fresh = |d: &Path| -> Result<()> {
        if d.exists() {
            std::fs::remove_dir_all(d)?;
        }
        std::fs::create_dir_all(d)?;
        Ok(())
    };
    let (src, mut kind, unpacked) = if input.is_dir() && ext == "app" {
        (input.clone(), "app", false)
    } else if input.is_dir() && ext == "xcarchive" {
        (only_app(&input.join("Products/Applications"), "xcarchive")?, "xcarchive", false)
    } else if input.is_file() {
        let mut h = [0u8; 4];
        std::fs::File::open(&input).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut h)).context("reading the archive")?;
        anyhow::ensure!(&h == b"PK\x03\x04", "{} is not an .ipa (zip) archive", input.display());
        fresh(work)?;
        let un = work.join("unpacked");
        std::fs::create_dir_all(&un)?;
        let out = Command::new("unzip").args(["-q", "-o"]).arg(&input).arg("-d").arg(&un).output().context("running unzip")?;
        anyhow::ensure!(out.status.success(), "unzip: {}", String::from_utf8_lossy(&out.stderr).trim());
        (only_app(&un.join("Payload"), "ipa")?, "ipa", true)
    } else {
        bail!("{}: give an .app, .ipa or .xcarchive", input.display());
    };
    anyhow::ensure!(src.join("Info.plist").is_file(), "{} is not an app bundle (no Info.plist)", src.display());

    // look first: what platform, encryption, slices
    let files = machos(&src)?;
    let exe = info_value(&src, "CFBundleExecutable").unwrap_or_default();
    anyhow::ensure!(!exe.is_empty() && files.contains(&src.join(&exe)), "{}: its executable {exe:?} (CFBundleExecutable) is missing or not a Mach-O", src.display());
    anyhow::ensure!(!files.is_empty(), "{}: no executable in the bundle", src.display());
    let mut bins = vec![];
    let mut problems = vec![];
    for f in &files {
        let rel = f.strip_prefix(&src).unwrap_or(f).to_string_lossy().into_owned();
        let bytes = std::fs::read(f)?;
        let (img, dropped, _) = match arm64_image(&bytes) {
            Ok(x) => x,
            Err(e) => {
                problems.push(format!("{rel}: {e}"));
                continue;
            }
        };
        let s = scan_thin(&img).with_context(|| rel.clone())?;
        bins.push(Binary {
            path: rel,
            platform: s.platform,
            platform_name: platform_label(s.platform).into(),
            encrypted: s.encrypted,
            dropped_slices: dropped,
            entitlements: s.entitlements.is_some(),
            changed: false,
        });
    }
    let enc: Vec<&str> = bins.iter().filter(|b| b.encrypted).map(|b| b.path.as_str()).collect();
    if !enc.is_empty() {
        bail!(
            "{} is encrypted with FairPlay (an App Store download: LC_ENCRYPTION_INFO cryptid=1 in {}). It only runs on the device it was bought for; install a development / ad-hoc / enterprise export (Xcode: Product > Archive > Distribute App > Debugging or Release Testing) or the simulator build",
            input.file_name().unwrap_or_default().to_string_lossy(),
            enc.join(", ")
        );
    }
    anyhow::ensure!(problems.is_empty(), "can't run in the simulator: {}", problems.join("; "));
    let other: Vec<String> = bins.iter().filter(|b| !matches!(b.platform, 0 | 2 | 3 | 4 | 11) && !is_simulator(b.platform)).map(|b| format!("{} ({})", b.path, b.platform_name)).collect();
    anyhow::ensure!(other.is_empty(), "built for another platform: {}", other.join(", "));
    let needs = bins.iter().any(|b| simulator_of(b.platform).is_some() || !b.dropped_slices.is_empty());
    if !needs {
        kind = if kind == "app" { "simulator app" } else { kind };
        return Ok(Prepared { app: src, kind: kind.into(), converted: false, binaries: bins, notes });
    }
    if kind == "app" {
        kind = "device app";
    }

    // convert a copy
    let dst = if unpacked {
        src.clone()
    } else {
        fresh(work)?;
        let dst = work.join(src.file_name().unwrap());
        let out = Command::new("cp").args(["-a", "--reflink=auto"]).arg(&src).arg(&dst).output().context("copying the app")?;
        anyhow::ensure!(out.status.success(), "cp: {}", String::from_utf8_lossy(&out.stderr).trim());
        dst
    };
    let ents_dir = work.join("entitlements");
    std::fs::create_dir_all(&ents_dir)?;
    let mut scoped: Vec<(String, PathBuf)> = vec![];
    for b in bins.iter_mut() {
        let p = dst.join(&b.path);
        let bytes = std::fs::read(&p)?;
        let (mut img, _, thinned) = arm64_image(&bytes)?;
        let ents = scan_thin(&img)?.entitlements;
        let changed = retag_thin(&mut img).with_context(|| b.path.clone())?;
        if changed || thinned {
            std::fs::write(&p, &img)?;
            b.changed = true;
        }
        if let Some(e) = ents {
            let f = ents_dir.join(format!("{}.plist", scoped.len()));
            std::fs::write(&f, e)?;
            scoped.push((b.path.clone(), f));
        }
    }
    let dropped: Vec<String> = bins.iter().filter(|b| !b.dropped_slices.is_empty()).map(|b| format!("{} ({})", b.path, b.dropped_slices.join(", "))).collect();
    if !dropped.is_empty() {
        notes.push(format!("kept the arm64 slice only: {}", dropped.join("; ")));
    }
    let plists = retag_plists(&dst)?;
    notes.push(format!("Info.plist platform keys set to the simulator in {plists} bundle(s)"));
    sign(&dst, &scoped)?;
    notes.push(format!("ad-hoc signed; entitlements kept for {} binar{}", scoped.len(), if scoped.len() == 1 { "y" } else { "ies" }));
    if dst.join("embedded.mobileprovision").exists() {
        notes.push("embedded.mobileprovision left in place (the simulator does not read it)".into());
    }
    Ok(Prepared { app: dst, kind: kind.into(), converted: true, binaries: bins, notes })
}

/// Rewrites the platform keys of every bundle's Info.plist (XML or binary, kept in its format). Returns how many.
fn retag_plists(app: &Path) -> Result<usize> {
    let map: Vec<String> = PLATFORMS.iter().map(|p| format!("{}:{}:{}", p.2, p.3, p.4)).collect();
    // plistlib (the repo's scripts rely on python3); -I: nothing from the bundle's directories is imported
    const PY: &str = r#"
import os, plistlib, sys
app = sys.argv[1]
m = {a: (b, c) for a, b, c in (x.split(':') for x in sys.argv[2:])}
n = 0
for d, _, fs in os.walk(app):
    if 'Info.plist' not in fs or (d != app and not os.path.splitext(d)[1]):
        continue
    p = os.path.join(d, 'Info.plist')
    raw = open(p, 'rb').read()
    try:
        pl = plistlib.loads(raw)
    except Exception:
        continue
    if not isinstance(pl, dict):
        continue
    sp = pl.get('CFBundleSupportedPlatforms')
    dev = next((x for x in (sp or []) if x in m), None)
    if dev is None and pl.get('DTPlatformName') in [k.lower() for k in m]:
        dev = next(k for k in m if k.lower() == pl['DTPlatformName'])
    if dev is None:
        continue
    sim, dt = m[dev]
    pl['CFBundleSupportedPlatforms'] = [sim]
    pl['DTPlatformName'] = dt
    if isinstance(pl.get('DTSDKName'), str) and pl['DTSDKName'].lower().startswith(dev.lower()):
        pl['DTSDKName'] = dt + pl['DTSDKName'][len(dev):]
    fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
    open(p, 'wb').write(plistlib.dumps(pl, fmt=fmt))
    n += 1
print(n)
"#;
    let out = Command::new("python3").args(["-I", "-c", PY]).arg(app).args(&map).output().context("python3 (Info.plist)")?;
    anyhow::ensure!(out.status.success(), "Info.plist: {}", String::from_utf8_lossy(&out.stderr).trim());
    Ok(String::from_utf8_lossy(&out.stdout).trim().parse().unwrap_or(0))
}

/// rcodesign, as build/linux-bin/codesign finds it (PATH, then ~/.cargo/bin)
fn rcodesign() -> Result<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(h) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(h).join(".cargo/bin"));
    }
    dirs.into_iter().map(|d| d.join("rcodesign")).find(|p| p.is_file()).ok_or_else(|| anyhow::anyhow!("rcodesign not found (cargo install apple-codesign): needed to re-sign the converted app"))
}

/// Ad-hoc signs the bundle (nested bundles too, inside out, as rcodesign does) with each binary's own entitlements:
/// the main executable's unscoped, the others scoped by their bundle-relative path.
fn sign(app: &Path, ents: &[(String, PathBuf)]) -> Result<()> {
    let main_exe = info_value(app, "CFBundleExecutable").unwrap_or_default();
    let mut cmd = Command::new(rcodesign()?);
    cmd.arg("sign");
    for (rel, f) in ents {
        if *rel == main_exe {
            cmd.arg("--entitlements-xml-file").arg(f);
        } else {
            cmd.arg("--entitlements-xml-file").arg(format!("{rel}:{}", f.display()));
        }
    }
    let out = cmd.arg(app).output().context("running rcodesign")?;
    anyhow::ensure!(out.status.success(), "rcodesign sign: {}", String::from_utf8_lossy(&out.stderr).lines().filter(|l| l.contains("error") || l.contains("Error")).collect::<Vec<_>>().join("; "));
    Ok(())
}

fn info_value(app: &Path, key: &str) -> Option<String> {
    let out = Command::new("python3")
        .args(["-I", "-c", "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')).get(sys.argv[2],''))"])
        .arg(app.join("Info.plist"))
        .arg(key)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Entitlements in a file's signature (for checks and tests): the XML, or None.
pub fn entitlements_of(file: &Path) -> Result<Option<String>> {
    let (img, _, _) = arm64_image(&std::fs::read(file)?)?;
    Ok(scan_thin(&img)?.entitlements.map(|v| String::from_utf8_lossy(&v).into_owned()))
}

/// Platform of a file's arm64 image (for checks and tests)
pub fn platform_of(file: &Path) -> Result<u32> {
    let (img, _, _) = arm64_image(&std::fs::read(file)?)?;
    Ok(scan_thin(&img)?.platform)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn macho(cmds: &[Vec<u8>], pad: usize) -> Vec<u8> {
        let size: usize = cmds.iter().map(|c| c.len()).sum();
        let mut b = vec![];
        for v in [MH_MAGIC_64, CPU_TYPE_ARM64, 0, 2, cmds.len() as u32, size as u32, 0, 0] {
            b.extend(v.to_le_bytes());
        }
        for c in cmds {
            b.extend(c);
        }
        b.resize(b.len() + pad, 0);
        b
    }
    fn cmd(words: &[u32]) -> Vec<u8> {
        words.iter().flat_map(|w| w.to_le_bytes()).collect()
    }

    #[test]
    fn build_version_is_retagged() {
        let mut b = macho(&[cmd(&[LC_BUILD_VERSION, 24, 2, 0x1b0000, 0x1b0200, 0])], 64);
        assert!(retag_thin(&mut b).unwrap());
        assert_eq!(scan_thin(&b).unwrap().platform, 7);
        let mut tv = macho(&[cmd(&[LC_BUILD_VERSION, 24, 3, 0, 0, 0])], 0);
        retag_thin(&mut tv).unwrap();
        assert_eq!(scan_thin(&tv).unwrap().platform, 8);
    }

    #[test]
    fn version_min_becomes_build_version() {
        let mut b = macho(&[cmd(&[LC_VERSION_MIN_IPHONEOS, 16, 0x0c0000, 0x0e0000]), cmd(&[0x1b, 24, 1, 2, 3, 4])], 16);
        assert!(retag_thin(&mut b).unwrap());
        assert_eq!(rd32(&b, 20), 48);
        assert_eq!(&b[32..56], &cmd(&[LC_BUILD_VERSION, 24, 7, 0x0c0000, 0x0e0000, 0])[..]);
        // the following command moved along intact
        assert_eq!(&b[56..80], &cmd(&[0x1b, 24, 1, 2, 3, 4])[..]);
        // without padding it is refused
        let mut tight = macho(&[cmd(&[LC_VERSION_MIN_IPHONEOS, 16, 0, 0])], 0);
        assert!(retag_thin(&mut tight).is_err());
    }

    #[test]
    fn encryption_is_seen() {
        let b = macho(&[cmd(&[LC_ENCRYPTION_INFO_64, 24, 0x4000, 0x1000, 1, 0])], 0);
        assert!(scan_thin(&b).unwrap().encrypted);
        let b = macho(&[cmd(&[LC_ENCRYPTION_INFO_64, 24, 0x4000, 0x1000, 0, 0])], 0);
        assert!(!scan_thin(&b).unwrap().encrypted);
    }

    #[test]
    fn fat_keeps_arm64() {
        let thin = macho(&[cmd(&[LC_BUILD_VERSION, 24, 2, 0, 0, 0])], 0);
        let mut fat = vec![];
        for v in [FAT_MAGIC, 2, 12, 9, 64, 0, 14, CPU_TYPE_ARM64, 0, 64 + thin.len() as u32, thin.len() as u32, 14] {
            fat.extend(v.to_be_bytes());
        }
        fat.resize(64, 0);
        fat.extend(&thin); // "armv7" slice (content irrelevant)
        fat.extend(&thin);
        let (img, dropped, thinned) = arm64_image(&fat).unwrap();
        assert!(thinned);
        assert_eq!(dropped, vec!["armv7".to_string()]);
        assert_eq!(img, thin);
        // arm64e alone is refused
        let mut e = thin.clone();
        wr32(&mut e, 8, 2);
        assert!(arm64_image(&e).is_err());
    }

    #[test]
    fn entitlements_from_signature() {
        let xml = b"<?xml version=\"1.0\"?><plist><dict><key>application-identifier</key><string>T.x</string></dict></plist>";
        let mut blob = vec![];
        blob.extend(0xfade_7171u32.to_be_bytes());
        blob.extend(((8 + xml.len()) as u32).to_be_bytes());
        blob.extend(xml);
        let mut sig = vec![];
        sig.extend(0xfade_0cc0u32.to_be_bytes());
        sig.extend(((20 + blob.len()) as u32).to_be_bytes());
        sig.extend(1u32.to_be_bytes());
        sig.extend(5u32.to_be_bytes());
        sig.extend(20u32.to_be_bytes());
        sig.extend(&blob);
        let mut b = macho(&[cmd(&[LC_CODE_SIGNATURE, 16, 0, sig.len() as u32])], 0);
        let at = b.len() as u32;
        wr32(&mut b, 32 + 8, at);
        b.extend(&sig);
        assert_eq!(scan_thin(&b).unwrap().entitlements.as_deref(), Some(&xml[..]));
    }
}
