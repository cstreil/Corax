//! Kern im selben Prozess: `corax-host` starten und Befehle absetzen.
//!
//! Der Host läuft in einem eigenen Thread mit eigener Tokio-Runtime; die UI
//! spricht über Kanäle mit ihm und blockiert nie (L-E1). Anfragen sind typisiert,
//! Antworten werden hier geparst, damit die UI nur mit Rust-Typen arbeitet.
//! Ereignisse des Kerns (`spawn_notifications`) laufen durch denselben Kanal.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

use corax_host::{Host, HostConfig, HostDelegate, UiEvent};

use super::models::{
    Account, Label, ListThreadsArgs, SplitRule, ThreadDetail, ThreadPage, ThreadSummary,
    UnreadCounts,
};

pub const SANDBOX_IDENTIFIER: &str = "com.coraxapp.corax.sandbox";

/// Gesamtbudget für den Bildabruf einer Mail (AUDIT-L1, Zeitbudget je Mail).
const BUDGET_JE_MAIL: std::time::Duration = std::time::Duration::from_secs(20);

/// Eine Anfrage an den Kern.
#[derive(Clone, Debug)]
pub enum Request {
    Accounts,
    Splits,
    Labels,
    Unread,
    /// Erste Seite einer Ansicht.
    Threads { generation: u64, args: ListThreadsArgs },
    /// Nächste Seite (Paging beim Scrollen).
    More { generation: u64, args: ListThreadsArgs },
    Thread { generation: u64, id: i64 },
    Search { generation: u64, query: String },
    OpenAttachment(i64),
    /// Externe Bilder einer Mail holen. Läuft auf der Laufzeit des Kerns, damit
    /// weder UI noch Kern-Thread warten (der Kern bleibt für anderes offen).
    Bilder { thread: i64, urls: Vec<String> },
    /// Nach der ersten Liste: der Kern muss nicht mehr auf die UI warten.
    UiReady,
}

/// Eine Antwort oder ein Ereignis aus dem Kern.
pub enum Reply {
    Accounts(Vec<Account>),
    Splits(Vec<SplitRule>),
    Labels(Vec<Label>),
    Unread(UnreadCounts),
    Threads { generation: u64, threads: Vec<ThreadSummary>, cursor: Option<i64> },
    More { generation: u64, threads: Vec<ThreadSummary>, cursor: Option<i64> },
    Search { generation: u64, threads: Vec<ThreadSummary> },
    Thread { generation: u64, detail: Box<ThreadDetail> },
    /// Ergebnis eines Bildabrufs: je Adresse `(mime, bytes)` oder der Grund.
    Bilder { thread: i64, ergebnisse: Vec<(String, Result<(String, Vec<u8>), crate::html::FetchError>)> },
    Event(CoreEvent),
    Status(String),
    Error(String),
}

/// Kernereignisse, die L1 braucht; alles Übrige heißt „sonstiges Ereignis".
/// Die Nutzlast (Thread-Ids, Konto) wertet erst L2 aus — Abgleich nach
/// `mail:new` und Sync-Status je Konto.
#[allow(dead_code)]
#[derive(Clone, Debug)]
pub enum CoreEvent {
    Ready { core_start_ms: f64 },
    Failed { code: String, message: String },
    MailUpdated { thread_ids: Vec<i64> },
    MailNew { thread_ids: Vec<i64> },
    SyncProgress { phase: String, done: i64, total: i64 },
    SyncStatus { account_id: i64, state: String },
    AccountState { account_id: i64, sync_state: String },
    NetworkState { online: bool },
    Other { name: String },
}

pub struct MailCore {
    tx: Sender<Request>,
    rx: Receiver<Reply>,
}

struct Delegate {
    tx: Sender<Reply>,
}

impl Delegate {
    fn send(&self, event: CoreEvent) {
        let _ = self.tx.send(Reply::Event(event));
    }
}

impl HostDelegate for Delegate {
    fn open_url(&self, url: String) {
        // Externe Links gehen an den Systembrowser, wie in der Mac-App.
        let _ = std::process::Command::new("xdg-open").arg(&url).spawn();
    }

    fn open_path(&self, path: String) {
        let _ = std::process::Command::new("xdg-open").arg(&path).spawn();
    }

    fn on_event(&self, event: UiEvent) {
        let mapped = match event {
            UiEvent::HostReady { core_start_ms } => CoreEvent::Ready { core_start_ms },
            UiEvent::HostFailed { code, message } => CoreEvent::Failed { code, message },
            UiEvent::MailUpdated { thread_ids } => CoreEvent::MailUpdated { thread_ids },
            UiEvent::MailNew { thread_ids, .. } => CoreEvent::MailNew { thread_ids },
            UiEvent::SyncProgress(progress) => CoreEvent::SyncProgress {
                phase: progress.phase.clone(),
                done: progress.done as i64,
                total: progress.total as i64,
            },
            UiEvent::SyncStatus(status) => CoreEvent::SyncStatus {
                account_id: status.account_id,
                state: status.state.clone(),
            },
            UiEvent::AccountState { account_id, sync_state } => {
                CoreEvent::AccountState { account_id, sync_state }
            }
            UiEvent::NetworkState { online } => CoreEvent::NetworkState { online },
            other => CoreEvent::Other { name: event_name(&other) },
        };
        self.send(mapped);
    }

    fn notify(&self, notification: corax_host::Notification) -> bool {
        // L5 macht daraus eine echte Desktop-Benachrichtigung mit Symbol und
        // Klick-Ziel; für L1 genügt der Systemweg über notify-send.
        // `--` davor: ein Betreff wie „--icon=…" darf nicht als Option gelten.
        std::process::Command::new("notify-send")
            .arg("--")
            .arg(&notification.title)
            .arg(&notification.body)
            .spawn()
            .is_ok()
    }

    fn copy_to_clipboard(&self, _text: String) -> bool {
        // Nicht in L1 gebraucht (Bestätigungscode kopieren ist L4).
        false
    }
}

fn event_name(event: &UiEvent) -> String {
    serde_json::to_value(event)
        .ok()
        .and_then(|value| value.get("name").and_then(|name| name.as_str()).map(str::to_string))
        .unwrap_or_else(|| "unbekannt".into())
}

impl MailCore {
    /// Startet den Kern im Hintergrund. `identifier` ist die Sandbox-Kennung;
    /// echte Daten fasst L1 nicht an.
    pub fn start(identifier: &str) -> MailCore {
        let (req_tx, req_rx) = channel::<Request>();
        let (rep_tx, rep_rx) = channel::<Reply>();
        let identifier = identifier.to_string();

        let events = rep_tx.clone();
        std::thread::Builder::new()
            .name("corax-core".into())
            .spawn(move || {
                let delegate = Arc::new(Delegate { tx: events });
                let cfg = match HostConfig::new(&identifier) {
                    Ok(cfg) => cfg,
                    Err(error) => {
                        let _ = rep_tx.send(Reply::Error(format!("Host-Konfiguration: {error}")));
                        return;
                    }
                };
                let host = match Host::start(cfg, delegate) {
                    Ok(host) => host,
                    Err(error) => {
                        let _ = rep_tx.send(Reply::Error(format!("Host-Start: {error}")));
                        return;
                    }
                };
                let _ = rep_tx.send(Reply::Status(format!(
                    "Daten in {}",
                    host.data_dir().display()
                )));
                if let Err(error) = host.runtime().block_on(host.wait_ready()) {
                    let _ = rep_tx.send(Reply::Error(format!("Kern-Start: {error}")));
                    return;
                }
                let _ = rep_tx.send(Reply::Status("bereit".into()));

                while let Ok(request) = req_rx.recv() {
                    // Bilder nebenher holen: die Anfrage geht an die Laufzeit
                    // des Kerns, der Thread nimmt derweil die nächste an.
                    let request = match request {
                        Request::Bilder { thread, urls } => {
                            let antwort = rep_tx.clone();
                            host.runtime().spawn(async move {
                                // Budget je Mail statt je Bild: zwanzig tote
                                // Adressen dürfen nicht 200 s auf der Uhr stehen.
                                let ende = tokio::time::Instant::now() + BUDGET_JE_MAIL;
                                let mut ergebnisse = Vec::with_capacity(urls.len());
                                for url in urls {
                                    let rest = ende.saturating_duration_since(tokio::time::Instant::now());
                                    if rest.is_zero() {
                                        ergebnisse.push((url, Err(crate::html::FetchError::Timeout)));
                                        continue;
                                    }
                                    let grenzen = crate::html::FetchLimits {
                                        timeout: crate::html::FetchLimits::default().timeout.min(rest),
                                        ..crate::html::FetchLimits::default()
                                    };
                                    let ergebnis = crate::html::fetch_image(&url, &grenzen).await;
                                    ergebnisse.push((url, ergebnis));
                                }
                                let _ = antwort.send(Reply::Bilder { thread, ergebnisse });
                            });
                            continue;
                        }
                        other => other,
                    };
                    let Some((cmd, args)) = command_for(&request) else {
                        match request {
                            Request::UiReady => host.notify_ui_ready(),
                            _ => {}
                        }
                        continue;
                    };
                    let result = host.runtime().block_on(host.dispatch(cmd, &args));
                    let reply = match result {
                        Ok(json) => parse_reply(request, &json),
                        Err(error) => Reply::Error(format!("{cmd}: {error}")),
                    };
                    let _ = rep_tx.send(reply);
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

/// Befehl und Argumente zu einer Anfrage. `None` = kein `dispatch` nötig.
fn command_for(request: &Request) -> Option<(&'static str, String)> {
    let args = |value: serde_json::Value| serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    match request {
        Request::Accounts => Some(("list_accounts", "{}".into())),
        Request::Splits => Some(("list_splits", "{}".into())),
        Request::Labels => Some(("list_labels", "{}".into())),
        Request::Unread => Some(("unread_counts", "{}".into())),
        Request::Threads { args, .. } | Request::More { args, .. } => Some((
            "list_threads",
            serde_json::to_string(args).unwrap_or_else(|_| "{}".into()),
        )),
        Request::Thread { id, .. } => Some(("get_thread", args(serde_json::json!({ "threadId": id })))),
        Request::Search { query, .. } => Some((
            "search",
            args(serde_json::json!({
                "args": { "query": query, "accountId": null, "limit": 100 }
            })),
        )),
        Request::OpenAttachment(id) => Some((
            "open_attachment",
            args(serde_json::json!({ "attachmentId": id })),
        )),
        // Bilder holt die Laufzeit, nicht `dispatch` (siehe Schleife oben).
        Request::Bilder { .. } => None,
        Request::UiReady => None,
    }
}

fn parse_reply(request: Request, json: &str) -> Reply {
    fn decode<T: serde::de::DeserializeOwned>(json: &str, was: &str) -> Result<T, Reply> {
        serde_json::from_str(json).map_err(|error| Reply::Error(format!("{was}: {error}")))
    }
    match request {
        Request::Accounts => match decode::<Vec<Account>>(json, "list_accounts") {
            Ok(items) => Reply::Accounts(items),
            Err(reply) => reply,
        },
        Request::Splits => match decode::<Vec<SplitRule>>(json, "list_splits") {
            Ok(items) => Reply::Splits(items),
            Err(reply) => reply,
        },
        Request::Labels => match decode::<Vec<Label>>(json, "list_labels") {
            Ok(items) => Reply::Labels(items),
            Err(reply) => reply,
        },
        Request::Unread => match decode::<UnreadCounts>(json, "unread_counts") {
            Ok(counts) => Reply::Unread(counts),
            Err(reply) => reply,
        },
        Request::Threads { generation, .. } => match decode::<ThreadPage>(json, "list_threads") {
            Ok(page) => Reply::Threads { generation, threads: page.threads, cursor: page.next_cursor },
            Err(reply) => reply,
        },
        Request::More { generation, .. } => match decode::<ThreadPage>(json, "list_threads") {
            Ok(page) => Reply::More { generation, threads: page.threads, cursor: page.next_cursor },
            Err(reply) => reply,
        },
        Request::Search { generation, .. } => match decode::<corax_host_types::SearchResults>(json, "search") {
            Ok(results) => Reply::Search { generation, threads: results.threads },
            Err(reply) => reply,
        },
        Request::Thread { generation, .. } => match decode::<ThreadDetail>(json, "get_thread") {
            Ok(detail) => Reply::Thread { generation, detail: Box::new(detail) },
            Err(reply) => reply,
        },
        Request::OpenAttachment(_) => Reply::Status("Anhang geöffnet".into()),
        // Kommt hier nie an: Bilder beantwortet die Laufzeit selbst.
        Request::Bilder { .. } => Reply::Error("Bilder laufen nicht über dispatch".into()),
        Request::UiReady => Reply::Status("UI bereit".into()),
    }
}

/// `search` antwortet `{"threads":[…]}`, wie `ThreadPage` ohne Cursor.
mod corax_host_types {
    use super::super::models::ThreadSummary;
    use serde::Deserialize;

    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase")]
    pub struct SearchResults {
        #[serde(default)]
        pub threads: Vec<ThreadSummary>,
    }
}
