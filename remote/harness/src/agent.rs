//! One conversation per device: the model turn, the tool loop, and the guards
//! that keep a chat box from being flooded or a token budget from being spent
//! on a loop.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{info, warn};

use crate::bridge::{ChatLine, Handle};
use crate::llm::{self, Message};
use crate::tools::{self, ConfirmRequest};
use crate::Config;

/// tool rounds one turn may take before it is told to answer
const MAX_TOOL_ROUNDS: usize = 8;
const TURN_TIMEOUT: Duration = Duration::from_secs(90);
/// past this, chat is told the agent is still on it
const ACK_AFTER: Duration = Duration::from_secs(4);
/// how many exchanges ride along into the next turn
const HISTORY: usize = 20;
/// per player, per minute
const TURNS_PER_MINUTE: usize = 5;
/// lines queued while a turn runs; beyond it the player is told to wait
const QUEUE: usize = 4;
/// one chat line, and how many of them one answer may take
const LINE: usize = 200;
const LINES: usize = 6;

fn system_prompt(host: &str, web: bool, extra: Option<&str>) -> String {
    let mut text = format!(
        "You are the computer of a GregTech: New Horizons base, answering players in Minecraft chat. \
You are addressed as @c or @computer. You run on an OpenComputers machine called {host}, and you \
reach the rest of the base's computers over a mesh network through the tools you are given.\n\
\n\
The game is GregTech: New Horizons (GTNH), a Minecraft 1.7.10 modpack built around GregTech 5 \
Unofficial. Its recipes, tiers and machine behaviour differ from what the same mods do elsewhere, \
so never answer from memory of the plain mods. GTNH forks most of its mods, and the forks at \
https://github.com/GTNewHorizons are the authoritative source for how a mod behaves here. The \
wiki is https://gtnh.miraheze.org, and https://wiki.gtnewhorizons.com is the same wiki. The \
players already know all of this and are in the game with you: do not explain the pack, name the \
version or say where you looked unless they ask.\n\
\n\
Answer in one or two short chat lines. No markdown, no lists, no headings. Numbers with units \
(L for litres, EU for energy, K for temperature). Say which machine or tank a number comes from \
when there is more than one. If a tool answers with nothing, say so plainly rather than guessing.\n\
\n\
The game draws plain ASCII only. Use letters, digits, spaces and the punctuation . , : ; ! ? \
( ) - / % + = @ # * ' and straight double quotes. Never an em dash, a curly quote, an ellipsis \
character, an accented letter or an emoji: they come out as boxes.\n\
\n\
The agent computer sees only its own components: a chat box, an internet card, a data card, \
a modem, screens and disks. Every furnace, tank, generator and pipe belongs to a satellite, \
reached through the tools, never through a chunk run on the agent computer.\n\
\n\
Use fluid_totals for how much of a fluid there is. Use base_status for what machines are doing. \
Use base_log for what happened. Use run_lua for anything the other tools do not cover; only \
methods starting with get, is or has are safe to call freely. Before calling any method that \
changes the world, use confirm, and only proceed on a confirmed answer.\n\
\n\
run_lua runs on OpenOS with Lua 5.3. component.list(kind) iterates components, \
component.invoke(address, method, ...) calls one, component.proxy(address) wraps one. \
Print what you want back. Keep chunks small."
    );
    if web {
        text.push_str(
            "\n\nweb_search and web_fetch reach the internet through the base's search engine, for \
             mod mechanics, recipes and anything not about this base.",
        );
    }
    if let Some(extra) = extra {
        text.push_str("\n\n");
        text.push_str(extra.trim());
    }
    text
}

/// What the game font can draw. Typographic characters a model likes become
/// their plain forms; anything else outside ASCII is dropped.
pub fn ascii(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\u{2013}' | '\u{2014}' | '\u{2212}' => out.push('-'),
            '\u{2018}' | '\u{2019}' | '\u{201A}' => out.push('\''),
            '\u{201C}' | '\u{201D}' | '\u{201E}' => out.push('"'),
            '\u{2026}' => out.push_str("..."),
            '\u{00D7}' => out.push('x'),
            '\u{00A0}' => out.push(' '),
            c if c.is_ascii() => out.push(c),
            _ => {}
        }
    }
    out
}

/// Splits an answer into chat-sized lines, on whitespace where it can.
pub fn lines(text: &str) -> Vec<String> {
    let text = ascii(text);
    let mut out = Vec::new();
    for paragraph in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let mut current = String::new();
        for word in paragraph.split_whitespace() {
            if !current.is_empty() && current.len() + 1 + word.len() > LINE {
                out.push(std::mem::take(&mut current));
            }
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(word);
            while current.len() > LINE {
                let mut cut = LINE;
                while !current.is_char_boundary(cut) {
                    cut -= 1;
                }
                let rest = current.split_off(cut);
                out.push(std::mem::replace(&mut current, rest));
            }
        }
        if !current.is_empty() {
            out.push(current);
        }
    }
    if out.len() > LINES {
        out.truncate(LINES);
        if let Some(last) = out.last_mut() {
            last.push_str(" ...");
        }
    }
    out
}

struct Turn {
    player: String,
    reply: Result<String>,
}

async fn turn(
    config: Arc<Config>,
    client: Arc<llm::Client>,
    bridge: Handle,
    history: Vec<Message>,
    line: ChatLine,
    confirm: mpsc::Sender<ConfirmRequest>,
) -> Result<String> {
    let web = config.searxng.is_some();
    let mut messages = vec![Message::system(system_prompt(
        &bridge.host,
        web,
        config.extra_prompt.as_deref(),
    ))];
    messages.extend(history);
    messages.push(Message::user(format!("{}: {}", line.player, line.text)));
    let definitions = tools::definitions(web);
    let context = tools::Context {
        bridge: bridge.clone(),
        player: line.player.clone(),
        confirm,
        http: reqwest::Client::new(),
        searxng: config.searxng.clone(),
    };

    for round in 0..=MAX_TOOL_ROUNDS {
        let tools_now: &[Value] = if round == MAX_TOOL_ROUNDS {
            &[]
        } else {
            &definitions
        };
        let answer = client.complete(&config.llm, &messages, tools_now).await?;
        let calls = answer.tool_calls.clone().unwrap_or_default();
        if calls.is_empty() {
            return answer
                .content
                .filter(|text| !text.trim().is_empty())
                .ok_or_else(|| anyhow!("the model said nothing"));
        }
        messages.push(answer);
        for call in calls {
            let arguments: Value =
                serde_json::from_str(&call.function.arguments).unwrap_or(Value::Null);
            info!(player = %line.player, tool = %call.function.name, "tool call {}", call.function.arguments);
            let result = tools::call(&call.function.name, &arguments, &context).await;
            messages.push(Message::tool(call.id, result));
        }
    }
    Err(anyhow!("ran out of tool rounds"))
}

struct RateLimit {
    recent: HashMap<String, VecDeque<Instant>>,
}

impl RateLimit {
    fn allows(&mut self, player: &str) -> bool {
        let now = Instant::now();
        let times = self.recent.entry(player.to_string()).or_default();
        while times
            .front()
            .is_some_and(|at| now.duration_since(*at) > Duration::from_secs(60))
        {
            times.pop_front();
        }
        if times.len() >= TURNS_PER_MINUTE {
            return false;
        }
        times.push_back(now);
        true
    }
}

pub async fn run(bridge: Handle, mut chat: mpsc::Receiver<ChatLine>, config: Arc<Config>) {
    let client = Arc::new(llm::Client::new());
    let mut history: Vec<Message> = Vec::new();
    let mut queue: VecDeque<ChatLine> = VecDeque::new();
    let mut limit = RateLimit {
        recent: HashMap::new(),
    };
    let mut running: Option<(JoinHandle<Turn>, Instant, bool)> = None;
    let mut waiting: Option<ConfirmRequest> = None;
    let (confirm_tx, mut confirm_rx) = mpsc::channel::<ConfirmRequest>(4);

    let start = |line: ChatLine, history: &[Message]| -> (JoinHandle<Turn>, Instant, bool) {
        let player = line.player.clone();
        let fut = turn(
            Arc::clone(&config),
            Arc::clone(&client),
            bridge.clone(),
            history.to_vec(),
            line,
            confirm_tx.clone(),
        );
        let task = tokio::spawn(async move {
            let reply = match tokio::time::timeout(TURN_TIMEOUT, fut).await {
                Ok(reply) => reply,
                Err(_) => Err(anyhow!(
                    "took longer than {} seconds",
                    TURN_TIMEOUT.as_secs()
                )),
            };
            Turn { player, reply }
        });
        (task, Instant::now(), false)
    };

    loop {
        let ack_due = match &running {
            Some((_, since, false)) => ACK_AFTER.saturating_sub(since.elapsed()),
            _ => Duration::from_secs(3600),
        };
        tokio::select! {
            line = chat.recv() => {
                let Some(line) = line else { break };
                if let Some(request) = waiting.take() {
                    if request.player == line.player {
                        let _ = request.answer.send(line.text);
                        continue;
                    }
                    waiting = Some(request);
                }
                if !limit.allows(&line.player) {
                    bridge.say(&format!("{}, slow down: {TURNS_PER_MINUTE} questions a minute is the limit.", line.player)).await;
                    continue;
                }
                if running.is_some() {
                    if queue.len() >= QUEUE {
                        bridge.say(&format!("{}, still busy, ask again in a moment.", line.player)).await;
                    } else {
                        queue.push_back(line);
                    }
                    continue;
                }
                history.push(Message::user(format!("{}: {}", line.player, line.text)));
                running = Some(start(line, &history[..history.len() - 1]));
            }
            request = confirm_rx.recv() => {
                if let Some(request) = request {
                    waiting = Some(request);
                }
            }
            _ = tokio::time::sleep(ack_due), if running.as_ref().is_some_and(|(_, _, acked)| !acked) => {
                if let Some((_, _, acked)) = running.as_mut() {
                    *acked = true;
                }
                bridge.say("one moment, looking.").await;
            }
            finished = async { match running.as_mut() { Some((task, _, _)) => task.await, None => std::future::pending().await } } => {
                running = None;
                waiting = None;
                match finished {
                    Ok(Turn { player, reply: Ok(text) }) => {
                        info!(%player, "reply: {text}");
                        for line in lines(&text) {
                            bridge.say(&line).await;
                        }
                        history.push(Message::assistant(text));
                    }
                    Ok(Turn { player, reply: Err(why) }) => {
                        warn!(%player, "turn failed: {why:#}");
                        bridge.say(&format!("{player}, that did not work: {why}")).await;
                        history.pop();
                    }
                    Err(why) => {
                        warn!("turn task died: {why}");
                        history.pop();
                    }
                }
                while history.len() > HISTORY {
                    history.remove(0);
                }
                if let Some(line) = queue.pop_front() {
                    history.push(Message::user(format!("{}: {}", line.player, line.text)));
                    running = Some(start(line, &history[..history.len() - 1]));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_answers_become_short_lines() {
        let text = "Diesel: 43,500 L in total. ".repeat(60);
        let out = lines(&text);
        assert!(out.iter().all(|line| line.len() <= LINE), "{out:?}");
        assert!(out.len() <= LINES);
        assert!(out.last().unwrap().ends_with("..."));
    }

    #[test]
    fn typography_becomes_plain_ascii() {
        assert_eq!(
            ascii("it\u{2019}s \u{2014} fine\u{2026} caf\u{e9}"),
            "it's - fine... caf"
        );
    }

    #[test]
    fn short_answers_stay_whole() {
        assert_eq!(
            lines("42,000 L of diesel in the chem room tank.\n"),
            vec!["42,000 L of diesel in the chem room tank."]
        );
    }
}
