//! The chat completions call, as any OpenAI-compatible proxy serves it.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub struct Settings {
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ToolCall {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub function: FunctionCall,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FunctionCall {
    pub name: String,
    pub arguments: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Message {
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

impl Message {
    fn plain(role: &str, text: impl Into<String>) -> Message {
        Message {
            role: role.into(),
            content: Some(text.into()),
            tool_calls: None,
            tool_call_id: None,
        }
    }

    pub fn system(text: impl Into<String>) -> Message {
        Message::plain("system", text)
    }

    pub fn user(text: impl Into<String>) -> Message {
        Message::plain("user", text)
    }

    pub fn assistant(text: impl Into<String>) -> Message {
        Message::plain("assistant", text)
    }

    pub fn tool(call_id: impl Into<String>, text: impl Into<String>) -> Message {
        Message {
            role: "tool".into(),
            content: Some(text.into()),
            tool_calls: None,
            tool_call_id: Some(call_id.into()),
        }
    }
}

#[derive(Serialize)]
struct Request<'a> {
    model: &'a str,
    messages: &'a [Message],
    tools: &'a [Value],
    temperature: f32,
}

#[derive(Deserialize)]
struct Response {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: Message,
}

pub struct Client {
    http: reqwest::Client,
}

impl Client {
    pub fn new() -> Client {
        Client {
            http: reqwest::Client::new(),
        }
    }

    pub async fn complete(
        &self,
        settings: &Settings,
        messages: &[Message],
        tools: &[Value],
    ) -> Result<Message> {
        let mut request = self
            .http
            .post(format!("{}/chat/completions", settings.base_url))
            .json(&Request {
                model: &settings.model,
                messages,
                tools,
                temperature: 0.2,
            });
        if let Some(key) = &settings.api_key {
            request = request.bearer_auth(key);
        }
        let response = request.send().await.context("calling the model")?;
        let status = response.status();
        let body = response
            .text()
            .await
            .context("reading the model's answer")?;
        if !status.is_success() {
            return Err(anyhow!(
                "model answered {status}: {}",
                body.chars().take(300).collect::<String>()
            ));
        }
        let parsed: Response =
            serde_json::from_str(&body).context("model answer is not chat completions JSON")?;
        parsed
            .choices
            .into_iter()
            .next()
            .map(|choice| choice.message)
            .ok_or_else(|| anyhow!("model answered with no choices"))
    }
}
