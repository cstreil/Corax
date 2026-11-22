//! Zustandsschicht: was geladen ist, was ausgewählt ist, was offen ist.
//! Gegenstück zu den Stores der Mac-App (`MailboxStore`, `SidebarState`).

pub mod app;

pub use app::{AppState, Tab};
