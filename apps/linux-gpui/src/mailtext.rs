//! Notnagel und Zulieferer für Text: HTML zu Text mit Auszeichnung.
//!
//! Der Körper einer HTML-Mail läuft in L1 über Blitz (`crate::html_view`).
//! Dieser Konverter bleibt für drei Dinge: den Textkörper einer Mail
//! (`text/plain`) als Zeilen, die Vorschauzeile einer Nachricht, und als
//! Rückfall, wenn Blitz einen Körper nicht zeichnen kann.

use std::ops::Range;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Emphasis {
    Bold,
    Italic,
    Link,
}

#[derive(Clone, Debug, Default)]
pub struct RichText {
    pub text: String,
    pub ranges: Vec<(Range<usize>, Emphasis)>,
}

pub fn to_text(html: &str) -> RichText {
    let mut out = RichText::default();
    let mut stack: Vec<Emphasis> = Vec::new();
    let mut quote_depth = 0usize;
    let mut list_depth = 0usize;
    let mut skip = 0usize; // >0: Inhalt von script/style/head überspringen
    let mut i = 0usize;
    let bytes = html.as_bytes();

    while i < bytes.len() {
        if bytes[i] == b'<' {
            let end = html[i..].find('>').map(|p| i + p).unwrap_or(bytes.len());
            let tag = &html[i + 1..end];
            let closing = tag.starts_with('/');
            let name = tag
                .trim_start_matches('/')
                .split(|c: char| c.is_whitespace() || c == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();

            match name.as_str() {
                "script" | "style" | "head" | "title" => {
                    if closing {
                        skip = skip.saturating_sub(1);
                    } else if !tag.ends_with('/') {
                        skip += 1;
                    }
                }
                "b" | "strong" if skip == 0 => {
                    if closing {
                        pop(&mut stack, Emphasis::Bold);
                    } else {
                        stack.push(Emphasis::Bold);
                    }
                }
                "i" | "em" if skip == 0 => {
                    if closing {
                        pop(&mut stack, Emphasis::Italic);
                    } else {
                        stack.push(Emphasis::Italic);
                    }
                }
                "a" if skip == 0 => {
                    if closing {
                        pop(&mut stack, Emphasis::Link);
                    } else if let Some(href) = attribute(tag, "href") {
                        if !href.starts_with('#') {
                            stack.push(Emphasis::Link);
                        }
                    }
                }
                "blockquote" if skip == 0 => {
                    if closing {
                        quote_depth = quote_depth.saturating_sub(1);
                    } else {
                        quote_depth += 1;
                    }
                    block(&mut out);
                }
                "ul" | "ol" if skip == 0 => {
                    if closing {
                        list_depth = list_depth.saturating_sub(1);
                        block(&mut out);
                    } else {
                        list_depth += 1;
                    }
                }
                "li" if skip == 0 && !closing => {
                    block(&mut out);
                    let indent = "  ".repeat(list_depth.saturating_sub(1));
                    push_text(&mut out, &indent, quote_depth);
                    push_text(&mut out, "• ", quote_depth);
                }
                "br" if skip == 0 => line(&mut out),
                "p" | "div" | "tr" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "table"
                | "header" | "footer" | "section" | "article" | "center"
                    if skip == 0 =>
                {
                    block(&mut out);
                }
                "td" | "th" if skip == 0 => push_text(&mut out, " ", quote_depth),
                "hr" if skip == 0 => {
                    block(&mut out);
                    push_text(&mut out, "————", quote_depth);
                    block(&mut out);
                }
                _ => {}
            }
            i = end + 1;
            continue;
        }

        let next = html[i..].find('<').map(|p| i + p).unwrap_or(bytes.len());
        if skip == 0 {
            let decoded = decode_entities(&html[i..next]);
            let start = out.text.len();
            push_text(&mut out, &decoded, quote_depth);
            let end = out.text.len();
            if let Some(emphasis) = stack.last().copied() {
                mark(&mut out, start..end, emphasis);
            }
        }
        i = next;
    }

    trim(&mut out);
    out
}

fn pop(stack: &mut Vec<Emphasis>, emphasis: Emphasis) {
    if let Some(index) = stack.iter().rposition(|item| *item == emphasis) {
        stack.remove(index);
    }
}

fn mark(out: &mut RichText, range: Range<usize>, emphasis: Emphasis) {
    if range.start >= range.end {
        return;
    }
    if let Some((last, kind)) = out.ranges.last_mut() {
        if *kind == emphasis && last.end == range.start {
            last.end = range.end;
            return;
        }
    }
    out.ranges.push((range, emphasis));
}

/// Text anhängen: Leerraum wird zu einzelnen Leerzeichen, am Zeilenanfang
/// bekommt eine Zitatzeile ihr "> ".
fn push_text(out: &mut RichText, value: &str, quote_depth: usize) {
    for c in value.chars() {
        if c.is_whitespace() {
            if !out.text.is_empty() && !out.text.ends_with(' ') && !out.text.ends_with('\n') {
                out.text.push(' ');
            }
            continue;
        }
        if out.text.is_empty() || out.text.ends_with('\n') {
            for _ in 0..quote_depth {
                out.text.push_str("> ");
            }
        }
        out.text.push(c);
    }
}

fn line(out: &mut RichText) {
    if !out.text.ends_with('\n') {
        out.text.push('\n');
    }
}

fn block(out: &mut RichText) {
    if out.text.is_empty() {
        return;
    }
    if !out.text.ends_with('\n') {
        out.text.push('\n');
    }
    if out.text.ends_with("\n\n") {
        return;
    }
    out.text.push('\n');
}

fn trim(out: &mut RichText) {
    while out.text.ends_with('\n') || out.text.ends_with(' ') {
        out.text.pop();
    }
    let len = out.text.len();
    out.ranges.retain_mut(|(range, _)| {
        range.start = range.start.min(len);
        range.end = range.end.min(len);
        range.start < range.end
    });
}

fn attribute(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut search = 0usize;
    while let Some(found) = lower[search..].find(&format!("{name}=")) {
        let idx = search + found;
        // Wortgrenze: davor muss Leerraum stehen
        if idx == 0 || lower.as_bytes()[idx - 1].is_ascii_whitespace() {
            let rest = tag[idx + name.len() + 1..].trim_start();
            let quote = rest.chars().next()?;
            return if quote == '"' || quote == '\'' {
                let end = rest[1..].find(quote)?;
                Some(rest[1..1 + end].to_string())
            } else {
                Some(rest.split_whitespace().next()?.to_string())
            };
        }
        search = idx + name.len();
    }
    None
}

fn decode_entities(value: &str) -> String {
    if !value.contains('&') {
        return value.to_string();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(pos) = rest.find('&') {
        out.push_str(&rest[..pos]);
        rest = &rest[pos..];
        let Some(end) = rest.find(';').filter(|end| *end <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            "ndash" => Some('–'),
            "mdash" => Some('—'),
            "hellip" => Some('…'),
            "auml" => Some('ä'),
            "ouml" => Some('ö'),
            "uuml" => Some('ü'),
            "Auml" => Some('Ä'),
            "Ouml" => Some('Ö'),
            "Uuml" => Some('Ü'),
            "szlig" => Some('ß'),
            "euro" => Some('€'),
            _ => entity
                .strip_prefix('#')
                .and_then(|num| {
                    if let Some(hex) = num.strip_prefix('x').or_else(|| num.strip_prefix('X')) {
                        u32::from_str_radix(hex, 16).ok()
                    } else {
                        num.parse::<u32>().ok()
                    }
                })
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bold_and_links_survive() {
        let rich = to_text(r#"<p>Hallo <b>Welt</b>, <a href="https://x.test">Link</a></p>"#);
        assert_eq!(rich.text, "Hallo Welt, Link");
        assert!(rich
            .ranges
            .iter()
            .any(|(r, k)| *k == Emphasis::Bold && &rich.text[r.clone()] == "Welt"));
        assert!(rich
            .ranges
            .iter()
            .any(|(r, k)| *k == Emphasis::Link && &rich.text[r.clone()] == "Link"));
    }

    #[test]
    fn lists_and_quotes() {
        let rich = to_text("<ul><li>eins</li><li>zwei</li></ul><blockquote>zitat</blockquote>");
        assert!(rich.text.contains("• eins"), "{}", rich.text);
        assert!(rich.text.contains("> zitat"), "{}", rich.text);
    }

    #[test]
    fn scripts_vanish() {
        let rich = to_text("<p>a</p><script>alert('x')</script><p>b</p>");
        assert!(!rich.text.contains("alert"), "{}", rich.text);
        assert!(rich.text.starts_with('a'), "{}", rich.text);
    }

    #[test]
    fn entities_decode() {
        assert_eq!(to_text("<p>Gr&uuml;&szlig;e &amp; mehr</p>").text, "Grüße & mehr");
    }

    #[test]
    fn whitespace_collapses() {
        assert_eq!(to_text("<p>  viel   Luft  </p>").text, "viel Luft");
    }
}
