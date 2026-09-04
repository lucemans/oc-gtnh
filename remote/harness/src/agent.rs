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
use tracing::warn;

use crate::console;

use crate::bridge::{ChatLine, Handle};
use crate::llm::{self, Message};
use crate::tools::{self, ConfirmRequest};
use crate::Config;

/// tool rounds one turn may take before it is told to answer
const MAX_TOOL_ROUNDS: usize = 8;
/// how many times an empty reply is asked for again before the turn fails
const MAX_NUDGES: usize = 2;
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

fn system_prompt(host: &str, web: bool, recipes: bool, notes: &str, extra: Option<&str>) -> String {
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
Use base_log for what happened. Use run_lua for anything the other tools do not cover.\n\
\n\
A player asking you to do something is the permission to do it: do it, then report. Use the \
confirm tool only when you would stop or start a production machine the player did not name, \
or when the action cannot be undone, such as deleting or overwriting a file. Doors, lamps, \
notes and reading are never worth a confirmation. Never ask for confirmation in your reply \
text; the confirm tool is the only way to ask, and one answer covers the whole request. A \
player who has said to stop asking is never asked again.\n\
\n\
Call several tools in one turn when they do not depend on each other: they run at the same \
time, and a turn with one call after another is slower for everybody.\n\
\n\
Use remember for anything a player teaches you about the base: what a machine is for, which \
door is which, what an address belongs to, how they like things done. Those notes come back \
to you in every conversation; nothing else does.\n\
\n\
The base has a display. board(title, lines) puts a recipe, a plan or a to-do list on it, and \
stock(item) says what the base holds of something and whether AE could craft it. Asked for a \
recipe, look it up, check the stock of each input, put the recipe with what is there and what \
is missing on the board, and tell the player the short version in chat. Asked for a list or a \
plan, keep it on the board and update it as things get done.\n\
\n\
run_lua runs on OpenOS with Lua 5.3. component.list(kind) iterates components with their \
full addresses, component.invoke(address, method, ...) calls one, component.proxy(address) \
wraps one, and component.get(prefix) turns the short form of an address into the full one, \
which invoke and proxy need. Print what you want back. Keep chunks small.\n\
\n\
A GregTech machine is a gt_machine component. Reading: getName, getCoordinates, isMachineActive, \
isWorkAllowed, hasWork, getWorkProgress and getWorkMaxProgress in ticks, getSensorInformation \
(the scanner lines, and the only detail a multiblock gives), getStoredEU, getEUCapacity, \
getStoredEUString and getEUCapacityString for numbers too big for a double, getInputVoltage, \
getOutputVoltage, getOutputAmperage, getAverageElectricInput, getAverageElectricOutput, \
getStoredSteam, getSteamCapacity. The one thing that changes it: setWorkAllowed(boolean), which \
soft-stops or restarts it. A Lapotronic Super Capacitor is an LSC component with the EU getters; \
an energy hatch or battery buffer is gt_energyContainer with the voltage and EU getters."
    );
    if recipes {
        text.push_str(
            "\n\nrecipe_search knows every recipe in this pack: what makes an item and what uses it, \
             with the machine, tier and cost. Use it before answering any recipe question.",
        );
    }
    if web {
        text.push_str(
            "\n\nweb_search and web_fetch reach the internet through the base's search engine, for \
             mod mechanics and anything not about this base.",
        );
    }
    if !notes.trim().is_empty() {
        text.push_str("\n\nWhat players have taught you about this base, newest last:\n");
        text.push_str(notes.trim());
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

/// The note written down when a player says to stop asking; its presence is
/// what makes confirm answer yes for them from then on.
fn no_questions_note(player: &str) -> String {
    format!("{player} does not want to be asked for confirmation")
}

/// Whether a chat line is the player saying to stop asking.
pub fn asks_for_no_questions(text: &str) -> bool {
    let lowered = text.to_lowercase();
    [
        "stop asking",
        "don't ask",
        "dont ask",
        "do not ask",
        "no need to ask",
        "never ask",
        "without asking",
        "quit asking",
    ]
    .iter()
    .any(|phrase| lowered.contains(phrase))
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
    let notes = tools::notes(&config.notes).await;
    let mut messages = vec![Message::system(system_prompt(
        &bridge.host,
        web,
        config.recipes.is_some(),
        &notes,
        config.extra_prompt.as_deref(),
    ))];
    messages.extend(history);
    messages.push(Message::user(format!("{}: {}", line.player, line.text)));
    let definitions = tools::definitions(web, config.recipes.is_some());
    let context = tools::Context {
        bridge: bridge.clone(),
        player: line.player.clone(),
        confirm,
        http: reqwest::Client::new(),
        searxng: config.searxng.clone(),
        notes: config.notes.clone(),
        trusted: config.trusted.contains(&line.player.to_lowercase())
            || notes
                .to_lowercase()
                .contains(&no_questions_note(&line.player).to_lowercase()),
        recipes: config.recipes.clone(),
    };

    let mut nudges = 0;
    for round in 0..=MAX_TOOL_ROUNDS {
        let tools_now: &[Value] = if round == MAX_TOOL_ROUNDS {
            &[]
        } else {
            &definitions
        };
        let answer = client.complete(&config.llm, &messages, tools_now).await?;
        console::thinking(answer.reasoning.as_deref().unwrap_or(""));
        let calls = answer.tool_calls.clone().unwrap_or_default();
        if calls.is_empty() {
            let text = answer.text();
            if !text.is_empty() {
                return Ok(text);
            }
            // A reasoning model sometimes stops after thinking, with nothing said.
            // Asked once more for the words, it says them.
            if nudges >= MAX_NUDGES {
                return Err(anyhow!("the model said nothing"));
            }
            nudges += 1;
            let thought: String = answer
                .reasoning
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(200)
                .collect();
            console::trouble(&format!(
                "empty reply from the model, asking again; it thought: {thought}"
            ));
            messages.push(Message::user(
                "Your reply had no text. Answer the player now in one or two plain lines.",
            ));
            continue;
        }
        messages.push(answer);
        // every call the model made at once runs at once, in the order it asked
        let mut running = Vec::with_capacity(calls.len());
        for call in calls {
            let arguments: Value =
                serde_json::from_str(&call.function.arguments).unwrap_or(Value::Null);
            console::call(&call.function.name, &call.function.arguments);
            let context = context.clone();
            let name = call.function.name.clone();
            running.push((
                call.id,
                name,
                tokio::spawn(async move {
                    let started = Instant::now();
                    let result = tools::call(&call.function.name, &arguments, &context).await;
                    (result, started.elapsed())
                }),
            ));
        }
        for (id, name, task) in running {
            let (result, took) = task.await.unwrap_or_else(|why| {
                (format!("error: the tool call died: {why}"), Duration::ZERO)
            });
            console::result(&name, &result, took);
            messages.push(Message::tool(id, result));
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
                if asks_for_no_questions(&line.text) {
                    let note = no_questions_note(&line.player);
                    if !tools::notes(&config.notes).await.contains(&note) {
                        if let Err(why) = tools::remember(&config.notes, &line.player, &note).await {
                            warn!("could not write the note: {why:#}");
                        }
                    }
                }
                if !limit.allows(&line.player) {
                    console::aside(&format!("{} asked too often", line.player));
                    bridge.say(&format!("{}, slow down: {TURNS_PER_MINUTE} questions a minute is the limit.", line.player)).await;
                    continue;
                }
                if running.is_some() {
                    if queue.len() >= QUEUE {
                        console::aside(&format!("{} queued past the limit", line.player));
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
                console::aside("one moment, looking.");
                bridge.say("one moment, looking.").await;
            }
            finished = async { match running.as_mut() { Some((task, _, _)) => task.await, None => std::future::pending().await } } => {
                running = None;
                waiting = None;
                match finished {
                    Ok(Turn { player, reply: Ok(text) }) => {
                        console::reply(&player, &text);
                        for line in lines(&text) {
                            bridge.say(&line).await;
                        }
                        history.push(Message::assistant(text));
                    }
                    Ok(Turn { player, reply: Err(why) }) => {
                        console::trouble(&format!("turn for {player} failed: {why:#}"));
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
    fn hears_a_player_say_stop_asking() {
        assert!(asks_for_no_questions(
            "yes, stop asking for confirmation when I ask"
        ));
        assert!(asks_for_no_questions("Dont ask, just do it"));
        assert!(!asks_for_no_questions("how much diesel do we have?"));
    }

    #[test]
    fn short_answers_stay_whole() {
        assert_eq!(
            lines("42,000 L of diesel in the chem room tank.\n"),
            vec!["42,000 L of diesel in the chem room tank."]
        );
    }
}
