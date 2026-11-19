//! JSON dispatcher: the machine-readable twin of `src-tauri/src/commands.rs`.
//!
//! Every command registered in `src-tauri/src/lib.rs::generate_handler!` is
//! here, with the same name, the same camelCase argument names and the same
//! result JSON. Three frontend commands are deliberately absent (see
//! [`EXCEPTIONS`]). Tauri-bound bodies are mapped onto the host delegate
//! (`open_url`, `open_path`); everything else is a straight port.
//!
//! The argument types come from `comail_core::models` wherever the core already
//! defines them; the five that only ever lived in the Tauri crate are mirrored
//! here, field for field.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use comail_core::Core;
use comail_core::db::repo::search::SearchResults;
use comail_core::models::*;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::{HostDelegate, HostError};

/// Every command this dispatcher implements - `generate_handler!` minus
/// [`EXCEPTIONS`].
pub const COMMANDS: &[&str] = &[
    // accounts
    "list_accounts",
    "add_account_password",
    "test_connection",
    "set_account_display_name",
    "remove_account",
    "start_oauth",
    "reauth_account",
    "cancel_oauth",
    // reading
    "list_threads",
    "get_thread",
    "get_body",
    "thread_unsubscribe_message",
    "unsubscribe_message",
    "get_attachment",
    "open_attachment",
    "save_attachment",
    "open_logs_dir",
    "preview_attachment",
    "list_folders",
    // actions / compose
    "perform_action",
    "undo_last",
    "cancel_send",
    "send_now",
    "save_draft",
    "get_draft",
    "delete_draft",
    "queue_send",
    // contacts
    "list_contacts",
    "suggest_contacts",
    // search
    "search",
    "warm_search_embedding",
    "explain_search",
    "record_search_open",
    "clear_search_history",
    // snippets
    "list_snippets",
    "save_snippet",
    "delete_snippet",
    "use_snippet",
    // splits / routing
    "list_splits",
    "save_split",
    "delete_split",
    "preview_rule_change",
    "find_matching_split",
    "explain_route",
    "preview_split_condition",
    "reorder_tabs",
    // labels
    "list_labels",
    "save_label",
    "delete_label",
    "restore_auto_labels",
    // sync / counts
    "sync_now",
    "get_sync_status",
    "unread_counts",
    "relabel_auto",
    "reroute_all",
    // settings / avatars
    "get_settings",
    "sender_avatar",
    "set_settings",
    // MCP
    "mcp_status",
    "mcp_get_token",
    "mcp_regenerate_token",
    "mcp_activity",
    "mcp_list_clients",
    "mcp_client_snippet",
    "mcp_install_client",
    // calendar
    "list_events",
    "events_for_message",
    "create_event",
    "rsvp_event",
    "update_event",
    "delete_event",
    "connect_calendar",
    "create_teams_meeting",
    "disconnect_calendar",
    "list_calendars",
    "set_calendar_enabled",
    "set_calendar_color",
    "set_default_calendar",
    "calendar_sync_now",
    // AI
    "ai_status",
    "latest_verification_code",
    "ai_list_models",
    "ai_usage_stats",
    "email_stats",
    "ai_plan_automation",
    "set_ai_key",
    "set_decision_key",
    "test_decision_provider",
    "create_category",
    "ai_command",
    "ai_search_filter",
    "ai_summarize",
    "ai_quick_replies",
    "ai_draft",
    "ai_draft_actions",
    "ai_proofread",
    "ai_signature",
    "ai_learn_voice",
    "ai_ask",
    // embeddings / system
    "embedding_status",
    "system_colors",
    "semantic_reindex",
];

/// Commands from `generate_handler!` that are intentionally not dispatched.
/// They are window behaviour, not core work: `focus_main_window` and
/// `cinema_close` act on Tauri windows, `ui_ready` is [`crate::Host::notify_ui_ready`].
pub const EXCEPTIONS: &[&str] = &["focus_main_window", "cinema_close", "ui_ready"];

pub(crate) async fn run(
    core: &Core,
    delegate: &Arc<dyn HostDelegate>,
    data_dir: &Path,
    cmd: &str,
    args_json: &str,
) -> Result<String, HostError> {
    let args = if args_json.trim().is_empty() {
        "{}"
    } else {
        args_json
    };

    match cmd {
        // ---------- accounts ----------
        "list_accounts" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.list_accounts().await.map_err(core_error)?)
        }
        "add_account_password" => {
            let a: WithArgs<AddPasswordAccountArgs> = parse(args)?;
            to_json(
                &core
                    .add_account_password(a.args)
                    .await
                    .map_err(core_error)?,
            )
        }
        "test_connection" => {
            let a: WithArgs<AddPasswordAccountArgs> = parse(args)?;
            to_json(&core.test_connection(&a.args).await)
        }
        "set_account_display_name" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                account_id: i64,
                name: String,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .set_account_display_name(a.account_id, &a.name)
                    .await
                    .map_err(core_error)?,
            )
        }
        "remove_account" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                account_id: i64,
            }
            let a: A = parse(args)?;
            core.remove_account(a.account_id)
                .await
                .map_err(core_error)?;
            null()
        }
        "start_oauth" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                provider: Provider,
            }
            let a: A = parse(args)?;
            let opener = UrlOpener::new(delegate);
            let account = core
                .start_oauth(a.provider, opener.open_fn())
                .await
                .map_err(core_error)?;
            opener.finish()?;
            to_json(&account)
        }
        "reauth_account" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                account_id: i64,
            }
            let a: A = parse(args)?;
            let opener = UrlOpener::new(delegate);
            let account = core
                .reauth_account(a.account_id, opener.open_fn())
                .await
                .map_err(core_error)?;
            opener.finish()?;
            to_json(&account)
        }
        "cancel_oauth" => {
            let _: NoArgs = parse(args)?;
            core.cancel_oauth();
            null()
        }

        // ---------- reading ----------
        "list_threads" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                view: View,
                #[serde(default)]
                split_id: Option<i64>,
                #[serde(default)]
                account_id: Option<i64>,
                #[serde(default)]
                label_id: Option<i64>,
                #[serde(default)]
                folder_id: Option<i64>,
                #[serde(default)]
                cursor: Option<i64>,
                #[serde(default)]
                limit: Option<i64>,
            }
            let a: A = parse(args)?;
            let page = core
                .list_threads(
                    a.view,
                    a.split_id,
                    a.account_id,
                    a.label_id,
                    a.folder_id,
                    a.cursor,
                    a.limit.unwrap_or(50),
                )
                .await
                .map_err(core_error)?;
            to_json(&page)
        }
        "get_thread" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(&core.get_thread(a.thread_id).await.map_err(core_error)?)
        }
        "get_body" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                message_id: i64,
            }
            let a: A = parse(args)?;
            to_json(&core.get_body(a.message_id).await.map_err(core_error)?)
        }
        "thread_unsubscribe_message" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .thread_unsubscribe_message(a.thread_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "unsubscribe_message" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                message_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .unsubscribe_message(a.message_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "get_attachment" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                attachment_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .get_attachment(a.attachment_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "open_attachment" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                attachment_id: i64,
            }
            let a: A = parse(args)?;
            let path = core
                .get_attachment(a.attachment_id)
                .await
                .map_err(core_error)?;
            // Quarantined and resolved before the system opener sees it: an
            // attachment is untrusted content, and the opener must get the
            // canonical path that was checked, not the database string
            // (audit N-M1).
            open_attachment_path(delegate, data_dir, &path)?;
            null()
        }
        "save_attachment" => {
            // Tauri takes `attachment_id`; the frontend sends `attachmentId`.
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                attachment_id: i64,
                dest: String,
            }
            let a: A = parse(args)?;
            core.save_attachment(a.attachment_id, a.dest)
                .await
                .map_err(core_error)?;
            null()
        }
        "open_logs_dir" => {
            let _: NoArgs = parse(args)?;
            let dir = comail_core::config::Paths::default_dirs()
                .data_dir
                .join("logs");
            std::fs::create_dir_all(&dir).map_err(|error| {
                HostError::new("io", format!("cannot create logs dir: {error}"))
            })?;
            open_local_path(delegate, data_dir, &dir.to_string_lossy())?;
            null()
        }
        "preview_attachment" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                attachment_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .preview_attachment(a.attachment_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "list_folders" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(&core.list_folders(a.account_id).await.map_err(core_error)?)
        }

        // ---------- actions / compose ----------
        "perform_action" => {
            let a: WithArgs<PerformActionArgs> = parse(args)?;
            to_json(&core.perform_action(a.args).await.map_err(core_error)?)
        }
        "undo_last" => {
            let _: NoArgs = parse(args)?;
            let undone = core.undo_last().await.map_err(core_error)?;
            to_json(&json!({ "undone": undone }))
        }
        "cancel_send" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                action_id: i64,
            }
            let a: A = parse(args)?;
            let cancelled = core.cancel_send(a.action_id).await.map_err(core_error)?;
            to_json(&json!({ "cancelled": cancelled }))
        }
        "send_now" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                action_id: i64,
            }
            let a: A = parse(args)?;
            let sent = core.send_now(a.action_id).await.map_err(core_error)?;
            to_json(&json!({ "sent": sent }))
        }
        "save_draft" => {
            let a: WithArgs<SaveDraftArgs> = parse(args)?;
            let draft_id = core.save_draft(a.args).await.map_err(core_error)?;
            to_json(&json!({ "draftId": draft_id }))
        }
        "get_draft" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                draft_id: i64,
            }
            let a: A = parse(args)?;
            to_json(&core.get_draft(a.draft_id).await.map_err(core_error)?)
        }
        "delete_draft" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                draft_id: i64,
            }
            let a: A = parse(args)?;
            core.delete_draft(a.draft_id).await.map_err(core_error)?;
            null()
        }
        "queue_send" => {
            let a: WithArgs<QueueSendArgs> = parse(args)?;
            to_json(&core.queue_send(a.args).await.map_err(core_error)?)
        }

        // ---------- contacts ----------
        "list_contacts" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                prefix: String,
                #[serde(default)]
                account_id: Option<i64>,
                #[serde(default)]
                limit: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .list_contacts(a.prefix, a.account_id, a.limit.unwrap_or(8))
                    .await
                    .map_err(core_error)?,
            )
        }
        "suggest_contacts" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                query: String,
                #[serde(default)]
                limit: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .suggest_contacts(a.query, a.limit.unwrap_or(4))
                    .await
                    .map_err(core_error)?,
            )
        }

        // ---------- search ----------
        "search" => {
            let a: WithArgs<SearchArgs> = parse(args)?;
            let results: SearchResults = core
                .search(a.args.query, a.args.account_id, a.args.limit.unwrap_or(50))
                .await
                .map_err(core_error)?;
            to_json(&results)
        }
        "warm_search_embedding" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                query: String,
            }
            let a: A = parse(args)?;
            core.warm_query_embedding(a.query).await;
            null()
        }
        "explain_search" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                query: String,
            }
            let a: A = parse(args)?;
            to_json(&core.explain_search(a.query).await.map_err(core_error)?)
        }
        "record_search_open" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                query: String,
                thread_id: i64,
            }
            let a: A = parse(args)?;
            core.record_search_open(a.query, a.thread_id)
                .await
                .map_err(core_error)?;
            null()
        }
        "clear_search_history" => {
            let _: NoArgs = parse(args)?;
            core.clear_search_history().await.map_err(core_error)?;
            null()
        }

        // ---------- snippets ----------
        "list_snippets" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.list_snippets().await.map_err(core_error)?)
        }
        "save_snippet" => {
            // Tauri's parameter is `snippet: SnippetInput`; the frontend sends
            // `{"snippet": {...}}`, not `{"args": {...}}`.
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                snippet: SnippetInput,
            }
            let a: A = parse(args)?;
            let s = a.snippet;
            to_json(
                &core
                    .save_snippet(s.id, s.name, s.shortcut, s.subject, s.body_text)
                    .await
                    .map_err(core_error)?,
            )
        }
        "delete_snippet" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                snippet_id: i64,
            }
            let a: A = parse(args)?;
            core.delete_snippet(a.snippet_id)
                .await
                .map_err(core_error)?;
            null()
        }
        "use_snippet" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                snippet_id: i64,
            }
            let a: A = parse(args)?;
            core.use_snippet(a.snippet_id).await.map_err(core_error)?;
            null()
        }

        // ---------- splits / routing ----------
        "list_splits" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.list_splits().await.map_err(core_error)?)
        }
        "save_split" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                split: SplitInput,
                #[serde(default)]
                apply_existing: Option<bool>,
            }
            let a: A = parse(args)?;
            let s = a.split;
            to_json(
                &core
                    .save_split(
                        s.id,
                        s.name,
                        s.position,
                        s.query,
                        s.condition,
                        s.target,
                        s.ai,
                        s.count_all,
                        a.apply_existing.unwrap_or(true),
                    )
                    .await
                    .map_err(core_error)?,
            )
        }
        "delete_split" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                split_id: i64,
                #[serde(default)]
                apply_existing: Option<bool>,
            }
            let a: A = parse(args)?;
            core.delete_split(a.split_id, a.apply_existing.unwrap_or(true))
                .await
                .map_err(core_error)?;
            null()
        }
        "preview_rule_change" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                change: comail_core::route::reroute::RuleChange,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .preview_rule_change(a.change)
                    .await
                    .map_err(core_error)?,
            )
        }
        "find_matching_split" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .find_matching_split(a.thread_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "explain_route" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(&core.explain_route(a.thread_id).await.map_err(core_error)?)
        }
        "preview_split_condition" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                condition: RuleCondition,
                #[serde(default)]
                limit: Option<usize>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .preview_split_condition(a.condition, a.limit.unwrap_or(5))
                    .await
                    .map_err(core_error)?,
            )
        }
        "reorder_tabs" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                order: Vec<TabRef>,
                #[serde(default)]
                apply_existing: Option<bool>,
            }
            let a: A = parse(args)?;
            let order = a.order.into_iter().map(|t| (t.kind, t.id)).collect();
            core.reorder_tabs(order, a.apply_existing.unwrap_or(true))
                .await
                .map_err(core_error)?;
            null()
        }

        // ---------- labels ----------
        "list_labels" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.list_labels().await.map_err(core_error)?)
        }
        "save_label" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                label: LabelInput,
            }
            let a: A = parse(args)?;
            let l = a.label;
            to_json(
                &core
                    .save_label(l.id, l.name, l.color, l.position)
                    .await
                    .map_err(core_error)?,
            )
        }
        "delete_label" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                label_id: i64,
            }
            let a: A = parse(args)?;
            core.delete_label(a.label_id).await.map_err(core_error)?;
            null()
        }
        "restore_auto_labels" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.restore_auto_labels().await.map_err(core_error)?)
        }

        // ---------- sync / counts ----------
        "sync_now" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            core.sync_now(a.account_id).await.map_err(core_error)?;
            null()
        }
        "get_sync_status" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.get_sync_status().await.map_err(core_error)?)
        }
        "unread_counts" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(&core.unread_counts(a.account_id).await.map_err(core_error)?)
        }
        "relabel_auto" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.relabel_auto().await.map_err(core_error)?)
        }
        "reroute_all" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.reroute_all().await.map_err(core_error)?)
        }

        // ---------- settings / avatars ----------
        "get_settings" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.get_settings().await.map_err(core_error)?)
        }
        "sender_avatar" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                email: String,
            }
            let a: A = parse(args)?;
            to_json(&core.sender_avatar(&a.email).await)
        }
        "set_settings" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                settings: Settings,
            }
            let a: A = parse(args)?;
            core.set_settings(a.settings).await.map_err(core_error)?;
            null()
        }

        // ---------- MCP ----------
        "mcp_status" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.mcp_status().await.map_err(core_error)?)
        }
        "mcp_get_token" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.mcp_token().await.map_err(core_error)?)
        }
        "mcp_regenerate_token" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.mcp_regenerate_token().await.map_err(core_error)?)
        }
        "mcp_activity" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.mcp_activity())
        }
        "mcp_list_clients" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.mcp_list_clients().await.map_err(core_error)?)
        }
        "mcp_client_snippet" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                id: String,
            }
            let a: A = parse(args)?;
            to_json(&core.mcp_client_snippet(a.id).await.map_err(core_error)?)
        }
        "mcp_install_client" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                id: String,
            }
            let a: A = parse(args)?;
            let result = core.mcp_install_client(a.id).await.map_err(core_error)?;
            if let Some(url) = &result.open_url {
                open_external(delegate, url)?;
            }
            to_json(&result)
        }

        // ---------- calendar ----------
        "list_events" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                start_ms: i64,
                end_ms: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .list_events(a.start_ms, a.end_ms)
                    .await
                    .map_err(core_error)?,
            )
        }
        "events_for_message" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                message_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .events_for_message(a.message_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "create_event" => {
            let a: WithArgs<CreateEventArgs> = parse(args)?;
            to_json(&core.create_event(a.args).await.map_err(core_error)?)
        }
        "rsvp_event" => {
            let a: WithArgs<RsvpEventArgs> = parse(args)?;
            to_json(&core.rsvp_event(a.args).await.map_err(core_error)?)
        }
        "update_event" => {
            let a: WithArgs<UpdateEventArgs> = parse(args)?;
            to_json(&core.update_event(a.args).await.map_err(core_error)?)
        }
        "delete_event" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                event_id: i64,
                #[serde(default)]
                notify: Option<bool>,
            }
            let a: A = parse(args)?;
            core.delete_event(a.event_id, a.notify.unwrap_or(true))
                .await
                .map_err(core_error)?;
            null()
        }
        "connect_calendar" => {
            let a: WithArgs<ConnectCalendarArgs> = parse(args)?;
            let args = a.args;
            let opener = UrlOpener::new(delegate);
            let calendars = if args.kind == "google" {
                let account_id = args.account_id;
                core.connect_google_calendar(account_id, opener.open_fn())
                    .await
                    .map_err(core_error)?
            } else if args.kind == "microsoft" {
                let account_id = args.account_id;
                core.connect_microsoft_calendar(account_id, opener.open_fn())
                    .await
                    .map_err(core_error)?
            } else {
                core.connect_calendar(args).await.map_err(core_error)?
            };
            opener.finish()?;
            to_json(&calendars)
        }
        "create_teams_meeting" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                account_id: i64,
                subject: String,
                start_ms: i64,
                end_ms: i64,
            }
            let a: A = parse(args)?;
            let opener = UrlOpener::new(delegate);
            let meeting = core
                .create_teams_meeting(
                    a.account_id,
                    &a.subject,
                    a.start_ms,
                    a.end_ms,
                    opener.open_fn(),
                )
                .await
                .map_err(core_error)?;
            opener.finish()?;
            to_json(&json!({ "joinUrl": meeting.join_url }))
        }
        "disconnect_calendar" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                account_id: i64,
            }
            let a: A = parse(args)?;
            core.disconnect_calendar(a.account_id)
                .await
                .map_err(core_error)?;
            null()
        }
        "list_calendars" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .list_calendars(a.account_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "set_calendar_enabled" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                calendar_id: i64,
                enabled: bool,
            }
            let a: A = parse(args)?;
            core.set_calendar_enabled(a.calendar_id, a.enabled)
                .await
                .map_err(core_error)?;
            null()
        }
        "set_calendar_color" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                calendar_id: i64,
                #[serde(default)]
                color: Option<String>,
            }
            let a: A = parse(args)?;
            core.set_calendar_color(a.calendar_id, a.color)
                .await
                .map_err(core_error)?;
            null()
        }
        "set_default_calendar" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                calendar_id: i64,
            }
            let a: A = parse(args)?;
            core.set_default_calendar(a.calendar_id)
                .await
                .map_err(core_error)?;
            null()
        }
        "calendar_sync_now" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            core.calendar_sync_now(a.account_id).await;
            null()
        }

        // ---------- AI ----------
        "ai_status" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.ai_status().await.map_err(core_error)?)
        }
        "latest_verification_code" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                max_age_minutes: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .latest_verification_code(a.max_age_minutes.unwrap_or(30))
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_list_models" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.ai_list_models().await.map_err(core_error)?)
        }
        "ai_usage_stats" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.ai_usage_stats().await.map_err(core_error)?)
        }
        "email_stats" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.email_stats().await.map_err(core_error)?)
        }
        "ai_plan_automation" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                prompt: String,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_plan_automation(a.prompt)
                    .await
                    .map_err(core_error)?,
            )
        }
        "set_ai_key" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                api_key: String,
            }
            let a: A = parse(args)?;
            core.set_ai_key(a.api_key).await.map_err(core_error)?;
            null()
        }
        "set_decision_key" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                provider: String,
                api_key: String,
            }
            let a: A = parse(args)?;
            core.set_decision_key(a.provider, a.api_key)
                .await
                .map_err(core_error)?;
            null()
        }
        "test_decision_provider" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.test_decision_provider().await.map_err(core_error)?)
        }
        "create_category" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                name: String,
                color: String,
                description: String,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .create_category(a.name, a.color, a.description)
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_command" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                query: String,
            }
            let a: A = parse(args)?;
            to_json(&core.ai_command(a.query).await.map_err(core_error)?)
        }
        "ai_search_filter" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                request: String,
                #[serde(default)]
                history: Option<Vec<comail_core::ai::search_filter::FilterTurn>>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_search_filter(a.request, a.history.unwrap_or_default())
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_summarize" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(&core.ai_summarize(a.thread_id).await.map_err(core_error)?)
        }
        "ai_quick_replies" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                thread_id: i64,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_quick_replies(a.thread_id)
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_draft" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                thread_id: Option<i64>,
                #[serde(default)]
                reply_to_message_id: Option<i64>,
                instruction: String,
                #[serde(default)]
                current_draft: Option<String>,
                #[serde(default)]
                sender_name: Option<String>,
                #[serde(default)]
                voice: Option<bool>,
                #[serde(default)]
                has_signature: Option<bool>,
                #[serde(default)]
                request_id: Option<String>,
            }
            let a: A = parse(args)?;
            let draft = core
                .ai_draft(
                    a.thread_id,
                    a.reply_to_message_id,
                    a.instruction,
                    a.current_draft.unwrap_or_default(),
                    a.sender_name.unwrap_or_default(),
                    a.voice,
                    a.has_signature.unwrap_or(false),
                    a.request_id,
                )
                .await
                .map_err(core_error)?;
            to_json(&draft)
        }
        "ai_draft_actions" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                #[serde(default)]
                thread_id: Option<i64>,
                draft: String,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_draft_actions(a.thread_id, a.draft)
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_proofread" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                body: String,
            }
            let a: A = parse(args)?;
            to_json(&core.ai_proofread(a.body).await.map_err(core_error)?)
        }
        "ai_signature" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct A {
                name: String,
                email: String,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_signature(a.name, a.email)
                    .await
                    .map_err(core_error)?,
            )
        }
        "ai_learn_voice" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.ai_learn_voice().await.map_err(core_error)?)
        }
        "ai_ask" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct A {
                question: String,
                request_id: String,
                // The frontend sends an `accountId` (its type declares it and
                // `hooks.ts` passes it), but the Tauri command has no such
                // parameter and the core filters citations on its own. Keep it
                // accepted so `deny_unknown_fields` does not break that call;
                // it is ignored exactly like Tauri ignores it.
                #[allow(dead_code)]
                #[serde(default)]
                account_id: Option<i64>,
            }
            let a: A = parse(args)?;
            to_json(
                &core
                    .ai_ask(a.question, a.request_id)
                    .await
                    .map_err(core_error)?,
            )
        }

        // ---------- embeddings / system ----------
        "embedding_status" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.embedding_status().await.map_err(core_error)?)
        }
        "system_colors" => {
            let _: NoArgs = parse(args)?;
            to_json(&comail_core::system_theme::detect())
        }
        "semantic_reindex" => {
            let _: NoArgs = parse(args)?;
            to_json(&core.semantic_reindex().await.map_err(core_error)?)
        }

        other => Err(HostError::new(
            "unknown_command",
            format!(
                "unknown command {other}; {} commands are available",
                COMMANDS.len()
            ),
        )),
    }
}

/// Tauri's `State`-free equivalent for commands without arguments.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoArgs {}

/// Tauri delivers a single struct parameter under its name, so the frontend
/// sends `{"args": {…}}`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WithArgs<T> {
    args: T,
}

// ---------- argument types that only existed in the Tauri crate ----------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SearchArgs {
    pub query: String,
    pub account_id: Option<i64>,
    pub limit: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnippetInput {
    pub id: Option<i64>,
    pub name: String,
    pub shortcut: Option<String>,
    pub subject: Option<String>,
    pub body_text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SplitInput {
    pub id: Option<i64>,
    pub name: String,
    pub position: i64,
    #[serde(default)]
    pub query: SplitRuleQuery,
    #[serde(default)]
    pub condition: Option<RuleCondition>,
    #[serde(default)]
    pub target: Option<RouteKey>,
    #[serde(default)]
    pub ai: Option<AiCheck>,
    #[serde(default)]
    pub count_all: bool,
}

/// One reorderable tab: `kind` is `"split"` or `"label"`, `id` its row id.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabRef {
    pub kind: String,
    pub id: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LabelInput {
    pub id: Option<i64>,
    pub name: String,
    pub color: String,
    pub position: i64,
}

// ---------- external URLs and local paths ----------

/// Schemes the host hands to the system opener.
///
/// `http`, `https` and `mailto` are what links in mail, ICS invitations and
/// markdown may use; the rest are the MCP "add to client" deep links that
/// `mcp_install_client` itself produces (`comail-core/src/mcp/clients.rs`:
/// Cursor, VS Code, VS Code Insiders, LM Studio). Everything else - `file`,
/// `javascript`, `data`, `smb`, `ssh`, unknown schemes - is refused.
const ALLOWED_URL_SCHEMES: &[&str] = &[
    "http",
    "https",
    "mailto",
    "cursor",
    "vscode",
    "vscode-insiders",
    "lmstudio",
];

/// The scheme of `url`, if it looks like an absolute URL (`scheme:` prefix).
fn url_scheme(url: &str) -> Option<&str> {
    let end = url.find(':')?;
    let scheme = &url[..end];
    if scheme.is_empty()
        || !scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    Some(scheme)
}

/// Whether `url` may reach the system opener. Control characters (a `\r\n`
/// in the middle) are refused too - they are the classic way to smuggle a
/// second header or argument past a URL check.
pub(crate) fn is_allowed_url(url: &str) -> bool {
    if url.chars().any(char::is_control) {
        return false;
    }
    url_scheme(url).is_some_and(|scheme| {
        ALLOWED_URL_SCHEMES
            .iter()
            .any(|allowed| scheme.eq_ignore_ascii_case(allowed))
    })
}

/// Hand one already-validated URL to the UI.
fn open_external(delegate: &Arc<dyn HostDelegate>, url: &str) -> Result<(), HostError> {
    if !is_allowed_url(url) {
        let scheme = url_scheme(url).unwrap_or("none");
        // Never log the URL itself: OAuth and install links carry tokens.
        tracing::warn!(scheme, "refused to open url");
        return Err(HostError::new(
            "url_refused",
            format!("refusing to open a {scheme} url"),
        ));
    }
    delegate.open_url(url.to_string());
    Ok(())
}

/// Opener passed to the core's OAuth/calendar callbacks.
///
/// The core calls it synchronously from inside the command, so a refusal is
/// recorded and turned into the command's `url_refused` error afterwards
/// instead of disappearing in the callback.
#[derive(Clone)]
struct UrlOpener {
    delegate: Arc<dyn HostDelegate>,
    refused: Arc<std::sync::atomic::AtomicBool>,
}

impl UrlOpener {
    fn new(delegate: &Arc<dyn HostDelegate>) -> Self {
        Self {
            delegate: delegate.clone(),
            refused: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    /// The `Fn(String)` the core expects.
    fn open_fn(&self) -> impl Fn(String) + Send + Sync + 'static {
        let opener = self.clone();
        move |url| {
            if is_allowed_url(&url) {
                opener.delegate.open_url(url);
            } else {
                let scheme = url_scheme(&url).unwrap_or("none");
                tracing::warn!(scheme, "refused to open url");
                opener
                    .refused
                    .store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }
    }

    /// Fail the command when the core tried to open a refused URL.
    fn finish(&self) -> Result<(), HostError> {
        if self.refused.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(HostError::new(
                "url_refused",
                "the core asked to open a url with a scheme the host does not allow",
            ));
        }
        Ok(())
    }
}

/// Resolve `path` and require it to live inside the instance's own data
/// directory. Both sides are canonicalized, so `..`, symlinks and case
/// variants cannot escape; anything unresolvable is refused.
fn canonical_inside(data_dir: &Path, path: &str) -> Result<PathBuf, HostError> {
    let dir = data_dir.canonicalize().map_err(|error| {
        HostError::new(
            "path_refused",
            format!(
                "cannot resolve the instance data directory {}: {error}",
                data_dir.display()
            ),
        )
    })?;
    let target = Path::new(path).canonicalize().map_err(|error| {
        HostError::new("path_refused", format!("cannot resolve {path}: {error}"))
    })?;
    if !target.starts_with(&dir) {
        tracing::warn!(
            path,
            "refused to open a path outside the instance data directory"
        );
        return Err(HostError::new(
            "path_refused",
            format!("refusing to open {path}: outside the instance data directory"),
        ));
    }
    Ok(target)
}

/// Reveal one path, but only inside the instance's own data directory - and
/// hand the opener exactly the canonical path that was checked.
fn open_local_path(
    delegate: &Arc<dyn HostDelegate>,
    data_dir: &Path,
    path: &str,
) -> Result<PathBuf, HostError> {
    let canonical = canonical_inside(data_dir, path)?;
    delegate.open_path(canonical.to_string_lossy().into_owned());
    Ok(canonical)
}

/// Open one downloaded attachment: canonical path inside the instance, marked
/// with the quarantine attribute the core uses for every attachment file
/// (`comail_core::quarantine::mark`, the same helper `save_attachment` calls),
/// and only then handed to the system opener.
///
/// The quarantine mark is what makes the file open like a download (macOS
/// asks before running a `.command`/`.app` from Mail; Windows carries the Mark
/// of the Web). If it cannot be set, the file is not opened at all.
fn open_attachment_path(
    delegate: &Arc<dyn HostDelegate>,
    data_dir: &Path,
    path: &str,
) -> Result<PathBuf, HostError> {
    let canonical = canonical_inside(data_dir, path)?;
    comail_core::quarantine::mark(&canonical).map_err(|error| {
        HostError::new(
            "io",
            format!(
                "cannot quarantine {} before opening it: {error}",
                canonical.display()
            ),
        )
    })?;
    delegate.open_path(canonical.to_string_lossy().into_owned());
    Ok(canonical)
}

// ---------- helpers ----------

fn parse<T: DeserializeOwned>(args: &str) -> Result<T, HostError> {
    serde_json::from_str(args)
        .map_err(|error| HostError::new("bad_args", format!("invalid arguments: {error}")))
}

fn core_error(error: comail_core::error::CoreError) -> HostError {
    HostError::from_core(&error)
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<String, HostError> {
    serde_json::to_string(value)
        .map_err(|error| HostError::new("serialize", format!("cannot serialize result: {error}")))
}

/// `()` in Tauri serializes to `null`.
fn null() -> Result<String, HostError> {
    Ok("null".to_string())
}

/// Kept so the module compiles when a command returns plain `Value`.
#[allow(dead_code)]
fn value(value: Value) -> Result<String, HostError> {
    to_json(&value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Records what would have reached the system opener.
    #[derive(Default)]
    struct Recorder {
        urls: Mutex<Vec<String>>,
        paths: Mutex<Vec<String>>,
    }

    impl HostDelegate for Recorder {
        fn open_url(&self, url: String) {
            self.urls.lock().expect("urls").push(url);
        }
        fn open_path(&self, path: String) {
            self.paths.lock().expect("paths").push(path);
        }
        fn on_event(&self, _event: crate::UiEvent) {}
    }

    #[test]
    fn url_allowlist_covers_links_and_mcp_deeplinks_only() {
        for url in [
            "https://accounts.example.test/oauth?state=1",
            "http://example.test/a",
            "mailto:someone@example.test",
            "cursor://anysphere.cursor-deeplink/mcp/install?name=comail&config=e30",
            "vscode:mcp/install?%7B%7D",
            "vscode-insiders:mcp/install?%7B%7D",
            "lmstudio://add_mcp?name=comail&config=e30",
        ] {
            assert!(is_allowed_url(url), "{url} must be allowed");
        }
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "smb://server/share",
            "ssh://server",
            "chrome://settings",
            "a//relative",
            "example.test/no-scheme",
            " https://example.test",
            "java\nscript:alert(1)",
            "",
        ] {
            assert!(!is_allowed_url(url), "{url:?} must be refused");
        }
    }

    #[test]
    fn a_refused_url_never_reaches_the_delegate() {
        let recorder = Arc::new(Recorder::default());
        let delegate: Arc<dyn HostDelegate> = recorder.clone();

        let error = open_external(&delegate, "file:///etc/passwd").expect_err("refused");
        assert_eq!(error.code, "url_refused");
        assert!(recorder.urls.lock().expect("urls").is_empty());

        open_external(&delegate, "https://example.test").expect("allowed");
        assert_eq!(
            recorder.urls.lock().expect("urls").as_slice(),
            ["https://example.test"]
        );
    }

    #[test]
    fn open_path_stays_inside_the_data_directory() {
        let dir = tempfile::tempdir().expect("data dir");
        let outside = tempfile::tempdir().expect("outside dir");
        let inside_file = dir.path().join("attachments/1/invoice.pdf");
        std::fs::create_dir_all(inside_file.parent().expect("parent")).expect("mkdir");
        std::fs::write(&inside_file, "pdf").expect("write");
        let outside_file = outside.path().join("secret.txt");
        std::fs::write(&outside_file, "secret").expect("write");

        let recorder = Arc::new(Recorder::default());
        let delegate: Arc<dyn HostDelegate> = recorder.clone();

        // An attachment inside the instance directory is revealed - and the
        // opener gets the canonical path that was checked, not the input
        // spelling (audit N-M1).
        let opened =
            open_local_path(&delegate, dir.path(), &inside_file.to_string_lossy()).expect("inside");
        assert_eq!(
            recorder.paths.lock().expect("paths").as_slice(),
            [opened.to_string_lossy().to_string()],
            "the canonical path must reach the opener"
        );
        assert_eq!(
            opened,
            inside_file.canonicalize().expect("canonical inside file")
        );

        // Absolute outside, `..` escape, symlink escape, missing path.
        let escape = dir.path().join("../escape.txt");
        std::os::unix::fs::symlink(outside.path(), dir.path().join("link")).expect("symlink");
        let link_escape = dir.path().join("link/secret.txt");
        for path in [
            outside_file.to_string_lossy().into_owned(),
            "/etc/passwd".to_string(),
            escape.to_string_lossy().into_owned(),
            link_escape.to_string_lossy().into_owned(),
            dir.path()
                .join("missing/file")
                .to_string_lossy()
                .into_owned(),
        ] {
            let error =
                open_local_path(&delegate, dir.path(), &path).expect_err("path must be refused");
            assert_eq!(error.code, "path_refused", "{path}");
        }
        assert_eq!(
            recorder.paths.lock().expect("paths").len(),
            1,
            "only the attachment inside the data directory reached the delegate"
        );
    }

    #[test]
    fn opening_an_attachment_quarantines_it_and_passes_the_canonical_path() {
        let dir = tempfile::tempdir().expect("data dir");
        let file = dir.path().join("attachments/1/invoice.pdf");
        std::fs::create_dir_all(file.parent().expect("parent")).expect("mkdir");
        std::fs::write(&file, "%PDF-1.7").expect("write");

        let recorder = Arc::new(Recorder::default());
        let delegate: Arc<dyn HostDelegate> = recorder.clone();

        let opened = open_attachment_path(&delegate, dir.path(), &file.to_string_lossy())
            .expect("attachment inside the data dir");

        assert_eq!(opened, file.canonicalize().expect("canonical file"));
        assert_eq!(
            recorder.paths.lock().expect("paths").as_slice(),
            [opened.to_string_lossy().to_string()],
            "the opener must get exactly the canonical path"
        );
        #[cfg(target_os = "macos")]
        {
            // Same attribute Finder/browsers set for a download, so the OS
            // asks before running an executable attachment.
            let output = std::process::Command::new("/usr/bin/xattr")
                .arg("-p")
                .arg("com.apple.quarantine")
                .arg(&opened)
                .output()
                .expect("run xattr");
            assert!(
                output.status.success(),
                "quarantine attribute missing on {}: {}",
                opened.display(),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    #[test]
    fn a_symlinked_attachment_cannot_escape_the_instance() {
        let dir = tempfile::tempdir().expect("data dir");
        let outside = tempfile::tempdir().expect("outside dir");
        let secret = outside.path().join("secret.txt");
        std::fs::write(&secret, "secret").expect("write");
        std::os::unix::fs::symlink(outside.path(), dir.path().join("attachments-link"))
            .expect("symlink");
        let escaped = dir.path().join("attachments-link/secret.txt");

        let recorder = Arc::new(Recorder::default());
        let delegate: Arc<dyn HostDelegate> = recorder.clone();

        let error = open_attachment_path(&delegate, dir.path(), &escaped.to_string_lossy())
            .expect_err("a symlink out of the instance must be refused");
        assert_eq!(error.code, "path_refused", "{error}");
        assert!(
            recorder.paths.lock().expect("paths").is_empty(),
            "nothing may reach the system opener"
        );
    }
}
