//! The relay. It knows a device by the name it joined under, lets one
//! controller attach to it, and forwards relay frames between the two without
//! reading them. It holds the proxy secret and nothing else.
//!
//! A device that joins again replaces the one under its name, since a device
//! that dropped off the network looks connected here until the silence runs
//! out. A second controller for a device is refused: the sealed session on the
//! relay channel is between exactly two ends.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context, Result};
use oclink::frame::{self, Keys};
use oclink::proxy::{self, Control, Role, CHALLENGE, SILENCE, STEP};
use oclink::{CONTROL, PROTOCOL, RELAY};
use rand::RngCore;
use tokio::io::AsyncWriteExt;
use tokio::net::tcp::OwnedWriteHalf;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};
use tracing::{info, warn};

/// What one connection's writer is handed.
enum Out {
    Control(Control),
    Relay(Vec<u8>),
    /// replaced by a newer join under the same name
    Close,
}

struct Peer {
    id: u64,
    out: mpsc::Sender<Out>,
}

impl Peer {
    async fn tell(&self, message: Out) {
        let _ = self.out.send(message).await;
    }
}

#[derive(Default)]
struct Slot {
    device: Option<Peer>,
    control: Option<Peer>,
}

#[derive(Default)]
struct Registry {
    slots: HashMap<String, Slot>,
    next_id: u64,
}

type Shared = Arc<Mutex<Registry>>;

/// Puts a joined connection in its slot, and says whether both ends are now
/// there. A replaced device is told to close.
async fn register(
    registry: &Shared,
    name: &str,
    role: Role,
    out: mpsc::Sender<Out>,
) -> Result<(u64, bool)> {
    let mut registry = registry.lock().await;
    registry.next_id += 1;
    let id = registry.next_id;
    let slot = registry.slots.entry(name.to_string()).or_default();
    let replaced = match role {
        Role::Device => slot.device.replace(Peer { id, out }),
        Role::Control => {
            if slot.control.is_some() {
                bail!("busy: another controller holds {name}");
            }
            slot.control.replace(Peer { id, out })
        }
    };
    if let Some(old) = replaced {
        old.tell(Out::Close).await;
    }
    Ok((id, slot.device.is_some() && slot.control.is_some()))
}

async fn counterpart(registry: &Shared, name: &str, role: Role) -> Option<mpsc::Sender<Out>> {
    let registry = registry.lock().await;
    let slot = registry.slots.get(name)?;
    match role {
        Role::Device => slot.control.as_ref().map(|peer| peer.out.clone()),
        Role::Control => slot.device.as_ref().map(|peer| peer.out.clone()),
    }
}

/// Takes a connection out of its slot, if it is still the one there, and tells
/// the other end it is alone again.
async fn unregister(registry: &Shared, name: &str, role: Role, id: u64) {
    let mut registry = registry.lock().await;
    let Some(slot) = registry.slots.get_mut(name) else {
        return;
    };
    let mine = match role {
        Role::Device => &mut slot.device,
        Role::Control => &mut slot.control,
    };
    if mine.as_ref().is_some_and(|peer| peer.id == id) {
        *mine = None;
        let other = match role {
            Role::Device => slot.control.as_ref(),
            Role::Control => slot.device.as_ref(),
        };
        if let Some(other) = other {
            other.tell(Out::Control(Control::Detached)).await;
        }
    }
    if slot.device.is_none() && slot.control.is_none() {
        registry.slots.remove(name);
    }
}

async fn write_out(
    mut writer: OwnedWriteHalf,
    keys: Keys,
    mut seq: i64,
    mut out: mpsc::Receiver<Out>,
) {
    while let Some(message) = out.recv().await {
        let result = match message {
            Out::Relay(body) => frame::write_frame(&mut writer, RELAY, &body).await,
            Out::Control(control) => {
                seq += 1;
                match proxy::seal_control(&keys, seq, &control) {
                    Ok(body) => frame::write_frame(&mut writer, CONTROL, &body).await,
                    Err(why) => Err(why),
                }
            }
            Out::Close => break,
        };
        if result.is_err() {
            break;
        }
    }
    let _ = writer.shutdown().await;
}

async fn serve(stream: TcpStream, keys: Arc<Keys>, registry: Shared) -> Result<()> {
    stream.set_nodelay(true)?;
    let (mut reader, mut writer) = stream.into_split();

    let mut challenge = [0u8; CHALLENGE];
    rand::thread_rng().fill_bytes(&mut challenge);
    frame::write_frame(&mut writer, CONTROL, &challenge).await?;

    let (channel, body) = tokio::time::timeout(STEP, frame::read_frame(&mut reader))
        .await
        .map_err(|_| anyhow!("no join within {} seconds", STEP.as_secs()))??;
    if channel != CONTROL {
        bail!("relayed before joining");
    }
    let (role, name, nonce) = match proxy::open_control(&keys, &body).context("opening the join")? {
        (
            1,
            Control::Join {
                role,
                name,
                protocol,
                challenge: given,
                nonce,
            },
        ) => {
            if given != oclink::hex(&challenge) {
                bail!("the join answers a different challenge");
            }
            if protocol != PROTOCOL {
                bail!("{name} speaks protocol {protocol}, this proxy speaks {PROTOCOL}");
            }
            (role, name, oclink::unhex(&nonce)?)
        }
        (_, other) => bail!("expected a join, got {other:?}"),
    };
    let session = proxy::session(&keys, &challenge, &nonce);

    let (out_tx, out_rx) = mpsc::channel(64);
    let (id, both) = match register(&registry, &name, role, out_tx.clone()).await {
        Ok(joined) => joined,
        Err(why) => {
            let refused = proxy::seal_control(
                &session,
                1,
                &Control::Refused {
                    why: why.to_string(),
                },
            )?;
            let _ = frame::write_frame(&mut writer, CONTROL, &refused).await;
            return Err(why);
        }
    };
    let writer_task = tokio::spawn(write_out(writer, session.clone(), 0, out_rx));
    info!(%name, %role, id, "joined");
    out_tx
        .send(Out::Control(Control::Joined))
        .await
        .map_err(|_| anyhow!("writer gone"))?;
    if both {
        let _ = out_tx.send(Out::Control(Control::Attached)).await;
        if let Some(other) = counterpart(&registry, &name, role).await {
            let _ = other.send(Out::Control(Control::Attached)).await;
        }
    }

    let mut seq_in = 1;
    let result = loop {
        let (channel, body) =
            match tokio::time::timeout(SILENCE, frame::read_frame(&mut reader)).await {
                Ok(Ok(frame)) => frame,
                Ok(Err(why)) => break Err(why),
                Err(_) => break Err(anyhow!("silent for {} seconds", SILENCE.as_secs())),
            };
        if writer_task.is_finished() {
            break Ok(());
        }
        if channel == RELAY {
            match counterpart(&registry, &name, role).await {
                Some(other) => {
                    let _ = other.send(Out::Relay(body)).await;
                }
                None => warn!(%name, %role, "relay frame with nobody attached, dropped"),
            }
            continue;
        }
        match proxy::open_control(&session, &body) {
            Ok((seq, message)) => {
                if seq <= seq_in {
                    warn!(%name, "control message that goes backwards, dropped");
                    continue;
                }
                seq_in = seq;
                if !matches!(message, Control::Ping) {
                    warn!(%name, "unexpected control message {message:?}, ignored");
                }
            }
            Err(why) => warn!(%name, "dropped a control frame: {why:#}"),
        }
    };

    unregister(&registry, &name, role, id).await;
    writer_task.abort();
    info!(%name, %role, id, "left");
    result
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let secret = std::env::var("PROXY_SECRET").context("PROXY_SECRET is not set")?;
    let listen = std::env::var("PROXY_LISTEN").unwrap_or_else(|_| "0.0.0.0:7071".to_string());
    let keys = Arc::new(Keys::from_secret(secret.as_bytes()));
    let registry: Shared = Arc::default();

    let listener = TcpListener::bind(&listen)
        .await
        .with_context(|| format!("listening on {listen}"))?;
    info!(%listen, version = env!("CARGO_PKG_VERSION"), "proxy up");

    loop {
        let (stream, peer) = listener.accept().await?;
        let keys = Arc::clone(&keys);
        let registry = Arc::clone(&registry);
        tokio::spawn(async move {
            if let Err(why) = serve(stream, keys, registry).await {
                info!(%peer, "connection ended: {why:#}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use oclink::proxy::{Event, Link};

    async fn start() -> (String, Arc<Keys>) {
        let keys = Arc::new(Keys::from_secret(b"proxy secret"));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let registry: Shared = Arc::default();
        let serving = Arc::clone(&keys);
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let keys = Arc::clone(&serving);
                let registry = Arc::clone(&registry);
                tokio::spawn(async move {
                    let _ = serve(stream, keys, registry).await;
                });
            }
        });
        (address, keys)
    }

    async fn next(link: &mut Link) -> Event {
        tokio::time::timeout(std::time::Duration::from_secs(5), link.events.recv())
            .await
            .expect("an event in time")
            .expect("the link is open")
    }

    #[tokio::test]
    async fn a_device_and_its_controller_are_attached_and_relayed() {
        let (address, keys) = start().await;
        let mut device = Link::connect(&address, &keys, Role::Device, "chem-01")
            .await
            .unwrap();
        let mut control = Link::connect(&address, &keys, Role::Control, "chem-01")
            .await
            .unwrap();

        assert!(matches!(next(&mut device).await, Event::Attached));
        assert!(matches!(next(&mut control).await, Event::Attached));

        control.relay(b"opaque bytes".to_vec()).await.unwrap();
        assert!(matches!(next(&mut device).await, Event::Relay(body) if body == b"opaque bytes"));
        device.relay(b"back".to_vec()).await.unwrap();
        assert!(matches!(next(&mut control).await, Event::Relay(body) if body == b"back"));

        // a second controller is refused, the first keeps its seat
        let refused = Link::connect(&address, &keys, Role::Control, "chem-01").await;
        assert!(refused.is_err(), "a second controller was let in");

        drop(control);
        assert!(matches!(next(&mut device).await, Event::Detached));

        // the seat is free again once the controller has gone
        let mut again = Link::connect(&address, &keys, Role::Control, "chem-01")
            .await
            .unwrap();
        assert!(matches!(next(&mut again).await, Event::Attached));
        assert!(matches!(next(&mut device).await, Event::Attached));
    }

    #[tokio::test]
    async fn a_wrong_secret_is_refused_before_anything_is_relayed() {
        let (address, _) = start().await;
        let wrong = Keys::from_secret(b"not the proxy secret");
        let result = Link::connect(&address, &wrong, Role::Device, "chem-01").await;
        assert!(result.is_err());
    }
}
