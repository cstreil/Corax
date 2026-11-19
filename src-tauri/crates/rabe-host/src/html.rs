//! HTML mail for display: the same sandboxed `srcdoc` the Tauri frontend builds
//! in `src/components/thread/MessageCard.tsx` (identical CSP, `no-referrer`,
//! `<base target="_top">`, base styles, trailing-spacer trimming).
//!
//! The email document runs with `default-src 'none'` and no scripts, exactly
//! like in the webview: the app disables page JS, so the dark-mode adaptation
//! below is injected by the host as a user script, not shipped inside the HTML.

use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

/// Colours the email is rendered against. Mirrors the app's CSS variables.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayTheme {
    /// `--text`, e.g. `#222`.
    pub text: String,
    /// `--text-muted`, e.g. `#666`.
    pub text_muted: String,
    /// `--accent`, e.g. `#714cb6`.
    pub accent: String,
    /// `"light"` or `"dark"` (`--iframe-scheme`).
    pub color_scheme: String,
    /// Optional UI font family; the email body uses it first in its stack.
    #[serde(default)]
    pub font_family: Option<String>,
}

impl Default for DisplayTheme {
    fn default() -> Self {
        Self {
            text: "#222".to_string(),
            text_muted: "#666".to_string(),
            accent: "#714cb6".to_string(),
            color_scheme: "light".to_string(),
            font_family: None,
        }
    }
}

const DEFAULT_FONT_STACK: &str =
    "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif";

/// The `srcDoc` template. Placeholders are replaced rather than passed through
/// `format!`, so the CSS keeps its braces and stays readable.
const TEMPLATE: &str = r#"<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src __IMG_SRC____UPGRADE__">
<meta name="referrer" content="no-referrer">
<base target="_top">
<style>
  :root { color-scheme: __SCHEME__; }
  /* height:auto defeats emails whose layout is sized to height:100% - against
     the iframe's short default height those collapse and scrollHeight can't
     measure the real content, leaving the body clipped with an inner scrollbar. */
  html, body { margin: 0; padding: 0; background: transparent; height: auto !important; min-height: 0 !important; }
  body {
    font: 15px/1.6 __FONT__;
    color: __TEXT__; overflow-wrap: break-word;
    /* The app sets a global user-select:none; make email text explicitly
       selectable so the user can copy content (e.g. an OTP) out of it. */
    -webkit-user-select: text; user-select: text;
    /* Contain child margins in a block-formatting context. Otherwise a leading/
       trailing <p> margin collapses through the margin-less body and escapes
       body.scrollHeight, so the frame is measured a margin short and clips the
       content behind an inner scrollbar. flow-root folds those margins back in. */
    display: flow-root;
  }
  /* Theme-consistent defaults for otherwise-unstyled emails. All accents are
     derived from the app's own text/accent via color-mix so they track both
     light and dark; every rule is low-specificity so an email's own CSS wins. */
  a { color: __ACCENT__; text-underline-offset: 2px;
    text-decoration-color: color-mix(in srgb, __ACCENT__ 40%, transparent); }
  a:hover { text-decoration-line: underline; }
  ::selection { background: color-mix(in srgb, __ACCENT__ 24%, transparent); }
  h1, h2, h3, h4, h5, h6 { color: __TEXT__; line-height: 1.3; }
  /* max-width caps an overflowing image; height:auto keeps its aspect ratio
     when that cap shrinks the width. Scope height:auto to imgs that declare a
     width - an unconditional rule overrides a height-only signature logo's
     height="65" attribute, dropping its sizing so it balloons to the image's
     natural width. */
  img { max-width: 100%; }
  img[width] { height: auto; }
  hr { border: 0; height: 1px; background: color-mix(in srgb, __TEXT__ 14%, transparent); margin: 1.25em 0; }
  code, kbd, samp { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 0.9em; background: color-mix(in srgb, __TEXT__ 6%, transparent);
    padding: 0.12em 0.35em; border-radius: 5px; }
  pre { white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    background: color-mix(in srgb, __TEXT__ 4%, transparent); padding: 12px 14px;
    border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; font-size: inherit; }
  blockquote { border-left: 3px solid color-mix(in srgb, __ACCENT__ 45%, transparent);
    margin: 0.8em 0; padding: 2px 0 2px 14px; color: __MUTED__; }
  table { max-width: 100%; }
</style></head><body>__BODY__</body></html>"#;

/// Build the document the UI shows for one message body.
///
/// Identical to `MessageCard.tsx`'s `srcDoc`, including the CSP: remote images
/// are allowed only when `load_remote_images` is on, and then with
/// `upgrade-insecure-requests` because the app runs in a secure context where
/// plain `http:` images would otherwise be blocked as mixed content.
pub fn wrap_for_display(html: &str, theme: &DisplayTheme, load_remote_images: bool) -> String {
    let (img_src, upgrade) = if load_remote_images {
        ("data: cid: http: https:", "; upgrade-insecure-requests")
    } else {
        ("data: cid:", "")
    };

    let font = match theme
        .font_family
        .as_deref()
        .map(sanitize_font)
        .filter(|f| !f.is_empty())
    {
        Some(family) => format!("\"{family}\", {DEFAULT_FONT_STACK}"),
        None => DEFAULT_FONT_STACK.to_string(),
    };

    // Body last: a message must not be able to rewrite our placeholders, and
    // it has to pass the sanitizer even though the core already runs it on
    // ingest (this function is public over the FFI).
    let body = trim_trailing_empty_html(&strip_unsafe_markup(html));
    TEMPLATE
        .replace("__IMG_SRC__", img_src)
        .replace("__UPGRADE__", upgrade)
        .replace("__SCHEME__", &sanitize_token(&theme.color_scheme, "light"))
        .replace("__FONT__", &font)
        .replace("__TEXT__", &sanitize_color(&theme.text, "#222"))
        .replace("__MUTED__", &sanitize_color(&theme.text_muted, "#666"))
        .replace("__ACCENT__", &sanitize_color(&theme.accent, "#714cb6"))
        .replace("__BODY__", &body)
}

/// Remove markup that must never reach the display document.
///
/// The core's own ammonia sanitizer (`comail_core::mime::sanitize_html`, the
/// one that already runs on ingest) does this for real: it parses the body,
/// drops every tag that is not on its allow-list (`script`, `iframe`,
/// `object`, `embed`, `meta`, `base`, `link`, form elements, ...), drops every
/// attribute that is not allowed (all `on*` handlers), removes the *content* of
/// `script` and `title`, and keeps the text a message actually shows.
///
/// The previous hand-written regex layer was neither idempotent nor safe for
/// text: `<scr<script></script>ipt>` left a `<script>` behind,
/// `<img/onerror=…>` survived (the pattern required whitespace before `on`),
/// and `Text onboarding=ja` lost its tail because ` on…=` matched inside prose
/// (audit N-M2). Reusing the core sanitizer removes the second parser instead
/// of fixing it.
pub fn strip_unsafe_markup(html: &str) -> String {
    comail_core::mime::sanitize_html(html)
}

/// Same detection as `MessageCard.tsx`: an `http(s)` `<img src>` or a CSS
/// `background`/`background-image: url(http…)` anywhere in the body.
pub fn has_remote_images(html: &str) -> bool {
    let (img, background) = remote_image_patterns();
    img.is_match(html) || background.is_match(html)
}

fn remote_image_patterns() -> &'static (Regex, Regex) {
    static PATTERNS: OnceLock<(Regex, Regex)> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        (
            Regex::new(r#"(?i)<img\b[^>]*\bsrc\s*=\s*["']?\s*https?:"#).expect("img pattern"),
            Regex::new(r#"(?i)background(?:-image)?\s*[:=][^;"']*url\(\s*["']?\s*https?:"#)
                .expect("background pattern"),
        )
    })
}

/// Drop trailing blank spacers so a one-line reply is not rendered into a tall
/// empty frame. Direct port of `trimTrailingEmptyHtml` in `src/lib/quotes.ts`;
/// JS uses a backreference for the matched tag, which Rust's regex crate cannot
/// express, so the alternative is spelled out once per tag.
pub fn trim_trailing_empty_html(html: &str) -> String {
    let (empty_el, trailing_break, trailing_space) = trim_patterns();
    let mut current = trailing_space.replace(html, "").to_string();
    let mut previous = String::new();
    while current != previous {
        previous = current.clone();
        current = empty_el.replace(&current, "").to_string();
        current = trailing_break.replace(&current, "").to_string();
        current = trailing_space.replace(&current, "").to_string();
    }
    current
}

fn trim_patterns() -> &'static (Regex, Regex, Regex) {
    static PATTERNS: OnceLock<(Regex, Regex, Regex)> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        const TAGS: &[&str] = &[
            "div", "p", "span", "o:p", "font", "center", "b", "i", "u", "em", "strong", "table",
            "tbody", "tr", "td",
        ];
        let tag_group = TAGS.join("|");
        // "Empty" inner content: whitespace, &nbsp;, <br>, and nested
        // open/close of the same structural tags (no text, no <img>).
        let inner =
            format!(r"(?:\s|&nbsp;|&#160;|\x{{00a0}}|<br\s*/?>|</?(?:{tag_group})\b[^>]*>)*");
        let alternatives: Vec<String> = TAGS
            .iter()
            .map(|tag| format!(r"<{tag}\b[^>]*>{inner}</{tag}>"))
            .collect();
        let empty_el = Regex::new(&format!(r"(?i)(?:{})\s*$", alternatives.join("|")))
            .expect("empty element pattern");
        let trailing_break = Regex::new(r"(?i)(?:<br\s*/?>|&nbsp;|&#160;|\x{00a0})\s*$")
            .expect("trailing break pattern");
        let trailing_space = Regex::new(r"\s+$").expect("trailing space pattern");
        (empty_el, trailing_break, trailing_space)
    })
}

/// The dark-mode blend, as a standalone script the host injects into the email
/// document (the document itself runs without scripts). Port of
/// `adaptDocumentForDarkMode` in `src/lib/emailDark.ts`: light surfaces are
/// darkened and dark text is lightened in place, keeping hue and the relative
/// order of shades.
pub fn dark_mode_script() -> &'static str {
    DARK_MODE_SCRIPT
}

const DARK_MODE_SCRIPT: &str = r#"(function () {
  var ctx;
  function parseColor(value) {
    var v = String(value == null ? '' : value).trim();
    if (!v || v === 'transparent' || v === 'inherit' || v === 'initial') return null;
    if (ctx === undefined) {
      var canvas = document.createElement('canvas');
      canvas.width = canvas.height = 1;
      ctx = canvas.getContext('2d', { willReadFrequently: true });
    }
    if (!ctx) return null;
    ctx.fillStyle = '#010203';
    ctx.fillStyle = v;
    if (ctx.fillStyle === '#010203' && !/^#?01/.test(v)) return null;
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillRect(0, 0, 1, 1);
    var d = ctx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3] / 255];
  }
  function luminance(c) { return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255; }
  function toHsl(c) {
    var r = c[0] / 255, g = c[1] / 255, b = c[2] / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var l = (max + min) / 2, d = max - min, h = 0, s = 0;
    if (d > 0) {
      s = d / (1 - Math.abs(2 * l - 1));
      if (max === r) h = ((g - b) / d) % 6;
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h = (h * 60 + 360) % 360;
    }
    return [h, s, l];
  }
  function lightenText(c) {
    var hsl = toHsl(c), h = hsl[0], s = hsl[1], l = hsl[2];
    var newL = s > 0.25 ? 0.72 : Math.max(0.78, 1 - l * 0.5);
    var newS = Math.min(s, 0.85);
    return 'hsl(' + Math.round(h) + ' ' + Math.round(newS * 100) + '% ' + Math.round(newL * 100) + '%)';
  }
  function darkenBackground(c) {
    var hsl = toHsl(c), h = hsl[0], s = hsl[1], l = hsl[2];
    var newL = 0.11 + (l - 0.5) * 0.1;
    var newS = Math.min(s, 0.2);
    return 'hsl(' + Math.round(h) + ' ' + Math.round(newS * 100) + '% ' + Math.round(newL * 100) + '%)';
  }
  function hasDirectText(el) {
    for (var i = 0; i < el.childNodes.length; i++) {
      var node = el.childNodes[i];
      if (node.nodeType === 3 && node.textContent && node.textContent.trim()) return true;
    }
    return false;
  }
  function walk(el, getStyle) {
    var tag = el.tagName;
    if (tag !== 'IMG' && tag !== 'SVG' && tag !== 'CANVAS' && tag !== 'VIDEO') {
      var cs = getStyle(el);
      var bg = parseColor(cs.backgroundColor);
      if (bg && bg[3] >= 0.5 && luminance(bg) > 0.5) {
        el.style.backgroundColor = darkenBackground(bg);
      }
      if (hasDirectText(el)) {
        var col = parseColor(cs.color);
        if (col && luminance(col) < 0.5) {
          el.style.color = lightenText(col);
        }
      }
    }
    for (var j = 0; j < el.children.length; j++) {
      walk(el.children[j], getStyle);
    }
  }
  try {
    var root = document.body;
    if (!root) return;
    var win = root.ownerDocument && root.ownerDocument.defaultView;
    if (!win) return;
    walk(root, function (el) { return win.getComputedStyle(el); });
  } catch (e) {
    // Best-effort: a failed adaptation leaves the email in its original colors.
  }
})();"#;

/// CSS colour values come from settings; keep them from breaking out of the
/// declaration they are placed in.
fn sanitize_color(value: &str, fallback: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 64
        || !trimmed.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '#' | '(' | ')' | ',' | '.' | '%' | ' ' | '-' | '+')
        })
    {
        return fallback.to_string();
    }
    trimmed.to_string()
}

fn sanitize_token(value: &str, fallback: &str) -> String {
    match value.trim() {
        "dark" => "dark".to_string(),
        "light" => "light".to_string(),
        _ => fallback.to_string(),
    }
}

/// A font family is a single name; drop anything that could end the string or
/// the declaration.
fn sanitize_font(value: &str) -> String {
    value
        .chars()
        .filter(|c| {
            !matches!(
                c,
                '"' | '\'' | '\\' | ';' | '{' | '}' | '<' | '>' | '\n' | '\r'
            )
        })
        .take(64)
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn theme() -> DisplayTheme {
        DisplayTheme {
            text: "#e8e8ec".into(),
            text_muted: "#9a9aa4".into(),
            accent: "#7c9cf5".into(),
            color_scheme: "dark".into(),
            font_family: None,
        }
    }

    #[test]
    fn csp_matches_messagecard_without_remote_images() {
        let html = wrap_for_display("<p>Hi</p>", &theme(), false);
        assert!(
            html.contains(
                r#"content="default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:""#
            ),
            "{html}"
        );
        assert!(!html.contains("http:"));
        assert!(!html.contains("upgrade-insecure-requests"));
        assert!(html.contains(r#"<meta name="referrer" content="no-referrer">"#));
        assert!(html.contains(r#"<base target="_top">"#));
    }

    #[test]
    fn csp_matches_messagecard_with_remote_images() {
        let html = wrap_for_display("<p>Hi</p>", &theme(), true);
        assert!(
            html.contains(
                r#"content="default-src 'none'; style-src 'unsafe-inline'; img-src data: cid: http: https:; upgrade-insecure-requests""#
            ),
            "{html}"
        );
    }

    #[test]
    fn theme_colors_and_scheme_reach_the_document() {
        let html = wrap_for_display("<p>Hi</p>", &theme(), false);
        assert!(html.contains("color-scheme: dark"));
        assert!(html.contains("color: #e8e8ec"));
        assert!(html.contains("a { color: #7c9cf5"));
        assert!(html.contains("color: #9a9aa4"));
    }

    #[test]
    fn font_family_is_prepended_and_sanitized() {
        let mut t = theme();
        t.font_family = Some("Inter".into());
        let html = wrap_for_display("<p>Hi</p>", &t, false);
        assert!(
            html.contains("font: 15px/1.6 \"Inter\", ui-sans-serif"),
            "{html}"
        );

        // A hostile family name may keep its words, but it stays quoted and
        // cannot end the declaration: the quotes, brace and semicolon are gone.
        t.font_family = Some("Bad\"}; color: red".into());
        let html = wrap_for_display("<p>Hi</p>", &t, false);
        let font_line = html
            .lines()
            .find(|line| line.contains("font: 15px/1.6"))
            .expect("font line");
        assert_eq!(font_line.matches(';').count(), 1, "{font_line}");
        assert!(!font_line.contains('}'), "{font_line}");
        // The name is always emitted inside quotes, so a stray colon stays a
        // (weird) family name instead of a new declaration.
        assert!(font_line.contains("\"Bad color: red\""), "{font_line}");
    }

    #[test]
    fn remote_image_detection_positive_and_negative() {
        assert!(has_remote_images(r#"<img src="https://x.test/a.png">"#));
        assert!(has_remote_images(r#"<IMG SRC=http://x.test/a.png>"#));
        assert!(has_remote_images(
            r#"<div style="background-image:url('https://x.test/bg.png')">x</div>"#
        ));
        // The HTML `background=` attribute is not covered by MessageCard's
        // regex either - R4 asks for the same detection, so this stays a miss.
        assert!(!has_remote_images(
            r#"<td background="https://x.test/bg.png">x</td>"#
        ));

        assert!(!has_remote_images(
            r#"<img src="data:image/png;base64,AAA">"#
        ));
        assert!(!has_remote_images(r#"<img src="cid:logo">"#));
        assert!(!has_remote_images("<p>no images</p>"));
        assert!(!has_remote_images(r#"<a href="https://x.test">link</a>"#));
    }

    #[test]
    fn trailing_empty_blocks_are_trimmed() {
        assert_eq!(
            trim_trailing_empty_html("<p>RFID band. Xem thử.</p><div><div><br></div></div>"),
            "<p>RFID band. Xem thử.</p>"
        );
        assert_eq!(
            trim_trailing_empty_html("<p>Hi</p><p>&nbsp;</p>\n\n"),
            "<p>Hi</p>"
        );
        assert_eq!(trim_trailing_empty_html("<p>Hi</p>"), "<p>Hi</p>");
        // Only the tail goes; a blank spacer between paragraphs stays.
        assert_eq!(
            trim_trailing_empty_html("<p>a</p><div></div><p>b</p>"),
            "<p>a</p><div></div><p>b</p>"
        );
        // A different tag pair is not "empty": <div><span></span></div> ends in
        // a span, and the div cannot close it.
        assert_eq!(
            trim_trailing_empty_html("<p>a</p><div><img src=\"x\"></div>"),
            "<p>a</p><div><img src=\"x\"></div>"
        );
    }

    /// The `<body>` of a wrapped document, so assertions do not hit the
    /// template's own `<meta>`/`<base>`.
    fn body_of(document: &str) -> &str {
        let start = document.find("<body>").expect("body start") + "<body>".len();
        let end = document.rfind("</body>").expect("body end");
        &document[start..end]
    }

    #[test]
    fn dangerous_markup_is_removed_before_it_reaches_the_document() {
        let cases = [
            "<script>alert(1)</script>",
            "<SCRIPT SRC=\"https://evil.test/x.js\"></SCRIPT>",
            "<meta http-equiv=\"refresh\" content=\"0;url=https://evil.test\">",
            "<base href=\"https://evil.test/\">",
            "<link rel=\"stylesheet\" href=\"https://evil.test/x.css\">",
            "<iframe src=\"https://evil.test\"></iframe>",
            "<object data=\"x.swf\"></object>",
            "<embed src=\"x.swf\">",
        ];
        for case in cases {
            let document =
                wrap_for_display(&format!("<p>keep</p>{case}<p>tail</p>"), &theme(), false);
            let body = body_of(&document).to_lowercase();
            for tag in [
                "<script", "<meta", "<base", "<link", "<iframe", "<object", "<embed",
            ] {
                assert!(!body.contains(tag), "{case} left {tag} in {body}");
            }
            assert!(
                body.contains("<p>keep</p>") && body.contains("<p>tail</p>"),
                "the text around {case} must survive: {body}"
            );
        }

        // An unclosed tag swallows the rest, like a browser would - the point
        // is that no part of it reaches the document as markup.
        for case in ["<script>alert(1)", "<iframe src=\"https://evil.test\">"] {
            let document = wrap_for_display(&format!("<p>keep</p>{case}"), &theme(), false);
            let body = body_of(&document).to_lowercase();
            assert!(
                !body.contains("<script") && !body.contains("<iframe"),
                "{body}"
            );
        }
    }

    #[test]
    fn event_handler_attributes_are_removed_but_benign_ones_survive() {
        for case in [
            r#"<img src="cid:x" onerror="alert(1)">"#,
            r#"<div ONCLICK='alert(1)'>x</div>"#,
            r#"<a href="https://x.test" onmouseover=alert(1)>x</a>"#,
            r#"<body onload="alert(1)">x</body>"#,
        ] {
            let document = wrap_for_display(case, &theme(), false);
            let body = body_of(&document).to_lowercase();
            for handler in ["onerror", "onclick", "onmouseover", "onload"] {
                assert!(!body.contains(handler), "{case} kept {handler} in {body}");
            }
        }

        // Ordinary attributes and formatting stay untouched.
        let document = wrap_for_display(
            r#"<p style="color:red">hi <b>there</b></p><img src="cid:logo">"#,
            &theme(),
            false,
        );
        let body = body_of(&document);
        assert!(body.contains(r#"style="color:red""#), "{body}");
        assert!(body.contains("<b>there</b>"), "{body}");
        assert!(body.contains(r#"<img src="cid:logo">"#), "{body}");
    }

    #[test]
    fn the_sanitizer_is_idempotent_and_keeps_prose_intact() {
        // The cases from the audit (N-M2): each one broke the old regex layer.
        for case in [
            "<scr<script></script>ipt>alert(1)</script>",
            r#"<img/onerror=alert(1) src="cid:x">"#,
            r#"<svg/onload=alert(1)></svg>"#,
            "<p>Text onboarding=ja</p>",
            "<p>keep</p><script>alert(1)</script><p>tail</p>",
        ] {
            let once = strip_unsafe_markup(case);
            let twice = strip_unsafe_markup(&once);
            assert_eq!(once, twice, "not idempotent for {case}: {once:?}");
        }

        // Normal prose that happens to assign something keeps its text - the
        // old pattern ate `onboarding=ja` and the closing tag.
        assert_eq!(
            strip_unsafe_markup("<p>Text onboarding=ja</p>"),
            "<p>Text onboarding=ja</p>"
        );

        // Neither a tag split across a script tag nor a handler without
        // whitespace in front of it reassembles into markup.
        let cleaned = strip_unsafe_markup("<scr<script></script>ipt>alert(1)</script>");
        assert!(!cleaned.to_lowercase().contains("<script"), "{cleaned}");
        let cleaned = strip_unsafe_markup(r#"<img/onerror=alert(1) src="cid:x">"#);
        assert!(!cleaned.to_lowercase().contains("onerror"), "{cleaned}");
    }

    #[test]
    fn dark_mode_script_is_self_contained() {
        let script = dark_mode_script();
        assert!(script.starts_with("(function ()"));
        assert!(script.trim_end().ends_with("})();"));
        assert!(script.contains("getComputedStyle"));
        // No network, no imports: it must run inside the sandboxed document.
        assert!(!script.contains("fetch("));
        assert!(!script.contains("import "));
    }
}
