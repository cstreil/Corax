//! Prüfungen vor riskanten Aktionen.
//!
//! Bisher nur Anhänge (A2). Der Aufrufer fragt vor dem Öffnen und entscheidet
//! nach [`OpenDecision`]: direkt öffnen, nachfragen oder blockieren.

pub mod attachments;

// Noch ohne Aufrufer im Binary, bis Coder 1 die Prüfung vor dem Öffnen
// einbindet (L2). Danach fällt das `allow` weg.
#[allow(unused_imports)]
pub use attachments::{OpenDecision, check_attachment};
