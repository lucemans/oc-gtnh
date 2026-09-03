//! The proxy's own channel: what a client says to join, what the proxy says
//! back, and a client that keeps one joined connection open.
//!
//! On connect the proxy sends a 16 byte challenge in the clear. The client
//! answers with a join sealed under the static proxy keys, carrying that
//! challenge and a nonce of its own, and both sides then run the channel under
//! keys derived from challenge and nonce together. A recorded join answers a
//! challenge that will never be asked again.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::warn;

use crate::frame::{self, Keys};
use crate::{hex, wire, CONTROL, PROTOCOL, RELAY};

pub const CHALLENGE: usize = 16;
/// how long a step of the handshake may take
pub const STEP: Duration = Duration::from_secs(15);
/// a connection that says nothing for this long is gone
pub const SILENCE: Duration = Duration::from_secs(180);
/// how often a quiet client says it is still there
pub const PING: Duration = Duration::from_secs(60);

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Device,
    Control,
}

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Role::Device => write!(f, "device"),
            Role::Control => write!(f, "control"),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "kind")]
pub enum Control {
    #[serde(rename = "join")]
    Join {
        role: Role,
        name: String,
        protocol: i64,
        challenge: String,
        nonce: String,
    },
    #[serde(rename = "joined")]
    Joined,
    #[serde(rename = "refused")]
    Refused { why: String },
    #[serde(rename = "attached")]
    Attached,
    #[serde(rename = "detached")]
    Detached,
    #[serde(rename = "ping")]
    Ping,
}

#[derive(Serialize)]
struct Envelope<'a> {
    seq: i64,
    #[serde(flatten)]
    body: &'a Control,
}

#[derive(Deserialize)]
pub struct Numbered {
    pub seq: i64,
}

/// One control message sealed and numbered, ready for the wire.
pub fn seal_control(keys: &Keys, seq: i64, message: &Control) -> Result<Vec<u8>> {
    let text = wire::to_string(&Envelope { seq, body: message })?;
    Ok(frame::seal(keys, text.as_bytes()))
}

/// The control message inside a sealed body, with its number.
pub fn open_control(keys: &Keys, body: &[u8]) -> Result<(i64, Control)> {
    let text = frame::open(keys, body)?;
    let seq: Numbered = wire::from_bytes(&text).context("no seq")?;
    let message: Control = wire::from_bytes(&text).context("not a control message")?;
    Ok((seq.seq, message))
}

/// Session keys for both sides, from the static proxy keys and both nonces.
pub fn session(keys: &Keys, challenge: &[u8], nonce: &[u8]) -> Keys {
    let mut both = challenge.to_vec();
    both.extend_from_slice(nonce);
    keys.session(&both)
}

/// The handshake from the client side, on any stream. Returns the session
/// keys and the number of the last control message received.
pub async fn join<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    keys: &Keys,
    role: Role,
    name: &str,
) -> Result<(Keys, i64)> {
    let (channel, challenge) = tokio::time::timeout(STEP, frame::read_frame(stream))
        .await
        .map_err(|_| anyhow!("no challenge within {} seconds", STEP.as_secs()))??;
    if channel != CONTROL || challenge.len() != CHALLENGE {
        bail!("the proxy did not challenge");
    }
    let mut nonce = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut nonce);
    let join = Control::Join {
        role,
        name: name.to_string(),
        protocol: PROTOCOL,
        challenge: hex(&challenge),
        nonce: hex(&nonce),
    };
    frame::write_frame(stream, CONTROL, &seal_control(keys, 1, &join)?).await?;
    let keys = session(keys, &challenge, &nonce);

    let (channel, body) = tokio::time::timeout(STEP, frame::read_frame(stream))
        .await
        .map_err(|_| anyhow!("no answer to the join within {} seconds", STEP.as_secs()))??;
    if channel != CONTROL {
        bail!("the proxy relayed before it answered the join");
    }
    match open_control(&keys, &body)? {
        (seq, Control::Joined) => Ok((keys, seq)),
        (_, Control::Refused { why }) => bail!("the proxy refused: {why}"),
        (_, other) => bail!("expected joined, got {other:?}"),
    }
}

/// What a joined client hears.
#[derive(Debug)]
pub enum Event {
    Attached,
    Detached,
    Relay(Vec<u8>),
    Closed(String),
}

/// One joined connection, read and written by tasks of its own. Relay bodies
/// go out through `relay`; everything that arrives comes through `events`.
pub struct Link {
    pub events: mpsc::Receiver<Event>,
    relay: mpsc::Sender<Vec<u8>>,
}

impl Link {
    pub async fn connect(address: &str, keys: &Keys, role: Role, name: &str) -> Result<Link> {
        let mut stream = TcpStream::connect(address)
            .await
            .with_context(|| format!("connecting to {address}"))?;
        stream.set_nodelay(true)?;
        let (keys, mut seq_in) = join(&mut stream, keys, role, name).await?;
        let (mut reader, mut writer) = stream.into_split();

        let (events_tx, events) = mpsc::channel(64);
        let (relay, mut relay_rx) = mpsc::channel::<Vec<u8>>(64);

        let write_keys = keys.clone();
        tokio::spawn(async move {
            let mut seq_out: i64 = 1;
            loop {
                let step = tokio::time::timeout(PING, relay_rx.recv()).await;
                let result = match step {
                    Ok(Some(body)) => frame::write_frame(&mut writer, RELAY, &body).await,
                    Ok(None) => break,
                    Err(_) => {
                        seq_out += 1;
                        match seal_control(&write_keys, seq_out, &Control::Ping) {
                            Ok(body) => frame::write_frame(&mut writer, CONTROL, &body).await,
                            Err(why) => Err(why),
                        }
                    }
                };
                if result.is_err() {
                    break;
                }
            }
        });

        tokio::spawn(async move {
            let why = loop {
                let (channel, body) =
                    match tokio::time::timeout(SILENCE, frame::read_frame(&mut reader)).await {
                        Ok(Ok(frame)) => frame,
                        Ok(Err(why)) => break format!("{why:#}"),
                        Err(_) => break format!("silent for {} seconds", SILENCE.as_secs()),
                    };
                let event = if channel == RELAY {
                    Event::Relay(body)
                } else {
                    match open_control(&keys, &body) {
                        Ok((seq, message)) => {
                            if seq <= seq_in {
                                warn!("dropped a proxy message that goes backwards");
                                continue;
                            }
                            seq_in = seq;
                            match message {
                                Control::Attached => Event::Attached,
                                Control::Detached => Event::Detached,
                                Control::Ping => continue,
                                Control::Refused { why } => {
                                    break format!("the proxy refused: {why}")
                                }
                                other => {
                                    warn!("ignored a proxy message: {other:?}");
                                    continue;
                                }
                            }
                        }
                        Err(why) => {
                            warn!("dropped a proxy frame: {why:#}");
                            continue;
                        }
                    }
                };
                if events_tx.send(event).await.is_err() {
                    break "the listener went away".to_string();
                }
            };
            let _ = events_tx.send(Event::Closed(why)).await;
        });

        Ok(Link { events, relay })
    }

    /// A link over channels rather than a socket, for a test that plays the
    /// proxy and the device itself.
    pub fn from_parts(events: mpsc::Receiver<Event>, relay: mpsc::Sender<Vec<u8>>) -> Link {
        Link { events, relay }
    }

    pub async fn relay(&self, body: Vec<u8>) -> Result<()> {
        self.relay
            .send(body)
            .await
            .map_err(|_| anyhow!("the link is closed"))
    }

    pub fn relay_sender(&self) -> mpsc::Sender<Vec<u8>> {
        self.relay.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_join_reads_back_with_its_number() {
        let keys = Keys::from_secret(b"proxy");
        let join = Control::Join {
            role: Role::Device,
            name: "chem-01".into(),
            protocol: PROTOCOL,
            challenge: "00".repeat(16),
            nonce: "ff".repeat(16),
        };
        let body = seal_control(&keys, 1, &join).unwrap();
        let (seq, back) = open_control(&keys, &body).unwrap();
        assert_eq!(seq, 1);
        assert!(
            matches!(back, Control::Join { role: Role::Device, ref name, .. } if name == "chem-01")
        );
        let text = wire::to_string(&Envelope {
            seq: 2,
            body: &Control::Attached,
        })
        .unwrap();
        assert_eq!(text, r#"{seq=2,kind="attached"}"#);
    }
}
