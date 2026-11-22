//! Integrationstests für `Resources`: Was der Blitz-Anbieter am Ende wirklich
//! bekommt — und was bewusst nicht.

#[path = "../src/html/mod.rs"]
mod html;

use std::sync::Arc;

use html::{Policy, RemoteImages, Resources, sanitize};

/// Sammelt alle `src`-Werte der `<img>`-Tags eines HTML-Schnipsels.
fn bild_quellen(html: &str) -> Vec<String> {
    let mut quellen = Vec::new();
    let mut rest = html;
    while let Some(start) = rest.find("<img") {
        let nach = &rest[start..];
        let ende = nach.find('>').map(|p| p + 1).unwrap_or(nach.len());
        let tag = &nach[..ende];
        if let Some(src_start) = tag.find("src=\"") {
            let wert = &tag[src_start + 5..];
            if let Some(quote) = wert.find('"') {
                quellen.push(entschaerfe(&wert[..quote]));
            }
        }
        rest = &nach[ende..];
    }
    quellen
}

/// Löst HTML-Entities auf: Blitz übergibt dem Anbieter den geparsten Wert,
/// nicht die Schreibweise aus dem Quelltext.
fn entschaerfe(wert: &str) -> String {
    wert.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

#[test]
fn anhaenge_loesen_cid_bilder() {
    let mitarbeiter = Resources::from_attachments(vec![
        ("<logo@corax>".to_string(), "image/png".to_string(), vec![7u8; 120]),
        ("foto-2@corax".to_string(), "image/jpeg".to_string(), vec![3u8; 64]),
    ]);
    let html = r#"<p>x</p><img src="cid:LOGO@corax"><img src="cid:<foto-2@corax>"><img src="cid:fehlt@corax">"#;
    let out = sanitize(html, &Policy::default());
    assert_eq!(out.blocked_remote, 0, "cid: ist kein Remote-Bild");

    let quellen = bild_quellen(&out.html);
    assert_eq!(quellen.len(), 3, "{:?}", quellen);

    let logo = mitarbeiter.resolve(&quellen[0]).expect("Logo aufgelöst");
    assert_eq!(logo.0, "image/png");
    assert_eq!(logo.1.len(), 120);
    let foto = mitarbeiter.resolve(&quellen[1]).expect("Foto aufgelöst");
    assert_eq!(foto.0, "image/jpeg");
    assert!(mitarbeiter.resolve(&quellen[2]).is_none(), "fehlender Anhang bleibt None");
}

#[test]
fn inline_bilder_des_kerns_loesen_ohne_anhaenge() {
    // Der Kern schreibt `cid:` vor der Auslieferung in `data:`-URIs um
    // (comail-core: inline_cid_images). Dann braucht es keine Anhänge.
    let html = r#"<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">"#;
    let out = sanitize(html, &Policy::default());
    let quellen = bild_quellen(&out.html);
    assert_eq!(quellen.len(), 1);
    let ressourcen = Resources::from_attachments(Vec::new());
    let bild = ressourcen.resolve(&quellen[0]).expect("data:-Bild aufgelöst");
    assert_eq!(bild.0, "image/gif");
    assert!(!bild.1.is_empty());
}

#[test]
fn remote_bild_erst_nach_dem_nachladen() {
    let url = "https://cdn.example/bild.png";
    let html = format!(r#"<img src="{url}">"#);

    let blockiert = sanitize(&html, &Policy::default());
    assert_eq!(blockiert.blocked_remote, 1);
    assert!(bild_quellen(&blockiert.html).is_empty(), "blockiert bleibt draußen");

    let policy = Policy {
        remote_images: RemoteImages::Allowed,
        ..Policy::default()
    };
    let erlaubt = sanitize(&html, &policy);
    assert_eq!(erlaubt.blocked_remote, 0);
    let quellen = bild_quellen(&erlaubt.html);
    assert_eq!(quellen, vec![url.to_string()]);

    let ressourcen = Resources::from_attachments(Vec::new());
    assert!(
        ressourcen.resolve(&quellen[0]).is_none(),
        "ohne Nachladen gibt es keine Bytes"
    );
    assert!(ressourcen.insert_remote(&quellen[0], "image/png", vec![1, 2, 3]));
    let bild = ressourcen.resolve(&quellen[0]).expect("nach dem Eintrag da");
    assert_eq!(bild.0, "image/png");
    assert_eq!(&*bild.1, &[1u8, 2, 3]);
}

#[test]
fn zu_grosse_inline_bilder_werden_abgelehnt() {
    let ressourcen = Resources::with_limits(Vec::new(), 8);
    let klein = "data:image/png;base64,AAEC"; // 3 Bytes
    let gross = "data:image/png;base64,AAECAwQFBgcICQ=="; // 10 Bytes
    assert!(ressourcen.resolve(klein).is_some());
    assert!(ressourcen.resolve(gross).is_none(), "über max_inline_bytes");

    let mitarbeiter = Resources::with_limits(Vec::new(), 4);
    assert!(!mitarbeiter.insert_remote("https://x/y.png", "image/png", vec![0u8; 9]));
}

#[test]
fn dateipfade_und_fremde_schemata_bleiben_gesperrt() {
    let ressourcen = Resources::from_attachments(vec![(
        "a".to_string(),
        "image/png".to_string(),
        vec![1],
    )]);
    for url in [
        "file:///etc/passwd",
        "/etc/passwd",
        "../relativ.png",
        "https://ungeladen.example/x.png",
        "data:text/html;base64,PHNjcmlwdD4=",
        "ftp://example.invalid/x.png",
    ] {
        assert!(ressourcen.resolve(url).is_none(), "{url} wurde aufgelöst");
    }
}

#[test]
fn tel_und_mailto_stoeren_nicht() {
    // Links dürfen bleiben; sie werden nicht über Resources aufgelöst.
    let html = r#"<a href="mailto:a@b.de">Mail</a><a href="https://example.org/x">Web</a>"#;
    let out = sanitize(html, &Policy::default());
    assert!(out.html.contains("mailto:a@b.de"));
    assert!(out.html.contains("https://example.org/x"));
    assert_eq!(out.blocked_remote, 0, "Links sind keine Bilder");
}

#[test]
fn gleicher_anhang_teilt_die_bytes() {
    // Zwei Bilder mit derselben cid sollen denselben Arc benutzen, statt die
    // Bytes je Auflösung zu kopieren (10 000-Zeilen-Messung hängt daran).
    let ressourcen = Resources::from_attachments(vec![(
        "logo@x".to_string(),
        "image/png".to_string(),
        vec![9u8; 1024],
    )]);
    let a = ressourcen.resolve("cid:logo@x").expect("a");
    let b = ressourcen.resolve("cid:logo@x").expect("b");
    assert!(Arc::ptr_eq(&a.1, &b.1), "Bytes werden kopiert statt geteilt");
}
