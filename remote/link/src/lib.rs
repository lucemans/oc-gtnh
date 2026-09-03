//! The wire between the computers in the game and whatever drives them,
//! as `lib/oclink.lua` speaks it.
//!
//! ```text
//! u16 length, u8 channel, body
//! ```
//!
//! Channel 0 belongs to the proxy: a 16 byte challenge on connect, then
//! messages sealed under keys from the proxy secret and that challenge.
//! Channel 1 is relayed untouched between a device and its controller, and
//! holds messages sealed under keys from the link key, which the proxy never
//! has. The text inside a sealed body is OpenOS serialization both ways.

pub mod frame;
pub mod proxy;
pub mod wire;

pub const PROTOCOL: i64 = 1;

pub const CONTROL: u8 = 0;
pub const RELAY: u8 = 1;

pub fn hex(raw: &[u8]) -> String {
    raw.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn unhex(text: &str) -> anyhow::Result<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        anyhow::bail!("odd length hex");
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).map_err(|_| anyhow::anyhow!("not hex")))
        .collect()
}
