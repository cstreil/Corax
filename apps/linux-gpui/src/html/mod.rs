//! Mail-Körper für den Blitz-Renderer: Sanitisierung und Bild-Ressourcen.
//!
//! Blitz führt kein JavaScript aus. Die Angriffsfläche sind deshalb weniger
//! Skripte als Dinge, die von außen nachladen (Tracking-Pixel, Remote-Bilder,
//! CSS-Verweise) und alles, was die Ansicht zerlegt. `sanitize` setzt die
//! Anzeige-Policy durch, `Resources` beantwortet die Bild-Anfragen des
//! Renderers, ohne dass der Renderer selbst Netzzugriff bekommt.

// Jedes Testziel bindet diese Datei per `#[path]` ein und braucht daraus nur
// seinen Teil; der Rest wäre dort „toter Code". Im Binary gilt die Warnung.
#![cfg_attr(test, allow(dead_code))]

mod fetch;
mod resources;
mod sanitize;

// `allow(unused_imports)`: Die Integrationstests binden diese Datei per
// `#[path]` ein; dort wird nicht jeder Re-Export gebraucht.
#[allow(unused_imports)]
pub use fetch::{FetchError, FetchLimits, fetch_image};
#[allow(unused_imports)]
pub use resources::Resources;
#[allow(unused_imports)]
pub use sanitize::{Policy, RemoteImages, Sanitized, sanitize};
