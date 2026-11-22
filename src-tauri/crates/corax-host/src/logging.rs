//! Logging: same shape as the Tauri app (file + stderr), plus a separate log
//! file for the native app so profiling runs don't interleave with the
//! Tauri instance.

use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};

use tracing_subscriber::Layer;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;

/// Install a global subscriber writing to `<data_dir>/logs/corax.log`
/// and stderr. Safe to call more than once (later calls are no-ops).
pub(crate) fn init(data_dir: &Path, default_level: &str) {
    let dir = data_dir.join("logs");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("corax.log");
    let rotated = dir.join("corax.log.1");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
        let _ = std::fs::rename(&path, &rotated);
    }

    let filter = || {
        tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| format!("{default_level},html5ever=off,markup5ever=off").into())
    };

    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_target(false)
        .with_filter(filter());

    match open(&path) {
        Some(file) => {
            let file_layer = tracing_subscriber::fmt::layer()
                .with_writer(FileWriter(Arc::new(Mutex::new(file))))
                .with_ansi(false)
                .with_filter(filter());
            let _ = tracing_subscriber::registry()
                .with(stderr_layer)
                .with(file_layer)
                .try_init();
        }
        None => {
            let _ = tracing_subscriber::registry().with(stderr_layer).try_init();
        }
    }
}

fn open(path: &Path) -> Option<std::fs::File> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).ok()
}

/// `MakeWriter` over a shared file handle.
#[derive(Clone)]
struct FileWriter(Arc<Mutex<std::fs::File>>);

impl Write for FileWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self.0.lock() {
            Ok(mut file) => file.write(buf),
            Err(_) => Ok(buf.len()),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self.0.lock() {
            Ok(mut file) => file.flush(),
            Err(_) => Ok(()),
        }
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for FileWriter {
    type Writer = FileWriter;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}
