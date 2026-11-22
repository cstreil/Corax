//! Typen der Antworten, die die Oberfläche liest (Ausschnitt aus
//! `src/ipc/types.ts`).
//!
//! Der Kern serialisiert mit `serde(rename_all = "camelCase")`, hier wird also
//! mit denselben Namen gelesen. Unbekannte Felder sind erlaubt: die Oberfläche
//! nimmt nur, was sie braucht, und ein neueres Kern-Feld bricht sie nicht.
//!
//! Die Typen spiegeln die Schnittstelle vollständig, auch Felder, die L1 noch
//! nicht anzeigt (z. B. `snoozedUntil`, `authKind`) — deshalb kein Dead-Code-Gemecker.
#![allow(dead_code)]

use std::collections::HashMap;

use serde::Deserialize;
use serde::Serialize;

/// `MailView` im Kern; serde schreibt klein (`#[serde(rename_all = "lowercase")]`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MailView {
    Inbox,
    Starred,
    Snoozed,
    Sent,
    Drafts,
    Done,
    Trash,
    Spam,
    All,
}

impl MailView {
    pub const ALLE: [MailView; 9] = [
        MailView::Inbox,
        MailView::Starred,
        MailView::Snoozed,
        MailView::Sent,
        MailView::Drafts,
        MailView::Done,
        MailView::Trash,
        MailView::Spam,
        MailView::All,
    ];

    pub fn name(self) -> &'static str {
        match self {
            MailView::Inbox => "Posteingang",
            MailView::Starred => "Markiert",
            MailView::Snoozed => "Später",
            MailView::Sent => "Gesendet",
            MailView::Drafts => "Entwürfe",
            MailView::Done => "Erledigt",
            MailView::Trash => "Papierkorb",
            MailView::Spam => "Spam",
            MailView::All => "Alle",
        }
    }

    /// Buchstabe der `G`-Folge (TASTATUR.md).
    pub fn go_key(self) -> char {
        match self {
            MailView::Inbox => 'i',
            MailView::Starred => 's',
            MailView::Drafts => 'd',
            MailView::Sent => 't',
            MailView::Done => 'e',
            MailView::Snoozed => 'h',
            MailView::Trash => '#',
            MailView::Spam => '!',
            MailView::All => 'a',
        }
    }

    /// Aus der `G`-Folge zurück auf die Ansicht.
    pub fn from_go_key(key: char) -> Option<MailView> {
        MailView::ALLE.into_iter().find(|view| view.go_key() == key)
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Address {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub email: String,
}

impl Address {
    /// `addressName` in `src/lib/format.ts`: Name, sonst der Teil vor dem @.
    pub fn display(&self) -> String {
        match self.name.as_deref().map(str::trim) {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => self
                .email
                .split('@')
                .next()
                .filter(|part| !part.is_empty())
                .unwrap_or(&self.email)
                .to_string(),
        }
    }

    pub fn initials(&self) -> String {
        let name = self.display();
        let letters: String = name
            .split_whitespace()
            .take(2)
            .filter_map(|word| word.chars().next())
            .collect();
        if letters.is_empty() { "?".into() } else { letters.to_uppercase() }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: i64,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub auth_kind: String,
    #[serde(default)]
    pub sync_state: String,
}

impl Account {
    /// `Account.label` der Mac-App.
    pub fn label(&self) -> String {
        match self.display_name.as_deref().map(str::trim) {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => self
                .email
                .split('@')
                .next()
                .filter(|part| !part.is_empty())
                .unwrap_or(&self.email)
                .to_string(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadSummary {
    pub id: i64,
    #[serde(default)]
    pub account_id: i64,
    #[serde(default)]
    pub account_email: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub snippet: String,
    #[serde(default)]
    pub participants: Vec<Address>,
    /// Millisekunden seit epoch (der Kern schreibt durchgehend `_ms`).
    #[serde(default)]
    pub last_message_at: i64,
    #[serde(default)]
    pub message_count: i64,
    #[serde(default)]
    pub unread_count: i64,
    #[serde(default)]
    pub is_starred: bool,
    #[serde(default)]
    pub has_attachments: bool,
    #[serde(default)]
    pub snoozed_until: Option<i64>,
    #[serde(default)]
    pub labels: Vec<i64>,
}

impl ThreadSummary {
    pub fn unread(&self) -> bool {
        self.unread_count > 0
    }

    pub fn from_display(&self) -> String {
        self.participants
            .first()
            .map(Address::display)
            .unwrap_or_else(|| "?".into())
    }

    pub fn participants_line(&self) -> String {
        let names: Vec<String> = self.participants.iter().take(3).map(Address::display).collect();
        names.join(", ")
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPage {
    #[serde(default)]
    pub threads: Vec<ThreadSummary>,
    #[serde(default)]
    pub next_cursor: Option<i64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentMeta {
    pub id: i64,
    #[serde(default)]
    pub filename: Option<String>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub size: Option<i64>,
    #[serde(default)]
    pub is_inline: bool,
}

impl AttachmentMeta {
    pub fn name(&self) -> String {
        self.filename
            .clone()
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| format!("Anhang {}", self.id))
    }

    pub fn size_text(&self) -> String {
        let Some(bytes) = self.size.filter(|bytes| *bytes > 0) else { return String::new() };
        if bytes < 1024 {
            format!("{bytes} B")
        } else if bytes < 1024 * 1024 {
            format!("{} KB", bytes / 1024)
        } else {
            format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
        }
    }

    /// Endung für das Kürzel im Anhangsblock („PDF", „PNG", …).
    pub fn kind(&self) -> String {
        self.filename
            .as_deref()
            .and_then(|name| name.rsplit_once('.').map(|(_, ext)| ext.to_uppercase()))
            .filter(|ext| !ext.is_empty() && ext.len() <= 4)
            .or_else(|| {
                self.mime_type
                    .as_deref()
                    .and_then(|mime| mime.rsplit('/').next())
                    .map(|part| part.to_uppercase())
            })
            .unwrap_or_else(|| "DATEI".into())
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageDetail {
    pub id: i64,
    #[serde(default)]
    pub thread_id: i64,
    #[serde(default)]
    pub account_id: i64,
    #[serde(default)]
    pub from: Address,
    #[serde(default)]
    pub to: Vec<Address>,
    #[serde(default)]
    pub cc: Vec<Address>,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub date: i64,
    #[serde(default)]
    pub is_read: bool,
    #[serde(default)]
    pub is_starred: bool,
    #[serde(default)]
    pub is_draft: bool,
    #[serde(default)]
    pub is_outgoing: bool,
    #[serde(default)]
    pub snippet: String,
    #[serde(default)]
    pub body_state: String,
    #[serde(default)]
    pub text_body: Option<String>,
    #[serde(default)]
    pub html_body: Option<String>,
    #[serde(default)]
    pub attachments: Vec<AttachmentMeta>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadDetail {
    #[serde(default)]
    pub thread: ThreadSummary,
    #[serde(default)]
    pub messages: Vec<MessageDetail>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Label {
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub color: String,
    #[serde(default)]
    pub keyword: String,
    #[serde(default)]
    pub position: i64,
    /// Automatische Kategorie des Kerns (Marketing/News/…): nicht umbenennbar.
    #[serde(default)]
    pub is_auto: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitRule {
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub position: i64,
    /// `None` = eigener Tab; sonst Ziel „important"/„other"/„label:<id>".
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub count_all: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnreadCounts {
    #[serde(default)]
    pub inbox: i64,
    #[serde(default)]
    pub important: i64,
    #[serde(default)]
    pub other: i64,
    #[serde(default)]
    pub splits: HashMap<String, i64>,
    #[serde(default)]
    pub labels: HashMap<String, i64>,
    #[serde(default)]
    pub views: HashMap<String, i64>,
}

impl UnreadCounts {
    /// Zähler neben einer Ansicht; was der Kern nicht zählt, bleibt ohne Zahl.
    pub fn badge(&self, view: MailView) -> i64 {
        match view {
            MailView::Inbox => self.inbox,
            MailView::Starred => self.views.get("starred").copied().unwrap_or(0),
            MailView::Snoozed => self.views.get("snoozed").copied().unwrap_or(0),
            MailView::Drafts => self.views.get("drafts").copied().unwrap_or(0),
            MailView::Spam => self.views.get("spam").copied().unwrap_or(0),
            MailView::Sent | MailView::Done | MailView::Trash | MailView::All => 0,
        }
    }

    pub fn label_badge(&self, id: i64) -> i64 {
        self.labels.get(&id.to_string()).copied().unwrap_or(0)
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResults {
    #[serde(default)]
    pub threads: Vec<ThreadSummary>,
}

/// Argumente für `list_threads` (der Kern hat `deny_unknown_fields`, deshalb
/// werden nicht gesetzte Felder weggelassen statt als `null` gesendet).
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListThreadsArgs {
    pub view: MailView,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub split_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<i64>,
    pub limit: i64,
}

impl Default for MailView {
    fn default() -> Self {
        MailView::Inbox
    }
}
