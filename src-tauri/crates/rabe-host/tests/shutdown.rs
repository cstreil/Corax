//! Audit M4: a host must never be dropped - and its tokio runtime tears down
//! inside an async context - on a runtime worker thread.
//!
//! The FFI used to clone `Arc<Host>` into the task that ran `invoke`, so the
//! last reference could fall on a worker and tokio panics with "Cannot drop a
//! runtime in a context where blocking is not allowed". Now commands hold a
//! [`rabe_host::Dispatcher`] (no runtime), and dropping a `Host` inside a
//! runtime moves the teardown to a plain thread.
//!
//! One test on purpose: the host reads process-wide environment variables.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use comail_core::config::Paths;
use comail_core::db::{Db, repo};
use comail_core::models::Settings;
use rabe_host::{Host, HostConfig, NoopDelegate};

/// Collects panics from any thread; a panic in a spawned task is caught by the
/// runtime and would otherwise be invisible to the test.
fn record_panics() -> Arc<std::sync::Mutex<Vec<String>>> {
    let panics = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorder = panics.clone();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        recorder.lock().expect("panic list").push(info.to_string());
        previous(info);
    }));
    panics
}

fn prepare() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let credentials = std::env::temp_dir().join(format!(
        "rabe-host-shutdown-{}-credentials.json",
        std::process::id()
    ));
    std::fs::write(&credentials, "{}").expect("credentials file");
    // A stale `COMAIL_DATA_DIR` and a release keyring service from a profiling
    // shell must not change anything: the host overwrites both from the
    // identifier (audit R2). `RabeHost` starts on its own temporary directory.
    let foreign =
        std::env::temp_dir().join(format!("rabe-host-shutdown-{}-foreign", std::process::id()));
    // SAFETY: single test in this binary, before the host starts.
    unsafe {
        std::env::set_var("COMAIL_DATA_DIR", &foreign);
        std::env::set_var("COMAIL_KEYRING_SERVICE", "comail");
        std::env::set_var("COMAIL_CREDENTIALS_INSECURE_FILE", &credentials);
    }
    assert!(
        !foreign.exists(),
        "the foreign directory must stay untouched"
    );

    // Park the embedding worker before the core starts (same trick as the
    // contract fixture): migrations create the settings row.
    let paths = Paths::for_tests(dir.path());
    let db = Db::open(&paths.db_file()).expect("db");
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("setup runtime")
        .block_on(async {
            db.write(|conn| {
                let mut settings = Settings::default();
                settings.embedding_backend = "none".to_string();
                settings.mcp_enabled = false;
                settings.notifications_enabled = false;
                repo::settings::set(conn, &settings)?;
                Ok(())
            })
            .await
            .expect("settings");
        });
    dir
}

#[test]
fn a_host_can_be_dropped_from_a_runtime_worker_and_releases_its_lock() {
    let dir = prepare();
    let panics = record_panics();

    // Phase 1: the last reference falls on a worker of the host's own runtime.
    let host =
        Host::start(HostConfig::for_tests(&dir), Arc::new(NoopDelegate)).expect("host start");
    // The host overwrites the inherited environment with its derived values.
    assert_eq!(
        std::env::var("COMAIL_DATA_DIR").expect("data dir"),
        host.data_dir().to_string_lossy()
    );
    assert_eq!(
        std::env::var("COMAIL_KEYRING_SERVICE").expect("keyring"),
        host.keyring_service()
    );
    assert_eq!(host.keyring_service(), "de.streil.rabe.native.test");
    let runtime = host.runtime().handle().clone();
    let dropped = Arc::new(AtomicBool::new(false));
    let flag = dropped.clone();
    runtime.spawn(async move {
        flag.store(true, Ordering::SeqCst);
        // Before the fix this ran `Host::drop` -> `Runtime::drop` inside an
        // async context and panicked.
        drop(host);
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    while !dropped.load(Ordering::SeqCst) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(dropped.load(Ordering::SeqCst), "the drop task never ran");
    std::thread::sleep(Duration::from_millis(300));

    // Phase 2: the instance lock is free again, and a command running while the
    // host is dropped does not keep it alive.
    let host =
        Host::start(HostConfig::for_tests(&dir), Arc::new(NoopDelegate)).expect("second start");
    host.runtime()
        .block_on(host.wait_ready())
        .expect("core start");
    let dispatcher = host.dispatcher();
    let probe = dispatcher.clone();
    let runtime = host.runtime().handle().clone();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_task = stop.clone();
    runtime.spawn(async move {
        // Keeps one dispatch in flight most of the time, like `invoke` does.
        while !stop_task.load(Ordering::SeqCst) {
            let _ = dispatcher.dispatch("get_settings", "{}").await;
        }
    });
    std::thread::sleep(Duration::from_millis(100));
    drop(host);

    // A dispatcher kept by the UI refuses instead of reaching a dead core.
    let after = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("probe runtime")
        .block_on(async { probe.dispatch("get_settings", "{}").await })
        .expect_err("the host is shutting down");
    assert_eq!(after.code, "host_stopped", "{after}");
    stop.store(true, Ordering::SeqCst);

    // Nothing is locked any more: a third host can take the directory.
    let third =
        Host::start(HostConfig::for_tests(&dir), Arc::new(NoopDelegate)).expect("lock released");
    third.shutdown();

    let messages = panics.lock().expect("panic list").clone();
    let _ = std::panic::take_hook(); // restores the default hook
    assert!(
        messages.is_empty(),
        "panics while dropping a host: {messages:?}"
    );

    // The data directory stayed put and still holds the instance lock file.
    assert!(Path::new(&dir.path().join("instance.lock")).exists());
}
