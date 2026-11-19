//! UniFFI facade: what the Swift app sees.
//!
//! The UI side is deliberately thin - one object with an async JSON dispatcher,
//! a delegate for callbacks, and a typed error. Everything else (commands,
//! payload shapes, notification policy, HTML wrapper) comes from `rabe-host`,
//! so Swift and QML speak the same contract as the Tauri frontend.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use rabe_host::{Host, HostConfig, HostDelegate, HostError};

uniffi::setup_scaffolding!();

/// One desktop notification to show.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RabeNotification {
    pub id: i64,
    pub title: String,
    pub body: String,
    pub thread_id: Option<i64>,
    pub account_id: Option<i64>,
}

/// Callbacks into the UI. Called from background threads; switch to the main
/// thread on the Swift side.
#[uniffi::export(with_foreign)]
pub trait RabeDelegate: Send + Sync {
    /// Open a URL in the system browser.
    fn open_url(&self, url: String);
    /// Open or reveal a path with the system handler.
    fn open_path(&self, path: String);
    /// One UI event as `{"name": ..., "payload": ...}` JSON.
    fn on_event(&self, event_json: String);
    /// Whether the user has **finally denied** notifications: `false` means
    /// "this is a decision", and the host closes due outbox rows as
    /// `suppressed`/`not_permitted` instead of delivering or stacking them.
    ///
    /// Answer `true` for every other status - not asked yet, unknown,
    /// provisional, or granted. Whether a notification actually reached the
    /// screen is reported separately by [`RabeDelegate::notify`] returning
    /// `false`, which the host retries with backoff; returning `false` here
    /// early would silently drop notifications the user never declined.
    fn notifications_allowed(&self) -> bool;
    /// Show a desktop notification. Return `false` when it did not reach the
    /// user (posting failed, authorization error at post time); the host
    /// retries with backoff, starting at 5 s and capped at 5 min, and does not
    /// suppress the row.
    fn notify(&self, notification: RabeNotification) -> bool;
    /// Put text on the clipboard. Return `false` if it did not get there.
    fn copy_to_clipboard(&self, text: String) -> bool;
}

/// Failure crossing the FFI boundary, shaped like `CoreError::to_ipc_json`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RabeError {
    #[error("{}: {}", code, message)]
    Core { code: String, message: String },
}

impl From<HostError> for RabeError {
    fn from(error: HostError) -> Self {
        RabeError::Core {
            code: error.code,
            message: error.message,
        }
    }
}

/// Adapts the FFI delegate to the host's delegate trait, serializing events.
struct DelegateAdapter(Arc<dyn RabeDelegate>);

impl HostDelegate for DelegateAdapter {
    fn open_url(&self, url: String) {
        self.0.open_url(url);
    }

    fn open_path(&self, path: String) {
        self.0.open_path(path);
    }

    fn on_event(&self, event: rabe_host::UiEvent) {
        match serde_json::to_string(&event) {
            Ok(json) => self.0.on_event(json),
            Err(error) => tracing::warn!("cannot serialize ui event: {error}"),
        }
    }

    fn can_notify(&self) -> bool {
        self.0.notifications_allowed()
    }

    fn notify(&self, notification: rabe_host::Notification) -> bool {
        self.0.notify(RabeNotification {
            id: notification.id,
            title: notification.title,
            body: notification.body,
            thread_id: notification.thread_id,
            account_id: notification.account_id,
        })
    }

    fn copy_to_clipboard(&self, text: String) -> bool {
        self.0.copy_to_clipboard(text)
    }
}

/// A running host. Create one per process; the instance lock lives as long as
/// this object does, or until [`RabeHost::shutdown`].
#[derive(uniffi::Object)]
pub struct RabeHost {
    /// `None` after [`RabeHost::shutdown`]; commands never hold the `Host`
    /// itself (only a [`Dispatcher`](rabe_host::Dispatcher)), so the runtime is
    /// always dropped from this thread or from `Drop`, never from a worker.
    host: Mutex<Option<Host>>,
    /// Kept next to the host so both survive a shutdown.
    data_dir: String,
    keyring_service: String,
}

#[uniffi::export]
impl RabeHost {
    /// Start the host. Returns as soon as the data directory is locked and the
    /// core is starting in the background - watch `host:ready` (or await
    /// [`RabeHost::wait_ready`]) before expecting data.
    #[uniffi::constructor]
    pub fn start(
        identifier: String,
        resource_dir: Option<String>,
        delegate: Arc<dyn RabeDelegate>,
    ) -> Result<Arc<Self>, RabeError> {
        // Only `de.streil.rabe.native` and `de.streil.rabe.native.sandbox`
        // exist (audit R1); the data directory and the keyring service are
        // derived from the identifier inside the host, never from the
        // environment.
        let mut config = HostConfig::new(identifier)?;
        if let Some(dir) = resource_dir {
            config = config.with_resource_dir(PathBuf::from(dir));
        }

        let host = Host::start(config, Arc::new(DelegateAdapter(delegate)))?;
        Ok(Arc::new(Self {
            data_dir: host.data_dir().to_string_lossy().into_owned(),
            keyring_service: host.keyring_service().to_string(),
            host: Mutex::new(Some(host)),
        }))
    }

    /// Wait until the core is up; fails with the start error otherwise.
    pub async fn wait_ready(&self) -> Result<(), RabeError> {
        let dispatcher = self.dispatcher()?;
        dispatcher.wait_ready().await.map_err(RabeError::from)
    }

    /// Tell the core the UI is up (account actors wait for this).
    pub fn notify_ui_ready(&self) {
        if let Ok(host) = self.host_guard()
            && let Some(host) = host.as_ref()
        {
            host.notify_ui_ready();
        }
    }

    /// Data directory in use, so the UI can write next to the host's log.
    pub fn data_dir(&self) -> String {
        self.data_dir.clone()
    }

    /// Keyring service in use (the identifier, unless overridden).
    pub fn keyring_service(&self) -> String {
        self.keyring_service.clone()
    }

    /// Stop the host: refuse new commands, wait briefly for running ones, stop
    /// the core's tasks and release the instance lock.
    ///
    /// Call from `applicationWillTerminate`. Afterwards every `invoke` fails
    /// with `host_stopped` and a second call is a no-op. Dropping the object
    /// without calling this does the same teardown, but a plain drop is not
    /// allowed to wait for commands in flight.
    pub fn shutdown(&self) {
        let host = self.host_guard().ok().and_then(|mut guard| guard.take());
        if let Some(host) = host {
            host.shutdown();
            tracing::info!("rabe-uniffi: host shut down");
        }
    }

    /// Wrap a message body for display: identical CSP and base styles to the
    /// Tauri frontend, plus a defensive strip of scripts, frames, plugins,
    /// `meta`/`base`/`link` and `on*` handlers.
    /// `theme_json` is a `DisplayTheme` (`text`, `textMuted`, `accent`,
    /// `colorScheme`, optional `fontFamily`).
    pub fn html_for_display(
        &self,
        html: String,
        theme_json: String,
        load_remote_images: bool,
    ) -> Result<String, RabeError> {
        let theme: rabe_host::DisplayTheme = if theme_json.trim().is_empty() {
            rabe_host::DisplayTheme::default()
        } else {
            serde_json::from_str(&theme_json).map_err(|error| RabeError::Core {
                code: "bad_args".to_string(),
                message: format!("invalid theme: {error}"),
            })?
        };
        Ok(rabe_host::wrap_for_display(
            &html,
            &theme,
            load_remote_images,
        ))
    }

    /// True when the body references remote `http(s)` images.
    pub fn html_has_remote_images(&self, html: String) -> bool {
        rabe_host::has_remote_images(&html)
    }

    /// JavaScript the UI injects into the email document on a dark theme.
    pub fn dark_mode_script(&self) -> String {
        rabe_host::dark_mode_script().to_string()
    }
}

/// Plain helpers, not exported over the FFI.
impl RabeHost {
    fn host_guard(&self) -> Result<std::sync::MutexGuard<'_, Option<Host>>, RabeError> {
        self.host.lock().map_err(|_| RabeError::Core {
            code: "host_stopped".to_string(),
            message: "the host lock was poisoned by a panic".to_string(),
        })
    }

    /// The dispatcher only (no runtime): a task holding this cannot keep the
    /// `Host` alive, so dropping the host never happens on a worker thread.
    fn dispatcher(&self) -> Result<rabe_host::Dispatcher, RabeError> {
        let guard = self.host_guard()?;
        guard
            .as_ref()
            .map(Host::dispatcher)
            .ok_or_else(|| RabeError::Core {
                code: "host_stopped".to_string(),
                message: "the host was shut down".to_string(),
            })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl RabeHost {
    /// Run one command with the Tauri frontend's names and arguments.
    /// Returns the result as JSON. Waits for the core to finish starting.
    pub async fn invoke(&self, cmd: String, args_json: String) -> Result<String, RabeError> {
        // Run on the host's own runtime: the core's actors and timers live
        // there, and a dispatch should not be polled on a foreign executor.
        let (dispatcher, runtime) = {
            let guard = self.host_guard()?;
            let host = guard.as_ref().ok_or_else(|| RabeError::Core {
                code: "host_stopped".to_string(),
                message: "the host was shut down".to_string(),
            })?;
            (host.dispatcher(), host.runtime().handle().clone())
        };
        if dispatcher.is_stopping() {
            return Err(RabeError::Core {
                code: "host_stopped".to_string(),
                message: "the host is shutting down".to_string(),
            });
        }

        let joined = runtime
            .spawn(async move { dispatcher.dispatch(&cmd, &args_json).await })
            .await;

        match joined {
            Ok(Ok(json)) => Ok(json),
            Ok(Err(error)) => Err(error.into()),
            // The runtime shut down under the task (the host was torn down
            // while this command ran). That is a lifecycle event, not a crash.
            Err(error) if error.is_cancelled() => Err(RabeError::Core {
                code: "host_stopped".to_string(),
                message: "the host shut down while the command was running".to_string(),
            }),
            // The task panicked; the panic message is all we have.
            Err(error) => Err(RabeError::Core {
                code: "panic".to_string(),
                message: error.to_string(),
            }),
        }
    }
}
