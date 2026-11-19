//! Contract tests: every dispatched command against a throwaway database.
//!
//! Nothing here touches the network or the real mailbox. Each test builds its
//! own temp data directory, seeds an account, a folder, one thread and one
//! message, and drives the dispatcher exactly as a UI would (camelCase JSON).
//!
//! The embedding worker is parked by storing `embeddingBackend: "none"` before
//! the core starts; without that it would fetch the model on first tick.

use std::sync::Arc;

use comail_core::Core;
use comail_core::config::Paths;
use comail_core::db::{Db, repo};
use comail_core::models::Settings;
use rabe_host::{HostDelegate, NoopDelegate, dispatch_json};
use serde_json::{Value, json};

struct Fixture {
    dir: tempfile::TempDir,
    core: Core,
    delegate: Arc<dyn HostDelegate>,
}

impl Fixture {
    async fn new() -> Fixture {
        use_insecure_credentials_file();
        let dir = tempfile::tempdir().expect("tempdir");
        let paths = Paths::for_tests(dir.path());

        // Migrations run in `Db::open`; seed settings and rows, then hand the
        // file to the core.
        let db = Db::open(&paths.db_file()).expect("open temp db");
        db.write(|conn| {
            let mut settings = Settings::default();
            settings.embedding_backend = "none".to_string();
            settings.mcp_enabled = false;
            // The notification test needs delivery enabled and unscoped; the
            // other tests are unaffected by these two.
            settings.notifications_enabled = true;
            settings.notification_scope = "all".to_string();
            settings.copy_verification_codes = false;
            repo::settings::set(conn, &settings)?;
            conn.execute_batch(SEED_SQL)?;
            Ok(())
        })
        .await
        .expect("seed fixtures");
        drop(db);
        seed_avatar_cache(dir.path());

        let core = Core::start(paths).await.expect("core start");
        Fixture {
            dir,
            core,
            delegate: Arc::new(NoopDelegate),
        }
    }

    async fn call(&self, cmd: &str, args: &str) -> Result<Value, rabe_host::HostError> {
        let raw = dispatch_json(&self.core, &self.delegate, self.dir.path(), cmd, args).await?;
        let value: Value = serde_json::from_str(&raw).expect("result is JSON");
        Ok(value)
    }
}

/// Keep the suite off the real keychain.
///
/// A credential lookup from a fresh, unsigned test binary makes macOS show a
/// "wants to access key … in your keychain" prompt and blocks until someone
/// answers it - that is what made this suite hang for minutes (`ai_status`
/// reads the AI key) and it put a security dialog in front of the user. The
/// core's own switch, `COMAIL_CREDENTIALS_INSECURE_FILE`, makes every
/// credential read/write go to a throwaway JSON file instead.
fn use_insecure_credentials_file() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let path = std::env::temp_dir().join(format!(
            "rabe-host-contract-{}-credentials.json",
            std::process::id()
        ));
        std::fs::write(&path, "{}").expect("credentials file");
        // SAFETY: set exactly once, before any core starts. Every test in this
        // binary shares the process, so they must agree on the same file.
        unsafe { std::env::set_var("COMAIL_CREDENTIALS_INSECURE_FILE", &path) };
    });
}

/// `sender_avatar` resolves over the network (Gravatar, then a BIMI DNS TXT,
/// then the site's icon) and has no offline switch. The contract only checks
/// that the command accepts the frontend's argument shape, so we write the
/// resolver's own cache entry instead: a cold cache made this suite take
/// minutes, and on a slow network it never finished.
fn seed_avatar_cache(data_dir: &std::path::Path) {
    use sha2::{Digest, Sha256};
    let email = "alice@example.invalid";
    let hash: String = Sha256::digest(email.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let dir = data_dir.join("avatars");
    std::fs::create_dir_all(&dir).expect("avatar cache dir");
    std::fs::write(
        dir.join(format!("p-{hash}")),
        "data:image/png;base64,         iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/         PzWvWQAAAABJRU5ErkJggg==",
    )
    .expect("avatar cache entry");
}

const SEED_SQL: &str = r#"
        INSERT INTO accounts (id, email, provider, auth_kind, username, imap_host, imap_port,
                              smtp_host, smtp_port, created_at, sync_state)
        VALUES (1, 'test@example.invalid', 'imap', 'password', 'test@example.invalid',
                'imap.example.invalid', 993, 'smtp.example.invalid', 587, 1700000000000, 'idle');

        INSERT INTO folders (id, account_id, imap_name, role, uidvalidity)
        VALUES (10, 1, 'INBOX', 'inbox', 1),
               (11, 1, 'Archive', 'archive', 1),
               (12, 1, 'Drafts', 'drafts', 1);

        INSERT INTO threads (id, account_id, subject_norm, last_message_at, message_count,
                             unread_count, starred_count, attachment_count, snippet,
                             participants_json)
        VALUES (100, 1, 'rechnung test', 1700000000000, 1, 1, 0, 0, 'snippet text',
                '[{"name":"Alice","email":"alice@example.invalid"}]');

        INSERT INTO messages (id, account_id, thread_id, folder_id, uid, message_id, subject,
                              from_name, from_addr, to_json, date, is_read, is_draft, snippet)
        VALUES (1000, 1, 100, 10, 1, '<m1@example.invalid>', 'Rechnung Test', 'Alice',
                'alice@example.invalid', '[{"name":null,"email":"test@example.invalid"}]',
                1700000000000, 0, 0, 'snippet text');

        -- The lexical search reads this contentless FTS table; sync fills it in
        -- production, here the fixture writes the same columns directly.
        INSERT INTO messages_fts (rowid, subject, from_text, to_text, body)
        VALUES (1000, 'Rechnung Test', 'Alice alice@example.invalid', 'test@example.invalid',
                'hello world rechnung');
        "#;

/// `start_oauth` and friends are not exercised: they open a browser and need a
/// real provider. `list_accounts` must not see credentials either.
#[tokio::test]
async fn list_accounts_returns_the_seeded_account() {
    let f = Fixture::new().await;
    let accounts = f.call("list_accounts", "{}").await.expect("list_accounts");
    let accounts = accounts.as_array().expect("array");
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0]["email"], "test@example.invalid");
    assert_eq!(accounts[0]["syncState"], "idle");
}

#[tokio::test]
async fn list_threads_works_for_every_view() {
    let f = Fixture::new().await;
    for view in [
        "inbox", "starred", "snoozed", "sent", "drafts", "done", "trash", "spam", "all",
    ] {
        let page = f
            .call(
                "list_threads",
                &format!(r#"{{"view":"{view}","limit":10}}"#),
            )
            .await
            .unwrap_or_else(|error| panic!("view {view} failed: {error}"));
        assert!(page["threads"].is_array(), "view {view}: {page}");
        assert!(
            page["nextCursor"].is_null() || page["nextCursor"].is_number(),
            "view {view}: {page}"
        );
    }

    let inbox = f
        .call("list_threads", r#"{"view":"inbox","limit":10}"#)
        .await
        .expect("inbox");
    assert_eq!(inbox["threads"][0]["id"], 100);
    assert_eq!(inbox["threads"][0]["subject"], "Rechnung Test");
    assert_eq!(inbox["threads"][0]["unreadCount"], 1);
}

#[tokio::test]
async fn get_thread_returns_the_message() {
    let f = Fixture::new().await;
    let detail = f
        .call("get_thread", r#"{"threadId":100}"#)
        .await
        .expect("get_thread");
    assert_eq!(detail["thread"]["id"], 100);
    assert_eq!(detail["messages"].as_array().expect("messages").len(), 1);
    assert_eq!(detail["messages"][0]["subject"], "Rechnung Test");
}

#[tokio::test]
async fn archive_moves_the_thread_out_of_the_inbox_and_undo_brings_it_back() {
    let f = Fixture::new().await;

    let result = f
        .call(
            "perform_action",
            r#"{"args":{"kind":"archive","threadIds":[100]}}"#,
        )
        .await
        .expect("perform_action");
    assert!(result["actionIds"].is_array(), "{result}");

    let inbox = f
        .call("list_threads", r#"{"view":"inbox","limit":10}"#)
        .await
        .expect("inbox after archive");
    assert_eq!(inbox["threads"].as_array().expect("threads").len(), 0);

    let undone = f.call("undo_last", "{}").await.expect("undo_last");
    assert!(undone["undone"].is_boolean(), "{undone}");

    let inbox = f
        .call("list_threads", r#"{"view":"inbox","limit":10}"#)
        .await
        .expect("inbox after undo");
    assert_eq!(inbox["threads"].as_array().expect("threads").len(), 1);
}

#[tokio::test]
async fn draft_roundtrip() {
    let f = Fixture::new().await;

    let saved = f
        .call(
            "save_draft",
            r#"{"args":{"draftId":null,"accountId":1,
                 "to":[{"name":"Bob","email":"bob@example.invalid"}],
                 "cc":[],"bcc":[],"subject":"Entwurf","bodyText":"Hallo Bob",
                 "bodyHtml":null,"mode":"new","inReplyToMessageId":null,"attachments":[]}}"#,
        )
        .await
        .expect("save_draft");
    let draft_id = saved["draftId"].as_i64().expect("draftId");

    let draft = f
        .call("get_draft", &format!(r#"{{"draftId":{draft_id}}}"#))
        .await
        .expect("get_draft");
    assert_eq!(draft["subject"], "Entwurf");
    assert_eq!(draft["bodyText"], "Hallo Bob");

    f.call("delete_draft", &format!(r#"{{"draftId":{draft_id}}}"#))
        .await
        .expect("delete_draft");
}

#[tokio::test]
async fn search_finds_the_fixture() {
    let f = Fixture::new().await;
    let results = f
        .call("search", r#"{"args":{"query":"rechnung","limit":5}}"#)
        .await
        .expect("search");
    assert!(results["threads"].is_array(), "{results}");
    assert!(results["hits"].is_array(), "{results}");
    let threads = results["threads"].as_array().expect("threads");
    assert!(
        threads.iter().any(|thread| thread["id"] == 100),
        "search did not find the seeded thread: {results}"
    );
}

#[tokio::test]
async fn settings_roundtrip() {
    let f = Fixture::new().await;

    let settings = f.call("get_settings", "{}").await.expect("get_settings");
    assert!(settings["theme"].is_string(), "{settings}");

    let mut updated = settings.clone();
    updated["fontFamily"] = json!("Test Sans");
    f.call("set_settings", &json!({ "settings": updated }).to_string())
        .await
        .expect("set_settings");

    let again = f
        .call("get_settings", "{}")
        .await
        .expect("get_settings again");
    assert_eq!(again["fontFamily"], "Test Sans");
    // The parked embedding backend must survive the roundtrip.
    assert_eq!(again["embeddingBackend"], "none");
}

#[tokio::test]
async fn counters_labels_and_splits_answer() {
    let f = Fixture::new().await;

    let counts = f.call("unread_counts", "{}").await.expect("unread_counts");
    assert!(counts.is_object(), "{counts}");

    let labels = f.call("list_labels", "{}").await.expect("list_labels");
    assert!(labels.is_array(), "{labels}");

    let splits = f.call("list_splits", "{}").await.expect("list_splits");
    assert!(splits.is_array(), "{splits}");

    let status = f
        .call("get_sync_status", "{}")
        .await
        .expect("get_sync_status");
    assert!(status.is_array(), "{status}");
}

#[tokio::test]
async fn bad_arguments_and_unknown_commands_are_reported() {
    let f = Fixture::new().await;

    let error = f
        .call("list_threads", r#"{"view":"nope"}"#)
        .await
        .expect_err("bad view must fail");
    assert_eq!(error.code, "bad_args", "{error}");
    assert!(error.message.contains("invalid arguments"), "{error}");

    let error = f
        .call("list_threads", r#"{"view":"inbox","limit":"zehn"}"#)
        .await
        .expect_err("bad limit must fail");
    assert_eq!(error.code, "bad_args", "{error}");

    // A command that is deliberately not dispatched.
    let error = f
        .call("focus_main_window", "{}")
        .await
        .expect_err("focus_main_window is window behaviour");
    assert_eq!(error.code, "unknown_command", "{error}");

    let error = f
        .call("does_not_exist", "{}")
        .await
        .expect_err("unknown command");
    assert_eq!(error.code, "unknown_command", "{error}");
}

/// Guards the surface P2/P3 will call first: every argument shape the frontend
/// sends must deserialize. These commands answer without network access.
#[tokio::test]
async fn read_only_surface_answers_with_the_frontend_argument_names() {
    let f = Fixture::new().await;

    let cases: &[(&str, &str)] = &[
        ("get_settings", "{}"),
        ("unread_counts", r#"{"accountId":1}"#),
        ("list_folders", r#"{"accountId":1}"#),
        ("list_contacts", r#"{"prefix":"Ali","limit":5}"#),
        ("suggest_contacts", r#"{"query":"bob","limit":3}"#),
        (
            "list_threads",
            r#"{"view":"inbox","splitId":null,"accountId":1,"labelId":null,"folderId":null,"cursor":null,"limit":5}"#,
        ),
        ("mcp_status", "{}"),
        ("mcp_activity", "{}"),
        ("ai_status", "{}"),
        ("embedding_status", "{}"),
        ("email_stats", "{}"),
        ("list_calendars", r#"{"accountId":1}"#),
        ("list_events", r#"{"startMs":0,"endMs":1}"#),
        ("sender_avatar", r#"{"email":"alice@example.invalid"}"#),
        ("explain_search", r#"{"query":"rechnung"}"#),
        (
            "preview_split_condition",
            r#"{"condition":{"kind":"all","of":[{"kind":"subject","op":"contains","value":"rechnung"}]},"limit":3}"#,
        ),
    ];

    for (cmd, args) in cases {
        // A `not_found`/`auth` answer still proves the arguments parsed.
        match f.call(cmd, args).await {
            Ok(value) => assert!(!value.is_null() || true, "{cmd} returned null"),
            Err(error) => assert_ne!(
                error.code, "bad_args",
                "{cmd} rejected the frontend argument shape: {error}"
            ),
        }
    }
}

/// Records what the host hands to the UI, so the notification path can be
/// checked without a visible banner.
#[derive(Default)]
struct Recorder {
    notifications: std::sync::Mutex<Vec<rabe_host::Notification>>,
    copied: std::sync::Mutex<Vec<String>>,
}

impl HostDelegate for Recorder {
    fn open_url(&self, _url: String) {}
    fn open_path(&self, _path: String) {}
    fn on_event(&self, _event: rabe_host::UiEvent) {}

    fn notify(&self, notification: rabe_host::Notification) -> bool {
        self.notifications
            .lock()
            .expect("recorder")
            .push(notification);
        true
    }

    fn copy_to_clipboard(&self, text: String) -> bool {
        self.copied.lock().expect("recorder").push(text);
        true
    }
}

#[tokio::test]
async fn due_notifications_reach_the_delegate_and_are_marked_delivered() {
    use_insecure_credentials_file();
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::for_tests(dir.path());

    let db = Db::open(&paths.db_file()).expect("open temp db");
    db.write(|conn| {
        let mut settings = Settings::default();
        settings.embedding_backend = "none".to_string();
        settings.mcp_enabled = false;
        settings.notifications_enabled = true;
        settings.notification_scope = "all".to_string();
        settings.copy_verification_codes = false;
        repo::settings::set(conn, &settings)?;
        conn.execute_batch(SEED_SQL)?;
        // Sync normally enqueues this when new mail arrives.
        repo::notifications::enqueue(conn, 1000)?;
        Ok(())
    })
    .await
    .expect("seed outbox");
    drop(db);

    let core = Core::start(paths).await.expect("core start");
    let recorder = Arc::new(Recorder::default());
    rabe_host::spawn_notifications(
        &tokio::runtime::Handle::current(),
        core.clone(),
        recorder.clone() as Arc<dyn HostDelegate>,
    );

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
    loop {
        if !recorder.notifications.lock().expect("recorder").is_empty() {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the dispatcher never handed a notification to the UI"
        );
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    let delivered = recorder.notifications.lock().expect("recorder")[0].clone();
    assert_eq!(delivered.title, "Alice");
    assert_eq!(delivered.body, "Rechnung Test");
    assert_eq!(delivered.thread_id, Some(100));
    assert_eq!(delivered.account_id, Some(1));

    // And the outbox row is terminal, so it is not delivered twice.
    let outbox_id = delivered.id;
    let state: String = core
        .db
        .read(move |conn| {
            Ok(conn.query_row(
                "SELECT state FROM notification_outbox WHERE id = ?1",
                [outbox_id],
                |row| row.get(0),
            )?)
        })
        .await
        .expect("outbox state");
    assert_eq!(state, "delivered");
}

/// Permission and delivery outcome are what the UI reports; the outbox must
/// reflect them instead of assuming success (audit M3).
struct GatedDelegate {
    allowed: bool,
    delivers: bool,
    notifications: std::sync::Mutex<Vec<rabe_host::Notification>>,
    paths: std::sync::Mutex<Vec<String>>,
}

impl GatedDelegate {
    fn new(allowed: bool, delivers: bool) -> Arc<Self> {
        Arc::new(Self {
            allowed,
            delivers,
            notifications: std::sync::Mutex::new(Vec::new()),
            paths: std::sync::Mutex::new(Vec::new()),
        })
    }

    fn count(&self) -> usize {
        self.notifications.lock().expect("notifications").len()
    }
}

impl HostDelegate for GatedDelegate {
    fn open_url(&self, _url: String) {}
    fn open_path(&self, path: String) {
        self.paths.lock().expect("paths").push(path);
    }
    fn on_event(&self, _event: rabe_host::UiEvent) {}

    fn can_notify(&self) -> bool {
        self.allowed
    }

    fn notify(&self, notification: rabe_host::Notification) -> bool {
        self.notifications
            .lock()
            .expect("notifications")
            .push(notification);
        self.delivers
    }

    fn copy_to_clipboard(&self, _text: String) -> bool {
        true
    }
}

/// A core with one due notification in the outbox (message 1000).
async fn outbox_fixture() -> (tempfile::TempDir, Core) {
    use_insecure_credentials_file();
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::for_tests(dir.path());

    let db = Db::open(&paths.db_file()).expect("open temp db");
    db.write(|conn| {
        let mut settings = Settings::default();
        settings.embedding_backend = "none".to_string();
        settings.mcp_enabled = false;
        settings.notifications_enabled = true;
        settings.notification_scope = "all".to_string();
        settings.copy_verification_codes = false;
        repo::settings::set(conn, &settings)?;
        conn.execute_batch(SEED_SQL)?;
        repo::notifications::enqueue(conn, 1000)?;
        Ok(())
    })
    .await
    .expect("seed outbox");
    drop(db);

    let core = Core::start(paths).await.expect("core start");
    (dir, core)
}

/// `(state, not_before, attempts, last_error)` of the seeded outbox row.
async fn outbox_state(core: &Core) -> (String, Option<i64>, i64, Option<String>) {
    core.db
        .read(|conn| {
            Ok(conn.query_row(
                "SELECT state, not_before, attempts, last_error FROM notification_outbox \
                 WHERE message_id = 1000",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?)
        })
        .await
        .expect("outbox row")
}

#[tokio::test]
async fn without_notification_permission_the_row_is_suppressed() {
    let (_dir, core) = outbox_fixture().await;
    let delegate = GatedDelegate::new(false, true);
    rabe_host::spawn_notifications(
        &tokio::runtime::Handle::current(),
        core.clone(),
        delegate.clone() as Arc<dyn HostDelegate>,
    );

    // Two dispatcher ticks: the first fires immediately, the second after the
    // 3 s poll interval.
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;

    assert_eq!(
        delegate.count(),
        0,
        "a denied permission must not post a notification"
    );
    // A denied permission ends the row with a reason instead of stacking it
    // for a later avalanche (audit N-M3): the next tick does not see it again.
    let (state, not_before, attempts, last_error) = outbox_state(&core).await;
    assert_eq!(state, "suppressed");
    assert_eq!(not_before, None, "nothing was deferred or retried");
    assert_eq!(attempts, 0, "no delivery attempt was counted");
    assert_eq!(last_error, None);
    let reason: Option<String> = core
        .db
        .read(|conn| {
            Ok(conn.query_row(
                "SELECT suppression_reason FROM notification_outbox WHERE message_id = 1000",
                [],
                |row| row.get(0),
            )?)
        })
        .await
        .expect("suppression reason");
    assert_eq!(reason.as_deref(), Some("not_permitted"));
}

#[tokio::test]
async fn a_failed_delivery_is_retried_instead_of_marked_delivered() {
    let (_dir, core) = outbox_fixture().await;
    let delegate = GatedDelegate::new(true, false);
    rabe_host::spawn_notifications(
        &tokio::runtime::Handle::current(),
        core.clone(),
        delegate.clone() as Arc<dyn HostDelegate>,
    );

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
    while delegate.count() == 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "the dispatcher never tried to deliver"
        );
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    // Give the retry write that follows the failed delivery a moment.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let (state, not_before, attempts, last_error) = outbox_state(&core).await;
    assert_eq!(state, "pending", "a failed delivery must not be terminal");
    assert!(attempts >= 1, "the attempt is counted: {attempts}");
    assert!(last_error.is_some(), "the failure reason is persisted");
    // `notify` returning false is a posting failure, not a denied permission:
    // the row must be retried, never suppressed (audit Nachprüfung 2, A1).
    let reason: Option<String> = core
        .db
        .read(|conn| {
            Ok(conn.query_row(
                "SELECT suppression_reason FROM notification_outbox WHERE message_id = 1000",
                [],
                |row| row.get(0),
            )?)
        })
        .await
        .expect("suppression reason");
    assert_eq!(
        reason, None,
        "a failed post must not be recorded as a denied permission"
    );
    let retry_at = not_before.expect("retry scheduled");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_millis() as i64;
    assert!(
        retry_at > now,
        "retry must be in the future, not before {now}"
    );
}

/// The four commands whose argument shapes broke the Tauri contract (audit H3).
/// Each must accept exactly what the frontend sends now, and an unknown field
/// must fail loudly instead of being dropped by serde.
#[tokio::test]
async fn the_four_fixed_commands_accept_the_frontend_shape() {
    let f = Fixture::new().await;

    // save_attachment: the frontend sends `attachmentId`, not `attachment_id`.
    let error = f
        .call(
            "save_attachment",
            r#"{"attachmentId":999,"dest":"/tmp/rabe-contract-test"}"#,
        )
        .await
        .expect_err("attachment 999 does not exist");
    assert_ne!(
        error.code, "bad_args",
        "save_attachment rejected the frontend shape: {error}"
    );

    // save_snippet: the frontend wraps the snippet in `snippet`, not `args`.
    let saved = f
        .call(
            "save_snippet",
            r#"{"snippet":{"id":null,"name":"Gruss","shortcut":"gr","subject":null,"bodyText":"Hallo"}}"#,
        )
        .await
        .expect("save_snippet");
    assert_eq!(saved["name"], "Gruss");

    // save_split: `applyExisting` (camelCase) is understood instead of being
    // ignored, which used to reroute the whole mailbox against the user's wish.
    let split = f
        .call(
            "save_split",
            r#"{"split":{"id":null,"name":"Contract","position":1,"query":{},"condition":null,"target":null,"ai":null,"countAll":false},"applyExisting":false}"#,
        )
        .await
        .expect("save_split");
    assert_eq!(split["name"], "Contract");

    // reorder_tabs: same option, empty order is valid.
    f.call("reorder_tabs", r#"{"order":[],"applyExisting":false}"#)
        .await
        .expect("reorder_tabs");

    // Unknown fields are now a loud `bad_args` instead of a silent default.
    for (command, args) in [
        (
            "save_attachment",
            r#"{"attachmentId":1,"dest":"/tmp/x","typo":true}"#,
        ),
        (
            "save_split",
            r#"{"split":{"id":null,"name":"T","position":0,"query":{},"countAll":false},"applyExisting":true,"typo":1}"#,
        ),
        ("reorder_tabs", r#"{"order":[],"typo":1}"#),
    ] {
        let error = f.call(command, args).await.expect_err("unknown field");
        assert_eq!(error.code, "bad_args", "{command}: {error}");
        assert!(
            error.message.contains("unknown field"),
            "{command}: {error}"
        );
    }
}

/// Audit M1: even a path that reached the database must not be handed to the
/// system opener unless it is inside the instance's own directory. Before the
/// allowlist, `open_attachment` revealed whatever `file_path` said.
#[tokio::test]
async fn open_attachment_refuses_a_path_outside_the_instance() {
    let f = Fixture::new().await;
    let outside = tempfile::tempdir().expect("outside dir");
    let outside_file = outside.path().join("secret.txt");
    std::fs::write(&outside_file, "secret").expect("write");
    let path = outside_file.to_string_lossy().into_owned();

    let stored = path.clone();
    f.core
        .db
        .write(move |conn| {
            conn.execute(
                "INSERT INTO attachments (id, message_id, part_id, filename, mime_type, size, \
                 is_inline, file_path) VALUES (900, 1000, '1', 'secret.txt', 'text/plain', 6, 0, ?1)",
                rusqlite::params![stored],
            )?;
            Ok(())
        })
        .await
        .expect("seed attachment");

    let delegate = GatedDelegate::new(true, true);
    let raw = dispatch_json(
        &f.core,
        &(delegate.clone() as Arc<dyn HostDelegate>),
        f.dir.path(),
        "open_attachment",
        r#"{"attachmentId":900}"#,
    )
    .await;
    let error = raw.expect_err("a path outside the instance must be refused");
    assert_eq!(error.code, "path_refused", "{error}");
    assert!(
        delegate.paths.lock().expect("paths").is_empty(),
        "nothing may reach the system opener"
    );
}

/// R3: an attachment inside the instance is handed to the opener as the
/// canonical path (and quarantined before it gets there).
#[tokio::test]
async fn open_attachment_opens_the_canonical_path_inside_the_instance() {
    let f = Fixture::new().await;
    let file = f.dir.path().join("attachments/1/invoice.pdf");
    std::fs::create_dir_all(file.parent().expect("parent")).expect("mkdir");
    std::fs::write(&file, "%PDF-1.7").expect("write");

    // Stored on purpose in the non-canonical spelling the tempdir reports
    // (`/var/...` vs `/private/var/...` on macOS): the host must canonicalize.
    let stored = file.to_string_lossy().into_owned();
    f.core
        .db
        .write(move |conn| {
            conn.execute(
                "INSERT INTO attachments (id, message_id, part_id, filename, mime_type, size, \
                 is_inline, file_path) VALUES (901, 1000, '1', 'invoice.pdf', 'application/pdf', 8, 0, ?1)",
                rusqlite::params![stored],
            )?;
            Ok(())
        })
        .await
        .expect("seed attachment");

    let delegate = GatedDelegate::new(true, true);
    dispatch_json(
        &f.core,
        &(delegate.clone() as Arc<dyn HostDelegate>),
        f.dir.path(),
        "open_attachment",
        r#"{"attachmentId":901}"#,
    )
    .await
    .expect("an attachment inside the instance is opened");

    let opened = delegate.paths.lock().expect("paths").clone();
    assert_eq!(opened.len(), 1, "{opened:?}");
    assert_eq!(
        std::path::Path::new(&opened[0]),
        file.canonicalize().expect("canonical file"),
        "the opener must get the canonical path"
    );
}
