//! Mail-Körper mit Blitz rendern: HTML + CSS → Bitmap.
//!
//! Blitz ist eine reine Rust-Engine (Servo-Style, Taffy-Layout, Parley-Text). Sie
//! ersetzt die Web-Ansicht: das Ergebnis ist ein Bild, das GPUI als `img` zeigt.
//! Alle Ressourcen (Bilder) kommen über `blitz-net` aus dem Dateisystem, es wird
//! nichts aus dem Netz geladen.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use anyrender::{ImageRenderer as _, PaintScene};
use blitz_traits::net::{Bytes, NetHandler, NetProvider, Request};
use blitz_dom::DocumentConfig;
use blitz_html::HtmlDocument;
use blitz_traits::shell::{ColorScheme, Viewport};

/// Synchroner Netzanbieter: liest nur lokale Dateien, ignoriert alles andere.
///
/// `blitz_net::Provider` verlangt eine Tokio-Laufzeit; für Mails aus dem Dateisystem
/// genügt ein direkter Lesezugriff, und der Ausgang ist deterministisch.
struct DateiQuelle;

impl NetProvider for DateiQuelle {
    fn fetch(&self, _doc_id: usize, request: Request, handler: Box<dyn NetHandler>) {
        let url = request.url.clone();
        if url.scheme() == "file" {
            match url.to_file_path() {
                Ok(pfad) => match std::fs::read(&pfad) {
                    Ok(bytes) => handler.bytes(url.to_string(), Bytes::from(bytes)),
                    Err(e) => eprintln!("BLITZ-QUELLE lesen {}: {e}", pfad.display()),
                },
                Err(()) => eprintln!("BLITZ-QUELLE kein Dateipfad: {url}"),
            }
        } else {
            eprintln!("BLITZ-QUELLE ignoriert (kein Netz): {url}");
        }
    }
}

/// Ergebnis eines Blitz-Laufs.
pub struct Gerendert {
    pub breite: u32,
    pub hoehe: u32,
    /// RGBA8, zeilenweise von oben nach unten.
    pub rgba: Vec<u8>,
    pub ms_layout: f64,
    pub ms_paint: f64,
}

impl Gerendert {
    pub fn als_png(&self) -> Result<Vec<u8>, String> {
        let bild = image::RgbaImage::from_raw(self.breite, self.hoehe, self.rgba.clone())
            .ok_or_else(|| "Puffergröße passt nicht".to_string())?;
        let mut png = Vec::new();
        bild.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .map_err(|e| format!("PNG: {e}"))?;
        Ok(png)
    }
}

/// Rendert eine HTML-Datei in ein Bitmap fester Breite.
///
/// Die Höhe wird in Stufen gesucht: Blitz legt auf die Viewporthöhe aus, deshalb
/// wächst der Viewport, bis der Inhalt hineinpasst (maximal 40 000 px).
pub fn rendere(datei: &Path, breite: u32) -> Result<Gerendert, String> {
    let html = std::fs::read_to_string(datei).map_err(|e| format!("lesen: {e}"))?;
    let pfad = datei
        .canonicalize()
        .map_err(|e| format!("Pfad: {e}"))?;
    let base_url = format!("file://{}", pfad.display());

    let mut doc = HtmlDocument::from_html(
        &html,
        DocumentConfig {
            base_url: Some(base_url),
            net_provider: Some(Arc::new(DateiQuelle) as Arc<dyn NetProvider>),
            viewport: Some(Viewport::new(breite, 1200, 1.0, ColorScheme::Light)),
            ..Default::default()
        },
    );

    let layout_start = Instant::now();
    let mut vh = 1200u32;
    let hoehe;
    loop {
        doc.set_viewport(Viewport::new(breite, vh, 1.0, ColorScheme::Light));
        // Zwei Läufe: der erste stößt die Bilder an, der zweite legt sie ein.
        doc.resolve(0.0);
        doc.resolve(0.0);
        // Der Wurzelknoten hat kein eigenes Layout; gemessen wird <body> (sonst <html>).
        let gemessen = doc
            .query_selector("body")
            .ok()
            .flatten()
            .or_else(|| doc.query_selector("html").ok().flatten())
            .and_then(|id| doc.get_node(id))
            .map(|n| {
                n.final_layout()
                    .size
                    .height
                    .max(n.scrollable_overflow().y1 as f32)
                    .ceil() as u32
            })
            .unwrap_or(0);
        if gemessen + 2 < vh || vh >= 40_000 {
            hoehe = gemessen.clamp(200, 40_000);
            break;
        }
        vh = (vh * 2).min(40_000);
    }

    // Letzter Layoutlauf auf die endgültige Höhe.
    doc.set_viewport(Viewport::new(breite, hoehe, 1.0, ColorScheme::Light));
    doc.resolve(0.0);
    let ms_layout = layout_start.elapsed().as_secs_f64() * 1000.0;

    let start = Instant::now();
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
    let ms_paint = start.elapsed().as_secs_f64() * 1000.0;

    Ok(Gerendert {
        breite,
        hoehe,
        rgba: puffer,
        ms_layout,
        ms_paint,
    })
}
