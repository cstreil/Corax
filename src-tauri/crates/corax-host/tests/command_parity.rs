//! Contract test: the dispatcher must know every command the Tauri app
//! registers, and must not invent any of its own.
//!
//! The source of truth is `src-tauri/src/lib.rs` (`generate_handler![…]`), read
//! at test time. A new upstream command therefore turns this test red until the
//! dispatcher learns it - or it is documented in `EXCEPTIONS`.

use std::collections::BTreeSet;
use std::path::PathBuf;

/// Commands that are window behaviour and cannot be dispatched without a Tauri
/// window. This list is the contract with `dispatch::EXCEPTIONS`.
const DOCUMENTED_EXCEPTIONS: &[&str] = &["cinema_close", "focus_main_window", "ui_ready"];

fn tauri_commands() -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../src/lib.rs");
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));

    let start = source
        .find("generate_handler![")
        .expect("no generate_handler![] block in src-tauri/src/lib.rs");
    let rest = &source[start..];
    let open = rest.find('[').expect("malformed generate_handler![");
    let close = rest.find("])").expect("unterminated generate_handler![");
    let body = &rest[open + 1..close];

    body.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(|entry| {
            entry
                .strip_prefix("commands::")
                .unwrap_or_else(|| panic!("unexpected handler entry {entry:?}"))
                .to_string()
        })
        .collect()
}

#[test]
fn every_tauri_command_is_dispatched_or_documented() {
    let tauri = tauri_commands();
    assert!(tauri.len() > 100, "parsed only {} commands", tauri.len());

    let dispatched: BTreeSet<&str> = corax_host::COMMANDS.iter().copied().collect();
    let exceptions: BTreeSet<&str> = corax_host::EXCEPTIONS.iter().copied().collect();

    let mut missing = Vec::new();
    for name in &tauri {
        if !dispatched.contains(name.as_str()) && !exceptions.contains(name.as_str()) {
            missing.push(name.clone());
        }
    }
    assert!(
        missing.is_empty(),
        "commands registered in the Tauri app but missing from the dispatcher: {missing:?}"
    );
}

#[test]
fn the_dispatcher_invents_no_command() {
    let tauri: BTreeSet<String> = tauri_commands().into_iter().collect();
    let mut unknown = Vec::new();
    for name in corax_host::COMMANDS
        .iter()
        .chain(corax_host::EXCEPTIONS.iter())
    {
        if !tauri.contains(*name) {
            unknown.push(*name);
        }
    }
    assert!(
        unknown.is_empty(),
        "dispatcher knows commands the Tauri app does not register: {unknown:?}"
    );
}

#[test]
fn exceptions_are_exactly_the_documented_ones() {
    let mut exceptions: Vec<&str> = corax_host::EXCEPTIONS.to_vec();
    exceptions.sort_unstable();
    let mut documented = DOCUMENTED_EXCEPTIONS.to_vec();
    documented.sort_unstable();
    assert_eq!(
        exceptions, documented,
        "a command became (or stopped being) an exception; update DOCUMENTED_EXCEPTIONS and the report"
    );
}

#[test]
fn commands_and_exceptions_do_not_overlap() {
    for name in corax_host::COMMANDS {
        assert!(
            !corax_host::EXCEPTIONS.contains(name),
            "{name} is both dispatched and an exception"
        );
    }
}

#[test]
fn command_names_are_unique_and_cover_the_handler_list() {
    let dispatched: BTreeSet<&str> = corax_host::COMMANDS.iter().copied().collect();
    assert_eq!(
        dispatched.len(),
        corax_host::COMMANDS.len(),
        "duplicate entries in COMMANDS"
    );

    let total = dispatched.len() + corax_host::EXCEPTIONS.len();
    assert_eq!(
        total,
        tauri_commands().len(),
        "COMMANDS + EXCEPTIONS must account for every generate_handler! entry"
    );
}
