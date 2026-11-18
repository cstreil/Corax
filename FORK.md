# Fork notes

This repository is a fork of [NextOSP/comail](https://github.com/NextOSP/comail), kept for
daily use. Upstream is the product; this fork carries targeted fixes and one UI change on top
of it. Nothing here is a rewrite — the architecture, the crate layout and the build stay the
upstream ones.

## What differs from upstream

**Sync correctness.** Upstream could mark a folder "fully synced" while messages were still
missing: `backfill_done` was set before the UID list had been reconciled against the server.
The folder reconcile now runs before that flag is set, backfills that already finished under
the old build are re-checked once, and a failing reconcile backs off instead of reconnecting on
every tick. Trash recovery gained an identity check (`UIDVALIDITY` plus a stable message
identity) so a message moved in and out of Trash is not restored twice or lost.

**IMAP robustness.** `async-imap` was upgraded 0.11 → 0.12: 0.11 could not parse iCloud's `NIL`
transfer encoding or UTF-8 bytes inside quoted strings, and a partially consumed response then
desynchronised the session for good, so later commands "succeeded" with empty data and folders
were marked done without storing anything. Attachment flags and identity come from BODYSTRUCTURE.
Mailbox names are decoded from modified UTF-7 (RFC 3501) at the IMAP boundary and re-encoded on
the way back, so folders named `anwälte` show and select correctly.

**MIME.** Styled HTML mail keeps `<style>` and `class` (the security boundary is the iframe CSP,
not the sanitizer), lenient Base64 in transfer encodings decodes instead of turning into
replacement characters, and the quoted-printable heuristic only fires on real escape runs —
before, ~1100 messages per start were needlessly re-fetched.

**One inbox by default.** The built-in Important/Other splits are gone unless the user enables
them; labels and rules can still be turned into tabs or splits.

**Inline conversation panel.** Opening a thread expands it inside the list instead of replacing
the list, sized to the conversation up to 75% of the viewport. A "Full view" button keeps the
old full-screen reading mode one click away. Selection is toggled from the left gutter only; the
rest of the row expands and collapses.

**German localization.** `src/i18n/locales/de/` is under construction. The tooling that keeps it
honest is general: `pnpm i18n:status`, and a parity test that refuses to drop placeholders,
inline tags or keys.

## Upstream state

- Based on upstream `d2384cd` (v0.2.41).
- Upstream has moved to v0.2.44 (37 commits). **Not merged yet.**
- Expect conflicts when it is: `src-tauri/crates/comail-core/src/imap/mod.rs` (+460 lines
  upstream), `sync/engine.rs` (+852), `imap/identity.rs`, plus four new keys in
  `src/i18n/locales/en/settings.json` that every other locale then has to add.

The merge is deliberately ordered after the German translation so the translation is not
invalidated halfway through by new source keys.

## Building

Requires Node, pnpm, a Rust toolchain, and the platform prerequisites from
[upstream's development notes](docs/DEVELOPMENT.md).

```sh
pnpm install
pnpm typecheck && pnpm test          # TypeScript
cargo test -p comail-core            # Rust

sh scripts/build-dev-app.sh          # macOS dev bundle: build + sign
```

`build-dev-app.sh` produces `src-tauri/target/release/bundle/macos/Comail Dev.app` with its own
bundle identifier (`com.deanoss.comail.dev`), its own data directory and its own keyring service,
so it runs next to an installed release build. It signs with an available "Apple Development"
identity — a stable signature keeps the keychain grant for stored IMAP credentials across
rebuilds — and it does **not** install the bundle; copy it to `/Applications` yourself.

## Releases

This fork publishes no releases and has no updater feed. The download links in the README point
at upstream.

## Licence

AGPL-3.0-only, unchanged, as required by the upstream licence. Upstream copyright and authorship
stay with [NextOSP/comail](https://github.com/NextOSP/comail); the changes above are additional
work on top of it.
