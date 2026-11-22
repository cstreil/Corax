//! HTML-Sanitisierung für den Blitz-Körper.
//!
//! Blitz führt kein JavaScript aus, deshalb ist die Frage nicht „Skripte
//! blocken“, sondern „was darf von außen nachladen und was zerlegt die
//! Ansicht“. Diese Datei setzt die Anzeige-Policy durch: erlaubte Elemente und
//! Attribute, erlaubte URL-Schemata, Remote-Bilder je nach Policy und
//! Tracking-Pixel immer.
//!
//! Wichtig für Newsletter: `<style>`-Blöcke und `class`/`style`-Attribute
//! bleiben erhalten. Ohne sie fällt jede Mail, die ihr Layout per Stylesheet
//! setzt, auf unformatierten Text zusammen. Ein Schutz vor `@import` und
//! `url(http…)` ist hier nicht nötig: CSS-Verweise gehen über denselben
//! [`super::Resources`]-Pfad wie Bilder und werden dort nicht aufgelöst.

use std::collections::HashSet;

/// Dürfen Remote-Bilder (http/https) durch?
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RemoteImages {
    /// Standard: entfernen und zählen.
    #[default]
    Blocked,
    /// Nur für diese eine Mail nachgeladen („N externe Bilder blockiert – Laden“).
    Allowed,
}

/// Anzeige-Policy einer Mail.
#[derive(Debug, Clone)]
pub struct Policy {
    pub remote_images: RemoteImages,
    /// Obergrenze gleichzeitig dargestellter Bilder (Rest wird entfernt).
    pub max_images: usize,
    /// Obergrenze für ein einzelnes `data:`-Bild in Bytes.
    pub max_inline_bytes: usize,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            remote_images: RemoteImages::Blocked,
            max_images: 200,
            max_inline_bytes: super::resources::DEFAULT_MAX_INLINE_BYTES,
        }
    }
}

/// Ergebnis der Sanitisierung.
#[derive(Debug, Clone, Default)]
pub struct Sanitized {
    /// Aufgeräumtes HTML-Fragment für den Renderer (ohne `<html>`/`<body>`).
    pub html: String,
    /// Anzahl entfernter Remote-Bilder (für die Hinweiszeile).
    pub blocked_remote: usize,
    /// Was entfernt wurde, je Vorkommen ein Eintrag: `"script"`,
    /// `"event-handler"`, `"javascript-url"`, `"form"`, `"iframe"`,
    /// `"object"`, `"meta-refresh"`, `"base"`, `"link"`, `"tracking-pixel"`,
    /// `"image-limit"`.
    pub removed: Vec<String>,
}

/// Setzt die Policy auf ein Mail-HTML durch.
pub fn sanitize(html: &str, policy: &Policy) -> Sanitized {
    // 1. Was im Roh-HTML steht und gleich verschwindet, für den Bericht zählen.
    let mut removed = scan_removed(html);

    // 2. Allowlist: Elemente, Attribute, URL-Schemata.
    let clean = builder().clean(html).to_string();

    // 3. Bild-Policy: Remote-Bilder je Policy, Tracking-Pixel immer.
    let (html, blocked_remote) = apply_image_policy(&clean, policy, &mut removed);

    Sanitized {
        html,
        blocked_remote,
        removed,
    }
}

/// Ammonia-Voreinstellung für Mail-HTML.
///
/// Grundlage ist derselbe Aufbau wie `comail_core::mime::sanitize_html`: die
/// Mail behält ihr eigenes Stylesheet, weil Ammonia keine ganzen
/// Stylesheets filtern kann — die Grenze ist hier [`super::Resources`], das
/// nichts aus dem Netz holt.
fn builder<'a>() -> ammonia::Builder<'a> {
    let mut builder = ammonia::Builder::default();
    builder
        .add_generic_attributes([
            // `class` + `style` tragen das Layout von Mails, die mit
            // Stylesheet statt Inline-Styles arbeiten. Genau das unterscheidet
            // Blitz von einer Rich-Text-Engine wie der des Qt-Spikes.
            "class",
            "style",
            "align",
            "valign",
            "width",
            "height",
            "border",
            "cellpadding",
            "cellspacing",
            "bgcolor",
            "color",
        ])
        .add_tags([
            "style", "font", "colgroup", "tfoot", "nobr", "strike",
        ])
        // `<title>` ist Dokument-Metadatum; Ammonia würde seinen Text als
        // losen Absatz in den Körper hängen. `style` fehlt absichtlich, weil
        // sein CSS erhalten bleiben muss.
        .clean_content_tags(HashSet::from(["script", "title"]))
        .add_tag_attributes("img", ["src", "alt", "width", "height"])
        .add_tag_attributes("a", ["href", "title"])
        .url_schemes(HashSet::from(["http", "https", "mailto", "cid", "data"]))
        .link_rel(Some("noopener noreferrer"));
    builder
}

/// Entfernt Bilder nach Policy und zählt, was weg ist.
fn apply_image_policy(
    clean: &str,
    policy: &Policy,
    removed: &mut Vec<String>,
) -> (String, usize) {
    let mut out = String::with_capacity(clean.len());
    let mut cursor = 0usize;
    let mut blocked_remote = 0usize;
    let mut kept_images = 0usize;

    for tag in scan_tags(clean) {
        if !tag.name.eq_ignore_ascii_case("img") {
            continue;
        }
        let src = tag.attr("src").unwrap_or("").trim().to_string();
        let remote = crate::html::resources::is_remote(&src);

        let drop = if remote && looks_like_tracking_pixel(&tag) {
            removed.push("tracking-pixel".to_string());
            true
        } else if remote && policy.remote_images == RemoteImages::Blocked {
            blocked_remote += 1;
            true
        } else if is_data_uri(&src) && src.len() > data_uri_limit(policy.max_inline_bytes) {
            // Ein zu großes Inline-Bild würde den Speicher füllen, bevor der
            // Renderer es dekodiert. Gleiche Grenze wie `Resources`.
            removed.push("image-limit".to_string());
            true
        } else if kept_images >= policy.max_images {
            removed.push("image-limit".to_string());
            true
        } else {
            kept_images += 1;
            false
        };

        if drop {
            out.push_str(&clean[cursor..tag.start]);
            cursor = tag.end;
        }
    }
    out.push_str(&clean[cursor..]);
    (out, blocked_remote)
}

/// Ein 1×1-Pixel (oder ein per CSS verstecktes Bild) mit Remote-Quelle ist ein
/// Tracking-Pixel: es dient nur dem Absender als Lebenszeichen.
fn looks_like_tracking_pixel(tag: &Tag) -> bool {
    if tag.attr("width").and_then(parse_pixels).is_some_and(|n| n <= 1)
        || tag.attr("height").and_then(parse_pixels).is_some_and(|n| n <= 1)
    {
        return true;
    }
    let Some(style) = tag.attr("style") else {
        return false;
    };
    for declaration in style.split(';') {
        let Some((name, value)) = declaration.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim().to_ascii_lowercase();
        match name.as_str() {
            "display" if value == "none" => return true,
            "visibility" if value == "hidden" || value == "collapse" => return true,
            "opacity" if value.parse::<f32>() == Ok(0.0) => return true,
            "width" | "height" | "max-width" | "max-height" => {
                if parse_pixels(&value).is_some_and(|n| n <= 1) {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

fn is_data_uri(url: &str) -> bool {
    url.get(..5).is_some_and(|prefix| prefix.eq_ignore_ascii_case("data:"))
}

/// Erlaubte Länge einer `data:`-URI: Base64 bläht um ein Drittel auf, dazu
/// Präfix und mögliche Zeilenumbrüche.
fn data_uri_limit(max_bytes: usize) -> usize {
    max_bytes / 3 * 4 + 256
}

fn parse_pixels(value: &str) -> Option<u32> {
    let value = value.trim().trim_end_matches("px").trim();
    if value.is_empty() {
        return None;
    }
    value.parse::<u32>().ok()
}

/// Zählt, was Ammonia gleich entfernt — nur Kategorien, kein Ersatz für die
/// tatsächliche Filterung.
fn scan_removed(raw: &str) -> Vec<String> {
    let mut removed = Vec::new();
    for tag in scan_tags(raw) {
        let name = tag.name.to_ascii_lowercase();
        match name.as_str() {
            "script" => removed.push("script".to_string()),
            "form" => removed.push("form".to_string()),
            "iframe" => removed.push("iframe".to_string()),
            "object" | "embed" | "applet" => removed.push("object".to_string()),
            "base" => removed.push("base".to_string()),
            "link" => removed.push("link".to_string()),
            "meta" => {
                let refresh = tag
                    .attr("http-equiv")
                    .is_some_and(|value| value.trim().eq_ignore_ascii_case("refresh"));
                if refresh {
                    removed.push("meta-refresh".to_string());
                }
            }
            _ => {}
        }
        for (attr, value) in &tag.attrs {
            let attr_lower = attr.to_ascii_lowercase();
            if attr_lower.starts_with("on") && attr_lower.len() > 2 {
                removed.push("event-handler".to_string());
            }
            if is_javascript_url(value) {
                removed.push("javascript-url".to_string());
            }
        }
    }
    removed
}

/// `javascript:` auch mit eingestreuten Steuerzeichen (`java\tscript:`).
fn is_javascript_url(value: &str) -> bool {
    let mut normalized = String::with_capacity(16);
    for character in value.trim_start().chars() {
        if character.is_control() || character.is_whitespace() {
            continue;
        }
        normalized.extend(character.to_lowercase());
        if normalized.len() >= 11 {
            break;
        }
    }
    normalized.starts_with("javascript:")
}

/// Ein gefundenes Tag mit seinen Attributen (Namen klein, Werte wie im HTML).
struct Tag {
    start: usize,
    end: usize,
    name: String,
    attrs: Vec<(String, String)>,
}

impl Tag {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// Zerlegt HTML in Tags. Kein Parser, sondern nur so viel, wie die
/// Nachfilterung braucht: Kommentare, Doctype und schließende Tags werden
/// übersprungen, Anführungszeichen in Attributwerten respektiert.
fn scan_tags(html: &str) -> Vec<Tag> {
    let bytes = html.as_bytes();
    let mut tags = Vec::new();
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] != b'<' {
            index += 1;
            continue;
        }
        let rest = &html[index..];
        if rest.starts_with("<!--") {
            match rest.find("-->") {
                Some(offset) => index += offset + 3,
                None => break,
            }
            continue;
        }
        if rest.starts_with("<!") || rest.starts_with("<?") || rest.starts_with("</") {
            match rest.find('>') {
                Some(offset) => index += offset + 1,
                None => break,
            }
            continue;
        }
        let mut name_end = 1usize;
        while name_end < rest.len()
            && (rest.as_bytes()[name_end].is_ascii_alphanumeric()
                || rest.as_bytes()[name_end] == b'-'
                || rest.as_bytes()[name_end] == b':')
        {
            name_end += 1;
        }
        if name_end == 1 {
            index += 1;
            continue;
        }
        let name = &rest[1..name_end];
        let mut cursor = name_end;
        let mut quote: Option<u8> = None;
        while cursor < rest.len() {
            let byte = rest.as_bytes()[cursor];
            match quote {
                Some(open) => {
                    if byte == open {
                        quote = None;
                    }
                }
                None => match byte {
                    b'"' | b'\'' => quote = Some(byte),
                    b'>' => break,
                    _ => {}
                },
            }
            cursor += 1;
        }
        let end = if cursor < rest.len() {
            index + cursor + 1
        } else {
            html.len()
        };
        let raw_attrs = rest.get(name_end..cursor).unwrap_or("");
        let name_lower = name.to_ascii_lowercase();
        tags.push(Tag {
            start: index,
            end,
            name: name_lower.clone(),
            attrs: parse_attrs(raw_attrs),
        });
        // In `<style>`/`<script>` steht Text, kein HTML: ein `url(...)` oder
        // ein Beispiel-Tag darin darf nicht als Bild oder Link gelten.
        if name_lower == "style" || name_lower == "script" {
            let weiter = &html[end..];
            let schluss = format!("</{name_lower}");
            index = match weiter.to_ascii_lowercase().find(&schluss) {
                Some(offset) => match weiter[offset..].find('>') {
                    Some(close) => end + offset + close + 1,
                    None => html.len(),
                },
                None => html.len(),
            };
            continue;
        }
        index = end;
    }
    tags
}

fn parse_attrs(raw: &str) -> Vec<(String, String)> {
    let bytes = raw.as_bytes();
    let mut attrs = Vec::new();
    let mut index = 0usize;
    while index < bytes.len() {
        while index < bytes.len() && (bytes[index].is_ascii_whitespace() || bytes[index] == b'/') {
            index += 1;
        }
        if index >= bytes.len() {
            break;
        }
        let name_start = index;
        while index < bytes.len()
            && !bytes[index].is_ascii_whitespace()
            && bytes[index] != b'='
            && bytes[index] != b'/'
            && bytes[index] != b'>'
        {
            index += 1;
        }
        if index == name_start {
            index += 1;
            continue;
        }
        let name = raw[name_start..index].to_ascii_lowercase();
        let mut cursor = index;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor < bytes.len() && bytes[cursor] == b'=' {
            cursor += 1;
            while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            if cursor < bytes.len() && (bytes[cursor] == b'"' || bytes[cursor] == b'\'') {
                let quote = bytes[cursor];
                cursor += 1;
                let value_start = cursor;
                while cursor < bytes.len() && bytes[cursor] != quote {
                    cursor += 1;
                }
                attrs.push((name, raw[value_start..cursor].to_string()));
                index = (cursor + 1).min(bytes.len());
            } else {
                let value_start = cursor;
                while cursor < bytes.len() && !bytes[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                attrs.push((name, raw[value_start..cursor].to_string()));
                index = cursor;
            }
        } else {
            attrs.push((name, String::new()));
            index = cursor;
        }
    }
    attrs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ohne_remote() -> Policy {
        Policy::default()
    }

    #[test]
    fn skripte_und_handler_fliegen_raus() {
        let html = r#"<p onclick="alert(1)">hallo<script>alert(1)</script></p>"#;
        let out = sanitize(html, &ohne_remote());
        assert!(!out.html.contains("script"), "{}", out.html);
        assert!(!out.html.contains("onclick"), "{}", out.html);
        assert!(out.html.contains("hallo"));
        assert_eq!(out.removed.iter().filter(|r| *r == "script").count(), 1);
        assert_eq!(out.removed.iter().filter(|r| *r == "event-handler").count(), 1);
    }

    #[test]
    fn style_und_klassen_bleiben() {
        let html = r#"<style>.a{color:red}</style><p class="a" style="color:blue">x</p>"#;
        let out = sanitize(html, &ohne_remote());
        assert!(out.html.contains(".a{color:red}"), "{}", out.html);
        assert!(out.html.contains(r#"class="a""#), "{}", out.html);
        assert!(out.html.contains("color:blue"), "{}", out.html);
    }

    #[test]
    fn remote_bilder_zaehlen_und_verschwinden() {
        let html = r#"<img src="https://cdn.example/a.png"><img src="cid:b@c">"#;
        let out = sanitize(html, &ohne_remote());
        assert_eq!(out.blocked_remote, 1);
        assert!(!out.html.contains("cdn.example"));
        assert!(out.html.contains("cid:b@c"));
    }

    #[test]
    fn erlaubte_remote_bilder_bleiben() {
        let policy = Policy {
            remote_images: RemoteImages::Allowed,
            ..Policy::default()
        };
        let out = sanitize(r#"<img src="https://cdn.example/a.png">"#, &policy);
        assert_eq!(out.blocked_remote, 0);
        assert!(out.html.contains("https://cdn.example/a.png"));
    }

    #[test]
    fn tracking_pixel_faellt_auch_bei_erlaubten_bildern() {
        let policy = Policy {
            remote_images: RemoteImages::Allowed,
            ..Policy::default()
        };
        let html = r#"<img src="https://t.example/open?x=1" width="1" height="1">"#;
        let out = sanitize(html, &policy);
        assert!(!out.html.contains("t.example"), "{}", out.html);
        assert_eq!(out.removed.iter().filter(|r| *r == "tracking-pixel").count(), 1);
    }

    #[test]
    fn versteckte_bilder_gelten_als_pixel() {
        let policy = Policy {
            remote_images: RemoteImages::Allowed,
            ..Policy::default()
        };
        for style in ["display:none", "visibility: hidden", "opacity:0", "width:0px"] {
            let html = format!(r#"<img src="https://t.example/x.gif" style="{style}">"#);
            let out = sanitize(&html, &policy);
            assert!(
                out.removed.iter().any(|r| r == "tracking-pixel"),
                "style {style} nicht erkannt: {}",
                out.html
            );
        }
    }

    #[test]
    fn lokale_pixel_bleiben() {
        let html = r#"<img src="cid:spacer" width="1" height="1">"#;
        let out = sanitize(html, &ohne_remote());
        assert!(out.html.contains("cid:spacer"));
        assert!(out.removed.is_empty(), "{:?}", out.removed);
    }

    #[test]
    fn forms_object_meta_base_werden_gezaehlt() {
        let html = r##"<html><head><meta http-equiv="refresh" content="0;url=http://e"><base href="http://e"></head><body><form action="http://e"><input name="q"></form><object data="x"></object><iframe src="http://e"></iframe></body></html>"##;
        let out = sanitize(html, &ohne_remote());
        for kind in ["meta-refresh", "base", "form", "object", "iframe"] {
            assert!(
                out.removed.iter().any(|r| r == kind),
                "{kind} fehlt in {:?}",
                out.removed
            );
        }
        assert!(!out.html.contains("<form"));
        assert!(!out.html.contains("<object"));
        assert!(!out.html.contains("<iframe"));
    }

    #[test]
    fn javascript_urls_verschwinden() {
        let html = r#"<a href="javascript:alert(1)">klick</a><a href="java	script:alert(2)">x</a>"#;
        let out = sanitize(html, &ohne_remote());
        assert!(!out.html.contains("javascript:"), "{}", out.html);
        assert!(!out.html.to_ascii_lowercase().contains("script:"));
        assert_eq!(out.removed.iter().filter(|r| *r == "javascript-url").count(), 2);
    }

    #[test]
    fn bildobergrenze_greift() {
        let policy = Policy {
            max_images: 2,
            ..Policy::default()
        };
        let html = r#"<img src="cid:1"><img src="cid:2"><img src="cid:3">"#;
        let out = sanitize(html, &policy);
        assert_eq!(out.html.matches("<img").count(), 2);
        assert_eq!(out.removed.iter().filter(|r| *r == "image-limit").count(), 1);
    }

    #[test]
    fn zu_grosse_inline_bilder_werden_entfernt() {
        let policy = Policy {
            max_inline_bytes: 100, // Grenze ≈ 389 Zeichen im Attribut
            ..Policy::default()
        };
        let gross = format!(r#"<img src="data:image/png;base64,{}">"#, "A".repeat(2000));
        let klein = format!(r#"<img src="data:image/png;base64,{}">"#, "A".repeat(60));
        let out = sanitize(&format!("{gross}{klein}"), &policy);
        assert_eq!(out.html.matches("<img").count(), 1, "{}", out.html);
        assert!(out.html.contains("&quot;") || out.html.contains("data:image/png;base64,AAAA"), "{}", out.html);
        assert_eq!(out.removed.iter().filter(|r| *r == "image-limit").count(), 1);
    }

    #[test]
    fn srcset_und_unbekannte_attribute_bleiben_nicht() {
        let html = r#"<img src="cid:a" srcset="https://e/x.png 2x" onerror="x()">"#;
        let out = sanitize(html, &ohne_remote());
        assert!(!out.html.contains("srcset"), "{}", out.html);
        assert!(!out.html.contains("onerror"));
    }

    #[test]
    fn bilder_in_css_sind_keine_bilder() {
        // Steht ein <img> als Text im Stylesheet, darf er weder entfernt noch
        // gezählt werden.
        let html = r#"<style>.x{content:"<img src=\"https://b\">"}</style><p class="x">ok</p>"#;
        let out = sanitize(html, &Policy::default());
        assert_eq!(out.blocked_remote, 0);
        assert!(out.html.contains("<style>"), "{}", out.html);
        assert!(out.removed.is_empty(), "{:?}", out.removed);
    }

    #[test]
    fn kommentare_zaehlen_nichts() {
        let html = r#"<!-- <script>alert(1)</script> --><p>ok</p>"#;
        let out = sanitize(html, &ohne_remote());
        assert!(out.removed.is_empty(), "{:?}", out.removed);
    }
}
