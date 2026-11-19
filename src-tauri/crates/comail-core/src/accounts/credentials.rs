//! Secrets live in the OS keyring (Secret Service on Linux), never in SQLite.
//! Keyring entries are keyed "comail:<account_id>:<slot>".

use crate::error::{CoreError, Result};

const SERVICE: &str = "comail";

/// The one legacy rename this fork adopts: the pre-rename dev build wrote its
/// credentials under the upstream bundle identifier, the renamed dev build
/// under `de.streil.rabe.dev`. Adopting means reading the old service once and
/// copying the secret to the new one; the old entry is left in place.
///
/// This is deliberately a single explicit pair, not a list applied to every
/// non-release service: the native host runs as `de.streil.rabe.native` and the
/// sandbox as `de.streil.rabe.native.sandbox`, and neither may read (or copy)
/// the dev build's credentials. An unknown service adopts nothing at all, so it
/// can never touch a keychain entry it does not own - which is also what keeps
/// a fresh instance from triggering a keychain access prompt.
const LEGACY_DEV_SERVICE: &str = "com.deanoss.comail.dev";
/// The renamed dev service the legacy entry is adopted into.
const RENAMED_DEV_SERVICE: &str = "de.streil.rabe.dev";

/// Keyring service name. `COMAIL_KEYRING_SERVICE` overrides it so an isolated
/// dev instance never reads, overwrites or deletes the installed release's
/// credentials (same account ids would otherwise collide on the same entries).
fn service() -> String {
    std::env::var("COMAIL_KEYRING_SERVICE")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| SERVICE.to_string())
}

/// Read one secret from the pre-rename dev service and copy it under
/// `current`, so the adoption happens once.
///
/// Only `current == de.streil.rabe.dev` adopts anything: the entries live in
/// `com.deanoss.comail.dev` and are read exactly once per slot. Every other
/// service - the release `comail`, the native host's services, the sandbox,
/// a test service, the legacy service itself - gets `None` without reading any
/// other keychain entry. `fetch` returns `None` for a missing or unreadable
/// entry; `save` stores the found secret under `current`.
///
/// Chunk-split values (a Windows-only layout, see `MAX_SECRET_UTF16`) are left
/// untouched: reading one through this path would hand back a header string.
fn adopt_legacy(
    current: &str,
    user: &str,
    fetch: impl Fn(&str, &str) -> Option<String>,
    save: impl Fn(&str),
) -> Option<String> {
    if current != RENAMED_DEV_SERVICE {
        return None;
    }
    let secret = fetch(LEGACY_DEV_SERVICE, user)?;
    if secret.starts_with(CHUNK_MARKER) {
        return None;
    }
    save(&secret);
    Some(secret)
}

pub enum Slot {
    Password,
    RefreshToken,
    AccessToken,
    /// App-level AI API key (stored under account id 0).
    AiApiKey,
    /// Generic-CalDAV app password (Google CalDAV reuses the OAuth tokens).
    CaldavPassword,
    /// Bearer token for the local MCP server (stored under account id 0).
    McpToken,
    /// OpenRouter decision API key (stored under account id 0). Unset falls
    /// back to [`Slot::AiApiKey`], which is the same OpenRouter key for most setups.
    DecisionApiKey,
    /// OpenAI Decisions API key (account id 0).
    DecisionOpenAiKey,
    /// Command Code decision key (account id 0). Same key as its chat provider.
    DecisionCommandCodeKey,
    /// Key for a custom decision endpoint (account id 0).
    DecisionCustomKey,
}

impl Slot {
    fn as_str(&self) -> &'static str {
        match self {
            Slot::Password => "password",
            Slot::RefreshToken => "refresh_token",
            Slot::AccessToken => "access_token",
            Slot::AiApiKey => "ai_api_key",
            Slot::CaldavPassword => "caldav_password",
            Slot::McpToken => "mcp_token",
            Slot::DecisionApiKey => "decision_api_key",
            Slot::DecisionOpenAiKey => "decision_api_key_openai",
            Slot::DecisionCommandCodeKey => "decision_api_key_commandcode",
            Slot::DecisionCustomKey => "decision_api_key_custom",
        }
    }
}

fn entry(account_id: i64, slot: &Slot) -> Result<keyring::Entry> {
    let user = format!("{account_id}:{}", slot.as_str());
    keyring::Entry::new(&service(), &user).map_err(Into::into)
}

// Windows Credential Manager caps a credential blob at 2560 bytes
// (CRED_MAX_CREDENTIAL_BLOB_SIZE) and the native store encodes secrets as
// UTF-16, so ~1280 code units. Microsoft AAD refresh tokens routinely exceed
// that, and the store then fails with a "secure storage error" that leaves the
// account uncredentialed. Split oversized secrets across sibling entries on
// Windows; other platforms have no such limit and store secrets whole.
#[cfg(target_os = "windows")]
const MAX_SECRET_UTF16: usize = 1024;
#[cfg(not(target_os = "windows"))]
const MAX_SECRET_UTF16: usize = usize::MAX;

// A NUL-prefixed header no real token or password starts with. When present in
// the primary entry it means the value is split across `<slot>:c0..cN` entries.
const CHUNK_MARKER: &str = "\u{0}comail-chunks:";

// Chunk sanity cap; MAX_SECRET_UTF16 * this is far beyond any real secret.
const MAX_CHUNKS: usize = 256;

fn chunk_entry(account_id: i64, slot: &Slot, index: usize) -> Result<keyring::Entry> {
    let user = format!("{account_id}:{}:c{index}", slot.as_str());
    keyring::Entry::new(&service(), &user).map_err(Into::into)
}

/// Split on char boundaries so no chunk exceeds `max_units` UTF-16 code units
/// (what the Windows blob limit counts). Returns a single chunk when it fits.
fn split_utf16_chunks(secret: &str, max_units: usize) -> Vec<String> {
    let mut chunks = Vec::new();
    let mut cur = String::new();
    let mut units = 0usize;
    for ch in secret.chars() {
        let w = ch.len_utf16();
        if units.saturating_add(w) > max_units && !cur.is_empty() {
            chunks.push(std::mem::take(&mut cur));
            units = 0;
        }
        cur.push(ch);
        units += w;
    }
    chunks.push(cur);
    chunks
}

/// Delete `<slot>:c{index}` entries starting at `start`. Chunks are written
/// contiguously, so stop at the first missing (or unreadable) index.
fn delete_chunks_from(account_id: i64, slot: &Slot, start: usize) {
    for index in start..start + MAX_CHUNKS {
        match chunk_entry(account_id, slot, index) {
            Ok(e) => match e.delete_credential() {
                Ok(()) => {}
                _ => break,
            },
            Err(_) => break,
        }
    }
}

/// Fallback for machines without a Secret Service (headless boxes, tests):
/// COMAIL_CREDENTIALS_INSECURE_FILE=<path> stores secrets as plaintext JSON.
/// The OS keyring is always preferred; never set this on a desktop.
fn insecure_file() -> Option<std::path::PathBuf> {
    std::env::var("COMAIL_CREDENTIALS_INSECURE_FILE")
        .ok()
        .filter(|p| !p.is_empty())
        .map(std::path::PathBuf::from)
}

fn file_map(path: &std::path::Path) -> std::collections::HashMap<String, String> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn file_save(
    path: &std::path::Path,
    map: &std::collections::HashMap<String, String>,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_string(map)?)?;
    Ok(())
}

fn slot_key(account_id: i64, slot: &Slot) -> String {
    format!("{account_id}:{}", slot.as_str())
}

/// Keyring calls are blocking (D-Bus on Linux); call from spawn_blocking in async paths.
pub fn store(account_id: i64, slot: Slot, secret: &str) -> Result<()> {
    if let Some(path) = insecure_file() {
        let mut map = file_map(&path);
        map.insert(slot_key(account_id, &slot), secret.to_string());
        return file_save(&path, &map);
    }
    let chunks = split_utf16_chunks(secret, MAX_SECRET_UTF16);
    if chunks.len() <= 1 {
        // Fits in one entry (always the case off Windows). On Windows, clear any
        // stale chunks left by a previous oversized value, then store whole.
        #[cfg(target_os = "windows")]
        delete_chunks_from(account_id, &slot, 0);
        return entry(account_id, &slot)?
            .set_password(secret)
            .map_err(Into::into);
    }
    // Write data chunks first, header last: a partial write never reassembles.
    for (index, part) in chunks.iter().enumerate() {
        chunk_entry(account_id, &slot, index)?
            .set_password(part)
            .map_err(CoreError::from)?;
    }
    delete_chunks_from(account_id, &slot, chunks.len());
    entry(account_id, &slot)?
        .set_password(&format!("{CHUNK_MARKER}{}", chunks.len()))
        .map_err(Into::into)
}

pub fn load(account_id: i64, slot: Slot) -> Result<String> {
    if let Some(path) = insecure_file() {
        return file_map(&path)
            .remove(&slot_key(account_id, &slot))
            .ok_or_else(|| CoreError::Auth("no stored credential".into()));
    }
    let head = match entry(account_id, &slot)?.get_password() {
        Ok(s) => s,
        Err(keyring::Error::NoEntry) => {
            let current = service();
            let user = format!("{account_id}:{}", slot.as_str());
            let adopted = adopt_legacy(
                &current,
                &user,
                |service, user| keyring::Entry::new(service, user).ok()?.get_password().ok(),
                |secret| {
                    if let Ok(target) = keyring::Entry::new(&current, &user) {
                        let _ = target.set_password(secret);
                    }
                },
            );
            return adopted.ok_or_else(|| CoreError::Auth("no stored credential".into()));
        }
        Err(e) => return Err(e.into()),
    };
    let Some(count) = head.strip_prefix(CHUNK_MARKER) else {
        return Ok(head);
    };
    let count: usize = count
        .parse()
        .map_err(|_| CoreError::Other("corrupt keyring chunk header".into()))?;
    let mut out = String::new();
    for index in 0..count {
        match chunk_entry(account_id, &slot, index)?.get_password() {
            Ok(s) => out.push_str(&s),
            Err(keyring::Error::NoEntry) => {
                return Err(CoreError::Auth("no stored credential".into()));
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(out)
}

pub fn delete_all(account_id: i64) {
    if let Some(path) = insecure_file() {
        let mut map = file_map(&path);
        map.retain(|k, _| !k.starts_with(&format!("{account_id}:")));
        let _ = file_save(&path, &map);
        return;
    }
    for slot in [
        Slot::Password,
        Slot::RefreshToken,
        Slot::AccessToken,
        Slot::CaldavPassword,
    ] {
        if let Ok(e) = entry(account_id, &slot) {
            let _ = e.delete_credential();
        }
        delete_chunks_from(account_id, &slot, 0);
    }
}

/// Remove one stored secret; missing entries are fine.
pub fn delete(account_id: i64, slot: Slot) {
    if let Some(path) = insecure_file() {
        let mut map = file_map(&path);
        map.remove(&slot_key(account_id, &slot));
        let _ = file_save(&path, &map);
        return;
    }
    if let Ok(e) = entry(account_id, &slot) {
        let _ = e.delete_credential();
    }
    delete_chunks_from(account_id, &slot, 0);
}

pub async fn store_async(account_id: i64, slot: Slot, secret: String) -> Result<()> {
    tokio::task::spawn_blocking(move || store(account_id, slot, &secret))
        .await
        .map_err(|e| CoreError::Other(e.to_string()))?
}

pub async fn load_async(account_id: i64, slot: Slot) -> Result<String> {
    tokio::task::spawn_blocking(move || load(account_id, slot))
        .await
        .map_err(|e| CoreError::Other(e.to_string()))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_secret_is_one_chunk() {
        assert_eq!(split_utf16_chunks("abc", 1024), vec!["abc"]);
        assert_eq!(split_utf16_chunks("", 1024), vec![""]);
    }

    #[test]
    fn oversized_secret_splits_and_rejoins() {
        let secret: String = "a".repeat(2500);
        let chunks = split_utf16_chunks(&secret, 1024);
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|c| c.encode_utf16().count() <= 1024));
        assert_eq!(chunks.concat(), secret);
    }

    #[test]
    fn split_never_breaks_a_surrogate_pair() {
        // '😀' is two UTF-16 code units; a boundary must not land mid-char.
        let secret: String = "😀".repeat(600); // 1200 UTF-16 units
        let chunks = split_utf16_chunks(&secret, 1023); // odd cap, forces a squeeze
        assert!(chunks.iter().all(|c| c.encode_utf16().count() <= 1023));
        assert_eq!(chunks.concat(), secret);
    }

    #[test]
    fn a_renamed_service_adopts_its_legacy_credential() {
        let saved = std::cell::RefCell::new(Vec::new());
        let secret = adopt_legacy(
            "de.streil.rabe.dev",
            "1:password",
            |service, user| {
                (service == "com.deanoss.comail.dev" && user == "1:password")
                    .then(|| "app-specific-password".to_string())
            },
            |value| saved.borrow_mut().push(value.to_string()),
        );
        assert_eq!(secret.as_deref(), Some("app-specific-password"));
        assert_eq!(saved.borrow().as_slice(), ["app-specific-password"]);
    }

    #[test]
    fn the_current_service_is_never_treated_as_legacy() {
        // Otherwise a renamed app would read (and copy) its own entries forever.
        let secret = adopt_legacy(
            "com.deanoss.comail.dev",
            "1:password",
            |_, _| panic!("must not read the current service through this path"),
            |_| panic!("must not save"),
        );
        assert!(secret.is_none());
    }

    #[test]
    fn no_other_service_adopts_the_dev_credentials() {
        // The native host, its sandbox, the release app and the upstream
        // release service must not read `com.deanoss.comail.dev` at all: a
        // fresh instance that never had credentials must not inherit the dev
        // build's (and must not prompt for keychain access to them).
        for current in [
            "de.streil.rabe.native",
            "de.streil.rabe.native.sandbox",
            "de.streil.rabe.native.test",
            "comail",
            "de.streil.rabe",
            "com.deanoss.comail",
            "",
        ] {
            let secret = adopt_legacy(
                current,
                "1:password",
                |_, _| panic!("{current} must not read any legacy service"),
                |_| panic!("{current} must not save"),
            );
            assert!(secret.is_none(), "{current:?} adopted a credential");
        }
    }

    #[test]
    fn the_mapping_is_exactly_dev_to_dev() {
        // The other direction of the pair: the renamed dev service is the only
        // reader, and it reads the pre-rename dev service - nothing else.
        let reads = std::cell::RefCell::new(Vec::new());
        let secret = adopt_legacy(
            "de.streil.rabe.dev",
            "0:mcp_token",
            |service, user| {
                reads
                    .borrow_mut()
                    .push((service.to_string(), user.to_string()));
                (service == "com.deanoss.comail.dev").then(|| "dev-secret".to_string())
            },
            |_| {},
        );
        assert_eq!(secret.as_deref(), Some("dev-secret"));
        assert_eq!(
            reads.into_inner(),
            vec![(
                "com.deanoss.comail.dev".to_string(),
                "0:mcp_token".to_string()
            )]
        );
    }
}
