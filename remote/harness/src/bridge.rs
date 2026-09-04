//! One attached device: the hello and welcome on the relay channel, the
//! numbered messages both ways, and the requests still waiting for their
//! result.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use oclink::frame::{self, Keys};
use oclink::proxy::{Event, Link};
use oclink::{wire, PROTOCOL};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, warn};

use crate::console;

use crate::{agent, Config};

/// how long a device has to say hello once attached
const HELLO: Duration = Duration::from_secs(15);
/// a device that says nothing for this long is gone, whatever the proxy thinks
const SILENCE: Duration = Duration::from_secs(120);

#[derive(Deserialize, Debug)]
#[serde(tag = "kind")]
pub enum Inbound {
    #[serde(rename = "hello")]
    Hello {
        protocol: i64,
        host: String,
        nonce: String,
        /// why the device's last link died, when it knows
        dropped: Option<String>,
    },
    #[serde(rename = "chat")]
    Chat { player: String, text: String },
    #[serde(rename = "partial")]
    Partial {
        id: String,
        host: String,
        data: Value,
    },
    #[serde(rename = "result")]
    Result {
        id: String,
        ok: bool,
        output: Option<String>,
        error: Option<String>,
        hosts: Option<i64>,
    },
    #[serde(rename = "heartbeat")]
    Heartbeat { free: f64, uptime: f64 },
    #[serde(rename = "pong")]
    Pong,
}

#[derive(Deserialize)]
struct Numbered {
    seq: i64,
}

#[derive(Serialize, Debug)]
#[serde(tag = "kind")]
pub enum Outbound {
    #[serde(rename = "welcome")]
    Welcome,
    #[serde(rename = "say")]
    Say { text: String },
    #[serde(rename = "ask")]
    Ask {
        id: String,
        what: String,
        host: Option<String>,
        wait: f64,
    },
    #[serde(rename = "run")]
    Run {
        id: String,
        code: String,
        host: Option<String>,
    },
    #[serde(rename = "shell")]
    Shell { id: String, command: String },
    #[serde(rename = "file")]
    File {
        id: String,
        path: String,
        body: String,
    },
    #[serde(rename = "show")]
    Show {
        id: String,
        title: String,
        lines: Vec<String>,
    },
    #[serde(rename = "stock")]
    Stock { id: String, query: String },
}

#[derive(Serialize)]
struct Envelope<'a> {
    seq: i64,
    #[serde(flatten)]
    body: &'a Outbound,
}

/// What a mesh question came back with, or what a script did.
#[derive(Debug)]
pub struct Outcome {
    pub ok: bool,
    pub output: Option<String>,
    pub error: Option<String>,
    pub partials: Vec<(String, Value)>,
}

struct Pending {
    partials: Vec<(String, Value)>,
    done: oneshot::Sender<Outcome>,
}

#[derive(Clone)]
pub struct ChatLine {
    pub player: String,
    pub text: String,
}

/// The side of a device the agent holds: say things, ask things, run things.
#[derive(Clone)]
pub struct Handle {
    pub host: String,
    outgoing: mpsc::Sender<Outbound>,
    pending: Arc<Mutex<HashMap<String, Pending>>>,
    counter: Arc<Mutex<u64>>,
}

impl Handle {
    pub async fn say(&self, text: &str) {
        if self
            .outgoing
            .send(Outbound::Say {
                text: text.to_string(),
            })
            .await
            .is_err()
        {
            warn!(host = %self.host, "device gone, could not say: {text}");
        }
    }

    async fn request(
        &self,
        build: impl FnOnce(String) -> Outbound,
        wait: Duration,
    ) -> Result<Outcome> {
        let id = {
            let mut counter = self.counter.lock().await;
            *counter += 1;
            format!("q{}", *counter)
        };
        let (done, outcome) = oneshot::channel();
        self.pending.lock().await.insert(
            id.clone(),
            Pending {
                partials: Vec::new(),
                done,
            },
        );
        if self.outgoing.send(build(id.clone())).await.is_err() {
            self.pending.lock().await.remove(&id);
            bail!("the device is gone");
        }
        match tokio::time::timeout(wait, outcome).await {
            Ok(Ok(outcome)) => Ok(outcome),
            Ok(Err(_)) => bail!("the device detached before answering"),
            Err(_) => {
                self.pending.lock().await.remove(&id);
                bail!("the device did not answer in {} seconds", wait.as_secs())
            }
        }
    }

    /// Asks the mesh, and returns one entry per machine that answered.
    pub async fn ask(
        &self,
        what: &str,
        host: Option<String>,
        wait_seconds: f64,
    ) -> Result<Vec<(String, Value)>> {
        let outcome = self
            .request(
                |id| Outbound::Ask {
                    id,
                    what: what.to_string(),
                    host,
                    wait: wait_seconds,
                },
                Duration::from_secs_f64(wait_seconds + 10.0),
            )
            .await?;
        if !outcome.ok {
            bail!(
                "{}",
                outcome.error.unwrap_or_else(|| "the device refused".into())
            );
        }
        Ok(outcome.partials)
    }

    /// Runs a chunk on the agent computer, or on a named machine over the mesh.
    pub async fn run(&self, code: &str, host: Option<String>) -> Result<Outcome> {
        self.request(
            |id| Outbound::Run {
                id,
                code: code.to_string(),
                host,
            },
            Duration::from_secs(30),
        )
        .await
    }

    /// Puts a title and some lines on the agent computer's screen, and on the
    /// board view of every ocview; no lines takes the board down.
    pub async fn show(&self, title: &str, lines: Vec<String>) -> Result<Outcome> {
        self.request(
            |id| Outbound::Show {
                id,
                title: title.to_string(),
                lines,
            },
            Duration::from_secs(20),
        )
        .await
    }

    /// What Applied Energistics and Logistics Pipes hold of something.
    pub async fn stock(&self, query: &str) -> Result<Outcome> {
        self.request(
            |id| Outbound::Stock {
                id,
                query: query.to_string(),
            },
            Duration::from_secs(30),
        )
        .await
    }
}

/// Seals and numbers everything sent to the device, in one place so the
/// numbers stay in order whoever is sending.
fn spawn_writer(keys: Keys, relay: mpsc::Sender<Vec<u8>>) -> mpsc::Sender<Outbound> {
    let (tx, mut rx) = mpsc::channel::<Outbound>(64);
    tokio::spawn(async move {
        let mut seq: i64 = 0;
        while let Some(message) = rx.recv().await {
            seq += 1;
            let text = match wire::to_string(&Envelope {
                seq,
                body: &message,
            }) {
                Ok(text) => text,
                Err(why) => {
                    warn!("could not serialize {message:?}: {why}");
                    continue;
                }
            };
            if relay
                .send(frame::seal(&keys, text.as_bytes()))
                .await
                .is_err()
            {
                break;
            }
        }
    });
    tx
}

/// The next relay frame, or why there will be none.
async fn next_relay(link: &mut Link) -> Result<Vec<u8>> {
    loop {
        match link.events.recv().await {
            Some(Event::Relay(body)) => return Ok(body),
            Some(Event::Detached) => bail!("detached"),
            Some(Event::Closed(why)) => bail!("proxy link closed: {why}"),
            Some(Event::Attached) => {}
            None => bail!("the link is gone"),
        }
    }
}

/// Reads the hello and derives the session. Returns the keys, the host and
/// the number of the hello.
async fn hello(link: &mut Link, link_keys: &Keys) -> Result<(Keys, String, i64)> {
    let body = tokio::time::timeout(HELLO, next_relay(link))
        .await
        .map_err(|_| anyhow!("no hello within {} seconds", HELLO.as_secs()))??;
    let text = frame::open(link_keys, &body).context("opening the hello")?;
    let seq: Numbered = wire::from_bytes(&text).context("hello carries no seq")?;
    match wire::from_bytes::<Inbound>(&text).context("hello is not readable")? {
        Inbound::Hello {
            protocol,
            host,
            nonce,
            dropped,
        } => {
            if let Some(why) = dropped {
                crate::console::status(&format!("{host} says its last link ended: {why}"));
            }
            if protocol != PROTOCOL {
                bail!("{host} speaks protocol {protocol}, this harness speaks {PROTOCOL}");
            }
            let session = link_keys.session(&oclink::unhex(&nonce)?);
            Ok((session, host, seq.seq))
        }
        other => bail!("expected a hello, got {other:?}"),
    }
}

fn decode(keys: &Keys, seq_in: &mut i64, body: &[u8]) -> Option<Inbound> {
    let text = match frame::open(keys, body) {
        Ok(text) => text,
        Err(why) => {
            warn!("dropped a frame: {why}");
            return None;
        }
    };
    let seq = match wire::from_bytes::<Numbered>(&text) {
        Ok(numbered) => numbered.seq,
        Err(why) => {
            warn!("dropped a frame with no seq: {why}");
            return None;
        }
    };
    if seq <= *seq_in {
        warn!("dropped a frame that goes backwards: {seq} after {seq_in}");
        return None;
    }
    *seq_in = seq;
    match wire::from_bytes::<Inbound>(&text) {
        Ok(message) => Some(message),
        Err(why) => {
            warn!(
                "dropped an unreadable frame: {why}: {}",
                String::from_utf8_lossy(&text)
            );
            None
        }
    }
}

/// One command to a freshly attached device, and its result.
pub async fn once(link: &mut Link, link_keys: &Keys, command: Outbound) -> Result<Outcome> {
    let (keys, host, mut seq_in) = hello(link, link_keys).await?;
    console::status(&format!("{host} said hello"));
    let outgoing = spawn_writer(keys.clone(), link.relay_sender());
    outgoing
        .send(Outbound::Welcome)
        .await
        .map_err(|_| anyhow!("writer gone"))?;
    outgoing
        .send(command)
        .await
        .map_err(|_| anyhow!("writer gone"))?;
    let mut partials = Vec::new();
    loop {
        let body = tokio::time::timeout(Duration::from_secs(60), next_relay(link))
            .await
            .map_err(|_| anyhow!("no answer within 60 seconds"))??;
        match decode(&keys, &mut seq_in, &body) {
            Some(Inbound::Partial { host, data, .. }) => partials.push((host, data)),
            Some(Inbound::Result {
                ok, output, error, ..
            }) => {
                return Ok(Outcome {
                    ok,
                    output,
                    error,
                    partials,
                })
            }
            Some(_) | None => {}
        }
    }
}

/// The agent's session with an attached device, until it detaches.
pub async fn session(link: &mut Link, config: Arc<Config>) -> Result<()> {
    let (keys, host, mut seq_in) = hello(link, &config.link_keys).await?;
    console::status(&format!("{host} said hello"));

    let outgoing = spawn_writer(keys.clone(), link.relay_sender());
    let pending = Arc::new(Mutex::new(HashMap::new()));
    let handle = Handle {
        host: host.clone(),
        outgoing: outgoing.clone(),
        pending: Arc::clone(&pending),
        counter: Arc::new(Mutex::new(0)),
    };
    outgoing
        .send(Outbound::Welcome)
        .await
        .map_err(|_| anyhow!("writer gone"))?;

    let (chat_tx, chat_rx) = mpsc::channel(16);
    let agent_task = tokio::spawn(agent::run(handle.clone(), chat_rx, Arc::clone(&config)));

    let result = loop {
        let event = match tokio::time::timeout(SILENCE, link.events.recv()).await {
            Ok(Some(event)) => event,
            Ok(None) => break Err(anyhow!("the link is gone")),
            Err(_) => break Err(anyhow!("{host} silent for {} seconds", SILENCE.as_secs())),
        };
        let body = match event {
            Event::Relay(body) => body,
            Event::Detached => break Ok(()),
            Event::Closed(why) => break Err(anyhow!("proxy link closed: {why}")),
            Event::Attached => continue,
        };
        let Some(message) = decode(&keys, &mut seq_in, &body) else {
            continue;
        };
        match message {
            Inbound::Hello { .. } => break Err(anyhow!("a second hello mid-session")),
            Inbound::Chat { player, text } => {
                console::chat(&player, &text);
                if chat_tx.send(ChatLine { player, text }).await.is_err() {
                    break Err(anyhow!("the agent task ended"));
                }
            }
            Inbound::Partial {
                id,
                host: from,
                data,
            } => {
                if let Some(request) = pending.lock().await.get_mut(&id) {
                    request.partials.push((from, data));
                }
            }
            Inbound::Result {
                id,
                ok,
                output,
                error,
                hosts,
            } => {
                if let Some(hosts) = hosts {
                    debug!(%host, %id, hosts, "mesh question closed");
                }
                if let Some(request) = pending.lock().await.remove(&id) {
                    let _ = request.done.send(Outcome {
                        ok,
                        output,
                        error,
                        partials: request.partials,
                    });
                }
            }
            Inbound::Heartbeat { free, uptime } => {
                debug!(%host, free = free as i64, uptime = uptime as i64, "heartbeat");
            }
            Inbound::Pong => {}
        }
    };

    drop(chat_tx);
    drop(outgoing);
    agent_task.abort();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device on the far side of a pair of channels: it says hello under the
    /// link key, expects the welcome, and answers one shell command.
    #[tokio::test]
    async fn once_greets_the_device_and_brings_back_its_result() {
        let link_keys = Keys::from_secret(b"the link key");
        let (events_tx, events_rx) = mpsc::channel(8);
        let (relay_tx, mut relay_rx) = mpsc::channel::<Vec<u8>>(8);
        let mut link = Link::from_parts(events_rx, relay_tx);

        let device_keys = link_keys.clone();
        tokio::spawn(async move {
            let nonce = b"0123456789abcdef";
            let hello = format!(
                r#"{{kind="hello",protocol=1,host="chem-01",nonce="{}",seq=1}}"#,
                oclink::hex(nonce)
            );
            events_tx
                .send(Event::Relay(frame::seal(&device_keys, hello.as_bytes())))
                .await
                .unwrap();
            let session = device_keys.session(nonce);

            let welcome = relay_rx.recv().await.unwrap();
            let welcome = String::from_utf8(frame::open(&session, &welcome).unwrap()).unwrap();
            assert_eq!(welcome, r#"{seq=1,kind="welcome"}"#);

            let command = relay_rx.recv().await.unwrap();
            let command = String::from_utf8(frame::open(&session, &command).unwrap()).unwrap();
            assert_eq!(command, r#"{seq=2,kind="shell",id="1",command="ocup"}"#);

            let result = r#"{kind="result",id="1",ok=true,output="updated 3 files",seq=2}"#;
            events_tx
                .send(Event::Relay(frame::seal(&session, result.as_bytes())))
                .await
                .unwrap();
        });

        let outcome = once(
            &mut link,
            &link_keys,
            Outbound::Shell {
                id: "1".into(),
                command: "ocup".into(),
            },
        )
        .await
        .unwrap();
        assert!(outcome.ok);
        assert_eq!(outcome.output.as_deref(), Some("updated 3 files"));
    }
}
