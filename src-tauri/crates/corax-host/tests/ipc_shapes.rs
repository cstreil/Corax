//! Argument-shape contract: every command must accept exactly the argument
//! names the Tauri app accepts (`src-tauri/src/commands.rs`) and the frontend
//! sends (`src/ipc/types.ts`), with the same optional/required split.
//!
//! Audit P1 H3: four commands had drifted (`save_attachment` without
//! `rename_all`, `save_snippet` under `args`, `save_split`/`reorder_tabs` with
//! `apply_existing` instead of `applyExisting`). serde ignored the unknown
//! field, so two commands failed loudly and two silently used the default.
//! This test parses all three sources and compares; it needs no core, no
//! network and no database.
//!
//! The dispatcher side is read from its own source, so it always describes the
//! structs the code actually deserializes into.

use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Field {
    /// Argument name as it appears in the JSON the frontend sends.
    json: String,
    optional: bool,
}

type Signature = Vec<Field>;

fn source(relative: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(relative);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()))
}

fn camel_case(name: &str) -> String {
    let mut parts = name.split('_');
    let mut out = parts.next().unwrap_or_default().to_string();
    for part in parts {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.push(first.to_ascii_uppercase());
            out.extend(chars);
        }
    }
    out
}

/// Split on commas that are not inside `<…>` or `(…)`.
fn split_top_level(text: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut angle = 0i32;
    let mut paren = 0i32;
    for c in text.chars() {
        match c {
            '<' => angle += 1,
            '>' => angle -= 1,
            '(' => paren += 1,
            ')' => paren -= 1,
            ',' if angle == 0 && paren == 0 => {
                parts.push(std::mem::take(&mut current));
                continue;
            }
            _ => {}
        }
        current.push(c);
    }
    if !current.trim().is_empty() {
        parts.push(current);
    }
    parts
}

fn field_from_declaration(declaration: &str, camel: bool) -> Option<Field> {
    let declaration = declaration.trim();
    if declaration.is_empty() {
        return None;
    }
    let (name, ty) = declaration.split_once(':')?;
    let name = name.trim();
    let optional = name.ends_with('?');
    let name = name.trim_end_matches('?');
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(Field {
        json: if camel {
            camel_case(name)
        } else {
            name.to_string()
        },
        optional: optional || ty.trim_start().starts_with("Option<"),
    })
}

// ---------------------------------------------------------------- commands.rs

/// Parameters of every `pub (async) fn` in `commands.rs`, keyed by command.
fn tauri_signatures() -> BTreeMap<String, Signature> {
    let source = source("../../src/commands.rs");
    let mut out = BTreeMap::new();
    let mut lines = source.lines().peekable();

    while let Some(line) = lines.next() {
        let trimmed = line.trim_start();
        let rest = trimmed
            .strip_prefix("pub async fn ")
            .or_else(|| trimmed.strip_prefix("pub fn "));
        let Some(rest) = rest else { continue };
        let Some(open) = rest.find('(') else { continue };
        let name = rest[..open].trim().to_string();

        // Collect the parameter list: everything after `(` until the line that
        // starts with `)`; a one-line signature closes on the same line.
        let mut params = rest[open + 1..].to_string();
        if let Some(close) = params.find(')') {
            params.truncate(close);
        } else {
            for param_line in lines.by_ref() {
                if param_line.trim_start().starts_with(')') {
                    break;
                }
                params.push('\n');
                params.push_str(param_line);
            }
        }

        let mut signature = Vec::new();
        for declaration in split_top_level(&params) {
            let declaration = declaration.trim();
            let Some((param, ty)) = declaration.split_once(':') else {
                continue;
            };
            let param = param.trim();
            let ty = ty.trim();
            // Injected by Tauri, not sent by the frontend.
            if (param == "state" && ty.starts_with("State<"))
                || (param == "app" && ty.contains("AppHandle"))
            {
                continue;
            }
            signature.push(Field {
                json: camel_case(param),
                optional: ty.starts_with("Option<"),
            });
        }
        out.insert(name, signature);
    }
    out
}

// -------------------------------------------------------------------- types.ts

/// Fields of the `Commands` interface in `src/ipc/types.ts`.
fn frontend_signatures() -> BTreeMap<String, Signature> {
    let source = source("../../../src/ipc/types.ts");
    let start = source
        .find("export interface Commands {")
        .expect("no `export interface Commands` in types.ts");
    let body = &source[start + "export interface Commands {".len()..];

    let mut out = BTreeMap::new();
    let mut lines = body.lines().peekable();
    while let Some(line) = lines.next() {
        if line.trim().is_empty() {
            continue;
        }
        if !line.starts_with("  ") {
            break; // the interface ends at column 0
        }
        let rest = &line[2..];
        if rest.trim().is_empty() || rest.trim_start().starts_with("//") {
            continue;
        }
        let Some(open) = rest.find("(args: ") else {
            continue;
        };
        let name = rest[..open].trim().to_string();
        let first = rest[open + "(args: ".len()..].trim();

        if first.starts_with("Record<") {
            out.insert(name, Vec::new());
            continue;
        }

        // The argument type is an object literal; it may span lines and nest
        // (`save_split` has `split: Omit<…> & { … }` inside).
        let mut args = first.to_string();
        while first_object(&args).is_none() {
            let Some(next) = lines.next() else { break };
            args.push('\n');
            args.push_str(next);
        }
        let (object, _) = first_object(&args)
            .unwrap_or_else(|| panic!("cannot parse the argument object of {name}: {args:?}"));
        let inner = &object[1..object.len() - 1];
        out.insert(name, typescript_object_fields(inner));
    }
    out
}

/// The first balanced `{ … }` in `text` and where it ends.
fn first_object(text: &str) -> Option<(String, usize)> {
    let start = text.find('{')?;
    let mut depth = 0usize;
    for (offset, c) in text[start..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let end = start + offset + c.len_utf8();
                    return Some((text[start..end].to_string(), end));
                }
            }
            _ => {}
        }
    }
    None
}

/// Fields declared directly in a TypeScript object type body. Comments are
/// skipped, nested object types are skipped as a field's type.
fn typescript_object_fields(body: &str) -> Signature {
    let mut fields = Vec::new();
    let mut depth = 0i32;
    let mut declaration = String::new();
    let mut chars = body.chars().peekable();
    let mut in_line_comment = false;

    while let Some(c) = chars.next() {
        if in_line_comment {
            if c == '\n' {
                in_line_comment = false;
                declaration.push(' ');
            }
            continue;
        }
        match c {
            '/' if chars.peek() == Some(&'/') => {
                chars.next();
                in_line_comment = true;
            }
            '{' => {
                depth += 1;
                declaration.push(c);
            }
            '}' => {
                depth -= 1;
                declaration.push(c);
            }
            ';' if depth == 0 => {
                if let Some(field) = field_from_declaration(&declaration, false) {
                    fields.push(field);
                }
                declaration.clear();
            }
            _ => declaration.push(c),
        }
    }
    // The last field of a single-line type has no trailing `;`.
    if let Some(field) = field_from_declaration(&declaration, false) {
        fields.push(field);
    }
    fields
}

// ------------------------------------------------------------------ dispatch.rs

/// Fields of the argument struct each dispatcher match arm deserializes.
fn dispatcher_signatures() -> BTreeMap<String, Signature> {
    let source = source("src/dispatch.rs");
    let lines: Vec<&str> = source.lines().collect();
    let mut out = BTreeMap::new();
    let mut index = 0;

    while index < lines.len() {
        let line = lines[index];
        let Some(rest) = line.trim_start().strip_prefix('"') else {
            index += 1;
            continue;
        };
        let Some(close) = rest.find("\" => {") else {
            index += 1;
            continue;
        };
        // Only the arms of the command match (8 spaces of indentation).
        if line.len() - line.trim_start().len() != 8 {
            index += 1;
            continue;
        }
        let command = rest[..close].to_string();
        let start = index + 1;
        let mut end = start;
        while end < lines.len() && !is_command_arm(lines[end]) {
            end += 1;
        }
        out.insert(command, arm_signature(&lines[start..end]));
        index = end;
    }
    out
}

fn is_command_arm(line: &str) -> bool {
    let indent = line.len() - line.trim_start().len();
    indent == 8 && line.trim_start().starts_with('"') && line.contains("\" => {")
}

/// The argument struct of one arm: `NoArgs`, `WithArgs<T>` or a local `struct A`.
fn arm_signature(arm: &[&str]) -> Signature {
    let parse_line = arm
        .iter()
        .find(|line| line.contains("= parse(args)?;"))
        .unwrap_or_else(|| panic!("no `parse(args)` in arm: {arm:?}"));
    let ty = parse_line
        .split("= parse(args)?;")
        .next()
        .and_then(|binding| binding.split(':').nth(1))
        .map(str::trim)
        .unwrap_or_else(|| panic!("cannot read the argument type from {parse_line:?}"));

    if ty == "NoArgs" {
        return Vec::new();
    }
    if ty.starts_with("WithArgs<") {
        return vec![Field {
            json: "args".to_string(),
            optional: false,
        }];
    }

    // A local `struct A { … }`: fields, with the rename rule from the
    // attribute above it.
    let mut struct_index = arm
        .iter()
        .position(|line| line.trim_start().starts_with("struct A {"))
        .unwrap_or_else(|| panic!("no `struct A` in arm: {arm:?}"));
    let camel = arm[..struct_index]
        .iter()
        .rev()
        .take(3)
        .any(|line| line.contains("rename_all = \"camelCase\""));
    struct_index += 1;

    let mut fields = Vec::new();
    let mut default = false;
    for line in &arm[struct_index..] {
        let trimmed = line.trim();
        if trimmed == "}" {
            break;
        }
        if trimmed.is_empty() || trimmed.starts_with("//") {
            continue;
        }
        if trimmed == "#[serde(default)]" {
            default = true;
            continue;
        }
        if trimmed.starts_with("#[") {
            continue;
        }
        let declaration = trimmed.trim_end_matches(',');
        let Some(mut field) = field_from_declaration(declaration, camel) else {
            continue;
        };
        field.optional |= default;
        default = false;
        fields.push(field);
    }
    fields
}

// ----------------------------------------------------------------------- tests

fn sorted(mut signature: Signature) -> Signature {
    signature.sort_by(|left, right| left.json.cmp(&right.json));
    signature
}

fn describe(signature: &Signature) -> String {
    let parts: Vec<String> = signature
        .iter()
        .map(|field| format!("{}{}", field.json, if field.optional { "?" } else { "" }))
        .collect();
    format!("{{{}}}", parts.join(", "))
}

/// Commands the Tauri app registers but the frontend's `Commands` type does not
/// expose. Nothing can call them without a type error, so the dispatcher keeps
/// them for parity; the frontend list cannot be checked against them.
const TS_UNEXPOSED_COMMANDS: &[&str] = &[
    // Registered in commands.rs, wrapped nowhere in src/.
    "preview_rule_change",
];

/// Fields the dispatcher accepts on purpose although the Tauri command has no
/// such parameter: the frontend sends them, Tauri ignores them, and
/// `deny_unknown_fields` would reject the real call. Documented exceptions.
const FRONTEND_ONLY_FIELDS: &[(&str, &str)] = &[
    // `src/queries/hooks.ts` passes `accountId`; `commands.rs::ai_ask` has no
    // such parameter and the core filters citations itself.
    ("ai_ask", "accountId"),
];

#[test]
fn the_dispatcher_accepts_every_tauri_parameter() {
    let tauri = tauri_signatures();
    let dispatcher = dispatcher_signatures();
    assert!(tauri.len() > 100, "parsed only {} commands", tauri.len());

    let mut problems = Vec::new();
    for command in corax_host::COMMANDS {
        let cmd_key = *command;
        let Some(expected) = tauri.get(*command) else {
            problems.push(format!("{command}: not a Tauri command"));
            continue;
        };
        let Some(actual) = dispatcher.get(*command) else {
            problems.push(format!("{command}: no match arm"));
            continue;
        };
        let expected = sorted(expected.clone());
        let actual = sorted(
            actual
                .iter()
                .filter(|field| {
                    !FRONTEND_ONLY_FIELDS
                        .iter()
                        .any(|(command, name)| *command == cmd_key && *name == field.json)
                })
                .cloned()
                .collect(),
        );
        if expected != actual {
            problems.push(format!(
                "{command}: Tauri {}, dispatcher {}",
                describe(&expected),
                describe(&actual)
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "argument shapes drift from src-tauri/src/commands.rs:\n  {}",
        problems.join("\n  ")
    );
}

#[test]
fn the_dispatcher_accepts_every_frontend_argument() {
    let frontend = frontend_signatures();
    let dispatcher = dispatcher_signatures();

    let mut problems = Vec::new();
    for command in corax_host::COMMANDS {
        let Some(expected) = frontend.get(*command) else {
            if !TS_UNEXPOSED_COMMANDS.contains(command) {
                problems.push(format!("{command}: not in src/ipc/types.ts"));
            }
            continue;
        };
        let Some(actual) = dispatcher.get(*command) else {
            problems.push(format!("{command}: no match arm"));
            continue;
        };
        for field in expected {
            match actual.iter().find(|other| other.json == field.json) {
                // A field the frontend always sends may be optional in the
                // dispatcher (serde default) - harmless. The reverse is not:
                // the frontend omits an optional field, and a required
                // dispatcher field would answer `bad_args`.
                Some(other) if !field.optional || other.optional => {}
                Some(_) => problems.push(format!(
                    "{command}.{}: optional in types.ts but required by the dispatcher",
                    field.json
                )),
                None => problems.push(format!(
                    "{command}.{}: the frontend sends it, the dispatcher does not accept it",
                    field.json
                )),
            }
        }
        for field in actual {
            if !expected.iter().any(|other| other.json == field.json) && !field.optional {
                problems.push(format!(
                    "{command}.{}: the dispatcher requires it, the frontend never sends it",
                    field.json
                ));
            }
        }
    }
    assert!(
        problems.is_empty(),
        "argument shapes drift from src/ipc/types.ts:\n  {}",
        problems.join("\n  ")
    );
}

#[test]
fn every_command_appears_in_both_sources() {
    let tauri = tauri_signatures();
    let frontend = frontend_signatures();

    for (name, commands) in [
        ("src-tauri/src/commands.rs", &tauri),
        ("src/ipc/types.ts", &frontend),
    ] {
        for command in corax_host::COMMANDS {
            if name.contains("types.ts") && TS_UNEXPOSED_COMMANDS.contains(command) {
                continue;
            }
            assert!(
                commands.contains_key(*command),
                "{command} is dispatched but missing from {name}"
            );
        }
    }

    // The three window commands are the documented exceptions, not drift.
    for command in corax_host::EXCEPTIONS {
        assert!(
            frontend.contains_key(*command) || *command == "ui_ready",
            "{command} is an exception but unknown to the frontend"
        );
    }
}

#[test]
fn every_argument_struct_rejects_unknown_fields() {
    let source = source("src/dispatch.rs");
    let lines: Vec<&str> = source.lines().collect();
    let mut missing = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if line.trim() != "#[derive(Deserialize)]" {
            continue;
        }
        // The struct-level serde attribute sits between the derive and the
        // struct; a missing `deny_unknown_fields` there re-opens audit H3.
        let next: String = lines[index + 1..(index + 4).min(lines.len())].join("\n");
        let struct_line = next.find("struct ").unwrap_or(next.len());
        if !next[..struct_line].contains("deny_unknown_fields") {
            missing.push((index + 1, lines[index + 1..].first().copied().unwrap_or("")));
        }
    }
    assert!(
        missing.is_empty(),
        "argument structs without deny_unknown_fields: {missing:?}"
    );
}
