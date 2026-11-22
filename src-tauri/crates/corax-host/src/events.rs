//! Forwards `CoreEvent`s to the UI as `UiEvent`s, coalescing `mail:updated`
//! bursts over 100 ms - a port of `src-tauri/src/events.rs` so the native UI
//! sees the same stream, in the same shape, with the same debounce.

use std::sync::Arc;

use comail_core::events::CoreEvent;
use tokio::sync::broadcast;

use crate::{HostDelegate, UiEvent};

/// Start the forwarder, supervised like the notification loop: a panic
/// restarts it (with a fresh subscription) after a growing delay and is logged
/// instead of quietly ending UI updates for the rest of the process (audit
/// N5). A cancellation means the runtime is going down and ends the loop.
pub(crate) fn spawn(
    runtime: &tokio::runtime::Handle,
    delegate: Arc<dyn HostDelegate>,
    bus: comail_core::events::EventBus,
) {
    // Subscribe before spawning, so events emitted right after startup are not
    // dropped. A restarted forwarder subscribes again (a broadcast receiver
    // cannot be cloned; `resubscribe` would skip the queued events).
    let first = bus.subscribe();
    runtime.spawn(async move {
        let mut next = Some(first);
        let mut attempt: u32 = 0;
        loop {
            let rx = next.take().unwrap_or_else(|| bus.subscribe());
            let task_delegate = delegate.clone();
            let started = std::time::Instant::now();
            let joined = tokio::spawn(async move { forward(task_delegate, rx).await }).await;
            match joined {
                Ok(()) => break,
                Err(error) if error.is_cancelled() => {
                    tracing::debug!("ui event forwarder cancelled; stopping");
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
                        "ui event forwarder stopped; restarting"
                    );
                    tokio::time::sleep(delay).await;
                }
            }
        }
    });
}

async fn forward(delegate: Arc<dyn HostDelegate>, mut rx: broadcast::Receiver<CoreEvent>) {
    let mut pending_updated: Vec<i64> = Vec::new();
    // Tracked separately from the id list: a MailUpdated with no thread ids
    // (e.g. after AI routing moves threads between tabs) still means
    // "refresh".
    let mut update_pending = false;
    loop {
        let ev = if !update_pending {
            match rx.recv().await {
                Ok(ev) => Some(ev),
                // Dropped events may have included mail updates; refresh.
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    tracing::warn!(skipped, "ui event stream lagged; refreshing the list");
                    update_pending = true;
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        } else {
            // Debounce window for mail:updated coalescing.
            match tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(ev)) => Some(ev),
                Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(broadcast::error::RecvError::Closed)) => break,
                Err(_) => None, // window elapsed
            }
        };

        match ev {
            Some(CoreEvent::MailUpdated { mut thread_ids }) => {
                pending_updated.append(&mut thread_ids);
                update_pending = true;
                continue;
            }
            Some(other) => emit(&delegate, other),
            None => {}
        }

        if update_pending {
            update_pending = false;
            pending_updated.sort_unstable();
            pending_updated.dedup();
            let thread_ids = std::mem::take(&mut pending_updated);
            delegate.on_event(UiEvent::MailUpdated { thread_ids });
        }
    }
}

fn emit(delegate: &Arc<dyn HostDelegate>, ev: CoreEvent) {
    let event = match ev {
        CoreEvent::SyncProgress(progress) => UiEvent::SyncProgress(progress),
        CoreEvent::SyncStatus(status) => UiEvent::SyncStatus(status),
        CoreEvent::MailNew {
            account_id,
            thread_ids,
        } => UiEvent::MailNew {
            account_id,
            thread_ids,
        },
        CoreEvent::MailUpdated { thread_ids } => UiEvent::MailUpdated { thread_ids },
        CoreEvent::ActionState {
            action_id,
            kind,
            state,
            error,
        } => UiEvent::ActionState {
            action_id,
            kind,
            state,
            error,
        },
        CoreEvent::ActionFailed {
            action_id,
            kind,
            thread_id,
            reason,
            error,
        } => UiEvent::ActionFailed {
            action_id,
            kind,
            thread_id,
            reason,
            error,
        },
        CoreEvent::ThreadWoke { thread_id } => UiEvent::ThreadWoke { thread_id },
        CoreEvent::NetworkState { online } => UiEvent::NetworkState { online },
        CoreEvent::AccountState {
            account_id,
            sync_state,
        } => UiEvent::AccountState {
            account_id,
            sync_state,
        },
        CoreEvent::AskCitations {
            request_id,
            citations,
        } => UiEvent::AskCitations {
            request_id,
            citations,
        },
        CoreEvent::AskDelta { request_id, delta } => UiEvent::AskDelta { request_id, delta },
        CoreEvent::AskReasoning { request_id, delta } => {
            UiEvent::AskReasoning { request_id, delta }
        }
        CoreEvent::AskReset { request_id } => UiEvent::AskReset { request_id },
        CoreEvent::AskDone { request_id } => UiEvent::AskDone { request_id },
        CoreEvent::AiDraftDelta { request_id, delta } => {
            UiEvent::AiDraftDelta { request_id, delta }
        }
        CoreEvent::AiSummaryDelta { thread_id, delta } => {
            UiEvent::AiSummaryDelta { thread_id, delta }
        }
        CoreEvent::CalendarUpdated { account_id } => UiEvent::CalendarUpdated { account_id },
        CoreEvent::CalendarEventsAdded { account_id, events } => {
            UiEvent::CalendarEventsAdded { account_id, events }
        }
        CoreEvent::EventReminder {
            event,
            occurrence_start,
        } => UiEvent::EventReminder {
            event,
            occurrence_start,
        },
        CoreEvent::CalendarConflict { event_id, summary } => {
            UiEvent::CalendarConflict { event_id, summary }
        }
        CoreEvent::McpActivity(call) => UiEvent::McpActivity(call),
    };
    delegate.on_event(event);
}

#[cfg(test)]
mod tests {
    use super::*;
    use comail_core::events::SyncProgress;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct Recorder {
        events: Mutex<Vec<String>>,
    }

    impl Recorder {
        fn lines(&self) -> Vec<String> {
            self.events.lock().expect("recorder lock").clone()
        }
    }

    impl HostDelegate for Recorder {
        fn open_url(&self, _url: String) {}
        fn open_path(&self, _path: String) {}
        fn on_event(&self, event: UiEvent) {
            let line = serde_json::to_string(&event).expect("serialize");
            self.events.lock().expect("recorder lock").push(line);
        }
    }

    fn record() -> (
        tokio::runtime::Runtime,
        Arc<Recorder>,
        comail_core::events::EventBus,
    ) {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let recorder = Arc::new(Recorder::default());
        let bus = comail_core::events::EventBus::new();
        spawn(&runtime.handle(), recorder.clone(), bus.clone());
        (runtime, recorder, bus)
    }

    #[test]
    fn mail_updates_arrive_as_one_coalesced_event() {
        let (_runtime, recorder, bus) = record();

        bus.emit(CoreEvent::MailUpdated {
            thread_ids: vec![3, 1],
        });
        bus.emit(CoreEvent::MailUpdated {
            thread_ids: vec![2, 1],
        });
        std::thread::sleep(Duration::from_millis(400));

        assert_eq!(
            recorder.lines(),
            vec![r#"{"name":"mail:updated","payload":{"threadIds":[1,2,3]}}"#.to_string()]
        );
    }

    #[test]
    fn a_failed_move_reaches_the_ui_with_its_reason() {
        let (_runtime, recorder, bus) = record();
        bus.emit(CoreEvent::ActionFailed {
            action_id: 9,
            kind: "move".into(),
            thread_id: Some(42),
            reason: "source_missing".into(),
            error: "move: the source message is not on the server".into(),
        });
        bus.emit(CoreEvent::ActionFailed {
            action_id: 10,
            kind: "trash".into(),
            thread_id: None,
            reason: "deferral_exhausted".into(),
            error: "gone".into(),
        });
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(
            recorder.lines(),
            vec![
                r#"{"name":"action:failed","payload":{"actionId":9,"kind":"move","threadId":42,"reason":"source_missing","error":"move: the source message is not on the server"}}"#.to_string(),
                r#"{"name":"action:failed","payload":{"actionId":10,"kind":"trash","threadId":null,"reason":"deferral_exhausted","error":"gone"}}"#.to_string(),
            ]
        );
    }

    #[test]
    fn other_events_pass_through_unchanged() {
        let (_runtime, recorder, bus) = record();

        bus.emit(CoreEvent::SyncProgress(SyncProgress {
            account_id: 7,
            folder: "INBOX".into(),
            phase: "headers".into(),
            done: 12,
            total: 40,
        }));
        std::thread::sleep(Duration::from_millis(300));

        let lines = recorder.lines();
        assert_eq!(lines.len(), 1, "{lines:?}");
        let value: serde_json::Value = serde_json::from_str(&lines[0]).expect("json");
        assert_eq!(value["name"], "sync:progress");
        assert_eq!(value["payload"]["accountId"], 7);
        assert_eq!(value["payload"]["phase"], "headers");
    }
}
