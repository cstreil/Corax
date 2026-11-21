//! M4: der Name des lokalen MCP-Servers kommt aus `Paths` — Standard bleibt
//! `comail` (Tauri-App, Upstream), die native Instanz setzt `corax`.
//!
//! Eine Testdatei mit einem Test: sie setzt eine prozessweite Umgebungsvariable.

use comail_core::Core;
use comail_core::config::Paths;
use serde_json::{Value, json};

async fn rpc(client: &reqwest::Client, url: &str, token: &str, body: Value) -> (u16, Value) {
    let response = client
        .post(url)
        .bearer_auth(token)
        .header("content-type", "application/json")
        .body(body.to_string())
        .send()
        .await
        .expect("request");
    let status = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    (status, serde_json::from_str(&text).unwrap_or(Value::Null))
}

#[tokio::test]
async fn the_handshake_reports_the_configured_name() {
    let tmp = tempfile::tempdir().unwrap();
    let data_dir = tmp.path().join("data");
    std::fs::create_dir_all(&data_dir).unwrap();
    // Keep the token out of the developer's real keyring.
    // SAFETY: own test binary (one test), before any other thread reads it.
    unsafe {
        std::env::set_var(
            "COMAIL_CREDENTIALS_INSECURE_FILE",
            tmp.path().join("creds.json"),
        );
    }

    let core = Core::start(Paths::for_tests(&data_dir).with_mcp_name("corax-sandbox"))
        .await
        .unwrap();
    assert_eq!(core.mcp_name(), "corax-sandbox");
    assert_eq!(core.mcp_status().await.unwrap().name, "corax-sandbox");

    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let mut settings = core.get_settings().await.unwrap();
    settings.mcp_enabled = true;
    settings.mcp_port = port;
    core.set_settings(settings).await.unwrap();

    let status = core.mcp_status().await.unwrap();
    assert!(status.running, "server not running: {:?}", status.error);
    let token = core.mcp_token().await.unwrap();
    let http = reqwest::Client::new();
    let (code, v) = rpc(
        &http,
        &status.url,
        &token,
        json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": { "name": "m4-test", "version": "1" }
            }
        }),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(v["result"]["serverInfo"]["name"], "corax-sandbox");
    assert_eq!(v["result"]["serverInfo"]["title"], "corax-sandbox");

    // Der Standard für die Tauri-App bleibt unverändert.
    assert_eq!(comail_core::mcp::DEFAULT_MCP_NAME, "comail");
}
