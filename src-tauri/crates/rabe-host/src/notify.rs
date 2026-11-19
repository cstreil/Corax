//! Durable native desktop-notification delivery.
//!
//! Sync owns eligibility and enqueues an immutable presentation snapshot in
//! SQLite. This host-side worker is deliberately independent of the UI so a
//! hidden window or a temporarily unmounted listener cannot lose notifications.
//! Port of `src-tauri/src/notifications.rs`: same poll interval, batch size,
//! retry backoff, scope/routing decision and copy strings.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use comail_core::{Core, NotificationOutboxItem, RoutedTab};
use tokio::time::MissedTickBehavior;

use crate::{HostDelegate, Notification};

const POLL_INTERVAL: Duration = Duration::from_secs(3);
const DISPATCH_BATCH: i64 = 16;
const MAX_RETRY_DELAY_MS: i64 = 5 * 60 * 1_000;
/// How long to hold a notification while its thread awaits AI routing before
/// giving up and scoping against the thread's Important/Other fallback bucket
/// (the tab the list shows it under meanwhile).
const MAX_ROUTING_WAIT_MS: i64 = 30_000;
/// How far out a still-routing notification is deferred between re-checks.
const ROUTING_RECHECK_MS: i64 = 3_000;

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// What to do with one due notification once the user's scope is applied.
enum Decision {
    Deliver,
    /// Wait for the thread's tab to resolve; re-check at this epoch-ms.
    Defer(i64),
    Suppress(&'static str),
}

/// Whether a resolved route key passes the configured notification scope.
/// `"all"` lets everything through; `"tabs"` matches the selected route keys;
/// any other value (including the default `"important"`) keeps the historical
/// Important-only behavior.
fn scope_allows(scope: &str, tabs: &[String], routed_key: &str) -> bool {
    match scope {
        "all" => true,
        "tabs" => tabs.iter().any(|t| t == routed_key),
        _ => routed_key == "important",
    }
}

/// Decide one item's fate without claiming it, so a wait-for-routing deferral
/// never consumes a delivery attempt.
async fn delivery_decision(
    core: &Core,
    item: &NotificationOutboxItem,
    scope: &str,
    tabs: &[String],
    now: i64,
) -> Decision {
    // "all" needs no tab lookup at all.
    if scope == "all" {
        return Decision::Deliver;
    }
    let Some(thread_id) = item.thread_id else {
        // Nothing to scope against; fail open rather than drop it.
        return Decision::Deliver;
    };
    match core.notification_thread_tab(thread_id).await {
        Ok(Some(RoutedTab::Resolved(key))) => {
            if scope_allows(scope, tabs, &key) {
                Decision::Deliver
            } else {
                Decision::Suppress("out of notification scope")
            }
        }
        Ok(Some(RoutedTab::Pending { fallback })) => {
            if now - item.created_at < MAX_ROUTING_WAIT_MS {
                Decision::Defer(now + ROUTING_RECHECK_MS)
            } else if scope_allows(scope, tabs, &fallback) {
                Decision::Deliver
            } else {
                Decision::Suppress("out of notification scope")
            }
        }
        Ok(None) => Decision::Suppress("thread no longer present"),
        Err(error) => {
            tracing::warn!(outbox_id = item.id, %error, "notification tab lookup failed");
            // Don't lose a notification over a transient read error.
            Decision::Deliver
        }
    }
}

/// Start the single notification dispatcher for this host process.
///
/// The loop is supervised: a panic inside one cycle restarts it with a growing
/// delay instead of silently ending notification delivery for the rest of the
/// process or spin-restarting once per second (audit N5). The outbox rows
/// survive either way. A cancellation means the runtime is going down, which is
/// not a failure - the loop ends.
pub(crate) fn spawn(runtime: &tokio::runtime::Handle, core: Core, delegate: Arc<dyn HostDelegate>) {
    runtime.spawn(async move {
        let mut attempt: u32 = 0;
        loop {
            let task_core = core.clone();
            let task_delegate = delegate.clone();
            let started = std::time::Instant::now();
            let joined = tokio::spawn(async move { run(task_core, task_delegate).await }).await;
            match joined {
                Ok(()) => break,
                Err(error) if error.is_cancelled() => {
                    tracing::debug!("notification dispatcher cancelled; stopping");
                    break;
                }
                Err(error) => {
                    if crate::backoff::ran_long_enough(started.elapsed()) {
                        attempt = 0;
                    }
                    let delay = crate::backoff::delay(attempt);
                    attempt = attempt.saturating_add(1);
                    tracing::error!(
                        %error,
                        delay_ms = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX),
                        "notification dispatcher stopped; restarting"
                    );
                    tokio::time::sleep(delay).await;
                }
            }
        }
    });
}

async fn run(core: Core, delegate: Arc<dyn HostDelegate>) {
    if let Err(error) = core.recover_notification_deliveries().await {
        tracing::warn!(%error, "notification outbox recovery failed");
    }

    let mut tick = tokio::time::interval(POLL_INTERVAL);
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tick.tick().await;
        dispatch_due(&core, &delegate).await;
    }
}

/// Terminal outcome that needs no delivery attempt: the master switch is off,
/// or the user has **finally denied** notifications.
///
/// `can_notify()` must be `false` only for a final denial (see
/// [`HostDelegate::can_notify`]); unknown or not-yet-asked status answers
/// `true`, and a failed post is [`HostDelegate::notify`] returning `false`,
/// which retries instead of suppressing (audit Nachprüfung 2, A1).
///
/// Both terminal states end the row (`suppress`) instead of leaving it
/// pending - that is what keeps a denial from stacking days of notifications
/// that all arrive at once later (audit N-M3). The code copy in
/// [`dispatch_due`] runs before this, exactly like Tauri did it.
fn terminal_suppression(notifications_enabled: bool, can_notify: bool) -> Option<&'static str> {
    if !notifications_enabled {
        Some("notifications disabled")
    } else if !can_notify {
        Some("not_permitted")
    } else {
        None
    }
}

async fn dispatch_due(core: &Core, delegate: &Arc<dyn HostDelegate>) {
    let settings = match core.get_settings().await {
        Ok(settings) => settings,
        Err(error) => {
            tracing::warn!(%error, "notification dispatcher could not read settings");
            return;
        }
    };
    let notifications_enabled = settings.notifications_enabled;
    let scope = settings.notification_scope;
    let tabs = settings.notification_tabs;
    let due = match core.due_notifications(DISPATCH_BATCH).await {
        Ok(due) => due,
        Err(error) => {
            tracing::warn!(%error, "notification dispatcher could not read outbox");
            return;
        }
    };

    for item in due {
        // A one-time code is time-critical: copy it straight away (Universal
        // Clipboard offers it on the user's iPhone/iPad too) - whether or not
        // the user allows notifications, and whatever tab the mail lands in.
        // The permission gate must stay *after* this (audit N-M3: gating first
        // took the codes away from a user who only declined notifications).
        let code = if settings.copy_verification_codes || notifications_enabled {
            core.message_verification_code(item.message_id)
                .await
                .ok()
                .flatten()
        } else {
            None
        };
        if let Some(code) = &code {
            if settings.copy_verification_codes && first_copy(item.message_id) {
                if !delegate.copy_to_clipboard(code.clone()) {
                    tracing::warn!(outbox_id = item.id, "copying verification code failed");
                }
            }
        }

        // Master switch off, or no permission: move the row to a terminal
        // state instead of re-listing it every cycle and piling it up for a
        // later avalanche. `mark_suppressed` moves `pending` directly, so this
        // is not a delivery attempt and does not bump `attempts`.
        if let Some(reason) = terminal_suppression(notifications_enabled, delegate.can_notify()) {
            suppress(core, item.id, reason).await;
            continue;
        }

        // Apply the user's scope before claiming, so waiting for a thread's tab
        // to resolve never consumes a delivery attempt.
        let decision = if code.is_some() {
            Decision::Deliver
        } else {
            delivery_decision(core, &item, &scope, &tabs, now_ms()).await
        };
        match decision {
            Decision::Deliver => {}
            Decision::Defer(not_before) => {
                if let Err(error) = core.defer_notification_delivery(item.id, not_before).await {
                    tracing::warn!(outbox_id = item.id, %error, "notification defer failed");
                }
                continue;
            }
            Decision::Suppress(reason) => {
                if core
                    .claim_notification_delivery(item.id)
                    .await
                    .unwrap_or(false)
                {
                    suppress(core, item.id, reason).await;
                }
                continue;
            }
        }

        match core.claim_notification_delivery(item.id).await {
            Ok(true) => {}
            Ok(false) => continue,
            Err(error) => {
                tracing::warn!(outbox_id = item.id, %error, "notification claim failed");
                continue;
            }
        }

        let (title, body) = match &code {
            Some(code) => code_notification_copy(&item, code, settings.copy_verification_codes),
            None => notification_copy(&item),
        };
        let notification = Notification {
            id: item.id,
            title: title.clone(),
            body: body.clone(),
            thread_id: item.thread_id,
            account_id: Some(item.account_id),
        };
        if delegate.notify(notification) {
            match core.mark_notification_delivered(item.id).await {
                Ok(true) => {}
                Ok(false) => tracing::warn!(
                    outbox_id = item.id,
                    "native notification sent but outbox state was no longer claimable"
                ),
                Err(error) => tracing::warn!(
                    outbox_id = item.id,
                    %error,
                    "native notification sent but delivery state could not be persisted"
                ),
            }
        } else {
            let delay_ms = retry_delay_ms(item.attempts.saturating_add(1));
            tracing::warn!(
                outbox_id = item.id,
                attempts = item.attempts.saturating_add(1),
                delay_ms,
                "native notification failed; scheduled retry"
            );
            if let Err(db_error) = core
                .retry_notification_delivery(
                    item.id,
                    delay_ms,
                    "notification not delivered".to_string(),
                )
                .await
            {
                tracing::warn!(
                    outbox_id = item.id,
                    %db_error,
                    "notification retry state could not be persisted"
                );
            }
        }
    }
}

async fn suppress(core: &Core, id: i64, reason: &'static str) {
    match core.suppress_notification_delivery(id, reason).await {
        Ok(true) => {}
        Ok(false) => tracing::warn!(outbox_id = id, reason, "notification suppression lost race"),
        Err(error) => {
            tracing::warn!(outbox_id = id, reason, %error, "notification suppression failed")
        }
    }
}

fn notification_copy(item: &NotificationOutboxItem) -> (String, String) {
    let title = nonempty(item.sender_name.as_deref())
        .or_else(|| nonempty(item.sender_addr.as_deref()))
        .unwrap_or("Rabe")
        .to_owned();
    let body = nonempty(Some(&item.subject))
        .unwrap_or("New message")
        .to_owned();
    (title, body)
}

/// True the first time a message's code is seen, so a notification retry
/// doesn't clobber whatever the user copied since.
fn first_copy(message_id: i64) -> bool {
    static COPIED: std::sync::Mutex<Vec<i64>> = std::sync::Mutex::new(Vec::new());
    let mut copied = COPIED.lock().unwrap_or_else(|e| e.into_inner());
    if copied.contains(&message_id) {
        return false;
    }
    if copied.len() >= 64 {
        copied.remove(0);
    }
    copied.push(message_id);
    true
}

fn code_notification_copy(
    item: &NotificationOutboxItem,
    code: &str,
    copied: bool,
) -> (String, String) {
    let (sender, _) = notification_copy(item);
    let body = if copied {
        format!("{sender} · Copied to clipboard")
    } else {
        sender
    };
    (format!("Verification code {code}"), body)
}

fn nonempty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

/// Exponential retry beginning at five seconds and capped at five minutes.
fn retry_delay_ms(attempt: i64) -> i64 {
    let exponent = attempt.saturating_sub(1).clamp(0, 6) as u32;
    (5_000_i64.saturating_mul(1_i64 << exponent)).min(MAX_RETRY_DELAY_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(name: Option<&str>, address: Option<&str>, subject: &str) -> NotificationOutboxItem {
        NotificationOutboxItem {
            id: 1,
            account_id: 2,
            message_id: 3,
            thread_id: Some(4),
            sender_name: name.map(str::to_owned),
            sender_addr: address.map(str::to_owned),
            subject: subject.to_owned(),
            state: "pending".to_owned(),
            attempts: 0,
            not_before: None,
            created_at: 0,
            claimed_at: None,
            delivered_at: None,
            suppressed_at: None,
            suppression_reason: None,
            last_error: None,
        }
    }

    #[test]
    fn copy_prefers_name_then_address_and_has_safe_fallbacks() {
        assert_eq!(
            notification_copy(&item(Some(" Alice "), Some("alice@test.dev"), " Hi ")),
            ("Alice".to_owned(), "Hi".to_owned())
        );
        assert_eq!(
            notification_copy(&item(Some(" "), Some(" alice@test.dev "), "")),
            ("alice@test.dev".to_owned(), "New message".to_owned())
        );
        assert_eq!(
            notification_copy(&item(None, None, "Subject")),
            ("Rabe".to_owned(), "Subject".to_owned())
        );
    }

    #[test]
    fn scope_gates_by_routed_tab() {
        let tabs = vec!["important".to_owned(), "split:3".to_owned()];

        // "all" ignores the tab entirely.
        assert!(scope_allows("all", &[], "other"));
        assert!(scope_allows("all", &[], "label:9"));

        // "tabs" matches only the selected route keys.
        assert!(scope_allows("tabs", &tabs, "important"));
        assert!(scope_allows("tabs", &tabs, "split:3"));
        assert!(!scope_allows("tabs", &tabs, "other"));
        assert!(!scope_allows("tabs", &tabs, "split:4"));

        // The default (and any unknown value) is Important-only.
        assert!(scope_allows("important", &tabs, "important"));
        assert!(!scope_allows("important", &tabs, "other"));
        assert!(!scope_allows("", &tabs, "other"));
    }

    #[test]
    fn retry_backoff_is_bounded() {
        assert_eq!(retry_delay_ms(1), 5_000);
        assert_eq!(retry_delay_ms(2), 10_000);
        assert_eq!(retry_delay_ms(5), 80_000);
        assert_eq!(retry_delay_ms(7), MAX_RETRY_DELAY_MS);
        assert_eq!(retry_delay_ms(100), MAX_RETRY_DELAY_MS);
    }

    #[test]
    fn code_copy_names_the_code_and_who_sent_it() {
        let (title, body) =
            code_notification_copy(&item(Some("Bank"), None, "Ihr Code"), "123456", true);
        assert_eq!(title, "Verification code 123456");
        assert_eq!(body, "Bank · Copied to clipboard");

        let (_, body) =
            code_notification_copy(&item(Some("Bank"), None, "Ihr Code"), "123456", false);
        assert_eq!(body, "Bank");
    }

    #[test]
    fn both_terminal_states_suppress_instead_of_stacking() {
        assert_eq!(
            terminal_suppression(false, false),
            Some("notifications disabled")
        );
        assert_eq!(
            terminal_suppression(false, true),
            Some("notifications disabled")
        );
        assert_eq!(terminal_suppression(true, false), Some("not_permitted"));
        assert_eq!(terminal_suppression(true, true), None);
    }

    /// End to end against a seeded sandbox database: without the notification
    /// permission the code still reaches the clipboard and the outbox row ends
    /// as `suppressed`/`not_permitted` (never retried, never delivered later);
    /// with the permission the next row is delivered normally.
    ///
    /// One test on purpose: it sets a process-wide environment variable before
    /// the first `Core::start` (the core's credentials-file switch, which keeps
    /// the login keychain out of the test).
    #[tokio::test]
    async fn a_denied_permission_copies_the_code_and_suppresses_the_row() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let credentials = std::env::temp_dir().join(format!(
            "rabe-host-notify-{}-credentials.json",
            std::process::id()
        ));
        std::fs::write(&credentials, "{}").expect("credentials file");
        // SAFETY: single test of this binary touches the environment, before
        // the first core starts.
        unsafe { std::env::set_var("COMAIL_CREDENTIALS_INSECURE_FILE", &credentials) };

        let base = tempfile::tempdir().expect("tempdir");
        crate::seed_sandbox_at(base.path(), crate::SANDBOX_IDENTIFIER, false).expect("seed");
        let dir = base.path().join(crate::SANDBOX_IDENTIFIER);

        // Two messages with a code, two outbox rows, notifications allowed in
        // the settings (the gate under test is the delegate's permission).
        let db_path = dir.join("comail.db");
        let conn = rusqlite::Connection::open(&db_path).expect("db");
        conn.pragma_update(None, "foreign_keys", "ON").ok();
        let message_ids: Vec<i64> = {
            let mut stmt = conn
                .prepare("SELECT id FROM messages WHERE is_outgoing = 0 ORDER BY id LIMIT 2")
                .expect("prepare");
            stmt.query_map([], |row| row.get(0))
                .expect("query")
                .collect::<Result<_, _>>()
                .expect("ids")
        };
        assert_eq!(message_ids.len(), 2);
        for (index, message_id) in message_ids.iter().enumerate() {
            let text = format!("Your verification code is {}", 654_321 + index as i64);
            conn.execute(
                "UPDATE message_bodies SET text_body = ?1 WHERE message_id = ?2",
                rusqlite::params![text, message_id],
            )
            .expect("update body");
            conn.execute(
                "UPDATE messages SET snippet = ?1, body_state = 'cached' WHERE id = ?2",
                rusqlite::params![text, message_id],
            )
            .expect("update snippet");
            comail_core::db::repo::notifications::enqueue(&conn, *message_id).expect("enqueue");
        }
        let mut settings = comail_core::db::repo::settings::get(&conn).expect("settings");
        settings.notifications_enabled = true;
        settings.copy_verification_codes = true;
        comail_core::db::repo::settings::set(&conn, &settings).expect("settings");
        // Only the first row is due now; the second is released between the
        // two rounds below.
        conn.execute(
            "UPDATE notification_outbox SET not_before = 9999999999999 WHERE message_id = ?1",
            [message_ids[1]],
        )
        .expect("park second row");
        drop(conn);

        let core = comail_core::Core::start(comail_core::config::Paths::for_tests(&dir))
            .await
            .expect("core start");

        struct Recorder {
            allowed: AtomicBool,
            notifications: std::sync::Mutex<Vec<crate::Notification>>,
            copies: std::sync::Mutex<Vec<String>>,
        }
        impl HostDelegate for Recorder {
            fn open_url(&self, _url: String) {}
            fn open_path(&self, _path: String) {}
            fn on_event(&self, _event: crate::UiEvent) {}
            fn can_notify(&self) -> bool {
                self.allowed.load(Ordering::SeqCst)
            }
            fn notify(&self, notification: crate::Notification) -> bool {
                self.notifications
                    .lock()
                    .expect("notifications")
                    .push(notification);
                true
            }
            fn copy_to_clipboard(&self, text: String) -> bool {
                self.copies.lock().expect("copies").push(text);
                true
            }
        }
        let recorder = Arc::new(Recorder {
            allowed: AtomicBool::new(false),
            notifications: Default::default(),
            copies: Default::default(),
        });
        let delegate: Arc<dyn HostDelegate> = recorder.clone();

        // Round 1: notifications denied, code copy enabled.
        dispatch_due(&core, &delegate).await;
        assert_eq!(
            recorder.copies.lock().expect("copies").as_slice(),
            ["654321"],
            "the code must be copied even without the notification permission"
        );
        assert!(
            recorder
                .notifications
                .lock()
                .expect("notifications")
                .is_empty(),
            "a denied permission must not post a notification"
        );
        let (state, reason): (String, Option<String>) = {
            let conn = rusqlite::Connection::open(&db_path).expect("db");
            conn.query_row(
                "SELECT state, suppression_reason FROM notification_outbox WHERE message_id = ?1",
                [message_ids[0]],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("outbox row")
        };
        assert_eq!(state, "suppressed");
        assert_eq!(reason.as_deref(), Some("not_permitted"));

        // Round 2: permission granted, the parked row is released. The
        // suppressed row stays gone; the second row is delivered normally.
        {
            let conn = rusqlite::Connection::open(&db_path).expect("db");
            conn.execute(
                "UPDATE notification_outbox SET not_before = NULL WHERE message_id = ?1",
                [message_ids[1]],
            )
            .expect("release second row");
        }
        recorder.allowed.store(true, Ordering::SeqCst);
        dispatch_due(&core, &delegate).await;
        let posted = recorder.notifications.lock().expect("notifications");
        assert_eq!(posted.len(), 1, "{posted:?}");
        assert!(posted[0].title.contains("654322"), "{:?}", posted[0]);
        let delivered: i64 = {
            let conn = rusqlite::Connection::open(&db_path).expect("db");
            conn.query_row(
                "SELECT COUNT(*) FROM notification_outbox WHERE message_id = ?1 AND state = 'delivered'",
                [message_ids[1]],
                |row| row.get(0),
            )
            .expect("outbox row")
        };
        assert_eq!(delivered, 1);
    }
}
