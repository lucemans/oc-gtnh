//! What somebody watching the harness sees: the conversation, in colour, on
//! stderr. The plumbing goes through tracing at debug; this is the show.

use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde_json::{json, Value};

/// Everything shown is also written down, one JSON object a line, so a run can
/// be read back later. Opened once, at boot.
static LOG: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

pub fn init(path: &std::path::Path) -> std::io::Result<()> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let _ = LOG.set(Mutex::new(file));
    Ok(())
}

fn stamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn record(kind: &str, mut fields: Value) {
    let Some(log) = LOG.get() else { return };
    if let Value::Object(map) = &mut fields {
        map.insert("ts".into(), json!(stamp()));
        map.insert("kind".into(), json!(kind));
    }
    if let Ok(mut file) = log.lock() {
        let _ = writeln!(file, "{fields}");
    }
}

/// A new run: written first, so a restart is visible in the log.
pub fn boot(fields: Value) {
    record("boot", fields);
    line(
        "boot",
        "1;34",
        &paint("2", &format!("ocharness {} up", env!("CARGO_PKG_VERSION"))),
    );
}

/// how much of a long text goes on the screen
const WIDE: usize = 600;
const NARROW: usize = 240;

fn colour() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("NO_COLOR").is_none())
}

fn paint(code: &str, text: &str) -> String {
    if colour() {
        format!("\x1b[{code}m{text}\x1b[0m")
    } else {
        text.to_string()
    }
}

fn clock() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let seconds = now % 86_400;
    format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600,
        (seconds / 60) % 60,
        seconds % 60
    )
}

fn cut(text: &str, limit: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= limit {
        return flat;
    }
    let mut short: String = flat.chars().take(limit).collect();
    short.push_str(" ...");
    short
}

fn line(tag: &str, code: &str, body: &str) {
    let mut err = std::io::stderr().lock();
    let _ = writeln!(
        err,
        "{} {} {}",
        paint("2", &clock()),
        paint(code, &format!("{tag:<7}")),
        body
    );
}

/// A player addressing the agent.
pub fn chat(player: &str, text: &str) {
    record("chat", json!({ "player": player, "text": text }));
    line("chat", "1;36", &format!("{} {}", paint("1", player), text));
}

/// What the model thought before it spoke or called, when the provider shares it.
pub fn thinking(text: &str) {
    if text.trim().is_empty() {
        return;
    }
    record("think", json!({ "text": text }));
    line("think", "2;3", &paint("2;3", &cut(text, WIDE)));
}

/// One tool call as the model made it.
pub fn call(name: &str, arguments: &str) {
    record("tool", json!({ "name": name, "arguments": arguments }));
    let shown = if arguments == "{}" || arguments.is_empty() {
        String::new()
    } else {
        format!(" {}", paint("2", &cut(arguments, NARROW)))
    };
    line("tool", "33", &format!("{}{shown}", paint("1;33", name)));
}

/// What a tool answered, and how long it took.
pub fn result(name: &str, text: &str, took: Duration) {
    record(
        "result",
        json!({ "name": name, "text": text, "seconds": took.as_secs_f64() }),
    );
    let failed = text.starts_with("error:") || text.starts_with("failed:");
    let code = if failed { "31" } else { "32" };
    line(
        "result",
        code,
        &format!(
            "{} {} {}",
            paint("1", name),
            paint("2", &format!("{:.1}s", took.as_secs_f64())),
            paint(if failed { "31" } else { "0" }, &cut(text, NARROW))
        ),
    );
}

/// The words said in chat.
pub fn reply(player: &str, text: &str) {
    record("reply", json!({ "player": player, "text": text }));
    line("reply", "1;35", &format!("{} {}", paint("1", player), text));
}

/// The agent saying something on its own: an ack, a refusal, a limit.
pub fn aside(text: &str) {
    record("say", json!({ "text": text }));
    line("say", "35", &paint("2", text));
}

/// The link coming and going, and anything else worth a glance.
pub fn status(text: &str) {
    record("link", json!({ "text": text }));
    line("link", "34", &paint("2", text));
}

pub fn trouble(text: &str) {
    record("oops", json!({ "text": text }));
    line("oops", "1;31", &paint("31", text));
}
