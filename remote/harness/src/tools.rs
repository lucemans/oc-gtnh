//! What the model may do, each one a thin map onto a device command, and the
//! compaction that keeps a mesh answer inside a tool result the model can read.

use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use crate::bridge::Handle;

/// how much of a tool result the model sees
const RESULT_CAP: usize = 6000;
/// how long a mesh question collects answers
const MESH_WAIT: f64 = 5.0;
const CONFIRM_WAIT: Duration = Duration::from_secs(60);

pub fn definitions() -> Vec<Value> {
    let tool = |name: &str, description: &str, properties: Value, required: Vec<&str>| {
        json!({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": { "type": "object", "properties": properties, "required": required }
            }
        })
    };
    vec![
        tool(
            "base_status",
            "Every machine every satellite watches right now: gauges, status, alerts, moving items, fluid stock. Costs one broadcast and five seconds.",
            json!({}),
            vec![],
        ),
        tool(
            "fluid_totals",
            "How much of each fluid the base holds, summed across every tank and fluid network, in litres. Use for questions like how much diesel we have.",
            json!({}),
            vec![],
        ),
        tool(
            "base_log",
            "The last forty things the base wrote down: alerts tripping and clearing, fuel switches, updates. Newest first, ages in seconds.",
            json!({ "host": { "type": "string", "description": "one machine to ask; leave out to ask everybody" } }),
            vec![],
        ),
        tool(
            "base_versions",
            "What every computer on the mesh is running, which commit, and how long it has been up.",
            json!({}),
            vec![],
        ),
        tool(
            "run_lua",
            "Run a chunk of Lua on the agent computer, an OpenComputers machine running OpenOS. print() output and returned values come back, up to 4 KB. component, computer and require are available. Methods starting with set, cancel or similar change the world: ask with confirm first.",
            json!({ "code": { "type": "string" } }),
            vec!["code"],
        ),
        tool(
            "confirm",
            "Ask the player who asked to confirm before doing something that changes the base. Returns what they said. Do not proceed unless it says confirmed.",
            json!({ "question": { "type": "string", "description": "one line, what you are about to do" } }),
            vec!["question"],
        ),
    ]
}

/// A turn asking the loop that owns the chat stream for one player's next line.
pub struct ConfirmRequest {
    pub player: String,
    pub answer: oneshot::Sender<String>,
}

pub struct Context {
    pub bridge: Handle,
    pub player: String,
    pub confirm: mpsc::Sender<ConfirmRequest>,
}

fn cap(text: String) -> String {
    if text.len() <= RESULT_CAP {
        return text;
    }
    let mut cut = RESULT_CAP;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}\n... cut at {RESULT_CAP} characters", &text[..cut])
}

fn str_of(value: &Value, key: &str) -> String {
    match value.get(key) {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(number)) => number.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn num_of(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64)
}

fn items_of<'a>(value: &'a Value, key: &str) -> Vec<&'a Value> {
    match value.get(key) {
        Some(Value::Array(items)) => items.iter().collect(),
        Some(Value::Object(map)) => map.values().collect(),
        _ => Vec::new(),
    }
}

fn status_text(hosts: &[(String, Value)]) -> String {
    let mut out = String::new();
    for (host, report) in hosts {
        out.push_str(&format!("== {host}\n"));
        for card in items_of(report, "cards") {
            let status = str_of(card, "status");
            out.push_str(&format!(
                "- {}{}",
                str_of(card, "name"),
                if status.is_empty() {
                    String::new()
                } else {
                    format!(" [{status}]")
                }
            ));
            for gauge in items_of(card, "gauges") {
                let label = str_of(gauge, "label");
                let unit = str_of(gauge, "unit");
                let percent = num_of(gauge, "percent")
                    .map(|p| format!(" {p:.0}%"))
                    .unwrap_or_default();
                let rate = num_of(gauge, "rate")
                    .filter(|r| *r != 0.0)
                    .map(|r| format!(" {r:+.1}/s"))
                    .unwrap_or_default();
                out.push_str(&format!(
                    "  {}{} / {} {unit}{percent}{rate}",
                    if label.is_empty() {
                        String::new()
                    } else {
                        format!("{label}: ")
                    },
                    str_of(gauge, "current"),
                    str_of(gauge, "maximum"),
                ));
            }
            out.push('\n');
        }
        let tripped: Vec<String> = items_of(report, "alerts")
            .into_iter()
            .filter(|alert| {
                alert
                    .get("tripped")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .map(|alert| str_of(alert, "name"))
            .collect();
        if !tripped.is_empty() {
            out.push_str(&format!("alerts tripped: {}\n", tripped.join(", ")));
        }
        let fluids: Vec<String> = items_of(report, "fluids")
            .into_iter()
            .map(|fluid| {
                format!(
                    "{} {:.0} L{}",
                    str_of(fluid, "name"),
                    num_of(fluid, "amount").unwrap_or(0.0),
                    num_of(fluid, "rate")
                        .filter(|r| *r != 0.0)
                        .map(|r| format!(" ({r:+.1}/s)"))
                        .unwrap_or_default()
                )
            })
            .collect();
        if !fluids.is_empty() {
            out.push_str(&format!("fluid network: {}\n", fluids.join(", ")));
        }
        let items: Vec<String> = items_of(report, "items")
            .into_iter()
            .map(|item| {
                format!(
                    "{} {:+.1}/s",
                    str_of(item, "name"),
                    num_of(item, "rate").unwrap_or(0.0)
                )
            })
            .collect();
        if !items.is_empty() {
            out.push_str(&format!("items moving: {}\n", items.join(", ")));
        }
    }
    if out.is_empty() {
        out.push_str("nobody on the mesh answered");
    }
    out
}

fn parse_grouped(text: &str) -> Option<f64> {
    let cleaned: String = text
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.' || *c == '-')
        .collect();
    cleaned.parse().ok()
}

fn fluid_totals_text(hosts: &[(String, Value)]) -> String {
    let mut totals: Vec<(String, f64, Vec<String>)> = Vec::new();
    let mut add = |name: String, amount: f64, host: &str| {
        let key = name.to_lowercase();
        match totals.iter_mut().find(|(n, _, _)| n.to_lowercase() == key) {
            Some(entry) => {
                entry.1 += amount;
                entry.2.push(host.to_string());
            }
            None => totals.push((name, amount, vec![host.to_string()])),
        }
    };
    for (host, report) in hosts {
        for fluid in items_of(report, "fluids") {
            add(
                str_of(fluid, "name"),
                num_of(fluid, "amount").unwrap_or(0.0),
                &format!("{host} network"),
            );
        }
        for card in items_of(report, "cards") {
            for gauge in items_of(card, "gauges") {
                if str_of(gauge, "unit") != "L" {
                    continue;
                }
                let label = str_of(gauge, "label");
                if label.is_empty() {
                    continue;
                }
                if let Some(amount) = parse_grouped(&str_of(gauge, "current")) {
                    add(
                        label,
                        amount,
                        &format!("{} on {host}", str_of(card, "name")),
                    );
                }
            }
        }
    }
    if totals.is_empty() {
        return "no fluids reported by anybody".into();
    }
    totals.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    totals
        .iter()
        .map(|(name, amount, where_)| format!("{name}: {amount:.0} L ({})", where_.join(", ")))
        .collect::<Vec<_>>()
        .join("\n")
}

fn log_text(hosts: &[(String, Value)]) -> String {
    let mut lines = Vec::new();
    for (host, answer) in hosts {
        let now = num_of(answer, "now").unwrap_or(0.0);
        for record in items_of(answer, "records") {
            let age = num_of(record, "at")
                .map(|at| (now - at).max(0.0))
                .unwrap_or(0.0);
            lines.push((
                age,
                format!(
                    "{age:.0}s ago  {host}  {} {}  {}",
                    str_of(record, "service"),
                    str_of(record, "level"),
                    str_of(record, "text")
                ),
            ));
        }
    }
    if lines.is_empty() {
        return "nothing written down".into();
    }
    lines.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    lines
        .into_iter()
        .map(|(_, line)| line)
        .collect::<Vec<_>>()
        .join("\n")
}

fn versions_text(hosts: &[(String, Value)]) -> String {
    if hosts.is_empty() {
        return "nobody answered".into();
    }
    hosts
        .iter()
        .map(|(host, answer)| {
            let program = answer
                .get("program")
                .map(|p| format!("{} v{}", str_of(p, "name"), str_of(p, "version")))
                .unwrap_or_else(|| "?".into());
            let commit = answer
                .get("installed")
                .map(|i| str_of(i, "commit"))
                .unwrap_or_default();
            let commit: String = if commit.is_empty() {
                "unknown".into()
            } else {
                commit.chars().take(8).collect()
            };
            format!(
                "{host}: {program}, commit {commit}, up {:.0}s",
                num_of(answer, "uptime").unwrap_or(0.0)
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub async fn call(name: &str, arguments: &Value, context: &Context) -> String {
    let outcome = match name {
        "base_status" => context
            .bridge
            .ask("status", None, MESH_WAIT)
            .await
            .map(|hosts| status_text(&hosts)),
        "fluid_totals" => context
            .bridge
            .ask("status", None, MESH_WAIT)
            .await
            .map(|hosts| fluid_totals_text(&hosts)),
        "base_log" => {
            let host = arguments
                .get("host")
                .and_then(Value::as_str)
                .filter(|h| !h.is_empty())
                .map(String::from);
            context
                .bridge
                .ask("log", host, MESH_WAIT)
                .await
                .map(|hosts| log_text(&hosts))
        }
        "base_versions" => context
            .bridge
            .ask("versions", None, MESH_WAIT)
            .await
            .map(|hosts| versions_text(&hosts)),
        "run_lua" => {
            let code = arguments.get("code").and_then(Value::as_str).unwrap_or("");
            context.bridge.run(code).await.map(|outcome| {
                let output = outcome.output.unwrap_or_default();
                if outcome.ok {
                    if output.is_empty() {
                        "ran, printed nothing".into()
                    } else {
                        output
                    }
                } else {
                    format!(
                        "failed: {}{}",
                        outcome.error.unwrap_or_default(),
                        if output.is_empty() {
                            String::new()
                        } else {
                            format!("\noutput before it failed:\n{output}")
                        }
                    )
                }
            })
        }
        "confirm" => {
            let question = arguments
                .get("question")
                .and_then(Value::as_str)
                .unwrap_or("go ahead?");
            context
                .bridge
                .say(&format!(
                    "{question} Reply @c yes or @c no, {}.",
                    context.player
                ))
                .await;
            let (answer, waiting) = oneshot::channel();
            if context
                .confirm
                .send(ConfirmRequest {
                    player: context.player.clone(),
                    answer,
                })
                .await
                .is_err()
            {
                return "could not ask".into();
            }
            match tokio::time::timeout(CONFIRM_WAIT, waiting).await {
                Ok(Ok(text)) => {
                    let lowered = text.trim().to_lowercase();
                    if matches!(
                        lowered.as_str(),
                        "yes" | "y" | "yes please" | "do it" | "go ahead" | "ok" | "confirm"
                    ) {
                        Ok("confirmed".into())
                    } else {
                        Ok(format!("not confirmed, they said: {text}"))
                    }
                }
                Ok(Err(_)) => Ok("not confirmed: nobody answered".into()),
                Err(_) => Ok(format!(
                    "not confirmed: no answer in {} seconds",
                    CONFIRM_WAIT.as_secs()
                )),
            }
        }
        other => Err(anyhow::anyhow!("no tool called {other}")),
    };
    match outcome {
        Ok(text) => cap(text),
        Err(why) => format!("error: {why:#}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totals_add_networks_and_tanks() {
        let hosts = vec![
            (
                "chem".to_string(),
                json!({ "fluids": [{ "name": "Diesel", "amount": 42000 }], "cards": [] }),
            ),
            (
                "pwr".to_string(),
                json!({ "fluids": [], "cards": [{ "name": "Super Tank", "gauges": [{ "label": "Diesel", "current": "1,500", "maximum": "4,000,000", "unit": "L" }] }] }),
            ),
        ];
        let text = fluid_totals_text(&hosts);
        assert!(text.starts_with("Diesel: 43500 L"), "{text}");
    }

    #[test]
    fn status_reads_a_report() {
        let hosts = vec![(
            "boiler".to_string(),
            json!({
                "cards": [{ "name": "Super Tank", "status": "ok", "gauges": [{ "label": "Diesel", "current": "42,000", "maximum": "4,000,000", "unit": "L", "percent": 1.05 }] }],
                "alerts": [{ "name": "diesel low", "tripped": true }],
            }),
        )];
        let text = status_text(&hosts);
        assert!(text.contains("Super Tank [ok]"), "{text}");
        assert!(text.contains("Diesel: 42,000 / 4,000,000 L 1%"), "{text}");
        assert!(text.contains("alerts tripped: diesel low"), "{text}");
    }
}
