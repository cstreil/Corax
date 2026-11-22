//! Mail-Körper mit Blitz rendern: HTML + CSS → Bitmap für `gpui::img`.
//!
//! Blitz ist eine reine Rust-Engine (Servo-Style, Taffy-Layout, Parley-Text).
//! Das Ergebnis ist ein Bild, das GPUI ohne Web-Ansicht anzeigt (L-E3).
//!
//! Dieses Modul ist Coder 1s Teil der HTML-Schicht: es entscheidet die
//! Anbindung (§8 des Briefings). Die Sanitisierung (`crate::html::sanitize`)
//! und die Bild-Ressourcen (`crate::html::Resources`) kommen von außen; der
//! Renderer selbst bekommt **keinen** Netzzugriff, sondern fragt nur diesen
//! Anbieter, und der antwortet im Zweifel mit „nichts".

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyrender::{ImageRenderer as _, PaintScene};
use blitz_dom::DocumentConfig;
use blitz_html::HtmlDocument;
use blitz_traits::net::{Bytes, NetHandler, NetProvider, Request};
use blitz_traits::shell::{ColorScheme, Viewport};
use gpui::{Image, ImageFormat};

use crate::html::{Policy, RemoteImages, Resources, Sanitized, sanitize};

/// Rechenbreite einer Mail, wenn der Platz es zulässt (wie die Mac-App mit
/// ihrer 660-pt-Spalte). Schmalere Fenster bekommen weniger.
pub const MAX_KOERPER_BREITE: u32 = 660;
pub const MIN_KOERPER_BREITE: u32 = 360;
/// Obergrenze für einen gerenderten Körper (Blitz rechnet sonst unbegrenzt).
const MAX_HOEHE: u32 = 40_000;

/// Ein fertig gerenderter Mail-Körper.
pub struct Koerper {
    pub bild: Arc<Image>,
    pub breite: u32,
    pub hoehe: u32,
    /// Externe Bilder, die die Policy entfernt hat (Hinweiszeile).
    pub blockiert: usize,
    /// Externe Bilder, die der Renderer gezeichnet hätte, für die aber keine
    /// Bytes vorlagen (http/https, sortiert und doppelfrei). Das ist die
    /// Einkaufsliste für „Laden".
    pub fern: Vec<String>,
    /// Was der Sanitizer entfernt hat, für Statuszeile und Bericht.
    pub entfernt: Vec<String>,
}

/// Bild-Anbieter für Blitz: beantwortet **jede** Anfrage, damit nichts
/// „aussteht". `cid:`/`data:` und nachgeladene Remote-Bilder kommen aus den
/// [`Resources`], relative Pfade nur aus einem ausdrücklich gesetzten
/// Basisordner (Korpus-Mails für die Messung). Alles andere: leere Bytes.
struct Bildquelle {
    resources: Arc<Resources>,
    basis: Option<PathBuf>,
    /// Externe Adressen, die nicht beantwortet werden konnten (für „Laden").
    fern: Arc<Mutex<Vec<String>>>,
    /// Wie viele Bilder tatsächlich mit Bytes beantwortet wurden.
    geliefert: Arc<AtomicUsize>,
}

impl NetProvider for Bildquelle {
    fn fetch(&self, _doc_id: usize, request: Request, handler: Box<dyn NetHandler>) {
        let key = request.url.to_string();
        if let Some((_mime, bytes)) = self.resources.resolve(&key) {
            self.geliefert.fetch_add(1, Ordering::Relaxed);
            handler.bytes(key, Bytes::from(bytes.to_vec()));
            return;
        }
        if let Some(pfad) = self.basis.as_deref().and_then(|basis| datei_unter(basis, &key)) {
            match std::fs::read(&pfad) {
                Ok(bytes) => {
                    self.geliefert.fetch_add(1, Ordering::Relaxed);
                    handler.bytes(key, Bytes::from(bytes));
                    return;
                }
                Err(error) => eprintln!("L1-HTML quelle lesen {}: {error}", pfad.display()),
            }
        }
        // Nichts laden: leer beantworten statt offen lassen. Was von außen
        // käme, wird für „Laden" vorgemerkt.
        if ist_fern(&key)
            && let Ok(mut liste) = self.fern.lock()
        {
            liste.push(key.clone());
        }
        handler.bytes(key, Bytes::from(Vec::new()));
    }
}

/// Nur http(s) ist „fern"; `cid:`, `data:` und `file:` kommen aus den
/// [`Resources`] oder aus dem Basisordner.
fn ist_fern(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

/// `file://…` unterhalb von `basis` — nur für Korpus-/Testmails.
fn datei_unter(basis: &Path, url: &str) -> Option<PathBuf> {
    let rest = url.strip_prefix("file://")?;
    let basis_kanon = basis.canonicalize().ok()?;
    let pfad = PathBuf::from(rest);
    let pfad = if pfad.is_absolute() {
        pfad
    } else {
        basis_kanon.join(pfad)
    };
    let kanon = pfad.canonicalize().ok()?;
    kanon.starts_with(&basis_kanon).then_some(kanon)
}

/// HTML eines Mail-Körpers rendern: sanitisieren und als Bitmap zeichnen.
pub fn rendere_html(
    html: &str,
    breite: u32,
    policy: &Policy,
    resources: Arc<Resources>,
    basis: Option<&Path>,
) -> Result<Koerper, String> {
    let Sanitized { html, blocked_remote, removed } = sanitize(html, policy);
    let mut koerper = rendere_dokument(&html, breite, resources, basis)?;
    koerper.blockiert = blocked_remote;
    koerper.entfernt = removed;
    Ok(koerper)
}

/// Einfacher Textkörper (Mails ohne HTML-Teil) in ein schlichtes Dokument.
/// `schrift` ist die aufgelöste Familie der App (nie ein fontconfig-Alias —
/// sonst bliebe Fett auch hier unsichtbar).
pub fn rendere_text(text: &str, breite: u32, schrift: &str) -> Result<Koerper, String> {
    let html = text_dokument(text, schrift);
    rendere_dokument(&html, breite, Arc::new(Resources::from_attachments(Vec::new())), None)
}

/// Dokument für einen reinen Textkörper: gleiche Schrift wie die Liste,
/// Zeilenumbrüche bleiben stehen.
fn text_dokument(text: &str, schrift: &str) -> String {
    let escaped = escape_html(text);
    let familie = if schrift.contains(' ') {
        format!("\"{schrift}\"")
    } else {
        schrift.to_string()
    };
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>\
         html,body{{margin:0;padding:0;background:#ffffff;}}\
         pre{{white-space:pre-wrap;word-wrap:break-word;margin:0;\
         font:13px/1.55 {familie},sans-serif;color:#1b1b1b;}}\
         </style></head><body><pre>{escaped}</pre></body></html>"
    )
}

fn escape_html(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 16);
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

/// Zeichnet ein HTML-Dokument fester Breite.
pub fn rendere_dokument(
    html: &str,
    breite: u32,
    resources: Arc<Resources>,
    basis: Option<&Path>,
) -> Result<Koerper, String> {
    let breite = breite.clamp(MIN_KOERPER_BREITE, 2048);
    let basis_url = match basis {
        Some(dir) => format!(
            "file://{}/",
            dir.canonicalize()
                .map_err(|error| format!("Basisordner: {error}"))?
                .display()
        ),
        None => "about:blank".to_string(),
    };
    let fern = Arc::new(Mutex::new(Vec::new()));
    let geliefert = Arc::new(AtomicUsize::new(0));
    let net = Arc::new(Bildquelle {
        resources,
        basis: basis.map(Path::to_path_buf),
        fern: Arc::clone(&fern),
        geliefert: Arc::clone(&geliefert),
    }) as Arc<dyn NetProvider>;

    let layout_start = Instant::now();
    let mut doc = HtmlDocument::from_html(
        html,
        DocumentConfig {
            base_url: Some(basis_url),
            net_provider: Some(net),
            viewport: Some(Viewport::new(breite, 1200, 1.0, ColorScheme::Light)),
            ..Default::default()
        },
    );

    // Erster Lauf misst die Höhe; danach genau ein Layoutlauf auf die
    // gemessene Höhe. Der Bild-Anbieter antwortet synchron, deshalb genügt ein
    // Lauf (der Spike löste wegen des Datei-Anbieters zweimal auf: der zweite
    // Lauf kostete bei der langen Mail ~30 ms).
    doc.resolve(0.0);
    // Kein zweiter Layoutlauf: er ändert die Höhe nicht (gemessen: 527 px in
    // beiden Läufen), weil das Bildmaß schon im ersten Lauf in den Kästen steht.
    // Was fehlte, war die Höhenmessung am Rumpf — siehe `messe_hoehe`.
    let gemessen = messe_hoehe(&doc);
    // Kurze Mails nicht aufblähen: ein Einzeiler ist ~50 px hoch, nicht 200.
    let hoehe = gemessen.clamp(24, MAX_HOEHE);
    // Kein zweiter Layoutlauf auf die gemessene Höhe: Blitz legt das Dokument
    // ohnehin vollständig aus (die Viewporthöhe wirkt nur auf `vh`-Werte), und
    // gemalt wird mit der ausdrücklichen Größe. Der zweite Lauf kostete bei der
    // langen Mail ~35 ms — gemessen und im Bericht belegt.
    let ms_layout = layout_start.elapsed().as_secs_f64() * 1000.0;

    let paint_start = Instant::now();
    let mut renderer = anyrender_vello_cpu::VelloCpuImageRenderer::new(breite, hoehe);
    // Weißer Grund: Mails rechnen mit hellem Untergrund, undurchsichtig für GPUI.
    let mut puffer = vec![255u8; breite as usize * hoehe as usize * 4];
    renderer.render(
        |painter| {
            painter.reset();
            blitz_paint::paint_scene(painter, doc.as_mut(), 1.0, breite, hoehe, 0, 0);
        },
        &mut puffer,
    );
    let ms_paint = paint_start.elapsed().as_secs_f64() * 1000.0;

    // Vello zeichnet vormultipliziert und lässt nicht bemalte Flächen
    // durchsichtig. Mails rechnen aber mit Papier: über Weiß zusammensetzen,
    // sonst steht dunkle Schrift auf dunklem Kartenhintergrund.
    auf_weiss_legen(&mut puffer);

    let png_start = Instant::now();
    let bild = image::RgbaImage::from_raw(breite, hoehe, puffer)
        .ok_or_else(|| "Puffergröße passt nicht".to_string())?;
    let mut png = Vec::new();
    bild.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .map_err(|error| format!("PNG: {error}"))?;
    let ms_png = png_start.elapsed().as_secs_f64() * 1000.0;

    eprintln!(
        "L1-BLITZ breite={breite} hoehe={hoehe} bilder={} layout={ms_layout:.1} paint={ms_paint:.1} png={ms_png:.1}",
        geliefert.load(Ordering::Relaxed)
    );

    // Was der Renderer angefragt hat und nicht bekam: sortiert und doppelfrei.
    let mut offen = fern.lock().map(|liste| liste.clone()).unwrap_or_default();
    offen.sort();
    offen.dedup();

    Ok(Koerper {
        bild: Arc::new(Image::from_bytes(ImageFormat::Png, png)),
        breite,
        hoehe,
        blockiert: 0,
        fern: offen,
        entfernt: Vec::new(),
    })
}

/// Vormultipliziertes RGBA über opakem Weiß zusammensetzen.
fn auf_weiss_legen(puffer: &mut [u8]) {
    for pixel in puffer.chunks_exact_mut(4) {
        let alpha = u32::from(pixel[3]);
        if alpha == 255 {
            continue;
        }
        let rest = 255 - alpha;
        for kanal in &mut pixel[..3] {
            *kanal = (u32::from(*kanal) + rest).min(255) as u8;
        }
        pixel[3] = 255;
    }
}

/// Höhe des Inhalts: Unterkante des Rumpfs, mindestens aber die Unterkante des
/// tiefsten Kindes. Bilder ohne eigene Höhenangabe (`height:auto`) ragen sonst
/// über den Rumpf hinaus, weil Blitz dessen Höhe vor dem Bildmaß bestimmt.
fn messe_hoehe(doc: &HtmlDocument) -> u32 {
    let mut rumpf = 0f32;
    for selektor in ["body", "html"] {
        if let Ok(Some(id)) = doc.query_selector(selektor) {
            if let Some(node) = doc.get_node(id) {
                let layout = node.final_layout();
                rumpf = rumpf
                    .max(layout.location.y + layout.size.height)
                    .max(node.scrollable_overflow().y1 as f32);
            }
            break;
        }
    }
    let mut inhalt = 0f32;
    for id in doc.query_selector_all("*").unwrap_or_default() {
        if let Some(node) = doc.get_node(id) {
            let layout = node.final_layout();
            inhalt = inhalt.max(layout.location.y + layout.size.height);
        }
    }
    let unten = if inhalt > rumpf + 0.5 {
        // Dem Kind fehlt der Rand des Rumpfs: etwas Luft nach unten lassen.
        inhalt + 12.0
    } else {
        rumpf
    };
    unten.ceil() as u32
}

/// Policy einer Mail: externe Bilder standardmäßig aus (L-E3).
pub fn policy(remote: RemoteImages) -> Policy {
    Policy { remote_images: remote, ..Policy::default() }
}
