//! Corax-Spike für Linux/Omarchy in GPUI.
//!
//! Prüffragen aus dem Briefing: Fenster unter Hyprland, Liste mit 10 000
//! Zeilen, Kern im selben Prozess, HTML-Mail als Text mit Auszeichnung,
//! Texteingabe, Einzeltasten-Kürzel, Omarchy-Theme live.
//!
//! Bedienung: j/k oder Pfeile bewegen, Enter/e klappt auf, / springt in die
//! Suche, c öffnet das Verfassen-Feld, Esc verlässt ein Feld.

mod blitzview; mod htmltext; mod mailcore; mod textfield; mod theme;

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Abstand zwischen zwei gezeichneten Frames in Mikrosekunden.
static FRAME_GAPS_US: Mutex<Vec<f64>> = Mutex::new(Vec::new());
/// Startzeit des Prozesses für alle Messprotokolle.
static START: OnceLock<Instant> = OnceLock::new();
/// Zeitstempel jedes Frames (µs seit START), für die Tipp-Latenz.
static FRAME_TS_US: Mutex<Vec<f64>> = Mutex::new(Vec::new());
static FIRST_FRAME: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Zeitpunkt der letzten Textannahme, die noch nicht gezeichnet ist (Tipp-Latenz).
pub static TIPP_ZEIT: Mutex<Option<Instant>> = Mutex::new(None);

fn seit_start_us() -> f64 {
    START.get().map(|s| s.elapsed().as_secs_f64() * 1e6).unwrap_or(0.0)
}
static LAST_FRAME: Mutex<Option<Instant>> = Mutex::new(None);

use gpui::prelude::*;
use gpui::*;

use htmltext::{Emphasis, RichText};
use mailcore::{MailCore, Reply, Request, ThreadRow};
use textfield::TextField;
use theme::Theme;

const SYNTHETIC_ROWS: usize = 10_000;
const ROW_HEIGHT: f32 = 76.0;

struct Row {
    id: Option<i64>,
    from: String,
    subject: String,
    preview: String,
    date: String,
    unread: bool,
    count: i64,
}

struct Detail {
    subject: String,
    rich: RichText,
    note: String,
}

/// Ein mit Blitz gerenderter Mail-Körper, fertig für `img`.
struct MailBild {
    name: String,
    breite: u32,
    hoehe: u32,
    bild: std::sync::Arc<Image>,
    ms_render: f64,
    ms_png: f64,
}

struct Spike {
    theme: Theme,
    core: MailCore,
    synthetic: Vec<Row>,
    core_rows: Vec<Row>,
    selected: usize,
    detail: Option<Detail>,
    search: Entity<TextField>,
    composer: Entity<TextField>,
    composing: bool,
    list: UniformListScrollHandle,
    focus: FocusHandle,
    status: SharedString,
    core_status: SharedString,
    builds: u32,
    build_us_sum: f64,
    build_us_max: f64,
    build_us_last: f64,
    ticks: u32,
    /// Test-Hook: Datei, deren neue Zeilen als Befehle gelesen werden.
    cmd_file: Option<std::path::PathBuf>,
    cmd_pos: u64,
    /// Theme-Anzeige aus `~/.config/omarchy/themes/<name>` statt der Sitzung.
    theme_override: Option<String>,
    /// Noch zu setzender Tastaturfokus (wird beim nächsten Zeichnen angewandt).
    pending_focus: Option<Field>,
    /// Test-Hook `size:BxH`: Fenstergröße ändern.
    pending_size: Option<(f32, f32)>,
    /// Feld, in das `type:` schreibt (vom letzten `search`/`compose`).
    focus_target: Field,
    bench: Option<Bench>,
    /// Gerenderter Mail-Körper (Vergleichs-Spike) mit eigenem Scrollbereich.
    mail: Option<MailBild>,
    mail_scroll: ScrollHandle,
    /// Test-Hook `mailbench:N`: Scrollen im Mail-Körper messen.
    mail_bench: Option<usize>,
}

#[derive(Clone, Copy, PartialEq)]
enum Field {
    Search,
    Composer,
}

struct Bench {
    remaining: usize,
    samples: Vec<f64>,
}

fn synthetic_rows() -> Vec<Row> {
    let senders = [
        "Jana Peters", "iCloud", "GitHub", "Deutsche Bahn", "Mira Sanft",
        "Heise online", "Daniel Roth", "Postbank", "KDE e.V.", "Omarchy",
    ];
    let subjects = [
        "Runde 3 zum Rebranding", "Ihre Rechnung für November",
        "Pull request #482 kommentiert", "Ihre Reise nach Berlin",
        "Wochenplan", "KI-Modelle im Vergleich", "Termin am Donnerstag",
        "Kontoauszug bereit", "Mitgliederversammlung", "Theme-Vorschau",
    ];
    (0..SYNTHETIC_ROWS)
        .map(|i| Row {
            id: None,
            from: senders[i % senders.len()].to_string(),
            subject: format!("{} ({})", subjects[i % subjects.len()], i + 1),
            preview: "Vorschau der Nachricht, zwei Zeilen im Stil der Mac-App mit ruhiger Farbe …".into(),
            date: format!("{:02}.{:02}.", (i % 28) + 1, (i % 12) + 1),
            unread: i % 7 == 0,
            count: ((i % 4) + 1) as i64,
        })
        .collect()
}

impl Spike {
    fn new(cx: &mut Context<Self>) -> Self {
        let theme = Theme::load();
        let core = MailCore::start();
        let search = cx.new(|cx| TextField::new("Suche", false, "Suchen …", theme.clone(), cx));
        let composer = cx.new(|cx| TextField::new("Verfassen", true, "Neue Nachricht …", theme.clone(), cx));
        let focus = cx.focus_handle();
        core.request(Request::Threads);
        let cmd_file = std::env::var("CORAX_SPIKE_CMD").ok().map(std::path::PathBuf::from);
        let theme_override = std::env::var("CORAX_SPIKE_THEME").ok();

        // Kern melden lassen, Theme beobachten
        cx.spawn(async move |this: WeakEntity<Spike>, cx: &mut AsyncApp| loop {
            cx.background_executor().timer(Duration::from_millis(120)).await;
            if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                break;
            }
        })
        .detach();

        Spike {
            theme,
            core,
            synthetic: synthetic_rows(),
            core_rows: Vec::new(),
            selected: 0,
            detail: None,
            search,
            composer,
            composing: false,
            list: UniformListScrollHandle::new(),
            focus,
            status: "bereit".into(),
            core_status: "Kern startet …".into(),
            builds: 0,
            build_us_sum: 0.0,
            build_us_max: 0.0,
            build_us_last: 0.0,
            ticks: 0,
            cmd_file,
            cmd_pos: 0,
            theme_override,
            pending_focus: None,
            pending_size: None,
            focus_target: Field::Search,
            bench: None,
            mail: None,
            mail_scroll: ScrollHandle::new(),
            mail_bench: None,
        }
    }

    fn rows(&self) -> &[Row] {
        if self.core_rows.is_empty() { &self.synthetic } else { &self.core_rows }
    }

    fn tick(&mut self, cx: &mut Context<Self>) {
        self.ticks = self.ticks.wrapping_add(1);
        for reply in self.core.poll() {
            match reply {
                Reply::Threads(rows) => {
                    let synthetic = std::env::var("CORAX_SPIKE_SYNTHETIC").is_ok();
                    if synthetic {
                        self.core_status = format!(
                            "Kern antwortet mit {} Threads, Liste bleibt synthetisch",
                            rows.len()
                        )
                        .into();
                    } else if !rows.is_empty() {
                        self.status = format!("{} Threads aus der Sandbox", rows.len()).into();
                        self.core_rows = rows
                            .into_iter()
                            .map(|row: ThreadRow| Row {
                                id: Some(row.id),
                                from: row.from,
                                subject: row.subject,
                                preview: row.snippet,
                                date: row.date,
                                unread: row.unread,
                                count: row.count,
                            })
                            .collect();
                        self.selected = 0;
                    }
                    cx.notify();
                }
                Reply::Thread { subject, text, html, messages } => {
                    let rich = match html {
                        Some(html) => htmltext::to_text(&html),
                        None => RichText { text, ranges: Vec::new() },
                    };
                    self.detail = Some(Detail {
                        subject,
                        rich,
                        note: format!("{messages} Nachricht(en), HTML zu Text"),
                    });
                    cx.notify();
                }
                Reply::Status(status) => {
                    self.core_status = status.into();
                    cx.notify();
                }
                Reply::Event(event) => {
                    self.status = format!("Ereignis: {event}").into();
                    cx.notify();
                }
                Reply::Error(error) => {
                    self.core_status = format!("Kern-Fehler: {error}").into();
                    cx.notify();
                }
            }
        }

        // Dead Key, der kein Folgezeichen bekommen hat, nach kurzer Zeit einsetzen
        let a = self.search.update(cx, |field, cx| field.flush_dead(cx));
        let b = self.composer.update(cx, |field, cx| field.flush_dead(cx));
        if a || b {
            cx.notify();
        }
        self.poll_commands(cx);

        // Theme-Wechsel live übernehmen (jede Sekunde nachsehen)
        if self.theme_override.is_none() && self.theme.changed() {
            let t = seit_start_us();
            self.theme = Theme::load();
            eprintln!("THEME-WECHSEL t={:.1}ms name={}", t / 1000.0, self.theme.name);
            let theme = self.theme.clone();
            self.search.update(cx, |field, cx| {
                field.theme = theme.clone();
                cx.notify();
            });
            self.composer.update(cx, |field, cx| {
                field.theme = theme.clone();
                cx.notify();
            });
            cx.notify();
        }
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.rows().len();
        if count == 0 {
            return;
        }
        let next = (self.selected as isize + delta).clamp(0, count as isize - 1) as usize;
        self.selected = next;
        self.list.scroll_to_item(next, ScrollStrategy::Center);
        cx.notify();
    }

    fn open_selected(&mut self, cx: &mut Context<Self>) {
        if self.detail.is_some() {
            self.detail = None;
            cx.notify();
            return;
        }
        let Some(row) = self.rows().get(self.selected) else { return };
        match row.id {
            Some(id) => self.core.request(Request::Thread(id)),
            None => {
                // Synthetische Mail: Beispiel-HTML durch den Konverter
                let html = "<h2>Newsletter</h2><p>Hallo Christian, <b>fett</b> und \
                            <i>kursiv</i> mit <a href=\"https://example.test\">Link</a>.</p>\
                            <ul><li>erster Punkt</li><li>zweiter Punkt</li></ul>\
                            <blockquote>Zitat aus der letzten Mail</blockquote>";
                self.detail = Some(Detail {
                    subject: row.subject.clone(),
                    rich: htmltext::to_text(html),
                    note: "synthetische HTML-Mail".into(),
                });
                cx.notify();
            }
        }
    }

    /// Korpus-Mail aus dem Ordner `CORAX_SPIKE_KORPUS` mit Blitz rendern und zeigen.
    ///
    /// Läuft bewusst im UI-Thread: genau so würde es die App auch tun, und der
    /// Vergleich mit Qt soll gleiche Bedingungen haben.
    fn oeffne_korpus(&mut self, nummer: &str, cx: &mut Context<Self>) {
        let ordner = std::env::var("CORAX_SPIKE_KORPUS")
            .unwrap_or_else(|_| format!("{}/korpus", std::env::var("HOME").unwrap_or_default()));
        let dateien = [
            "01-newsletter-shop.html",
            "02-newsletter-welcome.html",
            "03-bilder-galerie.html",
            "04-lange-mail.html",
            "05-transaktionsmail.html",
        ];
        let index: usize = nummer.parse::<usize>().unwrap_or(1).saturating_sub(1);
        let datei = dateien.get(index).copied().unwrap_or(dateien[0]);
        let pfad = std::path::Path::new(&ordner).join(datei);
        // Feste Renderbreite: die Vorlagen haben 570–600 px breite Tabellen.
        let breite = 640u32;

        let start = Instant::now();
        match blitzview::rendere(&pfad, breite) {
            Ok(gerendert) => {
                let ms_render = start.elapsed().as_secs_f64() * 1000.0;
                let t_png = Instant::now();
                match gerendert.als_png() {
                    Ok(png) => {
                        let ms_png = t_png.elapsed().as_secs_f64() * 1000.0;
                        let bild = std::sync::Arc::new(Image::from_bytes(ImageFormat::Png, png));
                        eprintln!(
                            "MAIL-OPEN {} {}x{} blitz_layout={:.1}ms blitz_paint={:.1}ms png={:.1}ms gesamt={:.1}ms",
                            datei, gerendert.breite, gerendert.hoehe,
                            gerendert.ms_layout, gerendert.ms_paint, ms_png,
                            start.elapsed().as_secs_f64() * 1000.0
                        );
                        self.mail = Some(MailBild {
                            name: datei.to_string(),
                            breite: gerendert.breite,
                            hoehe: gerendert.hoehe,
                            bild,
                            ms_render: gerendert.ms_layout + gerendert.ms_paint,
                            ms_png,
                        });
                        self.detail = None;
                        self.mail_scroll = ScrollHandle::new();
                        self.status = format!("Mail {} · {} ms", datei, (gerendert.ms_layout + gerendert.ms_paint + ms_png) as i64).into();
                        cx.notify();
                    }
                    Err(e) => {
                        eprintln!("MAIL-FEHLER png: {e}");
                        self.status = format!("PNG-Fehler: {e}").into();
                        cx.notify();
                    }
                }
            }
            Err(e) => {
                eprintln!("MAIL-FEHLER blitz: {e}");
                self.status = format!("Blitz-Fehler: {e}").into();
                cx.notify();
            }
        }
    }

    fn start_mail_bench(&mut self, schritte: usize, cx: &mut Context<Self>) {
        FRAME_GAPS_US.lock().unwrap().clear();
        *LAST_FRAME.lock().unwrap() = None;
        self.mail_bench = Some(schritte);
        self.status = format!("Mail-Scrollmessung: {schritte} Schritte").into();
        let pro_schritt = self.mail.as_ref().map(|m| (m.hoehe / schritte.max(1) as u32).max(6)).unwrap_or(8);
        cx.spawn(async move |this: WeakEntity<Spike>, cx: &mut AsyncApp| loop {
            cx.background_executor().timer(Duration::from_millis(8)).await;
            let fertig = this
                .update(cx, |this, cx| this.mail_bench_schritt(pro_schritt, cx))
                .unwrap_or(true);
            if fertig {
                break;
            }
        })
        .detach();
        cx.notify();
    }

    fn mail_bench_schritt(&mut self, pro_schritt: u32, cx: &mut Context<Self>) -> bool {
        let Some(rest) = self.mail_bench.as_mut() else { return true };
        if *rest == 0 {
            self.mail_bench = None;
            let mut gaps = FRAME_GAPS_US.lock().unwrap().clone();
            gaps.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let n = gaps.len().max(1);
            let p50 = gaps[n / 2];
            let p95 = gaps[((n as f64 * 0.95) as usize).min(n - 1)];
            let p99 = gaps[((n as f64 * 0.99) as usize).min(n - 1)];
            let ueber33 = gaps.iter().filter(|g| **g > 33_000.0).count();
            let fps = if p50 > 0.0 { 1_000_000.0 / p50 } else { 0.0 };
            eprintln!(
                "MAILBENCH frames={n} p50_us={p50:.0} p95_us={p95:.0} p99_us={p99:.0} ueber33ms={ueber33} fps_p50={fps:.1}"
            );
            self.status = format!("Mail-Scrollmessung: p50 {:.1} ms, {ueber33} über 33 ms", p50 / 1000.0).into();
            cx.notify();
            return true;
        }
        *rest -= 1;
        let hoehe = self.mail.as_ref().map(|m| m.hoehe).unwrap_or(0);
        let aktuell = f32::from(self.mail_scroll.offset().y);
        // Am Ende wieder von vorn, damit die Messung die volle Zeit läuft.
        let neu = if aktuell + pro_schritt as f32 >= hoehe as f32 {
            0.0
        } else {
            aktuell + pro_schritt as f32
        };
        self.mail_scroll.set_offset(point(px(0.), px(neu)));
        cx.notify();
        false
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        eprintln!(
            "KEY key={:?} key_char={:?} ctrl={} alt={} shift={}",
            event.keystroke.key,
            event.keystroke.key_char,
            event.keystroke.modifiers.control,
            event.keystroke.modifiers.alt,
            event.keystroke.modifiers.shift
        );
        let key = event.keystroke.key.as_str();
        let plain = !event.keystroke.modifiers.control
            && !event.keystroke.modifiers.alt
            && !event.keystroke.modifiers.platform;

        let search_focused = self.search.read(cx).is_focused(window);
        let composer_focused = self.composer.read(cx).is_focused(window);

        if key == "escape" {
            if composer_focused || search_focused {
                window.focus(&self.focus);
                cx.notify();
            }
            return;
        }
        // Einzeltasten nur außerhalb von Textfeldern
        if (search_focused || composer_focused) || !plain {
            return;
        }

        match key {
            "j" | "down" => self.move_selection(1, cx),
            "k" | "up" => self.move_selection(-1, cx),
            "enter" | "e" => self.open_selected(cx),
            "/" => {
                window.focus(&self.search.read(cx).focus_handle());
                cx.notify();
            }
            "c" => {
                self.composing = true;
                window.focus(&self.composer.read(cx).focus_handle());
                cx.notify();
            }
            _ => {}
        }
    }

    fn poll_commands(&mut self, cx: &mut Context<Self>) {
        let Some(path) = self.cmd_file.clone() else { return };
        let Ok(meta) = std::fs::metadata(&path) else { return };
        let len = meta.len();
        if len <= self.cmd_pos {
            return;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { return };
        let start = self.cmd_pos as usize;
        let fresh = &text[start.min(text.len())..];
        self.cmd_pos = len;
        for line in fresh.lines() {
            self.run_command(line.trim(), cx);
        }
    }

    fn run_command(&mut self, line: &str, cx: &mut Context<Self>) {
        if line.is_empty() {
            return;
        }
        if line == "dump" {
            let search = self.search.read(cx).text().to_string();
            let composer = self.composer.read(cx).text().to_string();
            let points = |s: &str| {
                s.chars()
                    .map(|c| format!("U+{:04X}", c as u32))
                    .collect::<Vec<_>>()
                    .join(" ")
            };
            eprintln!(
                "DUMP search={:?} chars=[{}] selected={} composer={:?}",
                search,
                points(&search),
                self.selected,
                composer
            );
            return;
        }
        if let Some(rest) = line.strip_prefix("korpus:") {
            self.oeffne_korpus(rest.trim(), cx);
            return;
        }
        if let Some(rest) = line.strip_prefix("mailbench:") {
            let schritte: usize = rest.trim().parse().unwrap_or(200);
            self.start_mail_bench(schritte, cx);
            return;
        }
        if let Some(name) = line.strip_prefix("theme:") {
            self.theme = Theme::load_named(name);
            self.theme_override = Some(name.to_string());
            let theme = self.theme.clone();
            self.search.update(cx, |field, cx| {
                field.theme = theme.clone();
                cx.notify();
            });
            self.composer.update(cx, |field, cx| {
                field.theme = theme.clone();
                cx.notify();
            });
            cx.notify();
            return;
        }
        if let Some(text) = line.strip_prefix("type:") {
            let target = self.focus_target;
            self.insert_text(text, Some(target), cx);
            return;
        }
        if let Some(dims) = line.strip_prefix("size:") {
            if let Some((w, h)) = dims.split_once('x') {
                if let (Ok(w), Ok(h)) = (w.trim().parse::<f32>(), h.trim().parse::<f32>()) {
                    self.pending_size = Some((w, h));
                    cx.notify();
                }
            }
            return;
        }
        if let Some(steps) = line.strip_prefix("bench") {
            let steps = steps
                .strip_prefix(':')
                .and_then(|value| value.parse().ok())
                .unwrap_or(400);
            self.start_bench(steps, cx);
            return;
        }
        match line {
            "j" => self.move_selection(1, cx),
            "k" => self.move_selection(-1, cx),
            "open" => self.open_selected(cx),
            "search" => {
                self.focus_target = Field::Search;
                self.pending_focus = Some(Field::Search);
            }
            "compose" => {
                self.composing = true;
                self.focus_target = Field::Composer;
                self.pending_focus = Some(Field::Composer);
                cx.notify();
            }
            other => {
                self.status = format!("unbekannter Befehl: {other}").into();
                cx.notify();
            }
        }
    }

    fn insert_text(&mut self, text: &str, field: Option<Field>, cx: &mut Context<Self>) {
        match field.unwrap_or(self.focus_target) {
            Field::Search => {
                self.search.update(cx, |field, cx| {
                    field.type_text(text);
                    cx.notify();
                });
            }
            Field::Composer => {
                self.composer.update(cx, |field, cx| {
                    field.type_text(text);
                    cx.notify();
                });
            }
        }
    }

    fn start_bench(&mut self, steps: usize, cx: &mut Context<Self>) {
        FRAME_GAPS_US.lock().unwrap().clear();
        *LAST_FRAME.lock().unwrap() = None;
        self.bench = Some(Bench { remaining: steps, samples: Vec::with_capacity(steps) });
        let log = std::env::var("CORAX_SPIKE_CMD").ok();
        cx.spawn(async move |this: WeakEntity<Spike>, cx: &mut AsyncApp| loop {
            cx.background_executor().timer(Duration::from_millis(8)).await;
            let done = this
                .update(cx, |this, cx| this.bench_step(cx))
                .unwrap_or(true);
            if done {
                break;
            }
        })
        .detach();
        let _ = log;
        self.status = format!("Messlauf: {steps} Schritte").into();
        cx.notify();
    }

    fn bench_step(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(bench) = self.bench.as_mut() else { return true };
        if bench.remaining == 0 {
            let mut samples = bench.samples.clone();
            samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let n = samples.len().max(1);
            let p50 = samples[n / 2];
            let p95 = samples[((n as f64 * 0.95) as usize).min(n - 1)];
            let max = *samples.last().unwrap_or(&0.0);
            let sum: f64 = samples.iter().sum();
            eprintln!(
                "BENCH build frames={n} avg_us={:.0} p50_us={:.0} p95_us={:.0} max_us={:.0}",
                sum / n as f64,
                p50,
                p95,
                max
            );
            let gaps = FRAME_GAPS_US.lock().unwrap();
            let take = gaps.len().min(n);
            if take > 0 {
                let mut recent: Vec<f64> = gaps[gaps.len() - take..].to_vec();
                drop(gaps);
                recent.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                let m = recent.len();
                let g_p50 = recent[m / 2];
                let g_p95 = recent[((m as f64 * 0.95) as usize).min(m - 1)];
                let g_max = *recent.last().unwrap_or(&0.0);
                let g_p99 = recent[((m as f64 * 0.99) as usize).min(m - 1)];
                let g_ueber33 = recent.iter().filter(|g| **g > 33_000.0).count();
                let g_avg: f64 = recent.iter().sum::<f64>() / m as f64;
                eprintln!(
                    "BENCH frame gaps={m} avg_us={g_avg:.0} p50_us={g_p50:.0} p95_us={g_p95:.0} p99_us={g_p99:.0} ueber33ms={g_ueber33} max_us={g_max:.0} fps={:.1}",
                    1_000_000.0 / g_avg
                );
            }
            self.status = format!(
                "Messlauf: {n} Frames, Ø {:.2} ms, p95 {:.2} ms, max {:.2} ms",
                sum / n as f64 / 1000.0,
                p95 / 1000.0,
                max / 1000.0
            )
            .into();
            self.bench = None;
            cx.notify();
            return true;
        }
        bench.remaining -= 1;
        bench.samples.push(self.build_us_last);
        let next = (self.selected + 3) % self.rows().len().max(1);
        self.selected = next;
        self.list.scroll_to_item(next, ScrollStrategy::Top);
        cx.notify();
        false
    }

    fn render_row(&self, index: usize) -> AnyElement {
        let theme = &self.theme;
        let Some(row) = self.rows().get(index) else {
            return div().into_any_element();
        };
        let selected = index == self.selected;
        let background = if selected { mix(theme.selection(), theme.bg(), 0.35) } else { theme.bg() };
        let subject_color = if row.unread { theme.ink1() } else { theme.ink1() };
        let from_color = if row.unread { theme.ink1() } else { theme.ink2() };

        div()
            .id(ElementId::Name(format!("row-{index}").into()))
            .h(px(ROW_HEIGHT))
            .w_full()
            .flex()
            .flex_col()
            .justify_center()
            .px_4()
            .bg(rgb(background))
            .border_b_1()
            .border_color(rgb(theme.line()))
            .when(selected, |this| this.border_l_2().border_color(rgb(theme.accent())))
            .child(
                div()
                    .h(px(22.))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(rgb(from_color))
                            .text_sm()
                            .child(row.from.clone()),
                    )
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_color(rgb(theme.ink3()))
                            .text_xs()
                            .child(row.date.clone()),
                    )
                    .when(row.count > 1, |this| {
                        this.child(
                            div()
                                .flex_shrink_0()
                                .px_1()
                                .rounded_full()
                                .bg(rgb(mix(theme.ink3(), theme.bg(), 0.25)))
                                .text_xs()
                                .text_color(rgb(theme.ink2()))
                                .child(format!("{}", row.count)),
                        )
                    }),
            )
            .child(
                div()
                    .h(px(22.))
                    .w_full()
                    .min_w_0()
                    .truncate()
                    .text_color(rgb(subject_color))
                    .text_sm()
                    .child(row.subject.clone()),
            )
            .child(
                div()
                    .h(px(20.))
                    .w_full()
                    .min_w_0()
                    .truncate()
                    .text_color(rgb(theme.ink3()))
                    .text_xs()
                    .child(row.preview.clone()),
            )
            .into_any_element()
    }
}

impl Render for Spike {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let started = Instant::now();
        let theme = self.theme.clone();
        let row_count = self.rows().len();

        let status = format!(
            "{} · {} Threads · Auswahl {} · Ø Baum {:.2} ms, max {:.2} ms · {}",
            self.theme.name,
            row_count,
            self.selected + 1,
            if self.builds > 0 { self.build_us_sum / self.builds as f64 / 1000.0 } else { 0.0 },
            self.build_us_max / 1000.0,
            self.core_status,
        );

        let list = uniform_list("threads", row_count, cx.processor(
            |this: &mut Spike, range: std::ops::Range<usize>, _window, _cx| {
                range.map(|index| this.render_row(index)).collect::<Vec<_>>()
            },
        ))
        .h_full()
        .track_scroll(self.list.clone());

        // Mail-Körper aus Blitz: eigener Bereich rechts, mit Scrollen.
        let mail_pane = self.mail.as_ref().map(|mail| {
            let b = mail.breite as f32;
            let h = mail.hoehe as f32;
            let kopf = format!(
                "{} · {}×{} · Blitz {:.0} ms + PNG {:.0} ms",
                mail.name, mail.breite, mail.hoehe, mail.ms_render, mail.ms_png
            );
            div()
                .id("mailpane")
                .flex_1()
                .h_full()
                .flex_shrink_0()
                .border_l_1()
                .border_color(rgb(theme.line()))
                .flex()
                .flex_col()
                .overflow_hidden()
                .child(
                    div()
                        .w_full()
                        .px_4()
                        .py_2()
                        .border_b_1()
                        .border_color(rgb(theme.line()))
                        .text_color(rgb(theme.ink3()))
                        .text_xs()
                        .child(kopf),
                )
                .child(
                    div()
                        .id("mailscroll")
                        .flex_1()
                        .w_full()
                        .overflow_y_scroll()
                        .track_scroll(&self.mail_scroll)
                        .child(
                            div().w_full().flex().justify_center().child(
                                img(mail.bild.clone()).w(px(b)).h(px(h)).flex_shrink_0(),
                            ),
                        ),
                )
        });

        let detail = self.detail.as_ref().map(|detail| {
            let style = window.text_style();
            let highlights: Vec<(std::ops::Range<usize>, HighlightStyle)> = detail
                .rich
                .ranges
                .iter()
                .map(|(range, kind)| {
                    let style = match kind {
                        Emphasis::Bold => HighlightStyle {
                            font_weight: Some(FontWeight::BOLD),
                            ..Default::default()
                        },
                        Emphasis::Italic => HighlightStyle {
                            font_style: Some(FontStyle::Italic),
                            ..Default::default()
                        },
                        Emphasis::Link => HighlightStyle {
                            color: Some(rgb(theme.accent()).into()),
                            ..Default::default()
                        },
                        Emphasis::Quote => HighlightStyle {
                            color: Some(rgb(theme.ink3()).into()),
                            ..Default::default()
                        },
                    };
                    (range.clone(), style)
                })
                .collect();
            div()
                .id("detail")
                .flex_1()
                .h_full()
                .flex_shrink_0()
                .border_l_1()
                .border_color(rgb(theme.line()))
                .px_4()
                .py_3()
                .flex()
                .flex_col()
                .gap_2()
                .child(
                    div()
                        .text_color(rgb(theme.ink1()))
                        .text_lg()
                        .child(detail.subject.clone()),
                )
                .child(
                    div().text_color(rgb(theme.ink3())).text_xs().child(detail.note.clone()),
                )
                .child(
                    div()
                        .flex_1()
                        .overflow_hidden()
                        .text_sm()
                        .text_color(rgb(theme.ink2()))
                        .child(
                            StyledText::new(detail.rich.text.clone())
                                .with_default_highlights(&style, highlights),
                        ),
                )
                .when(self.mail.is_some(), |this| {
                    this.child(
                        div()
                            .text_color(rgb(theme.ink3()))
                            .text_xs()
                            .child(self.mail.as_ref().map(|m| m.name.clone()).unwrap_or_default()),
                    )
                })
        });

        if let Some((w, h)) = self.pending_size.take() {
            window.resize(size(px(w), px(h)));
        }

        // Echte Frame-Abstände für die Messung
        window.on_next_frame(|_window, _cx| {
            let now = Instant::now();
            if let Some(t) = TIPP_ZEIT.lock().unwrap().take() {
                eprintln!("TIP-LATENZ {:.2}", t.elapsed().as_secs_f64() * 1000.0);
            }
            {
                let mut ts = FRAME_TS_US.lock().unwrap();
                ts.push(seit_start_us());
                if ts.len() > 20000 {
                    ts.drain(0..10000);
                }
            }
            if FIRST_FRAME.swap(true, std::sync::atomic::Ordering::Relaxed) {
                // erster Frame bereits geloggt
            } else {
                eprintln!("ERSTER-FRAME {:.1} ms", seit_start_us() / 1000.0);
            }
            let mut last = LAST_FRAME.lock().unwrap();
            if let Some(prev) = *last {
                let gap = now.duration_since(prev).as_secs_f64() * 1_000_000.0;
                let mut gaps = FRAME_GAPS_US.lock().unwrap();
                gaps.push(gap);
                if gaps.len() > 4000 {
                    gaps.drain(0..2000);
                }
            }
            *last = Some(now);
        });

        // Fokus aus einem Test-Hook anwenden (braucht das Fenster)
        if let Some(field) = self.pending_focus.take() {
            match field {
                Field::Search => window.focus(&self.search.read(cx).focus_handle()),
                Field::Composer => window.focus(&self.composer.read(cx).focus_handle()),
            }
        }

        self.builds = self.builds.wrapping_add(1);
        let used_us = started.elapsed().as_secs_f64() * 1_000_000.0;
        self.build_us_last = used_us;
        self.build_us_sum += used_us;
        self.build_us_max = self.build_us_max.max(used_us);

        div()
            .id("root")
            .size_full()
            .flex()
            .flex_col()
            .bg(rgb(theme.bg()))
            .text_color(rgb(theme.ink1()))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this: &mut Spike, event: &KeyDownEvent, window, cx| {
                this.on_key(event, window, cx);
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this: &mut Spike, _event: &MouseDownEvent, window, cx| {
                    let in_field = this.search.read(cx).is_focused(window)
                        || this.composer.read(cx).is_focused(window);
                    if !in_field {
                        window.focus(&this.focus);
                    }
                }),
            )
            .child(
                // Kopfzeile
                div()
                    .h(px(52.))
                    .w_full()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_4()
                    .bg(rgb(theme.surface()))
                    .border_b_1()
                    .border_color(rgb(theme.line()))
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(theme.accent()))
                            .child("CORAX"),
                    )
                    .child(div().text_color(rgb(theme.ink1())).text_sm().child("Spike"))
                    .child(div().flex_1())
                    .child(div().text_color(rgb(theme.ink3())).text_xs().child(status)),
            )
            .child(
                // Suche
                div()
                    .px_4()
                    .py_2()
                    .w_full()
                    .bg(rgb(theme.surface()))
                    .border_b_1()
                    .border_color(rgb(theme.line()))
                    .child(self.search.clone()),
            )
            .child(
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .flex_row()
                    .overflow_hidden()
                    .child(div().flex_1().h_full().overflow_hidden().child(list))
                    .children(mail_pane)
                    .children(detail),
            )
            .children(self.composing.then(|| {
                div()
                    .w_full()
                    .px_4()
                    .py_3()
                    .bg(rgb(theme.surface()))
                    .border_t_1()
                    .border_color(rgb(theme.line()))
                    .child(self.composer.clone())
            }))
            .child({
                // Fußzeile mit Kürzeln
                div()
                    .h(px(26.))
                    .w_full()
                    .flex()
                    .items_center()
                    .px_4()
                    .bg(rgb(theme.surface()))
                    .border_t_1()
                    .border_color(rgb(theme.line()))
                    .text_xs()
                    .text_color(rgb(theme.ink3()))
                    .child(self.status.clone())
            })
    }
}


fn main() {
    START.set(Instant::now()).ok();
    // Nacheinander-Modus ohne Fenster: `corax-spike --blitz <datei.html> [breite]`
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 3 && args[1] == "--blitz" {
        let breite: u32 = args.get(3).and_then(|b| b.parse().ok()).unwrap_or(560);
        match blitzview::rendere(std::path::Path::new(&args[2]), breite) {
            Ok(g) => {
                eprintln!(
                    "BLITZ {} {}x{} layout={:.1}ms paint={:.1}ms",
                    args[2], g.breite, g.hoehe, g.ms_layout, g.ms_paint
                );
                match g.als_png() {
                    Ok(png) => {
                        let aus = format!("/tmp/blitz-{}.png", std::path::Path::new(&args[2]).file_stem().unwrap_or_default().to_string_lossy());
                        match std::fs::write(&aus, &png) {
                            Ok(()) => eprintln!("BLITZ-PNG {aus} {} B", png.len()),
                            Err(e) => eprintln!("BLITZ-PNG-FEHLER {e}"),
                        }
                    }
                    Err(e) => eprintln!("BLITZ-PNG-FEHLER {e}"),
                }
            }
            Err(e) => eprintln!("BLITZ-FEHLER {e}"),
        }
        return;
    }

    Application::new().run(|cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1180.), px(780.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions { title: Some("Corax".into()), ..Default::default() }),
                app_id: Some("com.coraxapp.corax".into()),
                ..Default::default()
            },
            |window, cx| {
                // Unter Wayland setzt nur dieser Aufruf den Titel; `titlebar` wirkt nur unter macOS/Windows.
                window.set_window_title("Corax");
                let view = cx.new(Spike::new);
                // Ohne Fokus kommt keine Taste an: on_key_down hängt am Wurzelelement (track_focus).
                let focus = view.read(cx).focus.clone();
                window.focus(&focus);
                view
            },
        )
        .expect("Fenster");
        cx.activate(true);
    });
}

/// Eine Farbe `a` mit Anteil `t` über `b` (für Auswahl und Linien).
fn mix(a: u32, b: u32, t: f32) -> u32 {
    theme::mix(a, b, t)
}
