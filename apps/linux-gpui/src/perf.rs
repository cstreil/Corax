//! Messpunkte für die Abnahme (§4.11): Frame-Abstände, Tipp-Latenz, Zeiten
//! einzelner Schritte.
//!
//! Alles landet als eine Zeile auf stderr (`L1-…`), damit ein Messlauf auf
//! Tarantino nur mitgeschnitten werden muss. Im Normalbetrieb kostet das einen
//! Mutex und ein paar Zahlen; Ausgaben entstehen nur bei Messläufen und
//! Fehlern.

use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

/// Startzeit des Prozesses für alle Messprotokolle.
static START: OnceLock<Instant> = OnceLock::new();

pub fn start_uhr() {
    START.set(Instant::now()).ok();
}

pub fn seit_start_us() -> f64 {
    START
        .get()
        .map(|s| s.elapsed().as_secs_f64() * 1e6)
        .unwrap_or(0.0)
}

pub fn seit_start_ms() -> f64 {
    seit_start_us() / 1000.0
}

/// Abstand zwischen zwei gezeichneten Frames in Mikrosekunden.
pub static FRAME_GAPS_US: Mutex<Vec<f64>> = Mutex::new(Vec::new());
static LAST_FRAME: Mutex<Option<Instant>> = Mutex::new(None);
static FIRST_FRAME: AtomicBool = AtomicBool::new(false);
/// Zeitpunkt der letzten Textannahme, die noch nicht gezeichnet ist.
pub static TIPP_ZEIT: Mutex<Option<Instant>> = Mutex::new(None);

/// Wird am Ende jedes gezeichneten Frames aufgerufen (`on_next_frame`).
pub fn frame_mark() {
    let now = Instant::now();
    if let Some(t) = TIPP_ZEIT.lock().unwrap().take() {
        eprintln!("L1-TIPP ms={:.2}", t.elapsed().as_secs_f64() * 1000.0);
    }
    if !FIRST_FRAME.swap(true, Ordering::Relaxed) {
        eprintln!("L1-ERSTER-FRAME ms={:.1}", seit_start_ms());
    }
    let mut last = LAST_FRAME.lock().unwrap();
    if let Some(prev) = *last {
        let gap = now.duration_since(prev).as_secs_f64() * 1_000_000.0;
        let mut gaps = FRAME_GAPS_US.lock().unwrap();
        gaps.push(gap);
        // Bei langen Läufen die älteren Messwerte wegwerfen.
        if gaps.len() > 20000 {
            gaps.drain(0..10000);
        }
    }
    *last = Some(now);
}

/// Ein Schritt von Anfang bis zum nächsten gezeichneten Frame (Öffnen, Suchen …).
pub fn log_marke(name: &str, extra: &str, dauer: std::time::Duration) {
    if extra.is_empty() {
        eprintln!("L1-{name} ms={:.1}", dauer.as_secs_f64() * 1000.0);
    } else {
        eprintln!(
            "L1-{name} ms={:.1} {extra}",
            dauer.as_secs_f64() * 1000.0
        );
    }
}

/// Messfenster zurücksetzen (vor einem Lauf).
pub fn reset_frames() {
    FRAME_GAPS_US.lock().unwrap().clear();
    *LAST_FRAME.lock().unwrap() = None;
}

#[derive(Clone, Copy, Default, Debug)]
pub struct FrameStats {
    pub count: usize,
    pub p50_us: f64,
    pub p95_us: f64,
    pub p99_us: f64,
    pub max_us: f64,
    pub ueber_33ms: usize,
    pub fps_p50: f64,
}

impl FrameStats {
    pub fn zeile(&self) -> String {
        format!(
            "frames={} p50_ms={:.2} p95_ms={:.2} p99_ms={:.2} max_ms={:.2} ueber33ms={} fps_p50={:.1}",
            self.count,
            self.p50_us / 1000.0,
            self.p95_us / 1000.0,
            self.p99_us / 1000.0,
            self.max_us / 1000.0,
            self.ueber_33ms,
            self.fps_p50
        )
    }
}

pub fn frame_stats() -> FrameStats {
    let mut gaps = FRAME_GAPS_US.lock().unwrap().clone();
    if gaps.is_empty() {
        return FrameStats::default();
    }
    gaps.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = gaps.len();
    let at = |q: f64| gaps[((n as f64 * q) as usize).min(n - 1)];
    let p50 = at(0.5);
    FrameStats {
        count: n,
        p50_us: p50,
        p95_us: at(0.95),
        p99_us: at(0.99),
        max_us: *gaps.last().unwrap_or(&0.0),
        ueber_33ms: gaps.iter().filter(|g| **g > 33_000.0).count(),
        fps_p50: if p50 > 0.0 { 1_000_000.0 / p50 } else { 0.0 },
    }
}

/// Ein einzelner Messpunkt mit Namen, für Durchsatz und Latenz.
#[derive(Clone, Debug)]
pub struct Messpunkt {
    pub name: String,
    pub ms: f64,
}

static MESSPUNKTE: Mutex<Vec<Messpunkt>> = Mutex::new(Vec::new());

pub fn note(name: impl Into<String>, ms: f64) {
    MESSPUNKTE.lock().unwrap().push(Messpunkt { name: name.into(), ms });
}

pub fn note_zeilen() -> Vec<String> {
    MESSPUNKTE
        .lock()
        .unwrap()
        .iter()
        .map(|p| format!("{}={:.1}ms", p.name, p.ms))
        .collect()
}
