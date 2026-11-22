//! `corax-cli` - drive the native host without a UI.
//!
//! ```text
//! corax-cli commands
//! corax-cli invoke list_threads '{"view":"inbox","limit":5}'
//! corax-cli events
//! corax-cli --identifier de.streil.rabe.native.sandbox seed-sandbox [--reset]
//! ```
//!
//! Results go to stdout as JSON; failures to stderr as `{"code","message"}`
//! with a non-zero exit code.
//!
//! `--identifier` is global: it selects the instance for every mode, exactly
//! like `HostConfig::identifier` does for the app.
//!
//! The CLI never starts the native instance (`de.streil.rabe.native`), the
//! real account: `Core::start` starts the scheduler (wakes snoozes, consumes
//! calendar reminders) and the embedding worker even in read-only mode, so
//! there is no side-effect-free host for it. Looking into the data is
//! `sqlite3 -readonly` on the database file, or the app. The sandbox is fully
//! usable; hosts this CLI starts for `invoke` are read-only (no notification
//! dispatcher, no MCP-port rewrite, no settings write).

use std::io::Write;
use std::process::ExitCode;
use std::sync::Arc;

use corax_host::{
    Host, HostConfig, HostDelegate, HostError, NATIVE_IDENTIFIER, UiEvent, seed_sandbox,
};

/// Prints every UI event as one JSON line on stdout.
struct StdoutDelegate;

impl HostDelegate for StdoutDelegate {
    fn open_url(&self, url: String) {
        eprintln!("open_url {url}");
    }

    fn open_path(&self, path: String) {
        eprintln!("open_path {path}");
    }

    fn on_event(&self, event: UiEvent) {
        match serde_json::to_string(&event) {
            Ok(line) => {
                println!("{line}");
                let _ = std::io::stdout().flush();
            }
            Err(error) => eprintln!("cannot serialize event: {error}"),
        }
    }
}

fn usage() {
    eprintln!(
        "usage:\n  corax-cli [--identifier <id>] commands\n  \
         corax-cli --identifier {sandbox} invoke <command> '<json-args>'\n  \
         corax-cli --identifier {sandbox} events\n  \
         corax-cli --identifier {sandbox} seed-sandbox [--reset]\n\n\
         {native} is the real account and is never started from the CLI:\n\
         the core starts its scheduler and embedding worker even in read-only\n\
         mode. For inspection use `sqlite3 -readonly`. Only {sandbox} starts\n\
         a host here. dispatch knows {commands} commands",
        sandbox = corax_host::SANDBOX_IDENTIFIER,
        native = NATIVE_IDENTIFIER,
        commands = corax_host::COMMANDS.len(),
    );
}

/// Arguments after the global options have been taken out.
struct Args {
    identifier: String,
    rest: Vec<String>,
}

/// Split the global options out of argv. They apply to every mode, including
/// `seed-sandbox`.
///
/// The identifier is validated here, before any host is built: only the two
/// exact identifiers exist (audit R1), so a spelling such as
/// `DE.STREIL.RABE.NATIVE` or `x/../comail` is refused instead of resolving to
/// the real account's directory.
fn parse_args(argv: &[String]) -> Result<Args, HostError> {
    let mut identifier = NATIVE_IDENTIFIER.to_string();
    let mut rest = Vec::new();
    let mut iter = argv.iter();
    while let Some(arg) = iter.next() {
        if arg == "--identifier" {
            let value = iter
                .next()
                .ok_or_else(|| HostError::new("bad_usage", "--identifier needs a value"))?;
            identifier = value.clone();
        } else if let Some(value) = arg.strip_prefix("--identifier=") {
            identifier = value.to_string();
        } else if arg == "--reset" {
            // Only `seed-sandbox` reads it; kept as a mode argument.
            rest.push(arg.clone());
        } else if arg.starts_with("--") {
            return Err(HostError::new(
                "bad_usage",
                format!(
                    "unknown option {arg}; corax-cli knows --identifier and, for seed-sandbox, --reset"
                ),
            ));
        } else {
            rest.push(arg.clone());
        }
    }
    if !corax_host::is_allowed_identifier(&identifier) {
        return Err(HostError::new(
            "refused",
            format!(
                "unknown identifier {identifier:?}: only {NATIVE_IDENTIFIER} and {} are allowed",
                corax_host::SANDBOX_IDENTIFIER
            ),
        ));
    }
    Ok(Args { identifier, rest })
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = match parse_args(&argv) {
        Ok(args) => args,
        Err(error) => return fail(&error),
    };
    let rest = &args.rest;

    match rest.first().map(String::as_str) {
        Some("invoke") => invoke(&args, &rest[1..]),
        Some("commands") => {
            for name in corax_host::COMMANDS {
                println!("{name}");
            }
            ExitCode::SUCCESS
        }
        Some("events") => events(&args),
        Some("seed-sandbox") => seed_sandbox_mode(&args.identifier, &rest[1..]),
        Some("-h" | "--help" | "help") => {
            usage();
            ExitCode::SUCCESS
        }
        Some(other) => fail(&HostError::new(
            "bad_usage",
            format!("unknown mode {other}; use invoke, events or seed-sandbox"),
        )),
        None => {
            usage();
            ExitCode::from(2)
        }
    }
}

fn invoke(args: &Args, rest: &[String]) -> ExitCode {
    let (Some(cmd), Some(args_json)) = (rest.first(), rest.get(1)) else {
        usage();
        return ExitCode::from(2);
    };
    if let Err(error) = corax_host::check_cli_identifier(&args.identifier) {
        return fail(&error);
    }

    // `invoke` prints exactly one JSON value on stdout, so nothing else may
    // write there - events go to the delegate only in `events` mode.
    let host = match start_quiet(&args.identifier) {
        Ok(host) => host,
        Err(error) => return fail(&error),
    };

    let result = host.runtime().block_on(host.dispatch(cmd, args_json));
    host.shutdown();

    match result {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(error) => fail(&error),
    }
}

fn events(args: &Args) -> ExitCode {
    if let Err(error) = corax_host::check_cli_identifier(&args.identifier) {
        return fail(&error);
    }
    let host = match start(&args.identifier) {
        Ok(host) => host,
        Err(error) => return fail(&error),
    };

    eprintln!("corax-cli: forwarding ui events to stdout, Ctrl-C to stop");
    host.notify_ui_ready();
    host.runtime().block_on(async {
        let _ = tokio::signal::ctrl_c().await;
    });
    host.shutdown();
    ExitCode::SUCCESS
}

/// Build the mockup mailbox. Refuses anything but the sandbox identifier; the
/// seeder itself never starts the core, so nothing here reaches a server.
fn seed_sandbox_mode(identifier: &str, args: &[String]) -> ExitCode {
    let mut reset = false;
    for arg in args {
        match arg.as_str() {
            "--reset" => reset = true,
            other => {
                return fail(&HostError::new(
                    "bad_usage",
                    format!("unknown option {other}; seed-sandbox knows --reset"),
                ));
            }
        }
    }

    let report = match seed_sandbox(identifier, reset) {
        Ok(report) => report,
        Err(error) => return fail(&error),
    };
    match serde_json::to_string(&report) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(error) => fail(&HostError::new(
            "io",
            format!("cannot serialize the seed report: {error}"),
        )),
    }
}

fn config(identifier: &str, read_only: bool) -> Result<HostConfig, HostError> {
    Ok(HostConfig::new(identifier)?.with_read_only(read_only))
}

/// Interactive mode (sandbox only): the UI event stream needs the forwarder.
fn start(identifier: &str) -> Result<Host, HostError> {
    Host::start(config(identifier, false)?, Arc::new(StdoutDelegate))
}

/// One-shot command: no event forwarder and no notification dispatcher, so a
/// CLI read cannot mark notifications delivered.
fn start_quiet(identifier: &str) -> Result<Host, HostError> {
    Host::start(
        config(identifier, true)?,
        Arc::new(corax_host::NoopDelegate),
    )
}

fn fail(error: &HostError) -> ExitCode {
    eprintln!("{error}");
    ExitCode::FAILURE
}
