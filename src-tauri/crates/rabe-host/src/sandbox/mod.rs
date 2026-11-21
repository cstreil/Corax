//! The sandbox instance: the design mockup's mailbox in a disposable database.
//!
//! Why this exists: `credentials::adopt_legacy` in the core copies the dev
//! keyring's credentials into *every* non-release service, so a native
//! instance "without credentials" is not possible. Safety comes from the
//! address instead - an account on `sandbox.invalid` (RFC 2606) can never
//! resolve, so archiving, sending or snoozing works locally and reaches no
//! server.
//!
//! The seeder writes the database through the core's repository layer
//! (`comail_core::db::repo`) on top of the real migration set, so the schema is
//! the same one the app runs. It never touches the keyring, never starts the
//! core and never opens the release directory.

mod mockup;

use std::path::{Path, PathBuf};

use chrono::{Datelike, Duration, Local, NaiveDate, TimeZone};
use comail_core::db::repo::accounts::NewAccount;
use comail_core::db::repo::messages::{NewAttachment, NewMessage};
use comail_core::db::{migrations, repo};
use comail_core::models::roles;
use comail_core::models::{
    Address, AuthKind, Provider, RuleCondition, Settings, SplitRuleQuery, TextOp,
};
use rusqlite::{Connection, OptionalExtension, params};

use crate::HostError;

/// Identifier of the sandbox instance. Anything else is refused by the seeder.
pub const SANDBOX_IDENTIFIER: &str = "de.streil.corax.sandbox";

/// Port an enabled MCP server in the sandbox would use; the native instance
/// keeps 47833, so the two never fight over one port.
const SANDBOX_MCP_PORT: u16 = 47834;

/// What the seeder wrote, printed as JSON by `rabe-cli seed-sandbox`.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SeedReport {
    pub data_dir: String,
    pub account_id: i64,
    pub threads: usize,
    pub messages: usize,
    pub attachments: usize,
    pub labels: usize,
    pub splits: usize,
    /// Paths `--reset` removed, for the log and the report.
    pub removed: Vec<String>,
}

/// True for the sandbox identifier (and only that one).
pub fn is_sandbox_identifier(identifier: &str) -> bool {
    identifier == SANDBOX_IDENTIFIER
}

/// The sandbox's data directory under `base`, verified but not created.
///
/// The path is always `<base>/{SANDBOX_IDENTIFIER}` - never derived from an
/// environment variable - and the existing leaf must be a real directory, not
/// a symlink and not a differently named one, so `--reset` cannot be pointed
/// at data through the sandbox path.
pub(crate) fn sandbox_dir_at(base: &Path) -> Result<PathBuf, HostError> {
    let dir = base.join(SANDBOX_IDENTIFIER);
    verify_sandbox_path(&dir)?;
    Ok(dir)
}

/// Enforce the shape of a sandbox directory before it is seeded or emptied.
fn verify_sandbox_path(dir: &Path) -> Result<(), HostError> {
    if dir.file_name().and_then(|name| name.to_str()) != Some(SANDBOX_IDENTIFIER) {
        return Err(HostError::new(
            "refused",
            format!(
                "refusing to use {}: only {SANDBOX_IDENTIFIER} may be seeded or reset",
                dir.display()
            ),
        ));
    }
    if let Ok(metadata) = std::fs::symlink_metadata(dir)
        && metadata.file_type().is_symlink()
    {
        return Err(HostError::new(
            "refused",
            format!("refusing symlinked sandbox directory {}", dir.display()),
        ));
    }
    if dir.exists() {
        let canonical = dir.canonicalize().map_err(|error| {
            HostError::new("io", format!("cannot resolve {}: {error}", dir.display()))
        })?;
        let parent = dir
            .parent()
            .ok_or_else(|| HostError::new("refused", format!("{} has no parent", dir.display())))?;
        let parent_canonical = parent.canonicalize().map_err(|error| {
            HostError::new(
                "io",
                format!("cannot resolve {}: {error}", parent.display()),
            )
        })?;
        if canonical.parent() != Some(parent_canonical.as_path()) {
            return Err(HostError::new(
                "refused",
                format!(
                    "refusing {}: it resolves to {}, not to a directory below {}",
                    dir.display(),
                    canonical.display(),
                    parent_canonical.display()
                ),
            ));
        }
    }
    Ok(())
}

/// Fill `dir` with the mockup mailbox. `reset` removes everything in it except
/// the instance lock file (the caller holds that lock, so a running app cannot
/// be under us).
pub(crate) fn seed(dir: &Path, reset: bool) -> Result<SeedReport, HostError> {
    verify_sandbox_path(dir)?;
    std::fs::create_dir_all(dir).map_err(|error| {
        HostError::new("io", format!("cannot create {}: {error}", dir.display()))
    })?;
    let removed = if reset { reset_dir(dir)? } else { Vec::new() };

    let db_path = dir.join("comail.db");
    let mut conn = Connection::open(&db_path).map_err(|error| {
        HostError::new("io", format!("cannot open {}: {error}", db_path.display()))
    })?;
    conn.pragma_update(None, "journal_mode", "WAL").ok();
    conn.pragma_update(None, "foreign_keys", "ON").ok();
    migrations::run(&mut conn).map_err(core_error)?;

    let existing: i64 = conn
        .query_row("SELECT COUNT(*) FROM accounts", [], |row| row.get(0))
        .map_err(core_error)?;
    if existing > 0 {
        return Err(HostError::new(
            "already_seeded",
            format!(
                "{} already holds an account; pass --reset to rebuild the sandbox",
                db_path.display()
            ),
        ));
    }

    let now = Local::now().timestamp_millis();
    let tx = conn.transaction().map_err(core_error)?;
    let account_id = write_account(&tx)?;
    let folders = write_folders(&tx, account_id)?;
    write_settings(&tx)?;
    let labels = write_labels(&tx)?;
    let split_id = write_split(&tx)?;

    let mut threads = 0;
    let mut messages = 0;
    let mut attachments = 0;
    for thread in mockup::THREADS {
        let written = write_thread(&tx, dir, account_id, &folders, thread, now)?;
        threads += 1;
        messages += written.messages;
        attachments += written.attachments;

        let route = if thread.important {
            "important".to_string()
        } else {
            format!("split:{split_id}")
        };
        tx.execute(
            "UPDATE threads SET routed_tab = ?2 WHERE id = ?1",
            params![written.thread_id, route],
        )
        .map_err(core_error)?;

        if let Some((name, _)) = thread.tag {
            if let Some(label_id) = labels.get(name) {
                repo::labels::add_to_message(&tx, written.last_message_id, *label_id)
                    .map_err(core_error)?;
            }
        }
    }

    // UID bookkeeping: the next sync starts after the mail we just wrote and
    // must not backfill a server that does not exist.
    for folder_id in [folders.inbox, folders.sent] {
        let max_uid: i64 = tx
            .query_row(
                "SELECT COALESCE(MAX(uid), 0) FROM messages WHERE folder_id = ?1",
                params![folder_id],
                |row| row.get(0),
            )
            .map_err(core_error)?;
        repo::folders::set_uid_state(&tx, folder_id, Some(1), Some(max_uid + 1), None)
            .map_err(core_error)?;
        repo::folders::set_last_seen_uid(&tx, folder_id, max_uid).map_err(core_error)?;
        repo::folders::set_backfill(&tx, folder_id, Some(1), true).map_err(core_error)?;
    }

    // The core resolves every existing thread's tab once, guarded by this
    // marker. Write it now so the seeded routing survives the first start even
    // if someone turns auto-labels back on.
    tx.execute(
        "INSERT OR REPLACE INTO route_cache (sender_domain, route_key)
         VALUES ('__routing_backfill__', '1')",
        [],
    )
    .map_err(core_error)?;

    tx.commit().map_err(core_error)?;

    Ok(SeedReport {
        data_dir: dir.display().to_string(),
        account_id,
        threads,
        messages,
        attachments,
        labels: labels.len(),
        splits: 1,
        removed,
    })
}

struct Folders {
    inbox: i64,
    sent: i64,
}

fn write_account(conn: &Connection) -> Result<i64, HostError> {
    repo::accounts::insert(
        conn,
        &NewAccount {
            email: mockup::ACCOUNT_EMAIL,
            display_name: Some(mockup::ACCOUNT_NAME),
            provider: Provider::Imap,
            auth_kind: AuthKind::Password,
            username: mockup::ACCOUNT_EMAIL,
            imap_host: mockup::IMAP_HOST,
            imap_port: 993,
            smtp_host: mockup::SMTP_HOST,
            smtp_port: 587,
        },
    )
    .map_err(core_error)
}

fn write_folders(conn: &Connection, account_id: i64) -> Result<Folders, HostError> {
    let wanted = [
        ("INBOX", Some(roles::INBOX)),
        ("Archive", Some(roles::ARCHIVE)),
        ("Sent", Some(roles::SENT)),
        ("Drafts", Some(roles::DRAFTS)),
        ("Trash", Some(roles::TRASH)),
        ("Spam", Some(roles::SPAM)),
    ];
    let mut inbox = 0;
    let mut sent = 0;
    for (name, role) in wanted {
        let id =
            repo::folders::upsert(conn, account_id, name, Some("/"), role).map_err(core_error)?;
        // A seeded folder is complete: no backfill against a server that does
        // not exist, and no "backfill not started" state the actor would chase.
        repo::folders::set_uid_state(conn, id, Some(1), Some(1), None).map_err(core_error)?;
        repo::folders::set_backfill(conn, id, Some(1), true).map_err(core_error)?;
        match role {
            Some(roles::INBOX) => inbox = id,
            Some(roles::SENT) => sent = id,
            _ => {}
        }
    }
    Ok(Folders { inbox, sent })
}

fn write_settings(conn: &Connection) -> Result<(), HostError> {
    let mut settings = Settings::default();
    // No model download and no embedding work in a mockup mailbox.
    settings.embedding_backend = "none".to_string();
    // The mockup has the Wichtig/Newsletter tabs; the seeded `routed_tab`
    // values assume default splits are on.
    settings.inbox_default_splits = true;
    // Keep the seeded routing authoritative: the heuristic would move senders
    // like Cloudflare's `noreply@` out of "Wichtig".
    settings.auto_labels_enabled = false;
    // No MCP server in the sandbox; the port is reserved so enabling it later
    // cannot land on the native instance's 47833.
    settings.mcp_enabled = false;
    settings.mcp_port = SANDBOX_MCP_PORT;
    repo::settings::set(conn, &settings).map_err(core_error)
}

/// Mockup `tag` values as labels; returns name -> id.
///
/// A name the migration already seeded (the auto category "Social") is reused
/// instead of duplicated - `labels.name` is UNIQUE and the classifier resolves
/// its categories by keyword, not by name.
fn write_labels(
    conn: &Connection,
) -> Result<std::collections::HashMap<&'static str, i64>, HostError> {
    let mut out = std::collections::HashMap::new();
    let mut position = 0;
    for thread in mockup::THREADS {
        let Some((name, color)) = thread.tag else {
            continue;
        };
        if out.contains_key(name) {
            continue;
        }
        let existing: Option<i64> = conn
            .query_row(
                "SELECT id FROM labels WHERE name = ?1",
                params![name],
                |row| row.get(0),
            )
            .optional()
            .map_err(core_error)?;
        let id = match existing {
            Some(id) => {
                tracing::info!(label = name, %id, "sandbox: reusing the existing label");
                id
            }
            None => {
                repo::labels::save(conn, None, name, color, position)
                    .map_err(core_error)?
                    .id
            }
        };
        position += 1;
        out.insert(name, id);
    }
    Ok(out)
}

fn write_split(conn: &Connection) -> Result<i64, HostError> {
    let condition = RuleCondition::Any {
        of: mockup::NEWS_SENDERS
            .iter()
            .map(|sender| RuleCondition::Sender {
                op: TextOp::EndsWith,
                value: (*sender).to_string(),
            })
            .collect(),
    };
    let query = SplitRuleQuery {
        senders: Some(
            mockup::NEWS_SENDERS
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
        ),
        ..Default::default()
    };
    let split = repo::splits::save(
        conn,
        None,
        mockup::NEWS_SPLIT,
        1,
        &query,
        Some(&condition),
        None,
        None,
        false,
    )
    .map_err(core_error)?;
    Ok(split.id)
}

struct WrittenThread {
    thread_id: i64,
    last_message_id: i64,
    messages: usize,
    attachments: usize,
}

fn write_thread(
    conn: &Connection,
    data_dir: &Path,
    account_id: i64,
    folders: &Folders,
    thread: &mockup::MockupThread,
    now: i64,
) -> Result<WrittenThread, HostError> {
    let thread_id =
        repo::threads::create(conn, account_id, None, &normalize_subject(thread.subject))
            .map_err(core_error)?;

    let last = thread.messages.len().saturating_sub(1);
    let last_incoming = thread
        .messages
        .iter()
        .rposition(|message| !message.outgoing)
        .unwrap_or(last);
    let mut earlier_ids: Vec<String> = Vec::new();
    let mut last_message_id = 0;
    let mut attachment_count = 0;

    for (index, message) in thread.messages.iter().enumerate() {
        let outgoing = message.outgoing;
        let folder_id = if outgoing {
            folders.sent
        } else {
            folders.inbox
        };
        let uid: i64 = conn
            .query_row(
                "SELECT COALESCE(MAX(uid), 0) FROM messages WHERE folder_id = ?1",
                params![folder_id],
                |row| row.get(0),
            )
            .map_err(core_error)?;
        let uid = uid + 1;
        let message_id = format!(
            "<rabe-sandbox-{}-{}@sandbox.invalid>",
            thread.slug,
            index + 1
        );
        let text = html_to_text(message.body);
        let from = if outgoing {
            Address {
                name: Some(mockup::ACCOUNT_NAME.to_string()),
                email: mockup::ACCOUNT_EMAIL.to_string(),
            }
        } else {
            Address {
                name: Some(message.from_name.to_string()),
                email: thread.from_addr.to_string(),
            }
        };
        let to = if outgoing {
            vec![Address {
                name: Some(thread.from_name.to_string()),
                email: thread.from_addr.to_string(),
            }]
        } else {
            vec![Address {
                name: Some(mockup::ACCOUNT_NAME.to_string()),
                email: mockup::ACCOUNT_EMAIL.to_string(),
            }]
        };

        let id = repo::messages::insert(
            conn,
            &NewMessage {
                account_id,
                folder_id,
                uid: Some(uid),
                message_id: Some(message_id.clone()),
                gm_msgid: None,
                gm_thrid: None,
                subject: thread.subject.to_string(),
                from: Some(from),
                to,
                cc: Vec::new(),
                bcc: Vec::new(),
                date: message.at.millis(now),
                internal_date: Some(message.at.millis(now)),
                is_read: !(thread.unread && index == last_incoming),
                is_starred: thread.starred && index == last,
                is_draft: false,
                is_outgoing: outgoing,
                is_automated: !thread.important,
                has_attachments: !message.attachments.is_empty(),
                size: Some((message.body.len() + thread.subject.len()) as i64),
                snippet: snippet(&text),
                references: earlier_ids.clone(),
                list_unsubscribe: (!thread.important)
                    .then(|| "<mailto:unsubscribe@sandbox.invalid>".to_string()),
                list_unsubscribe_post: None,
                sender_addr: None,
            },
            thread_id,
        )
        .map_err(core_error)?;
        earlier_ids.push(message_id);
        last_message_id = id;

        repo::messages::store_body(
            conn,
            id,
            Some(&text),
            Some(message.body),
            None,
            !message.attachments.is_empty(),
            None,
        )
        .map_err(core_error)?;

        if !message.attachments.is_empty() {
            let part_ids: Vec<String> = (0..message.attachments.len())
                .map(|index| (index + 2).to_string())
                .collect();
            let atts: Vec<NewAttachment> = message
                .attachments
                .iter()
                .enumerate()
                .map(|(index, att)| NewAttachment {
                    message_id: id,
                    part_id: Some(part_ids[index].as_str()),
                    filename: Some(att.name),
                    mime_type: Some(att.kind),
                    size: Some(parse_size(att.size)),
                    content_id: None,
                    is_inline: false,
                })
                .collect();
            repo::messages::replace_attachments(conn, id, &atts).map_err(core_error)?;
            attachment_count += atts.len();
            write_placeholder_files(conn, data_dir, account_id, id, message)?;
        }

        repo::search::index_message(conn, id).map_err(core_error)?;
    }

    repo::threads::recompute(conn, thread_id).map_err(core_error)?;

    Ok(WrittenThread {
        thread_id,
        last_message_id,
        messages: thread.messages.len(),
        attachments: attachment_count,
    })
}

/// A small readable stand-in for the real attachment, at the path the core
/// uses for cached files, so "open"/"save" in the UI has something to hand out.
fn write_placeholder_files(
    conn: &Connection,
    data_dir: &Path,
    account_id: i64,
    message_id: i64,
    message: &mockup::MockupMessage,
) -> Result<(), HostError> {
    for att in message.attachments {
        let attachment_id: i64 = conn
            .query_row(
                "SELECT id FROM attachments WHERE message_id = ?1 AND filename = ?2",
                params![message_id, att.name],
                |row| row.get(0),
            )
            .map_err(core_error)?;
        let dir = data_dir
            .join("attachments")
            .join(account_id.to_string())
            .join(attachment_id.to_string());
        std::fs::create_dir_all(&dir).map_err(|error| {
            HostError::new("io", format!("cannot create {}: {error}", dir.display()))
        })?;
        let path = dir.join(att.name);
        if path.parent() != Some(dir.as_path()) {
            return Err(HostError::new(
                "refused",
                format!("unsafe attachment name {}", att.name),
            ));
        }
        let body = format!(
            "{} - Platzhalter aus der Rabe-Sandbox.\n\
             Kein echter Anhang, nur damit Öffnen und Sichern etwas anzeigen.\n",
            att.name
        );
        std::fs::write(&path, body).map_err(|error| {
            HostError::new("io", format!("cannot write {}: {error}", path.display()))
        })?;
        conn.execute(
            "UPDATE attachments SET file_path = ?2 WHERE id = ?1",
            params![attachment_id, path.to_string_lossy()],
        )
        .map_err(core_error)?;
    }
    Ok(())
}

/// Remove everything in the sandbox directory except the lock file the caller
/// holds. The directory itself must be `<parent>/{SANDBOX_IDENTIFIER}`; it is
/// verified again here, directly in front of the deletion.
fn reset_dir(dir: &Path) -> Result<Vec<String>, HostError> {
    verify_sandbox_path(dir)?;
    let platform = comail_core::config::platform_data_dir();
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if dir.parent().is_none() || home.as_deref() == Some(dir) || platform.as_deref() == Some(dir) {
        return Err(HostError::new(
            "refused",
            format!(
                "refusing to reset {}: not an instance directory",
                dir.display()
            ),
        ));
    }

    tracing::info!(dir = %dir.display(), "sandbox: reset requested");

    let mut removed = Vec::new();
    let entries = std::fs::read_dir(dir)
        .map_err(|error| HostError::new("io", format!("cannot read {}: {error}", dir.display())))?;
    for entry in entries {
        let path = entry
            .map_err(|error| {
                HostError::new("io", format!("cannot read {}: {error}", dir.display()))
            })?
            .path();
        if path.file_name().and_then(|n| n.to_str()) == Some("instance.lock") {
            continue;
        }
        if !path.starts_with(dir) {
            return Err(HostError::new(
                "refused",
                format!(
                    "refusing to remove {} outside {}",
                    path.display(),
                    dir.display()
                ),
            ));
        }
        if path.is_dir() {
            std::fs::remove_dir_all(&path).map_err(|error| {
                HostError::new("io", format!("cannot remove {}: {error}", path.display()))
            })?;
        } else {
            std::fs::remove_file(&path).map_err(|error| {
                HostError::new("io", format!("cannot remove {}: {error}", path.display()))
            })?;
        }
        tracing::info!(path = %path.display(), "sandbox: removed");
        removed.push(path.display().to_string());
    }
    Ok(removed)
}

impl mockup::Slot {
    /// Wall-clock time in local time, relative to the seeding run.
    fn millis(self, now: i64) -> i64 {
        let today = Local
            .timestamp_millis_opt(now)
            .single()
            .map(|dt| dt.date_naive())
            .unwrap_or_else(|| Local::now().date_naive());
        let (day, hour, minute) = match self {
            Self::Today(hour, minute) => (today, hour, minute),
            Self::Yesterday(hour, minute) => (today - Duration::days(1), hour, minute),
            Self::DaysAgo(days, hour, minute) => (today - Duration::days(days), hour, minute),
            Self::PreviousMonth(day, hour, minute) => {
                let (year, month) = if today.month() == 1 {
                    (today.year() - 1, 12)
                } else {
                    (today.year(), today.month() - 1)
                };
                let date =
                    NaiveDate::from_ymd_opt(year, month, day).unwrap_or(today - Duration::days(30));
                (date, hour, minute)
            }
        };
        let naive = day
            .and_hms_opt(hour, minute, 0)
            .unwrap_or_else(|| today.and_hms_opt(0, 0, 0).expect("midnight"));
        // Deliberately not clamped to "not in the future": a seed run before
        // 10:42 would otherwise collapse every "Heute" entry onto one
        // timestamp and lose the mockup's clock times, which the UI compares
        // against the design. Ordering and date groups stay correct either way.
        Local
            .from_local_datetime(&naive)
            .earliest()
            .map(|dt| dt.timestamp_millis())
            .unwrap_or(now)
    }
}

/// Mockup subject normalisation; only used for the subject-threading fallback,
/// which never runs in a sandbox (no sync).
fn normalize_subject(subject: &str) -> String {
    let mut subject = subject.trim().to_lowercase();
    loop {
        let stripped = ["re:", "aw:", "fwd:", "wg:", "fw:"]
            .iter()
            .find_map(|prefix| {
                subject
                    .strip_prefix(prefix)
                    .map(|rest| rest.trim().to_string())
            });
        match stripped {
            Some(rest) => subject = rest,
            None => break,
        }
    }
    subject
}

fn snippet(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= 140 {
        return flat;
    }
    let mut cut: String = flat.chars().take(140).collect();
    if let Some(space) = cut.rfind(' ') {
        cut.truncate(space);
    }
    cut.push('…');
    cut
}

/// Plain-text body from the mockup's small HTML subset.
fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut tag = String::new();
    for ch in html.chars() {
        match ch {
            '<' => {
                in_tag = true;
                tag.clear();
            }
            '>' if in_tag => {
                in_tag = false;
                let name = tag
                    .trim_start_matches('/')
                    .split_whitespace()
                    .next()
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                if name == "br" || name == "p" || name == "div" {
                    out.push('\n');
                }
            }
            _ if in_tag => tag.push(ch),
            _ => out.push(ch),
        }
    }
    let decoded = out
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    decoded
        .split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// "4,2 MB" -> bytes, for the attachment metadata.
fn parse_size(label: &str) -> i64 {
    let mut parts = label.split_whitespace();
    let value = parts.next().unwrap_or("0").replace(',', ".");
    let value: f64 = value.parse().unwrap_or(0.0);
    let unit = parts.next().unwrap_or("B").to_ascii_uppercase();
    let factor = match unit.as_str() {
        "GB" => 1024.0 * 1024.0 * 1024.0,
        "MB" => 1024.0 * 1024.0,
        "KB" => 1024.0,
        _ => 1.0,
    };
    (value * factor) as i64
}

fn core_error(error: impl Into<comail_core::error::CoreError>) -> HostError {
    let error = error.into();
    HostError::from_core(&error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_sandbox_identifier_is_accepted() {
        assert!(is_sandbox_identifier(SANDBOX_IDENTIFIER));
        assert!(!is_sandbox_identifier("de.streil.rabe.native"));
        assert!(!is_sandbox_identifier("de.streil.rabe"));
        assert!(!is_sandbox_identifier("de.streil.rabe.native.sandbox2"));
    }

    #[test]
    fn html_becomes_readable_text() {
        let text =
            html_to_text("<p>Hallo Christian,</p><p>anbei <b>Runde 3</b>.</p><p>Grüße<br>Jana</p>");
        assert_eq!(text, "Hallo Christian,\nanbei Runde 3.\nGrüße\nJana");
    }

    #[test]
    fn sizes_follow_the_mockup_labels() {
        assert_eq!(parse_size("96 KB"), 96 * 1024);
        assert_eq!(parse_size("820 KB"), 820 * 1024);
        assert_eq!(parse_size("4,2 MB"), (4.2 * 1024.0 * 1024.0) as i64);
    }

    #[test]
    fn subjects_lose_reply_prefixes() {
        assert_eq!(normalize_subject("AW: Hiwatt"), "hiwatt");
        assert_eq!(normalize_subject("Re: Re: Test"), "test");
    }

    #[test]
    fn snippets_are_short_and_flat() {
        let long = "Wort ".repeat(80);
        let cut = snippet(&long);
        assert!(cut.chars().count() <= 141, "{cut}");
        assert!(!cut.contains('\n'));
    }

    #[test]
    fn reset_refuses_the_platform_data_directory() {
        let platform = comail_core::config::platform_data_dir().expect("platform dir");
        let error = reset_dir(&platform).expect_err("must refuse");
        assert_eq!(error.code, "refused");
    }

    #[test]
    fn reset_refuses_a_foreign_directory_and_leaves_it_alone() {
        let base = tempfile::tempdir().expect("base");
        let foreign = base.path().join("profiling-copy");
        std::fs::create_dir(&foreign).expect("foreign dir");
        let keep = foreign.join("comail.db");
        std::fs::write(&keep, "precious").expect("seed file");

        // Same shape as `--reset`: the low-level entry point must refuse a
        // directory that is not the sandbox, before deleting anything.
        let error = seed(&foreign, true).expect_err("must refuse");
        assert_eq!(error.code, "refused");
        assert_eq!(
            std::fs::read_to_string(&keep).expect("still there"),
            "precious"
        );

        // The sandbox itself is accepted.
        let sandbox = sandbox_dir_at(base.path()).expect("sandbox path");
        let report = seed(&sandbox, true).expect("seed the sandbox");
        assert_eq!(report.threads, 10);
    }

    #[test]
    fn a_symlinked_sandbox_directory_is_refused() {
        let base = tempfile::tempdir().expect("base");
        let target = base.path().join("real-data");
        std::fs::create_dir(&target).expect("target dir");
        std::fs::write(target.join("keep.txt"), "keep").expect("target file");
        std::os::unix::fs::symlink(&target, base.path().join(SANDBOX_IDENTIFIER)).expect("symlink");

        let error = sandbox_dir_at(base.path()).expect_err("must refuse a symlink");
        assert_eq!(error.code, "refused");
        assert_eq!(
            std::fs::read_to_string(target.join("keep.txt")).expect("target untouched"),
            "keep"
        );
    }
}
