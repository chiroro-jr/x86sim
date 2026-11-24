//! x86Sim launcher core: the chunked AOT image (static discovery, incremental builds driven through libarm64jit's
//! builder), per-device feature toggles and sim control. Shared by the `x86sim-aot` CLI, the `x86sim-mcp` server and
//! the egui launcher.
pub mod aot;
pub mod ax;
pub mod appcache;
pub mod apps;
pub mod dev;
pub mod devapp;
pub mod discover;
pub mod dyldcache;
pub mod features;
pub mod hid;
pub mod host;
pub mod hot;
pub mod instance;
pub mod key;
pub mod logs;
pub mod pool;
pub mod macho;
pub mod ring;
pub mod setup;
/// Share: phones in a browser (x86sim serve)
pub mod share;
pub mod sim;
pub mod update;
