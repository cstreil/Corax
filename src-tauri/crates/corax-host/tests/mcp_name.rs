//! M4: die native Instanz meldet den MCP-Namen `corax` (eigener Port und Token
//! waren schon getrennt, nur der Name fehlte).
//!
//! Eine Testdatei mit einem Test: der Host liest prozessweite
//! Umgebungsvariablen, und parallel laufende Hosts würden sich die Umgebung
//! teilen.

use std::sync::Arc;

use comail_core::config::Paths;
use comail_core::db::{Db, repo};
use comail_core::models::Settings;
use corax_host::{
    Host, HostConfig, MCP_NAME, MCP_SANDBOX_NAME, NATIVE_IDENTIFIER, NoopDelegate,
    SANDBOX_IDENTIFIER, mcp_name_for,
};
use serde_json::Value;

/// Eigenes Datenverzeichnis, parkierter Embedding-Worker, keine Leitungsdaten.
fn prepare() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let credentials = std::env::temp_dir().join(format!(
        "corax-host-mcp-name-{}-credentials.json",
        std::process::id()
    ));
    std::fs::write(&credentials, "{}").expect("credentials file");
    // SAFETY: single test in this binary, before the host starts.
    unsafe {
        std::env::set_var("COMAIL_CREDENTIALS_INSECURE_FILE", &credentials);
    }

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
fn the_native_instance_reports_corax() {
    let dir = prepare();
    let host =
        Host::start(HostConfig::for_tests(&dir), Arc::new(NoopDelegate)).expect("host start");
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");

    let status: Value = runtime.block_on(async {
        host.wait_ready().await.expect("ready");
        let text = host.dispatch("mcp_status", "{}").await.expect("mcp_status");
        serde_json::from_str(&text).expect("json")
    });

    assert_eq!(status["name"], "corax");
    assert_eq!(status["name"], MCP_NAME);
    // Die Sandbox bekommt ihren eigenen Namen, damit sie den nativen Eintrag
    // nie überschreibt.
    assert_eq!(mcp_name_for(NATIVE_IDENTIFIER), MCP_NAME);
    assert_eq!(mcp_name_for(SANDBOX_IDENTIFIER), MCP_SANDBOX_NAME);

    drop(host);
    drop(dir);
}
