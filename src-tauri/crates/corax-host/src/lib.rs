//! Corax native host.
//!
//! Starts `comail-core` in its own data directory (in the background), holds
//! the instance lock, dispatches the Tauri command set as JSON, forwards
//! `CoreEvent`s to a UI, delivers desktop notifications and wraps HTML mail for
//! display. This is the layer the Swift app (via `corax-uniffi`) and the QML app
//! (via `rabe-qt`) both sit on.

mod backoff;
mod dispatch;
mod events;
mod html;
mod instance;
mod logging;
mod notify;
mod sandbox;

pub use html::{DisplayTheme, dark_mode_script, has_remote_images, wrap_for_display};

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use comail_core::Core;
use comail_core::config::Paths;
use comail_core::db::{Db, repo};
use comail_core::events::{NewEventInfo, SyncProgress};
use comail_core::mcp::McpCall;
use comail_core::models::{AskCitation, CalendarEvent, SyncStatus};
use serde::Serialize;
use tokio::runtime::Runtime;
use tokio::sync::watch;

use instance::Instance;

pub use dispatch::{COMMANDS, EXCEPTIONS};
pub use sandbox::{SANDBOX_IDENTIFIER, SeedReport, is_sandbox_identifier};

/// Bundle identifier of the native app (own data directory, own keyring).
/// M3.5: final identifier (`com.coraxapp.corax`); the Swift side (`AppIdentity`)
/// carries the same value, and the migration reads the previous directories
/// (`de.streil.corax`, then `de.streil.rabe.native`) once.
pub const NATIVE_IDENTIFIER: &str = "com.coraxapp.corax";
/// Identifier of the Tauri release app whose directory must never be opened.
pub const RELEASE_IDENTIFIER: &str = "de.streil.rabe";
/// Port the native instance uses when its settings would claim the release
/// app's MCP port.
pub const NATIVE_MCP_PORT: u16 = 47833;

/// Name the local MCP server uses: in the `initialize` handshake and as the
/// key the "add to app" helpers write (M4). The core default stays `comail`
/// for the Tauri app; `corax` keeps both entries apart.
pub const MCP_NAME: &str = "corax";
/// Sandbox twin, so a test instance never overwrites the native entry.
pub const MCP_SANDBOX_NAME: &str = "corax-sandbox";

/// MCP name for one of the two identifiers this host runs with.
pub fn mcp_name_for(identifier: &str) -> &'static str {
    if identifier == SANDBOX_IDENTIFIER {
        MCP_SANDBOX_NAME
    } else {
        MCP_NAME
    }
}

/// True for the only two identifiers this host runs with.
///
/// Byte-exact on purpose: no case folding, no trailing slash, no path
/// component. `DE.STREIL.RABE.NATIVE` resolves to the same directory as the
/// native identifier under APFS, and `de.streil.rabe.native/../comail` is the
/// release directory - both used to reach the daily driver's database through
/// the identifier (audit N-H2a, N-M5a). A whitelist makes that impossible
/// instead of trying to normalise every spelling.
pub fn is_allowed_identifier(identifier: &str) -> bool {
    identifier == NATIVE_IDENTIFIER || identifier == SANDBOX_IDENTIFIER
}

/// Where the host runs and which directories it may touch.
///
/// The data directory and the keyring service are derived from the identifier
/// alone: `platform_data_dir()/<identifier>` and `<identifier>`
/// (`src-tauri/crates/corax-host/src/instance.rs`). `COMAIL_DATA_DIR` and
/// `COMAIL_KEYRING_SERVICE` from the environment are overwritten at start, not
/// honoured, so a stray `launchctl setenv` or a profiling shell cannot point
/// the host at the release app's data (audit R2).
///
/// Fields are private and the constructor validates the identifier, so a
/// caller cannot assemble a config that escapes the rule. The app gets its
/// config from `corax-uniffi` (`CoraxHost.start`), the CLI from `corax-cli`.
#[derive(Debug, Clone)]
pub struct HostConfig {
    identifier: String,
    resource_dir: Option<PathBuf>,
    read_only: bool,
    /// Test-only: run on this directory instead of the platform data dir.
    /// `None` on every shipped path; see [`HostConfig::for_tests`].
    data_dir_override: Option<PathBuf>,
}

impl HostConfig {
    /// Config for `identifier`. Refuses everything except
    /// [`NATIVE_IDENTIFIER`] and [`SANDBOX_IDENTIFIER`].
    pub fn new(identifier: impl Into<String>) -> Result<Self, HostError> {
        let identifier = identifier.into();
        if !is_allowed_identifier(&identifier) {
            return Err(HostError::new(
                "refused",
                format!(
                    "unknown identifier {identifier:?}: only {NATIVE_IDENTIFIER} and \
                     {SANDBOX_IDENTIFIER} are allowed"
                ),
            ));
        }
        Ok(Self {
            identifier,
            resource_dir: None,
            read_only: false,
            data_dir_override: None,
        })
    }

    /// Test-only constructor: a temporary directory and a test keyring service
    /// instead of the platform data directory.
    ///
    /// Not part of the FFI (Swift cannot see it) and not used by `corax-cli`.
    /// The identifier whitelist and the release-directory identity check still
    /// run, so this only moves the instance to a throwaway directory.
    #[doc(hidden)]
    pub fn for_tests(dir: impl AsRef<Path>) -> Self {
        Self {
            identifier: NATIVE_IDENTIFIER.to_string(),
            resource_dir: None,
            read_only: false,
            data_dir_override: Some(dir.as_ref().to_path_buf()),
        }
    }

    /// Bundle resources (models); exported as `COMAIL_RESOURCE_DIR`.
    pub fn with_resource_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.resource_dir = Some(dir.into());
        self
    }

    /// Start without the background notification dispatcher, the UI event
    /// forwarder and the MCP-port rewrite. The `corax-cli` uses this so a read
    /// of the native instance cannot mark notifications as delivered or
    /// rewrite settings.
    pub fn with_read_only(mut self, read_only: bool) -> Self {
        self.read_only = read_only;
        self
    }

    pub fn identifier(&self) -> &str {
        &self.identifier
    }

    pub fn resource_dir(&self) -> Option<&Path> {
        self.resource_dir.as_deref()
    }

    pub fn read_only(&self) -> bool {
        self.read_only
    }

    /// Test-only directory override; `None` on every shipped path.
    pub(crate) fn data_dir_override(&self) -> Option<&Path> {
        self.data_dir_override.as_deref()
    }

    /// The keyring service this config runs with (the identifier, or the test
    /// service for [`HostConfig::for_tests`]).
    pub(crate) fn keyring_service(&self) -> Result<&str, HostError> {
        instance::keyring_service_for(self)
    }

    /// Validate the identifier and the keyring service before anything is
    /// created or locked. Every check is fail-closed.
    fn validate(&self) -> Result<(), HostError> {
        if !is_allowed_identifier(&self.identifier) {
            return Err(HostError::new(
                "refused",
                format!(
                    "unknown identifier {:?}: only {NATIVE_IDENTIFIER} and \
                     {SANDBOX_IDENTIFIER} are allowed",
                    self.identifier
                ),
            ));
        }
        self.keyring_service().map(|_| ())
    }
}

impl Default for HostConfig {
    /// The native instance.
    fn default() -> Self {
        Self::new(NATIVE_IDENTIFIER).expect("the native identifier is allowed")
    }
}

/// One desktop notification to show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    /// Outbox row id; stable across retries.
    pub id: i64,
    pub title: String,
    pub body: String,
    pub thread_id: Option<i64>,
    pub account_id: Option<i64>,
}

/// Callbacks the UI supplies. Methods may be called from background threads;
/// the UI is responsible for switching to its main thread.
pub trait HostDelegate: Send + Sync + 'static {
    /// Open a URL in the system browser (OAuth, external links).
    fn open_url(&self, url: String);
    /// Reveal or open a path with the system handler (attachments, log folder).
    fn open_path(&self, path: String);
    /// One UI event, already coalesced.
    fn on_event(&self, event: UiEvent);
    /// Whether the user has **finally denied** notifications: `false` means
    /// "do not post, this is a decision", and due rows are closed as
    /// `suppressed`/`not_permitted` instead of stacking up.
    ///
    /// Everything else answers `true`: not asked yet, unknown, provisional or
    /// a permission that was granted. Whether a notification actually reached
    /// the screen is reported by [`HostDelegate::notify`] returning `false`,
    /// which goes through the normal retry with backoff. Answering `false`
    /// early would silently drop notifications the user never declined (audit
    /// Nachprüfung 2, A1).
    fn can_notify(&self) -> bool {
        true
    }
    /// Show a desktop notification. `false` makes the host retry later, exactly
    /// like a failed Tauri notification did.
    fn notify(&self, _notification: Notification) -> bool {
        false
    }
    /// Put text on the clipboard. `false` means it did not reach the user.
    fn copy_to_clipboard(&self, _text: String) -> bool {
        false
    }
}

/// Delegate that ignores every callback; used by the CLI and tests.
pub struct NoopDelegate;

impl HostDelegate for NoopDelegate {
    fn open_url(&self, _url: String) {}
    fn open_path(&self, _path: String) {}
    fn on_event(&self, _event: UiEvent) {}
    /// Without a UI nobody can see a notification: report failure so the
    /// outbox retries instead of marking the notification delivered.
    fn notify(&self, _notification: Notification) -> bool {
        false
    }
    fn copy_to_clipboard(&self, _text: String) -> bool {
        true
    }
}

/// One event for the UI. Serialized as `{"name": "...", "payload": {...}}`,
/// the same names and payloads the Tauri app emits (`src-tauri/src/events.rs`),
/// plus the two host lifecycle events.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "name", content = "payload", rename_all_fields = "camelCase")]
pub enum UiEvent {
    /// The core finished starting; `dispatch` no longer waits.
    #[serde(rename = "host:ready")]
    HostReady { core_start_ms: f64 },
    /// The core could not start; every later `dispatch` fails with this error.
    #[serde(rename = "host:failed")]
    HostFailed { code: String, message: String },
    #[serde(rename = "mail:updated")]
    MailUpdated { thread_ids: Vec<i64> },
    #[serde(rename = "mail:new")]
    MailNew {
        account_id: i64,
        thread_ids: Vec<i64>,
    },
    #[serde(rename = "sync:progress")]
    SyncProgress(SyncProgress),
    #[serde(rename = "sync:status")]
    SyncStatus(SyncStatus),
    #[serde(rename = "action:state")]
    ActionState {
        action_id: i64,
        kind: String,
        state: String,
        error: Option<String>,
    },
    /// A move-family action failed; the UI tells the user instead of letting
    /// the mail jump back silently (M2.16).
    #[serde(rename = "action:failed")]
    ActionFailed {
        action_id: i64,
        kind: String,
        thread_id: Option<i64>,
        reason: String,
        error: String,
    },
    #[serde(rename = "thread:woke")]
    ThreadWoke { thread_id: i64 },
    #[serde(rename = "network:state")]
    NetworkState { online: bool },
    #[serde(rename = "account:state")]
    AccountState { account_id: i64, sync_state: String },
    #[serde(rename = "ai:ask:citations")]
    AskCitations {
        request_id: String,
        citations: Vec<AskCitation>,
    },
    #[serde(rename = "ai:ask:token")]
    AskDelta { request_id: String, delta: String },
    #[serde(rename = "ai:ask:reasoning")]
    AskReasoning { request_id: String, delta: String },
    #[serde(rename = "ai:ask:reset")]
    AskReset { request_id: String },
    #[serde(rename = "ai:ask:done")]
    AskDone { request_id: String },
    #[serde(rename = "ai:draft:token")]
    AiDraftDelta { request_id: String, delta: String },
    #[serde(rename = "ai:summary:token")]
    AiSummaryDelta { thread_id: i64, delta: String },
    #[serde(rename = "calendar:updated")]
    CalendarUpdated { account_id: i64 },
    #[serde(rename = "calendar:new")]
    CalendarEventsAdded {
        account_id: i64,
        events: Vec<NewEventInfo>,
    },
    #[serde(rename = "calendar:reminder")]
    EventReminder {
        event: CalendarEvent,
        occurrence_start: i64,
    },
    #[serde(rename = "calendar:conflict")]
    CalendarConflict {
        event_id: i64,
        summary: Option<String>,
    },
    #[serde(rename = "mcp:activity")]
    McpActivity(McpCall),
}

/// Failure crossing the host boundary, shaped like `CoreError::to_ipc_json`:
/// `{"code","message"}` with a stable code for the UI to localize.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HostError {
    pub code: String,
    pub message: String,
}

impl HostError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn from_core(error: &comail_core::error::CoreError) -> Self {
        Self::new(error.code(), error.to_string())
    }
}

impl std::fmt::Display for HostError {
    /// JSON, so stderr and the FFI carry the same shape as stdout results.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match serde_json::to_string(self) {
            Ok(json) => f.write_str(&json),
            Err(_) => write!(f, "{{\"code\":\"{}\"}}", self.code),
        }
    }
}

impl std::error::Error for HostError {}

#[derive(Clone, Debug)]
enum Status {
    Pending,
    Ready,
    Failed(HostError),
}

/// Shared with the background loader task, with every clone of a running
/// dispatch and with [`Dispatcher`] handles the UI keeps across a shutdown.
struct Inner {
    data_dir: PathBuf,
    core: OnceLock<Core>,
    status: watch::Sender<Status>,
    delegate: Arc<dyn HostDelegate>,
    /// Commands currently running; `shutdown` waits briefly for them.
    inflight: AtomicUsize,
    /// Set once shutdown started; new commands are refused.
    stopping: AtomicBool,
}

/// A running host: one tokio runtime, one `Core` (once ready), one locked data
/// directory.
pub struct Host {
    inner: Arc<Inner>,
    /// `None` only after [`Host::shutdown`] or the drop guard took it. The
    /// instance lock goes only once this runtime is fully shut down.
    runtime: Option<Runtime>,
    instance: Option<Instance>,
    keyring_service: String,
    delegate: Arc<dyn HostDelegate>,
}

/// Handle for running commands without keeping the [`Host`] (and its runtime)
/// alive. Cloning it into a background task is safe: dropping the last handle
/// never drops a runtime, so it cannot panic on a worker thread.
#[derive(Clone)]
pub struct Dispatcher {
    inner: Arc<Inner>,
}

impl Dispatcher {
    /// Run one command; see [`Host::dispatch`].
    pub async fn dispatch(&self, cmd: &str, args_json: &str) -> Result<String, HostError> {
        self.inner.dispatch(cmd, args_json).await
    }

    /// Wait until the core is running (or failed).
    pub async fn wait_ready(&self) -> Result<(), HostError> {
        self.inner.wait_core().await.map(|_| ())
    }

    /// True once the host started shutting down; no new command is accepted.
    pub fn is_stopping(&self) -> bool {
        self.inner.stopping.load(Ordering::SeqCst)
    }
}

/// Keeps the in-flight counter balanced even when the future is cancelled.
struct InFlight<'a>(&'a AtomicUsize);

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

impl Inner {
    async fn dispatch(&self, cmd: &str, args_json: &str) -> Result<String, HostError> {
        // Count first, check second: a shutdown that observes zero must not
        // race a command that is just starting (audit N4). A dispatch that
        // finds `stopping` already set leaves the counter again immediately.
        self.inflight.fetch_add(1, Ordering::SeqCst);
        let _inflight = InFlight(&self.inflight);
        if self.stopping.load(Ordering::SeqCst) {
            return Err(HostError::new(
                "host_stopped",
                "the host is shutting down; command refused",
            ));
        }

        let started = Instant::now();
        let core = self.wait_core().await?;
        // Waiting for the background start is not the command's cost; keep it
        // separate so a cold first call does not look like a slow query.
        let wait_ms = started.elapsed().as_secs_f64() * 1000.0;

        let started = Instant::now();
        let result = dispatch::run(&core, &self.delegate, &self.data_dir, cmd, args_json).await;
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        match &result {
            Ok(json) => tracing::info!(
                target: "perf", cmd, ms, wait_ms, bytes = json.len(), "dispatch"
            ),
            Err(error) => tracing::warn!(
                target: "perf", cmd, ms, wait_ms, code = %error.code, "dispatch_failed"
            ),
        }
        result
    }

    async fn wait_core(&self) -> Result<Core, HostError> {
        if let Some(core) = self.core.get() {
            return Ok(core.clone());
        }

        let mut rx = self.status.subscribe();
        loop {
            // Read the current status, then re-check the cell: the loader sets
            // the core before flipping the status, so this cannot miss it.
            let status = rx.borrow_and_update().clone();
            match status {
                Status::Ready => break,
                Status::Failed(error) => return Err(error),
                Status::Pending => {}
            }
            if let Some(core) = self.core.get() {
                return Ok(core.clone());
            }
            rx.changed().await.map_err(|_| {
                HostError::new("host_stopped", "the host was shut down while starting")
            })?;
        }

        self.core
            .get()
            .cloned()
            .ok_or_else(|| HostError::new("host_not_ready", "the core is not running"))
    }
}

/// Run one command against an already-started core. The same entry point the
/// host uses; exposed so `rabe-qt` and the contract tests can drive the
/// dispatcher without a UI. `data_dir` is the instance directory the command
/// may open paths from (attachments, logs).
pub async fn dispatch_json(
    core: &Core,
    delegate: &Arc<dyn HostDelegate>,
    data_dir: &Path,
    cmd: &str,
    args_json: &str,
) -> Result<String, HostError> {
    dispatch::run(core, delegate, data_dir, cmd, args_json).await
}

/// Start the notification dispatcher against a core the caller already owns.
/// [`Host::start`] does this itself; exposed so tests and `rabe-qt` can run the
/// same delivery loop without a host.
pub fn spawn_notifications(
    runtime: &tokio::runtime::Handle,
    core: Core,
    delegate: Arc<dyn HostDelegate>,
) {
    notify::spawn(runtime, core, delegate);
}

impl Host {
    /// Isolate the data directory, take the instance lock and start the core in
    /// the background. Returns immediately; poll [`Host::wait_ready`] or wait
    /// for the `host:ready` event.
    pub fn start(cfg: HostConfig, delegate: Arc<dyn HostDelegate>) -> Result<Host, HostError> {
        let started = Instant::now();
        // Validate before anything is created: an unknown identifier or a
        // release keyring service must fail without touching the disk.
        cfg.validate()?;
        let instance = Instance::acquire(&cfg)?;
        instance.export_env(cfg.resource_dir());
        logging::init(&instance.data_dir, "info");
        tracing::info!(
            identifier = %cfg.identifier(),
            keyring = %instance.keyring_service,
            data_dir = %instance.data_dir.display(),
            read_only = cfg.read_only(),
            "corax-host starting"
        );

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("corax-host")
            .build()
            .map_err(|error| {
                HostError::new("io", format!("cannot build the tokio runtime: {error}"))
            })?;

        let (status, _) = watch::channel(Status::Pending);
        let inner = Arc::new(Inner {
            data_dir: instance.data_dir.clone(),
            core: OnceLock::new(),
            status,
            delegate: delegate.clone(),
            inflight: AtomicUsize::new(0),
            stopping: AtomicBool::new(false),
        });

        let loading = inner.clone();
        let config = cfg.clone();
        runtime.spawn(async move {
            let core_started = Instant::now();
            // The MCP port has to be right *before* the core applies the
            // settings, or the native instance briefly binds the release app's
            // port (audit N2). Writing the setting first removes the race.
            // No allowed identifier is the release one, so this runs for the
            // native and the sandbox instance alike (the sandbox keeps the
            // port its seed wrote).
            if !config.read_only()
                && let Err(error) = point_mcp_port_away().await
            {
                tracing::warn!(%error, "mcp: cannot move the native instance off the release port");
            }

            let paths = Paths::default_dirs().with_mcp_name(mcp_name_for(config.identifier()));
            let core = match Core::start(paths).await {
                Ok(core) => core,
                Err(error) => {
                    let host_error = HostError::from_core(&error);
                    tracing::error!(
                        code = %host_error.code,
                        message = %host_error.message,
                        "corax-host: core did not start"
                    );
                    loading
                        .status
                        .send_replace(Status::Failed(host_error.clone()));
                    loading.delegate.on_event(UiEvent::HostFailed {
                        code: host_error.code,
                        message: host_error.message,
                    });
                    return;
                }
            };
            let core_ms = core_started.elapsed().as_secs_f64() * 1000.0;

            if loading.core.set(core.clone()).is_err() {
                tracing::warn!("corax-host: core start raced; keeping the first one");
            }
            loading.status.send_replace(Status::Ready);

            // A read-only host (the CLI) neither forwards events nor delivers
            // notifications: both would touch state the user's app owns.
            if !config.read_only {
                let handle = tokio::runtime::Handle::current();
                events::spawn(&handle, loading.delegate.clone(), core.bus.clone());
                notify::spawn(&handle, core.clone(), loading.delegate.clone());
            }

            tracing::info!(target: "perf", ms = core_ms, "core_start");
            tracing::info!(
                target: "perf",
                ms = started.elapsed().as_secs_f64() * 1000.0,
                "host_ready"
            );
            loading.delegate.on_event(UiEvent::HostReady {
                core_start_ms: core_ms,
            });
        });

        tracing::info!(
            target: "perf",
            ms = started.elapsed().as_secs_f64() * 1000.0,
            "host_started"
        );

        let keyring_service = instance.keyring_service.clone();
        Ok(Host {
            inner,
            runtime: Some(runtime),
            instance: Some(instance),
            keyring_service,
            delegate,
        })
    }

    /// Run one command. `args_json` is a JSON object with the frontend's
    /// parameter names (camelCase); returns the result as JSON. Waits for the
    /// core to finish starting.
    pub async fn dispatch(&self, cmd: &str, args_json: &str) -> Result<String, HostError> {
        self.inner.dispatch(cmd, args_json).await
    }

    /// A runtime-independent handle for background work (the FFI `invoke`).
    pub fn dispatcher(&self) -> Dispatcher {
        Dispatcher {
            inner: self.inner.clone(),
        }
    }

    /// Wait until the core is running (or failed).
    pub async fn wait_ready(&self) -> Result<(), HostError> {
        self.inner.wait_core().await.map(|_| ())
    }

    /// The core as a clone, once it is up.
    pub async fn core(&self) -> Result<Core, HostError> {
        self.inner.wait_core().await
    }

    /// The core if it is already running, without waiting (for `rabe-qt`).
    pub fn core_now(&self) -> Option<&Core> {
        self.inner.core.get()
    }

    /// Tell the core the UI is up; account actors wait for this (60 s fallback
    /// otherwise). Queues behind the background start when called early.
    pub fn notify_ui_ready(&self) {
        let inner = self.inner.clone();
        if let Some(runtime) = self.runtime.as_ref() {
            runtime.spawn(async move {
                if let Ok(core) = inner.wait_core().await {
                    tracing::info!(target: "perf", "ui_ready");
                    core.notify_ui_ready();
                }
            });
        }
    }

    pub fn runtime(&self) -> &Runtime {
        self.runtime
            .as_ref()
            .expect("the runtime lives until the host is shut down")
    }

    pub fn delegate(&self) -> &Arc<dyn HostDelegate> {
        &self.delegate
    }

    pub fn data_dir(&self) -> &std::path::Path {
        &self.inner.data_dir
    }

    pub fn keyring_service(&self) -> &str {
        &self.keyring_service
    }

    /// Stop accepting commands, wait briefly for running ones, stop the core's
    /// tasks and release the instance lock.
    ///
    /// This is the clean path the app calls from `applicationWillTerminate`;
    /// dropping a `Host` without it runs the same teardown from [`Drop`].
    pub fn shutdown(mut self) {
        self.inner.stopping.store(true, Ordering::SeqCst);
        self.wait_idle();
        self.teardown();
        tracing::info!("corax-host stopped");
    }

    fn wait_idle(&self) {
        const GRACE: Duration = Duration::from_millis(500);
        let deadline = Instant::now() + GRACE;
        loop {
            let inflight = self.inner.inflight.load(Ordering::SeqCst);
            if inflight == 0 {
                return;
            }
            if Instant::now() >= deadline {
                tracing::warn!(
                    inflight,
                    "shutdown: commands still running after the grace period"
                );
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Drop the runtime, then the instance lock - in that order, even when the
    /// last reference falls on a runtime worker.
    ///
    /// Releasing the `flock` while the runtime still winds down would let a
    /// second host open the same database for a short window (audit N4), so
    /// the lock moves into the same helper thread as the runtime.
    fn teardown(&mut self) {
        let Some(runtime) = self.runtime.take() else {
            return;
        };
        let instance = self.instance.take();
        if tokio::runtime::Handle::try_current().is_ok() {
            // Dropping a `Runtime` from inside a runtime panics with "Cannot
            // drop a runtime in a context where blocking is not allowed". A
            // short-lived thread is outside any such context.
            std::thread::spawn(move || {
                drop(runtime);
                drop(instance);
            });
        } else {
            // Consumes the runtime: it blocks until the tasks are done, so the
            // lock below is released only after the shutdown completed.
            runtime.shutdown_timeout(Duration::from_millis(500));
            drop(instance);
        }
    }
}

impl Drop for Host {
    /// Never panics, even when the last reference is dropped on a runtime
    /// worker: tokio refuses to drop a runtime inside an asynchronous context,
    /// so the teardown moves to a plain thread there.
    fn drop(&mut self) {
        self.inner.stopping.store(true, Ordering::SeqCst);
        self.teardown();
    }
}

/// Guard rail for `corax-cli`: the real account is never started from the CLI.
///
/// A "read-only" host was never read-only in practice: `Core::start` starts
/// the scheduler (wakes snoozed threads, consumes calendar reminders) and the
/// embedding worker before a single command runs, whatever the host config
/// says (audit Nachprüfung 2, A2). So the CLI refuses the native identifier
/// entirely. Looking into the data without side effects is `sqlite3 -readonly`
/// on the database file, or the app itself.
///
/// The sandbox stays fully usable: it has no real account, no working server
/// and its own throwaway database.
pub fn check_cli_identifier(identifier: &str) -> Result<(), HostError> {
    if identifier == NATIVE_IDENTIFIER {
        return Err(HostError::new(
            "refused",
            format!(
                "{NATIVE_IDENTIFIER} is the real account and is never started from the CLI \
                 (the core starts its scheduler and embedding worker even in read-only mode); \
                 for inspection use `sqlite3 -readonly \"<data dir>/comail.db\"` or the app"
            ),
        ));
    }
    if !is_allowed_identifier(identifier) {
        return Err(HostError::new(
            "refused",
            format!(
                "unknown identifier {identifier:?}: only {SANDBOX_IDENTIFIER} is started from the CLI"
            ),
        ));
    }
    Ok(())
}

/// Build the sandbox instance: the design mockup's mailbox in its own data
/// directory, on a mail domain that can never resolve.
///
/// Only [`SANDBOX_IDENTIFIER`] is accepted, and the directory is always
/// `platform_data_dir()/{SANDBOX_IDENTIFIER}` - `COMAIL_DATA_DIR` cannot move
/// it, so a typo or an inherited variable can never point the reset at the
/// native instance (real iCloud account), the release app or any other data.
pub fn seed_sandbox(identifier: &str, reset: bool) -> Result<SeedReport, HostError> {
    let base = instance::platform_data_dir()?;
    seed_sandbox_at(&base, identifier, reset)
}

/// [`seed_sandbox`] below an explicit base directory. Only the tests use this;
/// the CLI always passes the platform data directory.
#[doc(hidden)]
pub fn seed_sandbox_at(
    base: &Path,
    identifier: &str,
    reset: bool,
) -> Result<SeedReport, HostError> {
    if !sandbox::is_sandbox_identifier(identifier) {
        return Err(HostError::new(
            "refused",
            format!("can only seed {SANDBOX_IDENTIFIER}, not {identifier}"),
        ));
    }
    let data_dir = sandbox::sandbox_dir_at(base)?;
    // The seeder never touches the keyring; pinning the service keeps a stray
    // `COMAIL_KEYRING_SERVICE` out of the seeding path entirely.
    let instance = Instance::lock_verified(data_dir, identifier.to_string())?;
    logging::init(&instance.data_dir, "info");
    tracing::info!(
        identifier,
        data_dir = %instance.data_dir.display(),
        keyring = %instance.keyring_service,
        "sandbox: seeding"
    );
    let report = sandbox::seed(&instance.data_dir, reset)?;
    tracing::info!(
        threads = report.threads,
        messages = report.messages,
        attachments = report.attachments,
        labels = report.labels,
        splits = report.splits,
        "sandbox: seeded"
    );
    Ok(report)
}

/// Point the MCP port at [`NATIVE_MCP_PORT`] before the core reads its
/// settings, so the native instance never binds the release app's port even
/// briefly. Uses the core's own migration + repository layer on the database
/// the core is about to open.
async fn point_mcp_port_away() -> Result<(), HostError> {
    let paths = Paths::default_dirs();
    let db_path = paths.db_file();
    let db = tokio::task::spawn_blocking(move || Db::open(&db_path))
        .await
        .map_err(|error| HostError::new("io", format!("db open task failed: {error}")))?
        .map_err(|error| HostError::from_core(&error))?;
    db.write(|conn| {
        let mut settings = repo::settings::get(conn)?;
        if settings.mcp_port == 0 || settings.mcp_port == comail_core::mcp::DEFAULT_PORT {
            let previous = settings.mcp_port;
            settings.mcp_port = NATIVE_MCP_PORT;
            repo::settings::set(conn, &settings)?;
            tracing::info!(
                from = previous,
                to = NATIVE_MCP_PORT,
                "mcp: native instance moved off the release port"
            );
        } else {
            tracing::info!(
                port = settings.mcp_port,
                "mcp: native instance keeps its own port"
            );
        }
        Ok(())
    })
    .await
    .map_err(|error| HostError::from_core(&error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_two_exact_identifiers_are_accepted() {
        // The ground rule (audit R1): byte-exact, no normalisation. Every one
        // of these spellings reached the native or the release instance before.
        for identifier in [
            "x/../comail",
            "a/b/../../comail",
            "comail",
            "Comail",
            "de.streil.rabe",
            "DE.STREIL.RABE.NATIVE",
            "de.streil.rabe.native/",
            "de.streil.rabe.native.sandbox/..",
            "de.streil.rabe.native/../comail",
            "de.streil.rabe.native.profile",
            "comail/a/b",
            "",
            " de.streil.rabe.native",
        ] {
            let error = HostConfig::new(identifier).expect_err(identifier);
            assert_eq!(error.code, "refused", "{identifier:?}: {error}");
            let guard = check_cli_identifier(identifier)
                .expect_err("the CLI refuses unknown identifiers too");
            assert_eq!(guard.code, "refused", "{identifier:?}: {guard}");
        }

        for identifier in [NATIVE_IDENTIFIER, SANDBOX_IDENTIFIER] {
            HostConfig::new(identifier).expect("allowed");
        }
        assert_eq!(HostConfig::default().identifier(), NATIVE_IDENTIFIER);
        assert_eq!(
            HostConfig::new(SANDBOX_IDENTIFIER)
                .expect("sandbox config")
                .identifier(),
            SANDBOX_IDENTIFIER
        );
    }

    #[test]
    fn the_cli_never_starts_the_real_account() {
        let error = check_cli_identifier(NATIVE_IDENTIFIER).expect_err("native must be refused");
        assert_eq!(error.code, "refused", "{error}");
        assert!(
            error.message.contains("sqlite3 -readonly"),
            "the refusal must point at a side-effect-free way to look: {error}"
        );

        check_cli_identifier(SANDBOX_IDENTIFIER).expect("the sandbox stays usable");
        for identifier in [
            "comail",
            "de.streil.rabe",
            "DE.STREIL.RABE.NATIVE",
            "x/../comail",
        ] {
            let error = check_cli_identifier(identifier).expect_err(identifier);
            assert_eq!(error.code, "refused", "{identifier:?}: {error}");
        }
    }
}
