//! Background embedding worker.
//!
//! A single long-lived task that keeps the semantic index in sync with the
//! mailbox: it loads the configured local model, (re)builds the in-memory
//! index, and batch-embeds any messages flagged `embedding_state='pending'`.
//! Inference runs under `spawn_blocking` so it never touches the DB writer
//! thread; only the short vector write does.

use super::{
    EmbedState, Embedder, LocalCandle, model_dir, model_present, prepare_chunks, spec_or_default,
};
use crate::config::Paths;
use crate::db::{Db, repo};
use crate::embed::store::VectorIndex;
use crate::error::{CoreError, Result};
use std::sync::Arc;
use std::time::Duration;

/// Messages embedded per batch before yielding.
const BATCH: i64 = 4;
/// Cooperative yield between CPU-heavy batches while history is being built.
const WORK_YIELD: Duration = Duration::from_millis(500);
/// Poll interval when there is nothing to embed.
const IDLE: Duration = Duration::from_secs(3);
/// Backoff after a load/inference error.
const ERR_BACKOFF: Duration = Duration::from_secs(30);

/// Spawn the worker. Returns immediately; the task runs for the process life.
pub fn spawn(db: Db, state: Arc<EmbedState>, paths: Arc<Paths>) {
    tokio::spawn(async move {
        run(db, state, paths).await;
    });
}

async fn run(db: Db, state: Arc<EmbedState>, paths: Arc<Paths>) {
    loop {
        match tick(&db, &state, &paths).await {
            Ok(true) => {
                tokio::time::sleep(WORK_YIELD).await;
            }
            Ok(false) => tokio::time::sleep(IDLE).await,
            Err(e) => {
                tracing::warn!("embed worker: {e}");
                tokio::time::sleep(ERR_BACKOFF).await;
            }
        }
    }
}

/// How long a freshly enqueued action still outranks indexing.
const FOREGROUND_GRACE_MS: i64 = 120_000;

/// Whether live mail or a user action outranks **indexing**. A user action
/// counts only while it is really running: `inflight`, or enqueued moments ago
/// and never deferred. The queue retries deferred actions for up to a day
/// (`queue::record_deferral`), so counting those would keep the index stopped
/// forever once one action can never succeed — exactly what six stuck rows did
/// (M2.15a §1.4, fixed in M2.16).
fn foreground_busy(conn: &rusqlite::Connection) -> Result<bool> {
    let cutoff = crate::models::now_ms() - FOREGROUND_GRACE_MS;
    Ok(conn.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM accounts WHERE sync_state = 'syncing'
            UNION ALL
            SELECT 1 FROM pending_actions
             WHERE state = 'inflight'
                OR (
                  state = 'pending'
                  AND kind NOT LIKE 'cal!_%' ESCAPE '!'
                  AND COALESCE(json_extract(payload, '$.deferrals'), 0) = 0
                  AND created_at >= ?1
                )
            UNION ALL
            SELECT 1
              FROM messages m
              JOIN accounts a ON a.id = m.account_id
              JOIN folders f ON f.id = m.folder_id
             WHERE m.uid IS NOT NULL
               AND (a.provider = 'gmail' OR COALESCE(f.role, '') <> 'all')
               AND (
                 m.body_state = 'fetching'
                 OR (
                   m.body_state = 'none'
                   AND NOT EXISTS (
                     SELECT 1 FROM sync_failures sf
                      WHERE sf.stage = 'content' AND sf.message_id = m.id
                   )
                 )
               )
         )",
        [cutoff],
        |row| row.get::<_, i64>(0),
    )? != 0)
}

/// One cycle. Returns Ok(true) if it embedded at least one message.
async fn tick(db: &Db, state: &Arc<EmbedState>, paths: &Arc<Paths>) -> Result<bool> {
    let settings = db.read(|conn| repo::settings::get(conn)).await?;
    if settings.embedding_backend != "local" {
        // Disabled: drop any loaded model so we don't pin memory.
        if state.embedder().await.is_some() {
            *state.local.write().await = None;
            *state.active_model.write().await = String::new();
            *state.index.write().await = VectorIndex::new(0, "");
            state.clear_query_cache().await;
        }
        return Ok(false);
    }

    // Live mail, user actions, and an opened message always outrank semantic
    // **indexing**. Candle can otherwise consume several CPU cores while the
    // IMAP actor is trying to make the Inbox usable. The model itself is loaded
    // either way (M2.10, see below).
    let foreground_busy = db.read(|conn| foreground_busy(conn)).await?;
    // M2.10: das Modell **vor** der Beschäftigt-Prüfung laden. Vorher lud es
    // nur `tick`, und `tick` stieg aus, solange irgendeine Mail noch keinen
    // Inhalt hatte — in einem großen Postfach fast immer. Dann war
    // `embed.embedder()` leer, die semantische Suche lieferte nichts und
    // „Frag die KI“ brach mit „nichts gefunden“ ab. Das Laden ist einmalig und
    // liest nur (`ensure_ready` kehrt sofort zurück, wenn das Modell steht);
    // die Batch-Schleife wartet weiter.
    ensure_ready(db, state, paths, &settings.embedding_model).await?;
    if foreground_busy {
        return Ok(false);
    }

    let embedder = match state.embedder().await {
        Some(e) => e,
        None => return Ok(false),
    };
    let model_id = embedder.model_id().to_string();
    let dim = embedder.dim();

    let batch = db
        .read(|conn| repo::embeddings::pending(conn, BATCH))
        .await?;
    if batch.is_empty() {
        return Ok(false);
    }

    for mid in batch {
        let src = db
            .read(move |conn| repo::embeddings::source_text(conn, mid))
            .await?;
        let Some((subject, body)) = src else {
            // No text to embed; flip the flag so we don't rescan it.
            let m = model_id.clone();
            db.write(move |conn| repo::embeddings::store_vectors(conn, mid, &m, dim, &[]))
                .await?;
            continue;
        };

        let spec = spec_or_default(&model_id);
        let chunks = prepare_chunks(&subject, &body, spec.max_tokens);
        let vectors = if chunks.is_empty() {
            Vec::new()
        } else {
            let e = embedder.clone();
            tokio::task::spawn_blocking(move || e.embed(&chunks))
                .await
                .map_err(|e| CoreError::Other(format!("embed join: {e}")))??
        };

        let m = model_id.clone();
        let vecs = vectors.clone();
        db.write(move |conn| repo::embeddings::store_vectors(conn, mid, &m, dim, &vecs))
            .await?;

        // Reflect into the live index so new mail is searchable immediately.
        let mut idx = state.index.write().await;
        for (i, v) in vectors.iter().enumerate() {
            idx.push(mid, i as i32, v);
        }
    }
    Ok(true)
}

/// Load the model + build the index if not already scoped to `model_key`.
/// On a genuine model switch, requeue every cached message for re-embedding.
async fn ensure_ready(
    db: &Db,
    state: &Arc<EmbedState>,
    paths: &Arc<Paths>,
    model_key: &str,
) -> Result<()> {
    {
        let active = state.active_model.read().await;
        if *active == model_key && state.embedder().await.is_some() {
            return Ok(());
        }
    }

    let spec = spec_or_default(model_key);
    let models_dir = paths.models_dir();
    if !model_present(&models_dir, spec.key) {
        // Not bundled/copied yet - fetch on demand (network, first use only).
        super::ensure_model(&models_dir, spec).await?;
    }
    let dir = model_dir(&models_dir, spec.key);
    let embedder = tokio::task::spawn_blocking(move || LocalCandle::load(&dir, spec))
        .await
        .map_err(|e| CoreError::Other(format!("embed load join: {e}")))??;
    let embedder = Arc::new(embedder);

    // Rebuild the index from whatever is already stored for this model.
    let model_id = spec.key.to_string();
    let rows = {
        let m = model_id.clone();
        db.read(move |conn| repo::embeddings::load_all(conn, &m))
            .await?
    };
    let mut idx = VectorIndex::new(spec.dim, spec.key);
    for (mid, ci, v) in rows {
        idx.push(mid, ci, &v);
    }

    let prev = state.active_model.read().await.clone();
    let is_switch = !prev.is_empty() && prev != model_id;

    *state.index.write().await = idx;
    *state.local.write().await = Some(embedder);
    *state.active_model.write().await = model_id.clone();
    state.clear_query_cache().await;

    if is_switch {
        tracing::info!("embed model switched {prev} -> {model_id}; requeuing corpus");
        db.write(|conn| repo::embeddings::mark_all_pending(conn).map(|_| ()))
            .await?;
        let m = model_id.clone();
        db.write(move |conn| repo::embeddings::prune_other_models(conn, &m))
            .await?;
    }
    tracing::info!("embed ready: model={model_id}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed_action(
        conn: &rusqlite::Connection,
        kind: &str,
        state: &str,
        deferrals: i64,
        created_at: i64,
    ) {
        conn.execute(
            "INSERT INTO pending_actions (account_id, kind, payload, state, created_at)
             VALUES (1, ?1, ?2, ?3, ?4)",
            rusqlite::params![
                kind,
                format!("{{\"deferrals\":{deferrals}}}"),
                state,
                created_at
            ],
        )
        .unwrap();
    }

    fn seeded() -> rusqlite::Connection {
        let conn = crate::db::testutil::conn();
        crate::db::testutil::seed_account(&conn);
        conn
    }

    #[test]
    fn stuck_deferred_action_does_not_block_indexing() {
        let conn = seeded();
        let now = crate::models::now_ms();
        // M2.15a §1.4b: exactly this state kept the index stopped for hours.
        seed_action(&conn, "move", "pending", 22, now - 4 * 60 * 60 * 1000);
        assert!(!foreground_busy(&conn).unwrap());
    }

    #[test]
    fn a_young_deferred_action_does_not_block_indexing() {
        let conn = seeded();
        let now = crate::models::now_ms();
        seed_action(&conn, "trash", "pending", 1, now - 1_000);
        assert!(!foreground_busy(&conn).unwrap());
    }

    #[test]
    fn a_fresh_user_action_still_outranks_indexing() {
        let conn = seeded();
        let now = crate::models::now_ms();
        seed_action(&conn, "trash", "pending", 0, now - 1_000);
        assert!(foreground_busy(&conn).unwrap());
    }

    #[test]
    fn a_running_action_always_outranks_indexing() {
        let conn = seeded();
        let now = crate::models::now_ms();
        seed_action(&conn, "move", "inflight", 0, now - 4 * 60 * 60 * 1000);
        assert!(foreground_busy(&conn).unwrap());
    }

    #[test]
    fn calendar_actions_never_block_indexing() {
        let conn = seeded();
        let now = crate::models::now_ms();
        seed_action(&conn, "cal_push", "pending", 0, now - 1_000);
        assert!(!foreground_busy(&conn).unwrap());
    }
}
