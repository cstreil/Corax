//! Modified UTF-7 (RFC 3501 §5.1.3): how IMAP4rev1 carries non-ASCII mailbox
//! names on the wire.
//!
//! Printable ASCII passes through unchanged, `&` opens a base64 run of
//! UTF-16BE that `-` closes, and `&-` is a literal `&`. Servers keep using this
//! encoding even when the client never enables `UTF8=ACCEPT` (we don't), so a
//! name read from LIST must be decoded before it is stored or shown, and a name
//! handed back to SELECT/APPEND/COPY/CREATE must be encoded again.
//!
//! Decoding deliberately does not normalize Unicode. A mailbox name is an
//! opaque byte string to the server: iCloud stores `anwälte` decomposed
//! (`a` + U+0308) and answers SELECT with `[NONEXISTENT]` for the composed form.
//! Compose it and the round trip to the wire is no longer byte-exact, so the
//! composed form belongs in the UI layer only (`folderLeafName`), never in the
//! key that goes back to the server.

use base64::Engine;

/// Decode a mailbox name received from the server.
///
/// Malformed runs are kept verbatim instead of dropped: a name we cannot read
/// is still a name we have to SELECT, and silently losing characters would make
/// the folder unreachable.
pub fn decode(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut iter = raw.char_indices();
    while let Some((i, c)) = iter.next() {
        if c != '&' {
            out.push(c);
            continue;
        }
        let rest = &raw[i + 1..];
        let Some(end) = rest.find('-') else {
            // A bare `&` with no terminator is not an encoded run.
            out.push('&');
            continue;
        };
        let segment = &rest[..end];
        // Consume the run's payload and its `-` terminator.
        for _ in 0..end + 1 {
            iter.next();
        }
        if segment.is_empty() {
            out.push('&');
        } else {
            match decode_run(segment) {
                Some(text) => out.push_str(&text),
                None => {
                    out.push('&');
                    out.push_str(segment);
                    out.push('-');
                }
            }
        }
    }
    out
}

/// Encode a mailbox name before sending it to the server.
pub fn encode(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut run = String::new();
    for c in name.chars() {
        if c.is_ascii() && !c.is_ascii_control() {
            if !run.is_empty() {
                flush_run(&mut run, &mut out);
            }
            if c == '&' {
                out.push_str("&-");
            } else {
                out.push(c);
            }
        } else {
            run.push(c);
        }
    }
    if !run.is_empty() {
        flush_run(&mut run, &mut out);
    }
    out
}

/// One `&<base64>-` run of UTF-16BE code units, without the padding base64
/// would add and with `,` in place of `/`.
fn flush_run(run: &mut String, out: &mut String) {
    let mut bytes = Vec::with_capacity(run.len() * 2);
    for unit in run.encode_utf16() {
        bytes.extend_from_slice(&unit.to_be_bytes());
    }
    run.clear();
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    out.push('&');
    out.push_str(&b64.trim_end_matches('=').replace('/', ","));
    out.push('-');
}

fn decode_run(segment: &str) -> Option<String> {
    // mUTF-7 swaps `/` for `,`; accept both rather than reject a name over it.
    let mut b64 = segment.replace(',', "/");
    b64.push_str(&"=".repeat((4 - b64.len() % 4) % 4));
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    if bytes.len() % 2 != 0 {
        return None;
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
        .collect();
    String::from_utf16(&units).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_real_imap_names() {
        // The three shapes actually found in the dev mailbox. iCloud stores its
        // umlauts decomposed, so the decoded text carries U+0308, not U+00E4.
        assert_eq!(decode("Entw&APw-rfe"), "Entwürfe");
        assert_eq!(decode("Gel&APY-schte Elemente"), "Gelöschte Elemente");
        assert_eq!(decode("familie &- wohnung"), "familie & wohnung");
        assert_eq!(decode("finanzen/anwa&Awg-lte"), "finanzen/anwa\u{308}lte");
        assert_eq!(decode("kommerz/ka&Awg-ufe"), "kommerz/ka\u{308}ufe");
    }

    #[test]
    fn plain_ascii_is_identity() {
        assert_eq!(decode("INBOX"), "INBOX");
        assert_eq!(decode("job/offene bewerbungen"), "job/offene bewerbungen");
        assert_eq!(decode(""), "");
    }

    #[test]
    fn keeps_the_servers_code_units_and_round_trips_exactly() {
        // iCloud sends `a` + U+0308; that exact sequence must go back out.
        assert_eq!(decode("a&Awg-"), "a\u{308}");
        assert_eq!(encode("a\u{308}"), "a&Awg-");
        // Composed input stays composed: normalizing here would break SELECT.
        assert_eq!(decode("a&AOQ-"), "aä");
        assert_eq!(encode("aä"), "a&AOQ-");
    }

    #[test]
    fn encode_produces_wire_form() {
        assert_eq!(encode("Entwürfe"), "Entw&APw-rfe");
        assert_eq!(encode("Gelöschte Elemente"), "Gel&APY-schte Elemente");
        assert_eq!(encode("familie & wohnung"), "familie &- wohnung");
        assert_eq!(encode("anwälte"), "anw&AOQ-lte");
        assert_eq!(encode("INBOX"), "INBOX");
    }

    #[test]
    fn encode_escapes_a_literal_ampersand() {
        // Must differ from an untouched ASCII name, or the server reads `&D`
        // as the start of an encoded run.
        assert_eq!(encode("R&D"), "R&-D");
        assert_eq!(decode("R&-D"), "R&D");
    }

    #[test]
    fn round_trips() {
        for name in [
            "Entwürfe",
            "familie & wohnung",
            "kommerz/käufe",
            "Grüße & Küsse",
            "日本語",
            "job/über uns",
        ] {
            assert_eq!(decode(&encode(name)), name, "{name}");
        }
    }

    #[test]
    fn handles_non_bmp_characters() {
        assert_eq!(decode(&encode("Mails 📬")), "Mails 📬");
    }

    #[test]
    fn decode_is_idempotent() {
        for raw in [
            "finanzen/anwa&Awg-lte",
            "familie &- wohnung",
            "Entw&APw-rfe",
        ] {
            let once = decode(raw);
            assert_eq!(decode(&once), once, "{raw}");
        }
    }

    #[test]
    fn malformed_runs_are_kept_verbatim() {
        // Not base64, and no terminator at all: keep what the server sent.
        assert_eq!(decode("a&not base64-b"), "a&not base64-b");
        assert_eq!(decode("a&b"), "a&b");
        assert_eq!(decode("&&-x"), "&&-x");
    }
}
