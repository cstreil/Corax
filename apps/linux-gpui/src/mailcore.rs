//! Kern im selben Prozess: `corax-host` starten und Befehle absetzen.
//!
//! Der Host läuft in einem eigenen Thread mit eigener Tokio-Runtime; die UI
//! spricht über Kanäle mit ihm. Kein FFI, keine JSON-Datei, kein Netz.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

use corax_host::{Host, HostConfig, HostDelegate, UiEvent};

pub const SANDBOX_IDENTIFIER: &str = "com.coraxapp.corax.sandbox";

pub struct ThreadRow {
    pub id: i64,
    pub from: String,
    pub subject: String,
    pub snippet: String,
    pub date: String,
    pub unread: bool,
    pub count: i64,
}

pub enum Reply {
    Threads(Vec<ThreadRow>),
    Thread {
        subject: String,
        text: String,
        html: Option<String>,
        messages: usize,
    },
    Event(String),
    Status(String),
    Error(String),
}

pub enum Request {
    Threads,
    Thread(i64),
}

pub struct MailCore {
    tx: Sender<Request>,
    rx: Receiver<Reply>,
}

struct Delegate {
    tx: Sender<Reply>,
}

impl HostDelegate for Delegate {
    fn open_url(&self, url: String) {
        let _ = self.tx.send(Reply::Event(format!("open_url {url}")));
    }
    fn open_path(&self, path: String) {
        let _ = self.tx.send(Reply::Event(format!("open_path {path}")));
    }
    fn on_event(&self, event: UiEvent) {
        let _ = self
            .tx
            .send(Reply::Event(format!("event {:?}", std::mem::discriminant(&event))));
    }
}

impl MailCore {
    pub fn start() -> MailCore {
        let (req_tx, req_rx) = channel::<Request>();
        let (rep_tx, rep_rx) = channel::<Reply>();

        let events = rep_tx.clone();
        std::thread::Builder::new()
            .name("corax-spike-core".into())
            .spawn(move || {
                let delegate = Arc::new(Delegate { tx: events });
                let cfg = match HostConfig::new(SANDBOX_IDENTIFIER) {
                    Ok(cfg) => cfg,
                    Err(error) => {
                        let _ = rep_tx.send(Reply::Error(error.to_string()));
                        return;
                    }
                };
                let host = match Host::start(cfg, delegate) {
                    Ok(host) => host,
                    Err(error) => {
                        let _ = rep_tx.send(Reply::Error(error.to_string()));
                        return;
                    }
                };
                let _ = rep_tx.send(Reply::Status(format!(
                    "Host läuft, Daten in {}",
                    host.data_dir().display()
                )));
                if let Err(error) = host.runtime().block_on(host.wait_ready()) {
                    let _ = rep_tx.send(Reply::Error(error.to_string()));
                }
                let _ = rep_tx.send(Reply::Status("Kern bereit".into()));

                while let Ok(request) = req_rx.recv() {
                    match request {
                        Request::Threads => {
                            let json = host.runtime().block_on(
                                host.dispatch("list_threads", r#"{"view":"inbox","limit":200}"#),
                            );
                            match json {
                                Ok(json) => {
                                    let _ = rep_tx.send(Reply::Threads(parse_threads(&json)));
                                }
                                Err(error) => {
                                    let _ = rep_tx.send(Reply::Error(error.to_string()));
                                }
                            }
                        }
                        Request::Thread(id) => {
                            let args = format!(r#"{{"threadId":{id}}}"#);
                            match host.runtime().block_on(host.dispatch("get_thread", &args)) {
                                Ok(json) => {
                                    let _ = rep_tx.send(parse_thread(&json));
                                }
                                Err(error) => {
                                    let _ = rep_tx.send(Reply::Error(error.to_string()));
                                }
                            }
                        }
                    }
                }
                host.shutdown();
            })
            .expect("Kern-Thread");

        MailCore { tx: req_tx, rx: rep_rx }
    }

    pub fn request(&self, request: Request) {
        let _ = self.tx.send(request);
    }

    pub fn poll(&self) -> Vec<Reply> {
        self.rx.try_iter().collect()
    }
}

fn parse_threads(json: &str) -> Vec<ThreadRow> {
    let value: serde_json::Value = match serde_json::from_str(json) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    value["threads"]
        .as_array()
        .map(|items| items.iter().map(parse_row).collect())
        .unwrap_or_default()
}

fn parse_row(item: &serde_json::Value) -> ThreadRow {
    let from = item["participants"]
        .as_array()
        .and_then(|list| list.first())
        .map(|address| {
            address["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .or_else(|| address["email"].as_str())
                .unwrap_or("?")
                .to_string()
        })
        .unwrap_or_else(|| "?".into());
    ThreadRow {
        id: item["id"].as_i64().unwrap_or(0),
        from,
        subject: item["subject"].as_str().unwrap_or_default().to_string(),
        snippet: item["snippet"].as_str().unwrap_or_default().to_string(),
        date: item["lastMessageAt"].as_i64().map(format_date).unwrap_or_default(),
        unread: item["unreadCount"].as_i64().unwrap_or(0) > 0,
        count: item["messageCount"].as_i64().unwrap_or(1),
    }
}

fn parse_thread(json: &str) -> Reply {
    let value: serde_json::Value = match serde_json::from_str(json) {
        Ok(value) => value,
        Err(error) => return Reply::Error(format!("Thread-JSON: {error}")),
    };
    let messages = value["messages"].as_array().cloned().unwrap_or_default();
    let subject = value["thread"]["subject"].as_str().unwrap_or_default().to_string();
    let mut text = String::new();
    let mut html = None;
    for message in &messages {
        if let Some(body) = message["textBody"].as_str() {
            text.push_str(body);
            text.push('\n');
        } else if let Some(body) = message["htmlBody"].as_str() {
            html = Some(body.to_string());
            text.push_str(&crate::htmltext::strip(body));
            text.push('\n');
        } else if let Some(snippet) = message["snippet"].as_str() {
            text.push_str(snippet);
            text.push('\n');
        }
    }
    Reply::Thread { subject, text, html, messages: messages.len() }
}

fn format_date(seconds: i64) -> String {
    use chrono::{Local, TimeZone};
    match Local.timestamp_opt(seconds, 0) {
        chrono::LocalResult::Single(dt) => {
            let today = Local::now().date_naive();
            if dt.date_naive() == today {
                dt.format("%H:%M").to_string()
            } else {
                dt.format("%d.%m.").to_string()
            }
        }
        _ => String::new(),
    }
}
