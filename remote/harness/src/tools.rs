//! What the model may do, each one a thin map onto a device command, and the
//! compaction that keeps a mesh answer inside a tool result the model can read.

use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use std::sync::Arc;

use crate::bridge::{Button, Handle};
use crate::recipes::{Direction, Recipes};

/// how much of a tool result the model sees
const RESULT_CAP: usize = 6000;
/// how long a mesh question collects answers; a base of a dozen machines
/// answers inside a second, and the rest of the wait was silence
const MESH_WAIT: f64 = 3.0;
/// how many recipes one search brings back, and how many a plan checks stock for
const RECIPE_RESULTS: usize = 8;
const PLAN_RECIPES: usize = 3;
/// how wide a board line may be; the screen behind it is not wide
const BOARD_WIDTH: usize = 60;
const CONFIRM_WAIT: Duration = Duration::from_secs(60);

/// The tools the model sees; the web ones only when there is a SearXNG to search with.
pub fn definitions(web: bool, recipes: bool) -> Vec<Value> {
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
    let mut out = vec![
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
            "Run a chunk of Lua on an OpenComputers machine running OpenOS: the agent computer by default, or the named host from base_status. print() output and returned values come back, up to 4 KB. component, computer and require are available. A machine is reached by the address base_status shows after the @, on the host that reported it. Methods starting with set, cancel or similar change the world: ask with confirm first.",
            json!({ "code": { "type": "string" }, "host": { "type": "string", "description": "a host from base_status; leave out for the agent computer" } }),
            vec!["code"],
        ),
        tool(
            "confirm",
            "Ask the player who asked to confirm before doing something that changes the base. Returns what they said. Do not proceed unless it says confirmed.",
            json!({ "question": { "type": "string", "description": "one line, what you are about to do" } }),
            vec!["question"],
        ),
        tool(
            "board",
            "Put a title, up to 18 short lines and up to 6 buttons on the base's monitor, the board view of every ocview. Use it for a recipe, a to-do list, a plan, a status board. Plain ASCII, 60 characters a line, &a colour codes and {bar:42} allowed. A button is a label and the line it types to you when touched. Call it again to replace the board; no lines takes it down. Say in chat what you put up.",
            json!({
                "title": { "type": "string" },
                "lines": { "type": "array", "items": { "type": "string" } },
                "buttons": { "type": "array", "items": { "type": "object", "properties": { "label": { "type": "string" }, "command": { "type": "string" } }, "required": ["label", "command"] } }
            }),
            vec!["title", "lines"],
        ),
        tool(
            "stock",
            "What the base holds of some items, by name, from Applied Energistics and Logistics Pipes, and whether AE could craft each. One call for all the names you need: the network is read once, and every extra call costs seconds.",
            json!({ "items": { "type": "array", "items": { "type": "string" } } }),
            vec!["items"],
        ),
        tool(
            "inventory",
            "Everything a network holds, read once: how many kinds, units and craftables Applied Energistics and Logistics Pipes each have, then the items with the most, the least, or the craftable ones, up to a limit. Use it for anything about the whole stock: what we are low on, what is richest, which network holds more, what AE can craft.",
            json!({
                "source": { "type": "string", "enum": ["ae", "lp", "both"] },
                "sort": { "type": "string", "enum": ["most", "least", "craftable"] },
                "limit": { "type": "integer", "description": "how many items to list, up to 40" }
            }),
            vec!["source", "sort"],
        ),
        tool(
            "remember",
            "Write down one fact a player taught you about the base, so you know it in every later conversation: what a machine is for, which door is which, what an address belongs to, how they like things done. One short line.",
            json!({ "note": { "type": "string" } }),
            vec!["note"],
        ),
    ];
    if recipes {
        out.push(tool(
            "recipe_plan",
            "The cheapest recipes that make an item, and what the base holds of every input, in one call. Use this for any question about making something, then put the plan on the board.",
            json!({ "item": { "type": "string" }, "machine": { "type": "string", "description": "only this kind of machine" } }),
            vec!["item"],
        ));
        out.push(tool(
            "recipe_search",
            "Every recipe in this pack, from the planner dataset. Ask what makes an item or what uses it, by display name, optionally in one kind of machine. Returns the cheapest few as one line each: machine, tier, EU/t, seconds, inputs -> outputs. Fluids are in L.",
            json!({
                "item": { "type": "string", "description": "the item or fluid as it is named in game" },
                "direction": { "type": "string", "enum": ["makes", "uses"], "description": "recipes that make it, or recipes that use it" },
                "machine": { "type": "string", "description": "only this kind of machine, for example Electric Blast Furnace" }
            }),
            vec!["item", "direction"],
        ));
    }
    if web {
        out.push(tool(
            "web_search",
            "Search the web through the base's own SearXNG. Returns the top results with a title, a URL and a snippet each. Use it for recipes, mod mechanics and anything not about this base.",
            json!({ "query": { "type": "string" } }),
            vec!["query"],
        ));
        out.push(tool(
            "web_fetch",
            "Read one web page as plain text, up to a few thousand characters. Use it after web_search when a snippet is not enough.",
            json!({ "url": { "type": "string" } }),
            vec!["url"],
        ));
    }
    out
}

/// A turn asking the loop that owns the chat stream for one player's next line.
pub struct ConfirmRequest {
    pub player: String,
    pub answer: oneshot::Sender<String>,
}

/// What is on the board now, kept so the model can update it rather than
/// rewrite it, and so a new turn knows what is up.
pub type Board = Arc<tokio::sync::Mutex<Option<(String, Vec<String>)>>>;

#[derive(Clone)]
pub struct Context {
    pub board: Board,
    pub bridge: Handle,
    pub player: String,
    pub confirm: mpsc::Sender<ConfirmRequest>,
    pub http: reqwest::Client,
    pub searxng: Option<String>,
    pub notes: std::path::PathBuf,
    pub trusted: bool,
    pub recipes: Option<Arc<Recipes>>,
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
            let address = str_of(card, "address");
            out.push_str(&format!(
                "- {}{}{}",
                str_of(card, "name"),
                if status.is_empty() {
                    String::new()
                } else {
                    format!(" [{status}]")
                },
                if address.is_empty() {
                    String::new()
                } else {
                    format!(" @{address}")
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
            .status(MESH_WAIT)
            .await
            .map(|hosts| status_text(&hosts)),
        "fluid_totals" => context
            .bridge
            .status(MESH_WAIT)
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
            let host = arguments
                .get("host")
                .and_then(Value::as_str)
                .filter(|h| !h.is_empty())
                .map(String::from);
            context.bridge.run(code, host).await.map(|outcome| {
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
        "confirm" if context.trusted => {
            Ok("confirmed: this player's word is enough, no need to ask".into())
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
        "recipe_search" => match &context.recipes {
            Some(recipes) => {
                let item = arguments.get("item").and_then(Value::as_str).unwrap_or("");
                let direction = match arguments.get("direction").and_then(Value::as_str) {
                    Some("uses") => Direction::Uses,
                    _ => Direction::Makes,
                };
                let machine = arguments.get("machine").and_then(Value::as_str);
                let found = recipes.search(item, direction, machine, RECIPE_RESULTS);
                if found.is_empty() {
                    Ok(format!(
                        "no recipe {} {item}",
                        if direction == Direction::Uses {
                            "uses"
                        } else {
                            "makes"
                        }
                    ))
                } else {
                    Ok(found
                        .iter()
                        .map(|recipe| recipe.line())
                        .collect::<Vec<_>>()
                        .join("\n"))
                }
            }
            None => Err(anyhow::anyhow!("no recipe dataset is loaded")),
        },
        "board" => {
            let title = arguments.get("title").and_then(Value::as_str).unwrap_or("");
            let lines: Vec<String> = arguments
                .get("lines")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(|line| {
                            crate::agent::ascii(line)
                                .chars()
                                .take(BOARD_WIDTH)
                                .collect()
                        })
                        .collect()
                })
                .unwrap_or_default();
            let title = crate::agent::ascii(title);
            let buttons: Vec<Button> = arguments
                .get("buttons")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| {
                            let label = item.get("label").and_then(Value::as_str)?.trim();
                            let command = item.get("command").and_then(Value::as_str)?.trim();
                            (!label.is_empty() && !command.is_empty()).then(|| Button {
                                label: crate::agent::ascii(label).chars().take(16).collect(),
                                command: crate::agent::ascii(command),
                            })
                        })
                        .take(6)
                        .collect()
                })
                .unwrap_or_default();
            let outcome = context
                .bridge
                .show(&title, lines.clone(), buttons.clone())
                .await;
            if outcome.as_ref().is_ok_and(|outcome| outcome.ok) {
                let mut shown = lines.clone();
                for button in &buttons {
                    shown.push(format!("[button] {} -> {}", button.label, button.command));
                }
                *context.board.lock().await = if lines.is_empty() {
                    None
                } else {
                    Some((title, shown))
                };
            }
            outcome.map(|outcome| {
                if outcome.ok {
                    outcome.output.unwrap_or_else(|| "shown".into())
                } else {
                    format!("failed: {}", outcome.error.unwrap_or_default())
                }
            })
        }
        "recipe_plan" => match &context.recipes {
            Some(recipes) => {
                let item = arguments.get("item").and_then(Value::as_str).unwrap_or("");
                let machine = arguments.get("machine").and_then(Value::as_str);
                let found = recipes.search(item, Direction::Makes, machine, PLAN_RECIPES);
                if found.is_empty() {
                    Ok(format!("no recipe makes {item}"))
                } else {
                    let mut inputs: Vec<String> = Vec::new();
                    for recipe in &found {
                        for stack in &recipe.inputs {
                            if !inputs.iter().any(|name| name == &stack.name) {
                                inputs.push(stack.name.clone());
                            }
                        }
                    }
                    let lines = found
                        .iter()
                        .map(|recipe| recipe.line())
                        .collect::<Vec<_>>()
                        .join("\n");
                    match context.bridge.stock(inputs).await {
                        Ok(outcome) if outcome.ok => Ok(format!(
                            "{lines}\n\nin stock:\n{}",
                            outcome.output.unwrap_or_default()
                        )),
                        Ok(outcome) => Ok(format!(
                            "{lines}\n\nstock unknown: {}",
                            outcome.error.unwrap_or_default()
                        )),
                        Err(why) => Ok(format!("{lines}\n\nstock unknown: {why:#}")),
                    }
                }
            }
            None => Err(anyhow::anyhow!("no recipe dataset is loaded")),
        },
        "stock" => {
            let items: Vec<String> = arguments
                .get("items")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default();
            context.bridge.stock(items).await.map(|outcome| {
                if outcome.ok {
                    outcome.output.unwrap_or_else(|| "nothing".into())
                } else {
                    format!("failed: {}", outcome.error.unwrap_or_default())
                }
            })
        }
        "inventory" => {
            let source = arguments
                .get("source")
                .and_then(Value::as_str)
                .unwrap_or("both");
            let sort = arguments
                .get("sort")
                .and_then(Value::as_str)
                .unwrap_or("most");
            let limit = arguments.get("limit").and_then(Value::as_i64).unwrap_or(20);
            context
                .bridge
                .inventory(source, sort, limit)
                .await
                .map(|outcome| {
                    if outcome.ok {
                        outcome.output.unwrap_or_else(|| "nothing".into())
                    } else {
                        format!("failed: {}", outcome.error.unwrap_or_default())
                    }
                })
        }
        "remember" => {
            let note = arguments
                .get("note")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            remember(&context.notes, &context.player, note).await
        }
        "web_search" => match &context.searxng {
            Some(base) => {
                let query = arguments.get("query").and_then(Value::as_str).unwrap_or("");
                web_search(&context.http, base, query).await
            }
            None => Err(anyhow::anyhow!("no search engine is configured")),
        },
        "web_fetch" => match &context.searxng {
            Some(_) => {
                let url = arguments.get("url").and_then(Value::as_str).unwrap_or("");
                web_fetch(&context.http, url).await
            }
            None => Err(anyhow::anyhow!("no web access is configured")),
        },
        other => Err(anyhow::anyhow!("no tool called {other}")),
    };
    match outcome {
        Ok(text) => cap(text),
        Err(why) => format!("error: {why:#}"),
    }
}

// ---------------------------------------------------------------------------
// what players teach the agent

/// how much of the notes file rides in the system prompt; the oldest lines go first
const NOTES_CAP: usize = 8 * 1024;

/// The notes as the prompt gets them: the file, or nothing, cut to the newest part.
pub async fn notes(path: &std::path::Path) -> String {
    let text = tokio::fs::read_to_string(path).await.unwrap_or_default();
    if text.len() <= NOTES_CAP {
        return text;
    }
    let mut cut = text.len() - NOTES_CAP;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    match text[cut..].find('\n') {
        Some(newline) => text[cut + newline + 1..].to_string(),
        None => text[cut..].to_string(),
    }
}

pub async fn remember(path: &std::path::Path, player: &str, note: &str) -> anyhow::Result<String> {
    if note.is_empty() {
        anyhow::bail!("nothing to remember");
    }
    let line = format!(
        "- {} (from {player})\n",
        note.split_whitespace().collect::<Vec<_>>().join(" ")
    );
    use tokio::io::AsyncWriteExt;
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await?;
    file.write_all(line.as_bytes()).await?;
    Ok("remembered".into())
}

// ---------------------------------------------------------------------------
// the web, through SearXNG

/// how many results a search brings back
const SEARCH_RESULTS: usize = 6;
/// how much of a page is read before it is turned into text
const PAGE_BYTES: usize = 512 * 1024;
const WEB_TIMEOUT: Duration = Duration::from_secs(15);

async fn web_search(http: &reqwest::Client, base: &str, query: &str) -> anyhow::Result<String> {
    if query.trim().is_empty() {
        anyhow::bail!("nothing to search for");
    }
    let response = http
        .get(format!("{base}/search"))
        .query(&[("q", query), ("format", "json")])
        .timeout(WEB_TIMEOUT)
        .send()
        .await?
        .error_for_status()?;
    let body: Value = response.json().await?;
    let results = items_of(&body, "results");
    if results.is_empty() {
        return Ok("no results".into());
    }
    Ok(results
        .iter()
        .take(SEARCH_RESULTS)
        .enumerate()
        .map(|(index, result)| {
            format!(
                "{}. {}\n   {}\n   {}",
                index + 1,
                str_of(result, "title"),
                str_of(result, "url"),
                str_of(result, "content")
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
            )
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

async fn web_fetch(http: &reqwest::Client, url: &str) -> anyhow::Result<String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        anyhow::bail!("not a web address: {url}");
    }
    let response = http
        .get(url)
        .timeout(WEB_TIMEOUT)
        .send()
        .await?
        .error_for_status()?;
    let html = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|kind| kind.contains("html"));
    let bytes = response.bytes().await?;
    let bytes = &bytes[..bytes.len().min(PAGE_BYTES)];
    let text = String::from_utf8_lossy(bytes);
    if html {
        Ok(html_to_text(&text))
    } else {
        Ok(text.into_owned())
    }
}

/// Enough of an HTML page to read: scripts and styles gone, tags gone, the
/// common entities back to characters, and the whitespace collapsed.
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len() / 4);
    let lower = html.to_lowercase();
    let mut at = 0;
    while at < html.len() {
        let Some(open) = html[at..].find('<').map(|o| o + at) else {
            out.push_str(&html[at..]);
            break;
        };
        out.push_str(&html[at..open]);
        let tag = &lower[open..];
        let skip_to = if tag.starts_with("<script") {
            tag.find("</script>")
                .map(|end| open + end + "</script>".len())
        } else if tag.starts_with("<style") {
            tag.find("</style>")
                .map(|end| open + end + "</style>".len())
        } else if tag.starts_with("<!--") {
            tag.find("-->").map(|end| open + end + 3)
        } else {
            tag.find('>').map(|end| open + end + 1)
        };
        let Some(next) = skip_to else { break };
        if tag.starts_with("</p")
            || tag.starts_with("<br")
            || tag.starts_with("</div")
            || tag.starts_with("</h")
            || tag.starts_with("</li")
            || tag.starts_with("</tr")
        {
            out.push('\n');
        } else {
            out.push(' ');
        }
        at = next;
    }
    let decoded = out
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    decoded
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
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
    fn a_page_becomes_readable_text() {
        let html = "<html><head><style>p{}</style><script>x()</script></head><body><h1>Diesel</h1><p>Made from &amp; oil.</p><!-- no --><ul><li>one</li><li>two</li></ul></body></html>";
        assert_eq!(html_to_text(html), "Diesel\nMade from & oil.\none\ntwo");
    }

    #[test]
    fn status_reads_a_report() {
        let hosts = vec![(
            "boiler".to_string(),
            json!({
                "cards": [{ "name": "Super Tank", "status": "ok", "address": "aa11", "gauges": [{ "label": "Diesel", "current": "42,000", "maximum": "4,000,000", "unit": "L", "percent": 1.05 }] }],
                "alerts": [{ "name": "diesel low", "tripped": true }],
            }),
        )];
        let text = status_text(&hosts);
        assert!(text.contains("Super Tank [ok] @aa11"), "{text}");
        assert!(text.contains("Diesel: 42,000 / 4,000,000 L 1%"), "{text}");
        assert!(text.contains("alerts tripped: diesel low"), "{text}");
    }
}
