//! The sandbox seeder, end to end: mockup mailbox in, `list_threads` and
//! `get_thread` out - plus the path guard that keeps `--reset` inside the
//! sandbox directory (audit H1).
//!
//! One test on purpose: the seeding path reads process-wide environment
//! variables, which parallel tests in the same binary would race on.

use std::path::Path;
use std::sync::Arc;

use comail_core::Core;
use comail_core::config::Paths;
use rabe_host::{
    HostDelegate, NATIVE_IDENTIFIER, NoopDelegate, SANDBOX_IDENTIFIER, dispatch_json, seed_sandbox,
    seed_sandbox_at,
};
use serde_json::Value;

async fn call(
    core: &Core,
    delegate: &Arc<dyn HostDelegate>,
    data_dir: &Path,
    cmd: &str,
    args: &str,
) -> Result<Value, rabe_host::HostError> {
    let raw = dispatch_json(core, delegate, data_dir, cmd, args).await?;
    Ok(serde_json::from_str(&raw).expect("result is JSON"))
}

/// The seeded account has no password, but the core's credential lookup would
/// fall back to the keychain of the dev instance and prompt for access. The
/// core's file switch keeps this test offline and away from the login keychain.
fn use_insecure_credentials_file() {
    let path = std::env::temp_dir().join(format!(
        "rabe-host-sandbox-{}-credentials.json",
        std::process::id()
    ));
    std::fs::write(&path, "{}").expect("credentials file");
    // SAFETY: single test in this binary, set before the core starts.
    unsafe { std::env::set_var("COMAIL_CREDENTIALS_INSECURE_FILE", &path) };
}

#[test]
fn seeded_sandbox_serves_the_mockup_mail() {
    let base = tempfile::tempdir().expect("tempdir");
    let foreign = tempfile::tempdir().expect("foreign dir");
    let foreign_file = foreign.path().join("comail.db");
    std::fs::write(&foreign_file, "not the sandbox").expect("foreign file");

    // A stale `COMAIL_DATA_DIR` (a profiling shell, `launchctl setenv`) must
    // not move the sandbox or, worse, become the target of `--reset`.
    // SAFETY: this binary holds a single test.
    unsafe {
        std::env::set_var("COMAIL_DATA_DIR", foreign.path());
    }
    use_insecure_credentials_file();

    let sandbox_dir = base.path().join(SANDBOX_IDENTIFIER);
    let report = seed_sandbox_at(base.path(), SANDBOX_IDENTIFIER, false).expect("seed");
    assert_eq!(report.threads, 10, "one thread per mockup mail");
    assert_eq!(report.messages, 15, "15 mockup messages");
    assert_eq!(report.attachments, 7, "seven mockup attachments");
    assert_eq!(report.labels, 3, "Reise, Rechnung, Social");
    assert_eq!(report.splits, 1, "Newsletter");
    assert_eq!(report.account_id, 1);
    assert_eq!(
        Path::new(&report.data_dir),
        sandbox_dir,
        "the seed must ignore COMAIL_DATA_DIR"
    );
    assert_eq!(
        std::fs::read_to_string(&foreign_file).expect("foreign file still there"),
        "not the sandbox",
        "the directory COMAIL_DATA_DIR points at must stay untouched"
    );

    // A second seed without --reset must not merge into the first one.
    let error =
        seed_sandbox_at(base.path(), SANDBOX_IDENTIFIER, false).expect_err("already seeded");
    assert_eq!(error.code, "already_seeded");

    // Any other identifier is refused before the directory is opened.
    let error = seed_sandbox_at(base.path(), NATIVE_IDENTIFIER, true).expect_err("must refuse");
    assert_eq!(error.code, "refused");
    assert_eq!(
        std::fs::read_to_string(&foreign_file).expect("foreign file still there"),
        "not the sandbox"
    );

    // --reset rebuilds from scratch and reports what it removed.
    let report = seed_sandbox_at(base.path(), SANDBOX_IDENTIFIER, true).expect("reset + seed");
    assert!(!report.removed.is_empty(), "reset reports removed paths");
    assert_eq!(report.threads, 10);
    assert_eq!(
        std::fs::read_to_string(&foreign_file).expect("foreign file still there"),
        "not the sandbox"
    );

    // The public entry point pins the platform directory; with COMAIL_DATA_DIR
    // set it must still refuse every identifier but the sandbox, and it must
    // never follow the variable.
    let error = seed_sandbox(NATIVE_IDENTIFIER, true).expect_err("must refuse");
    assert_eq!(error.code, "refused");

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("core runtime");
    runtime.block_on(async {
        let core = Core::start(Paths::for_tests(&sandbox_dir))
            .await
            .expect("core start on the sandbox db");
        let delegate: Arc<dyn HostDelegate> = Arc::new(NoopDelegate);

        let page = call(
            &core,
            &delegate,
            &sandbox_dir,
            "list_threads",
            r#"{"view":"inbox","limit":50}"#,
        )
        .await
        .expect("list_threads");
        let threads = page["threads"].as_array().expect("threads array");
        assert_eq!(threads.len(), report.threads);
        let subjects: Vec<&str> = threads
            .iter()
            .map(|t| t["subject"].as_str().unwrap_or_default())
            .collect();
        for expected in [
            "Rebranding – Entwürfe Runde 3",
            "Ihre Reisebestätigung Hamburg Hbf → Berlin Hbf",
            "AW: Hiwatt",
            "Wochenende an der Ostsee?",
            "Create a recovery code now",
        ] {
            assert!(subjects.contains(&expected), "missing thread {expected}");
        }
        // Newest first; the four unread mockup threads keep their counter.
        assert_eq!(subjects[0], "Rebranding – Entwürfe Runde 3");
        let unread: Vec<&str> = threads
            .iter()
            .filter(|t| t["unreadCount"].as_i64().unwrap_or(0) > 0)
            .map(|t| t["subject"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(
            unread.len(),
            4,
            "mockup has four unread threads: {unread:?}"
        );
        assert_eq!(
            threads
                .iter()
                .filter(|t| t["isStarred"].as_bool().unwrap_or(false))
                .count(),
            1
        );
        assert_eq!(
            threads
                .iter()
                .filter(|t| t["hasAttachments"].as_bool().unwrap_or(false))
                .count(),
            6
        );

        // The Newsletter split carries the three `news` senders.
        let splits = call(&core, &delegate, &sandbox_dir, "list_splits", "{}")
            .await
            .expect("list_splits");
        let split_id = splits
            .as_array()
            .expect("splits array")
            .iter()
            .find(|s| s["name"].as_str() == Some("Newsletter"))
            .map(|s| s["id"].as_i64().expect("split id"))
            .expect("Newsletter split");
        let news = call(
            &core,
            &delegate,
            &sandbox_dir,
            "list_threads",
            &format!(r#"{{"view":"inbox","splitId":{split_id},"limit":50}}"#),
        )
        .await
        .expect("newsletter tab");
        assert_eq!(
            news["threads"].as_array().expect("threads").len(),
            3,
            "newsletter tab holds the three `news` threads"
        );

        // Bodies and attachments are there, so the reading pane has something
        // to show without any network.
        let thread_id = threads
            .iter()
            .find(|t| t["subject"].as_str() == Some("Rebranding – Entwürfe Runde 3"))
            .and_then(|t| t["id"].as_i64())
            .expect("jana thread id");
        let detail = call(
            &core,
            &delegate,
            &sandbox_dir,
            "get_thread",
            &format!(r#"{{"threadId":{thread_id}}}"#),
        )
        .await
        .expect("get_thread");
        let messages = detail["messages"].as_array().expect("messages");
        assert_eq!(messages.len(), 3);
        let last = messages.last().expect("last message");
        assert!(
            last["htmlBody"]
                .as_str()
                .unwrap_or_default()
                .contains("Runde 3")
        );
        assert!(
            last["textBody"]
                .as_str()
                .unwrap_or_default()
                .contains("Liebe Grüße")
        );
        assert_eq!(
            last["attachments"].as_array().expect("attachments").len(),
            2
        );
        assert_eq!(last["bodyState"].as_str(), Some("cached"));
        // The reply in the middle was written by the account owner.
        assert_eq!(messages[1]["isOutgoing"].as_bool(), Some(true));

        // A mockup `tag` arrives as a label on the thread.
        let db_thread = threads
            .iter()
            .find(|t| {
                t["subject"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("Reisebestätigung")
            })
            .expect("db thread");
        assert!(
            !db_thread["labels"].as_array().expect("labels").is_empty(),
            "tag `Reise` becomes a label"
        );
    });
}
