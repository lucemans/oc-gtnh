//! The agent behind `@c` in chat, and a shell onto any computer in the base.
//!
//! ```text
//! ocharness serve                          attach to DEVICE and answer chat
//! ocharness shell <device> <command...>    run a shell line there, print what it wrote
//! ocharness lua <device> <file.lua>        run a chunk there, print what it printed
//! ocharness file <device> <remote path> <local file>   write a file there
//! ```
//!
//! Every mode joins the proxy as the controller of one device. The device
//! says hello when the proxy attaches the two, and everything after that is
//! sealed between the two ends with the link key the proxy never sees.

mod agent;
mod bridge;
mod llm;
mod tools;

use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use oclink::frame::Keys;
use oclink::proxy::{Event, Link, Role};
use tracing::{error, info, warn};

/// Everything read from the environment, once.
pub struct Config {
    pub proxy: String,
    pub proxy_keys: Keys,
    pub link_keys: Keys,
    pub device: String,
    pub llm: llm::Settings,
    pub extra_prompt: Option<String>,
}

fn env_required(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("{name} is not set"))
}

fn config(device: Option<String>, with_model: bool) -> Result<Config> {
    let extra_prompt = match std::env::var("AGENT_PROMPT_FILE") {
        Ok(path) => {
            Some(std::fs::read_to_string(&path).with_context(|| format!("reading {path}"))?)
        }
        Err(_) => None,
    };
    let llm = if with_model {
        llm::Settings {
            base_url: env_required("LLM_BASE_URL")?
                .trim_end_matches('/')
                .to_string(),
            api_key: std::env::var("LLM_API_KEY").ok(),
            model: env_required("LLM_MODEL")?,
        }
    } else {
        llm::Settings {
            base_url: String::new(),
            api_key: None,
            model: String::new(),
        }
    };
    Ok(Config {
        proxy: env_required("PROXY_ADDR")?,
        proxy_keys: Keys::from_secret(env_required("PROXY_SECRET")?.as_bytes()),
        link_keys: Keys::from_secret(env_required("LINK_KEY")?.as_bytes()),
        device: match device {
            Some(device) => device,
            None => env_required("DEVICE")?,
        },
        llm,
        extra_prompt,
    })
}

/// Stays attached to the device for as long as the process runs. A proxy that
/// goes away is tried again with a pause that doubles up to a minute.
async fn serve(config: Arc<Config>) -> Result<()> {
    let mut pause = Duration::from_secs(2);
    loop {
        info!(proxy = %config.proxy, device = %config.device, "joining");
        match Link::connect(
            &config.proxy,
            &config.proxy_keys,
            Role::Control,
            &config.device,
        )
        .await
        {
            Ok(mut link) => {
                pause = Duration::from_secs(2);
                loop {
                    match link.events.recv().await {
                        Some(Event::Attached) => {
                            match bridge::session(&mut link, Arc::clone(&config)).await {
                                Ok(()) => info!(device = %config.device, "device detached"),
                                Err(why) => {
                                    warn!(device = %config.device, "session ended: {why:#}");
                                    break;
                                }
                            }
                        }
                        Some(Event::Detached) | Some(Event::Relay(_)) => {}
                        Some(Event::Closed(why)) => {
                            warn!("proxy link closed: {why}");
                            break;
                        }
                        None => break,
                    }
                }
            }
            Err(why) => error!("could not join the proxy: {why:#}"),
        }
        tokio::time::sleep(pause).await;
        pause = (pause * 2).min(Duration::from_secs(60));
    }
}

/// One command to one device, and its answer on stdout.
async fn once(config: Arc<Config>, command: bridge::Outbound) -> Result<i32> {
    let mut link = Link::connect(
        &config.proxy,
        &config.proxy_keys,
        Role::Control,
        &config.device,
    )
    .await?;
    let attached = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match link.events.recv().await {
                Some(Event::Attached) => return Ok(()),
                Some(Event::Closed(why)) => bail!("{why}"),
                Some(_) => {}
                None => bail!("the link closed"),
            }
        }
    })
    .await;
    match attached {
        Ok(Ok(())) => {}
        Ok(Err(why)) => return Err(why),
        Err(_) => bail!("{} is not connected to the proxy", config.device),
    }
    let outcome = bridge::once(&mut link, &config.link_keys, command).await?;
    if let Some(output) = &outcome.output {
        if !output.is_empty() {
            println!("{output}");
        }
    }
    if outcome.ok {
        Ok(0)
    } else {
        eprintln!("failed: {}", outcome.error.unwrap_or_default());
        Ok(1)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let mode = arguments.first().map(String::as_str).unwrap_or("serve");
    let code = match mode {
        "serve" => {
            let config = Arc::new(config(None, true)?);
            serve(config).await?;
            0
        }
        "shell" if arguments.len() >= 3 => {
            let config = Arc::new(config(Some(arguments[1].clone()), false)?);
            let command = arguments[2..].join(" ");
            once(
                config,
                bridge::Outbound::Shell {
                    id: "1".into(),
                    command,
                },
            )
            .await?
        }
        "lua" if arguments.len() == 3 => {
            let config = Arc::new(config(Some(arguments[1].clone()), false)?);
            let code = std::fs::read_to_string(&arguments[2])
                .with_context(|| format!("reading {}", arguments[2]))?;
            once(
                config,
                bridge::Outbound::Run {
                    id: "1".into(),
                    code,
                },
            )
            .await?
        }
        "file" if arguments.len() == 4 => {
            let config = Arc::new(config(Some(arguments[1].clone()), false)?);
            let body = std::fs::read_to_string(&arguments[3])
                .with_context(|| format!("reading {}", arguments[3]))?;
            once(
                config,
                bridge::Outbound::File {
                    id: "1".into(),
                    path: arguments[2].clone(),
                    body,
                },
            )
            .await?
        }
        _ => {
            eprintln!(
                "usage: ocharness serve | shell <device> <command...> | lua <device> <file.lua> | file <device> <remote path> <local file>"
            );
            2
        }
    };
    std::process::exit(code);
}
