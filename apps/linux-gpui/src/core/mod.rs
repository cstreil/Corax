//! Kern-Anbindung (L-E1): Host im eigenen Thread, typisierte Anfragen.
//!
//! Die UI importiert `host` (Kanal zum Kern) und `models` (gelesene
//! Antworttypen) direkt; hier steht nur die Sandbox-Kennung.

pub mod host;
pub mod models;

pub use host::SANDBOX_IDENTIFIER;
