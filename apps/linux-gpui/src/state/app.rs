//! Der Zustand der Oberfläche — Gegenstück zu `MailboxStore`/`SidebarState` der
//! Mac-App (L-E1).
//!
//! Eine Entity hält alles: Konten, Seitenleiste, Liste, Auswahl, aufgeklappter
//! Thread, Suche und den Kanal zum Kern. Die Ansichten (`ui/*`) rendern daraus
//! und rufen die Methoden hier; es gibt bewusst keine zweite Wahrheit.
//!
//! Arbeitsteilung beim Aufklappen (wie Mac-App): `oeffne_thread` schickt die
//! Anfrage an den Kern, `tick` nimmt die Antwort, baut die Karte (Blitz) und
//! setzt die Zeile in die Liste; erst dann wird gescrollt (Reveal).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use gpui::prelude::*;
use gpui::*;

use crate::core::host::{CoreEvent, MailCore, Reply, Request};
use crate::core::models::{
    Account, ContactVorschlag, FolderInfo, Label, ListThreadsArgs, MailView, SplitRule,
    ThreadDetail, ThreadSummary, UnreadCounts,
};
use crate::editor::ComposeEditor;
use crate::state::compose::{adressen_parsen, ungueltige, Compose, Modus};
use crate::html::RemoteImages;
use crate::input::TextField;
use crate::keys::{self, Action, Ergebnis, Kontext};
use crate::perf;
use crate::theme::Theme;
use crate::ui::auswahl::{Auswahl, Auswahlart, Eintrag};
use crate::ui::dialog::{self, Antwort};
use crate::ui::list::{self, Row};
use crate::ui::snooze;
use crate::ui::thread::{self, Karte};

/// Wie viele Threads je Seite geholt werden (Mac-App: 100).
const SEITENGROESSE: i64 = 100;
/// Ab wie vielen Zeilen vor dem Ende nachgeladen wird.
const NACH_LADEN_AB: usize = 8;
/// Wartezeit, bis `G` verfällt (TASTATUR.md: 2 s).
const GEHEZU_FENSTER: Duration = Duration::from_millis(2000);

/// Feld, das als Nächstes den Fokus bekommen soll (beim nächsten Zeichnen).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fokus {
    Suche,
    Liste,
    /// Eingabefeld für ein eigenes Snooze-Datum.
    Datum,
    /// Textkörper im Verfassen-Dock (der Editor, nicht die Felder).
    Verfassen,
    /// Ein Anhang im Verfassen-Dock (Index); `Entf` entfernt ihn.
    Anhaenge(usize),
}

/// Ein Tab des Posteingangs (eigene Splits). Ohne eigene Splits gibt es keinen
/// Tab-Streifen: der Posteingang ist eine Liste (Entscheidung des Nutzers).
#[derive(Clone, Debug)]
pub struct Tab {
    pub id: String,
    pub titel: String,
    pub split_id: Option<i64>,
    pub unread: i64,
}

/// Ein Lauf für die Abnahme (§4.11): Frames während des Scrollens.
/// Nur der Messbuild startet ihn.
#[allow(dead_code)] // nur der Messbuild startet und liest einen Messlauf
#[derive(Debug, Default)]
pub struct Messlauf {
    pub schritte: usize,
    pub rest: usize,
    pub name: String,
    pub start: Option<Instant>,
}

/// Was nach dem Speichern des Entwurfs passieren soll.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SendeAbsicht {
    Nichts,
    /// Sofort in die Warteschlange.
    Jetzt,
    /// Zu diesem Zeitpunkt (Millisekunden).
    Um(i64),
}

/// Eine Rückfrage, die eine bewusste Bestätigung verlangt. In L2 gibt es nur
/// „endgültig löschen"; die Vorgabe ist immer „Abbrechen".
#[derive(Clone, Debug)]
pub struct Bestaetigung {
    pub text: SharedString,
    pub knopf: SharedString,
    /// Ist der gefährliche Knopf gewählt? Vorgabe: nein.
    pub loeschen: bool,
    /// Kleingedruckte unter den Knöpfen (je Frage unterschiedlich).
    pub hinweis: SharedString,
    pub ziel: BestaetigungZiel,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BestaetigungZiel {
    EndgueltigLoeschen(i64),
    /// Nach A2-Rückfrage trotzdem öffnen (Pfad des Anhangs).
    AnhangOeffnen(String),
}

pub struct AppState {
    // ---- Kern und Theme ----
    pub theme: Theme,
    pub kern: MailCore,
    pub kern_status: SharedString,
    pub fehler: Option<SharedString>,

    // ---- Konten und Navigation ----
    pub accounts: Vec<Account>,
    pub account_id: Option<i64>,
    pub splits: Vec<SplitRule>,
    pub labels: Vec<Label>,
    pub unread: UnreadCounts,
    pub view: MailView,
    pub tab: usize,
    pub label_id: Option<i64>,

    // ---- Liste ----
    pub threads: Vec<ThreadSummary>,
    pub rows: Vec<Row>,
    pub next_cursor: Option<i64>,
    pub generation: u64,
    pub loading: bool,
    pub in_flight: usize,
    pub selected: Option<i64>,
    pub expanded: Option<i64>,
    pub details: HashMap<i64, ThreadDetail>,
    pub karten: HashMap<i64, Karte>,
    /// Threads, für die der Nutzer externe Bilder freigegeben hat (nur diese Mail).
    pub remote_erlaubt: std::collections::HashSet<i64>,
    /// Geteilter Bild-Speicher (Kern liefert `data:`, entfernte Bilder kommen
    /// über „Laden" dazu). Eine Instanz für alle Karten.
    pub bilder: Arc<crate::html::Resources>,
    /// Threads, deren Bilder gerade geholt werden.
    pub bilder_holt: std::collections::HashSet<i64>,
    /// Bilder je Thread, die nicht geholt werden konnten.
    pub bilder_fehler: HashMap<i64, usize>,
    pub list_state: ListState,
    /// Sichtbarer Bereich der Liste, vom Scroll-Handler gefüllt.
    pub sichtbar: Arc<AtomicUsize>,
    pub sichtbar_ende: Arc<AtomicUsize>,
    /// Nur Messbuild: Dauer der letzten Listenantwort.
    #[allow(dead_code)] // im Messbuild geschrieben, nur dort ausgewertet
    pub letzte_liste_ms: f64,

    // ---- Suche ----
    pub suche: Option<String>,
    pub suchfeld: Entity<TextField>,

    // ---- Oberfläche ----
    pub focus: FocusHandle,
    pub hilfe: bool,
    pub seitenleiste: bool,
    pub fenster_breite: f32,
    pub fenster_hoehe: f32,
    pub list_breite: f32,
    pub status: SharedString,
    pub hint: SharedString,
    /// Toast der letzten Aktion („Erledigt · Rückgängig").
    pub toast: Option<crate::ui::toast::Toast>,
    /// Offene Auswahl (Später, Verschieben, Label).
    pub auswahl: Option<Auswahl>,
    /// Eigenes Datum in der „Später"-Auswahl.
    pub datumfeld: Entity<TextField>,
    /// Ordner für „Verschieben …", vom Kern geholt.
    pub folders: Vec<FolderInfo>,
    /// Thread, für den die Ordnerliste gerade unterwegs ist.
    pub ordner_erwartet: Option<i64>,
    /// Offenes Kontextmenü.
    pub kontextmenue: Option<thread::Kontextmenue>,
    /// Offene Rückfrage (endgültig löschen).
    pub bestaetigung: Option<Bestaetigung>,

    // ---- Verfassen ----
    /// Offene Verfassen-Fenster (Dock unten rechts); höchstens eines ist aktiv.
    pub compose: Vec<Compose>,
    /// Welches Fenster die Felder und den Editor gerade hält.
    pub compose_aktiv: Option<u64>,
    /// Der Editor (eine Instanz; beim Wechsel wird der Inhalt getauscht).
    pub editor: Option<Entity<ComposeEditor>>,
    pub feld_an: Entity<TextField>,
    pub feld_cc: Entity<TextField>,
    pub feld_bcc: Entity<TextField>,
    pub feld_betreff: Entity<TextField>,
    /// Cc/Bcc-Zeilen eingeblendet?
    pub cc_bcc: bool,
    /// Kontaktvorschläge zum An-Feld.
    pub vorschlaege: Vec<ContactVorschlag>,
    pub vorschlag_index: usize,
    /// Laeuft gerade eine Vorschlagsanfrage?
    pub vorschlag_laeuft: bool,
    /// Letzter beobachteter Inhalt (An/…/Text): Grundlage fürs Autosave.
    pub compose_stand: Option<String>,
    /// Seit wann der Inhalt unverändert so steht.
    pub compose_stand_seit: Option<Instant>,
    /// Ein Entwurf ist unterwegs: (Fenster, was danach passiert).
    speichert: Option<(u64, SendeAbsicht)>,
    pub naechste_compose_id: u64,
    /// Beim Klick zuletzt im Dock: Einzeltasten bleiben aus.
    pub compose_fokus: bool,
    /// Der Datei-Dialog für Anhänge läuft.
    pub anhaenge_laeuft: bool,
    /// Thread, dessen Entwurf ins Dock geladen werden soll (Ansicht „Entwürfe").
    pub entwurf_wartet: Option<i64>,
    /// Dock soll mit diesem Entwurf geöffnet werden (kommt ohne Fenster an).
    pub pending_dock: Option<Compose>,
    /// Text, der beim nächsten Zeichnen in den Editor soll (Beleg-Hooks).
    pub pending_editor_text: Option<String>,
    /// Letzte Sendung für `cancel_send`: (action_id, Fensterinhalt).
    pub letzte_sendung: Option<(i64, Compose)>,
    /// Absicht der laufenden Einreihung: „jetzt" oder „später"; der Toast
    /// danach richtet sich danach, nicht nach dem Rückgängig-Fenster.
    send_absicht: Option<SendeAbsicht>,
    /// Markierter Anhang im Dock (Tastaturweg: `Tab` hin, `Entf` löscht).
    pub anhang_fokus: Option<usize>,
    pub gehezu_seit: Option<Instant>,
    pub pending_focus: Option<Fokus>,
    /// Nach einem Kernereignis neu laden (entprellt).
    pub neu_laden_um: Option<Instant>,
    /// Ein Öffnen ist unterwegs oder gerade gezeichnet: Startzeit für die Latenz.
    pub offen_seit: Option<(i64, Instant)>,
    /// Gerade gezeichnet: im nächsten Frame die Latenz protokollieren.
    pub offen_marke: Option<(i64, String, Instant)>,
    /// Die Liste war schon einmal im Bild (Kaltstart-Messung).
    pub liste_gesehen: bool,
    pub ui_ready_gesendet: bool,

    // ---- Messläufe / Test-Hooks ----
    pub messlauf: Option<Messlauf>,
    pub synthetisch: Option<Vec<ThreadSummary>>,

    /// Basisordner für relative Bilder (nur mit `test-hooks`, Korpus-Mails).
    pub korpus: Option<PathBuf>,
    /// Ein von Hand gewähltes Theme (Test-Hook): dann nicht der Sitzung folgen.
    pub theme_override: Option<String>,
    /// Stand der Befehlsdatei (Test-Hooks).
    /// Nur Messbuild: Leseposition in der Hook-Datei.
    #[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
    pub hook_pos: u64,
    /// Fenstergröße aus einem Test-Hook, beim nächsten Zeichnen angewandt.
    pub pending_size: Option<(f32, f32)>,
}

impl AppState {
    pub fn new(ident: &str, cx: &mut Context<Self>) -> Self {
        let theme = Theme::load();
        let kern = MailCore::start(ident);
        let suchfeld = cx.new(|cx| TextField::new("Suche", false, "Suchen …", theme.clone(), cx));
        let datumfeld =
            cx.new(|cx| TextField::new("Eigenes Datum", false, "morgen 9:00", theme.clone(), cx));
        let feld_an = cx.new(|cx| TextField::new("An", false, "name@example.com", theme.clone(), cx));
        let feld_cc = cx.new(|cx| TextField::new("Cc", false, "Cc", theme.clone(), cx));
        let feld_bcc = cx.new(|cx| TextField::new("Bcc", false, "Bcc", theme.clone(), cx));
        let feld_betreff = cx.new(|cx| TextField::new("Betreff", false, "Betreff", theme.clone(), cx));
        let focus = cx.focus_handle();
        let sichtbar = Arc::new(AtomicUsize::new(0));
        let sichtbar_ende = Arc::new(AtomicUsize::new(0));

        let mut state = AppState {
            theme,
            kern,
            kern_status: "Kern startet …".into(),
            fehler: None,
            accounts: Vec::new(),
            account_id: None,
            splits: Vec::new(),
            labels: Vec::new(),
            unread: UnreadCounts::default(),
            view: MailView::Inbox,
            tab: 0,
            label_id: None,
            threads: Vec::new(),
            rows: Vec::new(),
            next_cursor: None,
            generation: 0,
            loading: false,
            in_flight: 0,
            selected: None,
            expanded: None,
            details: HashMap::new(),
            karten: HashMap::new(),
            remote_erlaubt: Default::default(),
            bilder: Arc::new(crate::html::Resources::from_attachments(Vec::new())),
            bilder_holt: Default::default(),
            bilder_fehler: HashMap::new(),
            list_state: ListState::new(0, ListAlignment::Top, px(600.)),
            sichtbar: sichtbar.clone(),
            sichtbar_ende,
            letzte_liste_ms: 0.0,
            suche: None,
            suchfeld,
            focus,
            hilfe: false,
            seitenleiste: true,
            fenster_breite: 1180.0,
            fenster_hoehe: 820.0,
            list_breite: 800.0,
            status: "bereit".into(),
            hint: SharedString::default(),
            toast: None,
            auswahl: None,
            datumfeld,
            folders: Vec::new(),
            ordner_erwartet: None,
            kontextmenue: None,
            bestaetigung: None,
            compose: Vec::new(),
            compose_aktiv: None,
            editor: None,
            feld_an,
            feld_cc,
            feld_bcc,
            feld_betreff,
            cc_bcc: false,
            vorschlaege: Vec::new(),
            vorschlag_index: 0,
            vorschlag_laeuft: false,
            compose_stand: None,
            compose_stand_seit: None,
            speichert: None,
            naechste_compose_id: 1,
            compose_fokus: false,
            anhaenge_laeuft: false,
            entwurf_wartet: None,
            pending_dock: None,
            pending_editor_text: None,
            letzte_sendung: None,
            send_absicht: None,
            anhang_fokus: None,
            gehezu_seit: None,
            pending_focus: None,
            neu_laden_um: None,
            offen_seit: None,
            offen_marke: None,
            liste_gesehen: false,
            ui_ready_gesendet: false,
            messlauf: None,
            synthetisch: None,
            korpus: korpus_ordner(),
            theme_override: None,
            hook_pos: 0,
            pending_size: None,
        };

        // Sichtbaren Bereich mitschreiben (für Nachladen beim Scrollen).
        let ende = state.sichtbar_ende.clone();
        let start = state.sichtbar.clone();
        state.list_state.set_scroll_handler(move |event, _window, _cx| {
            start.store(event.visible_range.start, Ordering::Relaxed);
            ende.store(event.visible_range.end, Ordering::Relaxed);
        });

        // Zuerst die Liste (das ist das, was der Nutzer sieht), dann was die
        // Seitenleiste braucht. Der Kern arbeitet die Anfragen der Reihe nach ab.
        state.laden(cx);
        for request in [Request::Accounts, Request::Splits, Request::Labels, Request::Unread] {
            state.kern.request(request);
            state.in_flight += 1;
        }

        // Takt: nimmt Kern-Antworten ab, hält das Theme aktuell und gibt
        // Messläufe weiter. Läuft nur so schnell, wie gerade etwas zu tun ist.
        cx.spawn(async move |this: WeakEntity<AppState>, cx: &mut AsyncApp| loop {
            let ms = this
                .read_with(cx, |state, _| state.tick_ms())
                .unwrap_or(120);
            cx.background_executor()
                .timer(Duration::from_millis(ms))
                .await;
            if this.update(cx, |state, cx| state.tick(cx)).is_err() {
                break;
            }
        })
        .detach();

        state
    }

    /// Nächster Tick-Abstand: schnell, solange etwas läuft, sonst ruhig.
    pub fn tick_ms(&self) -> u64 {
        if self.in_flight > 0 || self.offen_seit.is_some() || self.messlauf.is_some() {
            8
        } else {
            120
        }
    }

    // ---------------------------------------------------------------- Ticks

    pub fn tick(&mut self, cx: &mut Context<Self>) {
        let mut neu_zeichnen = false;

        for reply in self.kern.poll() {
            neu_zeichnen |= self.antwort(reply, cx);
        }
        self.autosave_pruefen(cx);

        // Dead Key, der kein Folgezeichen bekommen hat, nach kurzer Zeit einsetzen
        let dead = self.suchfeld.update(cx, |field, cx| field.flush_dead(cx));
        if dead {
            neu_zeichnen = true;
        }

        // Toast abgelaufen?
        if let Some(toast) = &self.toast {
            if Instant::now() >= toast.bis {
                self.toast = None;
                neu_zeichnen = true;
            }
        }

        // Theme-Wechsel live übernehmen (wie im Spike, aber nur ein `stat`).
        if self.theme_override.is_none() && self.theme.changed() {
            let t = perf::seit_start_ms();
            let theme = Theme::load();
            eprintln!("L1-THEME ms={t:.1} name={}", theme.name);
            self.theme_setzen(theme, cx);
            neu_zeichnen = true;
        }

        // G-Fenster abgelaufen?
        if let Some(seit) = self.gehezu_seit {
            if seit.elapsed() > GEHEZU_FENSTER {
                self.gehezu_seit = None;
                self.hint = SharedString::default();
                neu_zeichnen = true;
            }
        }

        // Entprellt neu laden, wenn der Kern neue Post meldet.
        if let Some(um) = self.neu_laden_um {
            if Instant::now() >= um {
                self.neu_laden_um = None;
                self.aktualisieren(cx);
                neu_zeichnen = true;
            }
        }

        // Paging: kurz vor dem Ende der Liste die nächste Seite holen.
        if !self.loading && self.suche.is_none() && self.next_cursor.is_some() {
            let ende = self.sichtbar_ende.load(Ordering::Relaxed);
            if ende + NACH_LADEN_AB >= self.rows.len() && ende > 0 {
                self.mehr_laden();
                neu_zeichnen = true;
            }
        }

        if self.messlauf.is_some() {
            self.messlauf_schritt(cx);
        }

        self.hooks(cx);

        if neu_zeichnen {
            cx.notify();
        }
    }

    /// Eine Antwort des Kerns verarbeiten. `true` = neu zeichnen.
    fn antwort(&mut self, reply: Reply, cx: &mut Context<Self>) -> bool {
        match reply {
            Reply::Accounts(accounts) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.kern_status = format!("{} Konto/Konten", accounts.len()).into();
                self.accounts = accounts;
                true
            }
            Reply::Splits(splits) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.splits = splits;
                true
            }
            Reply::Labels(labels) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.labels = labels;
                true
            }
            Reply::Folders(folders) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.folders = folders;
                if let Some(id) = self.ordner_erwartet.take() {
                    self.auswahl_fuer_ordner(id, cx);
                }
                true
            }
            Reply::Unread(counts) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.unread = counts;
                true
            }
            Reply::Threads { generation, threads, cursor } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if generation != self.generation {
                    return false;
                }
                let started = self.offen_seit;
                self.loading = false;
                let alt = self.threads.len();
                self.threads = if let Some(synth) = self.synthetisch.clone() {
                    synth
                } else {
                    threads
                };
                self.next_cursor = cursor;
                list::rows_bauen(self);
                self.rows_sync(alt);
                self.auswahl_nach_liste();
                let _ = started;
                if !self.ui_ready_gesendet {
                    self.kern.request(Request::UiReady);
                    self.ui_ready_gesendet = true;
                }
                eprintln!(
                    "L1-LISTE ms={:.1} n={} rows={}",
                    perf::seit_start_ms(),
                    self.threads.len(),
                    self.rows.len()
                );
                true
            }
            Reply::More { generation, threads, cursor } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if generation != self.generation || self.synthetisch.is_some() {
                    return false;
                }
                self.loading = false;
                let alt = self.threads.len();
                let bekannt: std::collections::HashSet<i64> =
                    self.threads.iter().map(|t| t.id).collect();
                let frisch: Vec<ThreadSummary> =
                    threads.into_iter().filter(|t| !bekannt.contains(&t.id)).collect();
                if frisch.is_empty() {
                    self.next_cursor = None;
                    return false;
                }
                self.threads.extend(frisch);
                self.next_cursor = cursor;
                list::rows_bauen(self);
                self.rows_sync(alt);
                true
            }
            Reply::Search { generation, threads } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if generation != self.generation {
                    return false;
                }
                self.loading = false;
                let alt = self.threads.len();
                self.threads = threads;
                self.next_cursor = None;
                list::rows_bauen(self);
                self.rows_sync(alt);
                self.auswahl_nach_liste();
                true
            }
            Reply::Thread { generation, detail } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if generation != self.generation {
                    return false;
                }
                self.thread_empfangen(*detail, cx);
                true
            }
            Reply::Bilder { thread, ergebnisse } => {
                // Bewusst kein `in_flight`: der Abruf darf den 120-ms-Takt
                // nicht auf 8 ms hochziehen (bis zu 20 s je Mail).
                self.bilder_holt.remove(&thread);
                self.bilder_fehler.remove(&thread);
                let mut geladen = 0usize;
                let mut fehlgeschlagen = 0usize;
                for (url, ergebnis) in ergebnisse {
                    match ergebnis {
                        Ok((mime, bytes)) => {
                            if self.bilder.insert_remote(&url, &mime, bytes) {
                                geladen += 1;
                            }
                        }
                        Err(fehler) => {
                            fehlgeschlagen += 1;
                            // Nur im Messbuild: die Adresse trägt oft ein
                            // Tracking-Token und hat im Release nichts zu suchen.
                            if cfg!(feature = "test-hooks") {
                                eprintln!("L1-BILD fehler thread={thread} url={url} {fehler}");
                            }
                        }
                    }
                }
                if fehlgeschlagen > 0 {
                    self.bilder_fehler.insert(thread, fehlgeschlagen);
                }
                eprintln!(
                    "L1-BILDER thread={thread} geladen={geladen} fehler={fehlgeschlagen}"
                );
                // Karte neu zeichnen: die Bytes liegen jetzt im geteilten Speicher.
                self.karte_neu(thread, false, cx);
                true
            }
            Reply::Action { kind, thread_ids, action_ids } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                eprintln!(
                    "L1-AKTION kind={kind} threads={:?} aktionen={}",
                    thread_ids.len(),
                    action_ids.len()
                );
                // Die Zähler der Seitenleiste stimmen nach der Aktion neu.
                self.kern.request(Request::Unread);
                self.in_flight += 1;
                false
            }
            Reply::Undo { undone } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if undone {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Rückgängig gemacht",
                        std::time::Duration::from_secs(3),
                    ));
                    // Die Liste kommt vom Kern zurück (die Zeile war optimistisch weg).
                    self.aktualisieren(cx);
                } else {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Nichts zum Rückgängigmachen",
                        std::time::Duration::from_secs(3),
                    ));
                }
                true
            }
            Reply::Draft { id } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.entwurf_gespeichert(id, cx);
                true
            }
            Reply::Queued { action_id, dispatch_at } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.gesendet(action_id, dispatch_at, cx);
                true
            }
            Reply::Cancelled { action_id, cancelled } => {
                self.in_flight = self.in_flight.saturating_sub(1);
                if cancelled {
                    // Der Entwurf kommt zurück ins Dock, wo er war.
                    if let Some((aid, compose)) = self.letzte_sendung.take() {
                        if aid == action_id {
                            self.pending_dock = Some(compose);
                        }
                    }
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Senden abgebrochen",
                        Duration::from_secs(4),
                    ));
                } else {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Zu spät: die Mail ist schon raus",
                        Duration::from_secs(5),
                    ));
                }
                true
            }
            Reply::Anhang { pfad, aktion } => {
                // A2: blockiert → Toast, gefragt → Rückfrage, sonst öffnen.
                let text = aktion.text();
                match aktion {
                    crate::core::host::AnhangAktion::Oeffnen => {
                        if let Err(fehler) =
                            crate::core::host::oeffnen_mit(&crate::core::host::oeffner(), &pfad)
                        {
                            self.toast = Some(crate::ui::toast::Toast::neu(
                                format!("Öffnen fehlgeschlagen: {fehler}"),
                                Duration::from_secs(5),
                            ));
                        }
                    }
                    crate::core::host::AnhangAktion::Blockiert(_) => {
                        self.toast = Some(crate::ui::toast::Toast::neu(
                            text.unwrap_or_default(),
                            Duration::from_secs(7),
                        ));
                    }
                    crate::core::host::AnhangAktion::Fragen(_) => {
                        self.bestaetigung = Some(anhang_frage(text.unwrap_or_default(), pfad));
                    }
                }
                true
            }
            Reply::Anhaenge(dateien) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.anhaenge_laeuft = false;
                self.compose_einlesen(cx);
                let mut anzahl = 0usize;
                if let Some(id) = self.compose_aktiv {
                    if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
                        for (pfad, name, groesse, mime) in dateien {
                            compose.anhaenge.push(crate::state::compose::Anhang {
                                pfad,
                                name,
                                groesse,
                                mime,
                            });
                            anzahl += 1;
                        }
                    }
                }
                eprintln!("L2-ANHANG gewaehlt={anzahl}");
                if anzahl == 0 {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Kein Anhang gewählt",
                        Duration::from_secs(3),
                    ));
                }
                true
            }
            Reply::DraftLoaded(inhalt) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                let modus = match inhalt.mode.as_str() {
                    "reply" => Modus::Antwort,
                    "reply_all" => Modus::AllenAntworten,
                    "forward" => Modus::Weiterleiten,
                    _ => Modus::Neu,
                };
                let mut compose = Compose::neu(self.naechste_compose_id, modus, inhalt.account_id);
                self.naechste_compose_id += 1;
                compose.draft_id = inhalt.draft_id;
                compose.an = inhalt.to.iter().map(adresse_text).collect::<Vec<_>>().join(", ");
                compose.cc = inhalt.cc.iter().map(adresse_text).collect::<Vec<_>>().join(", ");
                compose.bcc = inhalt.bcc.iter().map(adresse_text).collect::<Vec<_>>().join(", ");
                compose.betreff = inhalt.subject;
                compose.antwort_auf = inhalt.in_reply_to_message_id;
                compose.doc = Some(match inhalt.body_html.as_deref() {
                    Some(html) if !html.trim().is_empty() && !inhalt.body_text.trim().is_empty() => {
                        crate::editor::EditorDoc::from_plain(inhalt.body_text.clone())
                    }
                    _ => crate::editor::EditorDoc::from_plain(inhalt.body_text.clone()),
                });
                compose.anhaenge = inhalt
                    .attachments
                    .iter()
                    .map(|anhang| {
                        let pfad = std::path::PathBuf::from(&anhang.file_path);
                        let groesse = std::fs::metadata(&pfad).map(|meta| meta.len()).unwrap_or(0);
                        let name = if anhang.filename.trim().is_empty() {
                            pfad.file_name()
                                .map(|name| name.to_string_lossy().to_string())
                                .unwrap_or_else(|| "anhang".into())
                        } else {
                            anhang.filename.clone()
                        };
                        let mime = crate::core::host::mime_aus_name(&name);
                        crate::state::compose::Anhang { pfad, name, groesse, mime }
                    })
                    .collect();
                self.pending_dock = Some(compose);
                true
            }
            Reply::DraftDeleted => {
                self.in_flight = self.in_flight.saturating_sub(1);
                true
            }
            Reply::Contacts(items) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.vorschlag_laeuft = false;
                self.vorschlaege = items;
                self.vorschlag_index = 0;
                true
            }
            Reply::Event(event) => self.kernereignis(event, cx),
            Reply::Status(text) => {
                self.kern_status = text.into();
                true
            }
            Reply::Error(text) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.loading = false;
                eprintln!("L1-FEHLER {text}");
                self.fehler = Some(text.clone().into());
                // Eine Aktion ist am Kern gescheitert: die optimistische
                // Änderung ist nicht passiert — Liste neu holen und sagen.
                if text.starts_with("perform_action") {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        "Aktion nicht ausgeführt",
                        Duration::from_secs(4),
                    ));
                    self.aktualisieren(cx);
                }
                true
            }
        }
    }

    fn kernereignis(&mut self, event: CoreEvent, _cx: &mut Context<Self>) -> bool {
        match event {
            CoreEvent::Ready { core_start_ms } => {
                eprintln!("L1-KERN-BEREIT ms={core_start_ms:.1}");
                self.kern_status = "Kern bereit".into();
                true
            }
            CoreEvent::Failed { code, message } => {
                self.fehler = Some(format!("{code}: {message}").into());
                false
            }
            CoreEvent::MailUpdated { .. } | CoreEvent::MailNew { .. } => {
                // Kurz sammeln: ein Sync schickt mehrere Ereignisse.
                self.neu_laden_um = Some(Instant::now() + Duration::from_millis(180));
                self.kern.request(Request::Unread);
                self.in_flight += 1;
                false
            }
            CoreEvent::SyncProgress { phase, done, total } => {
                self.kern_status = format!("Sync {phase} {done}/{total}").into();
                true
            }
            CoreEvent::SyncStatus { state, .. } => {
                self.kern_status = format!("Sync {state}").into();
                true
            }
            CoreEvent::AccountState { sync_state, .. } => {
                self.kern_status = format!("Konto {sync_state}").into();
                true
            }
            CoreEvent::NetworkState { online } => {
                self.kern_status = if online { "online".into() } else { "offline".into() };
                true
            }
            CoreEvent::Other { .. } => false,
        }
    }

    // ------------------------------------------------------------- Laden

    /// Erste Seite holen und Liste neu aufbauen (Ansicht, Suche, Konto).
    pub fn laden(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.loading = true;
        self.in_flight += 1;
        self.expanded = None;
        self.selected = None;
        self.threads.clear();
        self.rows.clear();
        self.next_cursor = None;
        self.list_state.reset(0);
        let args = self.listen_args(None);
        self.kern.request(Request::Threads { generation: self.generation, args });
        cx.notify();
    }

    /// Nachladen für die aktuelle Ansicht, Auswahl und Position behalten.
    fn aktualisieren(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.loading = true;
        self.in_flight += 1;
        let args = self.listen_args(None);
        self.kern.request(Request::Threads { generation: self.generation, args });
        cx.notify();
    }

    pub fn mehr_laden(&mut self) {
        let Some(cursor) = self.next_cursor else { return };
        self.loading = true;
        self.in_flight += 1;
        let args = self.listen_args(Some(cursor));
        self.kern.request(Request::More { generation: self.generation, args });
    }

    fn listen_args(&self, cursor: Option<i64>) -> ListThreadsArgs {
        ListThreadsArgs {
            view: self.view,
            split_id: self.aktueller_split(),
            account_id: self.account_id,
            label_id: self.label_id,
            folder_id: None,
            cursor,
            limit: SEITENGROESSE,
        }
    }

    /// Zeilen der Liste an den `ListState` anpassen. `alt` = Zeilenzahl vorher.
    fn rows_sync(&mut self, alt: usize) {
        let neu = self.rows.len();
        if alt == 0 || self.selected.is_none() {
            self.list_state.reset(neu);
        } else if neu != alt {
            self.list_state.splice(0..alt, neu);
        }
    }

    /// Nach dem ersten Laden: erste Zeile auswählen (wie `applyThreads`).
    fn auswahl_nach_liste(&mut self) {
        if self.selected.is_some() {
            let noch_da = self
                .selected
                .map(|id| self.threads.iter().any(|t| t.id == id))
                .unwrap_or(false);
            if noch_da {
                return;
            }
        }
        self.selected = self.threads.first().map(|t| t.id);
    }

    // ------------------------------------------------------------ Splits

    /// Tabs des Posteingangs: ohne eigene Splits keine (eine Liste).
    pub fn tabs(&self) -> Vec<Tab> {
        if self.view != MailView::Inbox || self.suche.is_some() {
            return Vec::new();
        }
        let eigene: Vec<&SplitRule> = self
            .splits
            .iter()
            .filter(|split| split.target.is_none())
            .collect();
        if eigene.is_empty() {
            return Vec::new();
        }
        let mut tabs = vec![Tab {
            id: "inbox".into(),
            titel: "Posteingang".into(),
            split_id: None,
            unread: self.unread.inbox,
        }];
        for split in eigene {
            tabs.push(Tab {
                id: format!("split-{}", split.id),
                titel: split.name.clone(),
                split_id: Some(split.id),
                unread: self.unread.splits.get(&split.id.to_string()).copied().unwrap_or(0),
            });
        }
        tabs
    }

    pub fn aktueller_split(&self) -> Option<i64> {
        let tabs = self.tabs();
        tabs.get(self.tab).and_then(|tab| tab.split_id)
    }

    pub fn split_wechseln(&mut self, delta: isize, cx: &mut Context<Self>) {
        let anzahl = self.tabs().len();
        if anzahl < 2 {
            return;
        }
        self.tab = ((self.tab as isize + delta).rem_euclid(anzahl as isize)) as usize;
        self.laden(cx);
    }

    pub fn split_waehlen(&mut self, index: usize, cx: &mut Context<Self>) {
        if index >= self.tabs().len() || index == self.tab {
            return;
        }
        self.tab = index;
        self.laden(cx);
    }

    // --------------------------------------------------------- Navigation

    pub fn gehe_zu(&mut self, view: MailView, cx: &mut Context<Self>) {
        self.view = view;
        self.label_id = None;
        self.tab = 0;
        self.suche = None;
        self.laden(cx);
    }

    pub fn konto_waehlen(&mut self, id: Option<i64>, cx: &mut Context<Self>) {
        if self.account_id == id {
            return;
        }
        self.account_id = id;
        self.laden(cx);
    }

    pub fn label_waehlen(&mut self, id: i64, cx: &mut Context<Self>) {
        self.label_id = Some(id);
        self.view = MailView::All;
        self.suche = None;
        self.laden(cx);
    }

    pub fn thread(&self, id: i64) -> Option<&ThreadSummary> {
        self.threads.iter().find(|thread| thread.id == id)
    }

    pub fn detail_von(&self, id: i64) -> Option<&ThreadDetail> {
        self.details.get(&id)
    }

    /// „Laden" in der Hinweiszeile: externe Bilder **dieser** Mail über den Kern
    /// holen, in den Bild-Speicher legen und die Karte neu zeichnen (§4.5;
    /// Merken je Absender ist L4).
    pub fn remote_laden(&mut self, id: i64, cx: &mut Context<Self>) {
        if self.bilder_holt.contains(&id) {
            // Läuft schon: kein zweiter Abruf.
            return;
        }
        self.remote_erlaubt.insert(id);
        self.bilder_fehler.remove(&id);
        // Bis die Antwort da ist, zeigt die Hinweiszeile „Bilder werden geladen …".
        self.bilder_holt.insert(id);
        self.karte_neu(id, false, cx);
        let urls: Vec<String> = self
            .karten
            .get(&id)
            .map(|karte| {
                karte
                    .fern
                    .iter()
                    // Der Speicher ist die Wahrheit: was noch drin ist, wird nicht
                    // erneut geholt (er verdrängt bei Platzmangel selbst).
                    .filter(|url| self.bilder.resolve(url).is_none())
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if urls.is_empty() {
            // Nichts nachzuladen (alles schon im Speicher): Hinweis zurücknehmen.
            self.bilder_holt.remove(&id);
            self.karte_neu(id, false, cx);
        } else {
            eprintln!("L1-BILD anfrage thread={id} n={}", urls.len());
            self.kern.request(Request::Bilder { thread: id, urls });
        }
        cx.notify();
    }

    /// Karte eines Threads neu bauen (Policy aus `remote_erlaubt`) und einsetzen.
    /// `scrollen` nur beim ersten Aufklappen: beim Nachladen der Bilder bleibt
    /// die Leseposition, wo sie ist.
    fn karte_neu(&mut self, id: i64, scrollen: bool, cx: &mut Context<Self>) {
        let Some(detail) = self.details.get(&id).cloned() else { return };
        let breite = self.koerper_breite();
        let remote = if self.remote_erlaubt.contains(&id) {
            RemoteImages::Allowed
        } else {
            RemoteImages::Blocked
        };
        let laedt = self.bilder_holt.contains(&id);
        let karte = thread::karte_bauen(
            &detail,
            breite,
            remote,
            self.korpus.as_deref(),
            Arc::clone(&self.bilder),
            laedt,
            self.bilder_fehler.get(&id).copied().unwrap_or(0),
            &self.theme,
        );
        if cfg!(feature = "test-hooks") {
            eprintln!(
                "L1-KARTE thread={id} ms={:.1} hoehe={:.0} nachrichten={} bilder={} fern={}",
                karte.ms,
                karte.hoehe,
                karte.nachrichten.len(),
                karte.bilder,
                karte.fern.len()
            );
        }
        self.karten.insert(id, karte.clone());
        if self.expanded != Some(id) {
            return;
        }
        if scrollen {
            self.karte_einsetzen(id, karte, cx);
        } else {
            self.karte_ersetzen(id, karte, cx);
        }
    }

    /// Karte in ihrer Zeile austauschen, ohne zu scrollen (Bilder nachgeladen).
    fn karte_ersetzen(&mut self, id: i64, karte: Karte, cx: &mut Context<Self>) {
        let Some(zeile) = self.zeile_von(id) else { return };
        if !matches!(self.rows.get(zeile + 1), Some(Row::Karte { .. })) {
            return;
        }
        self.rows.remove(zeile + 1);
        self.list_state.splice(zeile + 1..zeile + 2, 0);
        self.rows.insert(zeile + 1, Row::Karte { id, hoehe: karte.hoehe });
        self.list_state.splice(zeile + 1..zeile + 1, 1);
        self.status = format!("{} ms · {}", karte.ms as i64, karte.bilder_text()).into();
        cx.notify();
    }

    pub fn zeile_von(&self, id: i64) -> Option<usize> {
        self.rows.iter().position(|row| matches!(row, Row::Thread { id: t, .. } if *t == id))
    }

    pub fn bewegen(&mut self, delta: isize, cx: &mut Context<Self>) {
        let zeilen: Vec<usize> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| matches!(row, Row::Thread { .. }))
            .map(|(index, _)| index)
            .collect();
        if zeilen.is_empty() {
            return;
        }
        let aktuell = self
            .selected
            .and_then(|id| self.zeile_von(id))
            .unwrap_or(zeilen[0]);
        let position = zeilen.iter().position(|index| *index == aktuell).unwrap_or(0) as isize;
        let ziel = (position + delta).clamp(0, zeilen.len() as isize - 1) as usize;
        let zeile = zeilen[ziel];
        let Row::Thread { id, .. } = self.rows[zeile] else { return };
        self.selected = Some(id);
        self.zeile_sichtbar(zeile);
        cx.notify();
    }

    pub fn an_den_rand(&mut self, anfang: bool, cx: &mut Context<Self>) {
        let zeilen: Vec<usize> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| matches!(row, Row::Thread { .. }))
            .map(|(index, _)| index)
            .collect();
        let Some(zeile) = zeilen.into_iter().next_back().filter(|_| !anfang).or_else(|| {
            self.rows
                .iter()
                .position(|row| matches!(row, Row::Thread { .. }))
        }) else {
            return;
        };
        if let Row::Thread { id, .. } = self.rows[zeile] {
            self.selected = Some(id);
            self.zeile_sichtbar(zeile);
            cx.notify();
        }
    }

    /// Eine Zeile in den sichtbaren Bereich holen. Ein aufgeklappter Thread
    /// wird nicht „vollständig" gezeigt (das wäre die ganze Mail), sondern mit
    /// seiner Oberkante.
    fn zeile_sichtbar(&mut self, zeile: usize) {
        if let Some(Row::Thread { id, .. }) = self.rows.get(zeile) {
            if self.expanded == Some(*id) {
                self.list_state.scroll_to(ListOffset {
                    item_ix: zeile,
                    offset_in_item: px(0.),
                });
                return;
            }
        }
        self.list_state.scroll_to_reveal_item(zeile);
    }

    pub fn seitenweise(&mut self, weiter: bool) {
        let hoehe = self.list_state.viewport_bounds().size.height;
        let schritt = (hoehe - px(60.)).max(px(120.));
        self.list_state.scroll_by(if weiter { schritt } else { -schritt });
    }

    // ------------------------------------------------------------ Thread

    pub fn oeffnen_oder_schliessen(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected else { return };
        if self.expanded == Some(id) {
            self.schliessen(cx);
        } else {
            self.oeffne(id, cx);
        }
    }

    pub fn oeffne(&mut self, id: i64, cx: &mut Context<Self>) {
        // Immer nur eine Karte: einen anderen offenen Thread zuerst zuklappen,
        // sonst bliebe seine Kartenzeile in der Liste stehen.
        if self.expanded.is_some() && self.expanded != Some(id) {
            self.schliessen(cx);
        }
        self.selected = Some(id);
        // In „Entwürfe" öffnet ein Klick das Verfassen-Fenster, nicht die Mail.
        if self.view == MailView::Drafts {
            self.entwurf_wartet = Some(id);
        }
        if let Some(karte) = self.karten.get(&id).cloned() {
            self.karte_einsetzen(id, karte, cx);
            return;
        }
        self.expanded = Some(id);
        self.offen_seit = Some((id, Instant::now()));
        self.in_flight += 1;
        self.kern.request(Request::Thread { generation: self.generation, id });
        self.status = "Mail wird geladen …".into();
        cx.notify();
    }

    pub fn schliessen(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.expanded else { return };
        self.expanded = None;
        // Nur die eigene Messung verwerfen: beim Wechsel auf einen anderen
        // Thread gehört die startende Messung schon dem neuen.
        if self.offen_seit.map(|(offen, _)| offen) == Some(id) {
            self.offen_seit = None;
        }
        if self.offen_marke.as_ref().map(|(offen, _, _)| *offen) == Some(id) {
            self.offen_marke = None;
        }
        if let Some(zeile) = self.zeile_von(id) {
            if let Some(Row::Karte { .. }) = self.rows.get(zeile + 1).cloned() {
                self.rows.remove(zeile + 1);
                self.list_state.splice(zeile + 1..zeile + 2, 0);
            }
        }
        cx.notify();
    }

    /// Thread-Antwort: Karte bauen (Blitz) und einsetzen.
    fn thread_empfangen(&mut self, detail: ThreadDetail, cx: &mut Context<Self>) {
        if self.view == MailView::Drafts && self.entwurf_wartet == Some(detail.thread.id) {
            self.entwurf_wartet = None;
            if let Some(nachricht) = detail.messages.last() {
                self.in_flight += 1;
                self.kern.request(Request::GetDraft { draft_id: nachricht.id });
            }
            self.schliessen(cx);
        }
        let id = detail.thread.id;
        self.details.insert(id, detail);
        self.karte_neu(id, true, cx);
    }

    /// Die Karte als eigene Zeile direkt unter ihren Thread setzen und die
    /// Mail so weit hereinholen, wie es das Verhalten der Mac-App vorsieht.
    fn karte_einsetzen(&mut self, id: i64, karte: Karte, cx: &mut Context<Self>) {
        self.expanded = Some(id);
        let Some(zeile) = self.zeile_von(id) else { return };
        // Alte Karte (falls offen) zuerst weg.
        if let Some(Row::Karte { .. }) = self.rows.get(zeile + 1) {
            self.rows.remove(zeile + 1);
            self.list_state.splice(zeile + 1..zeile + 1 + 1, 0);
        }
        let hoehe = karte.hoehe;
        self.rows.insert(zeile + 1, Row::Karte { id, hoehe });
        self.list_state.splice(zeile + 1..zeile + 1, 1);
        // Erst zeichnen lassen, dann scrollen: die Kartenhöhe ist bekannt,
        // `bounds_for_item` braucht aber einen gelayouteten Stand. Das Scrollen
        // passiert im nächsten Tick (billig, ein Frame Abstand).
        self.scroll_nach_aufklappen(id);
        if let Some((oid, seit)) = self.offen_seit {
            if oid == id {
                self.offen_marke = Some((id, String::new(), seit));
                self.offen_seit = None;
            }
        }
        self.status = format!("{} ms · {}", karte.ms as i64, karte.bilder_text()).into();
        cx.notify();
    }

    /// Reveal nach dem Muster der Mac-App: ganze Karte plus eine Zeile
    /// darunter, oben bleibt mindestens eine Zeile stehen.
    fn scroll_nach_aufklappen(&mut self, id: i64) {
        let Some(zeile) = self.zeile_von(id) else { return };
        let Some(karte) = self.rows.get(zeile + 1) else { return };
        let Row::Karte { hoehe, .. } = *karte else { return };
        let Some(oben) = self.list_state.bounds_for_item(zeile) else {
            // Zeile noch nicht vermessen: schlicht hinscrollen.
            self.list_state.scroll_to_reveal_item(zeile);
            return;
        };
        let darueber = self
            .rows
            .get(zeile.wrapping_sub(1))
            .filter(|_| zeile > 0)
            .map(Row::hoehe)
            .unwrap_or(0.0);
        let above_top = oben.top() - px(darueber);
        let unter = self.rows.get(zeile + 2).map(Row::hoehe).unwrap_or(0.0);
        let sicht = self.list_state.viewport_bounds();
        let karten_hoehe = px(hoehe);
        let ziel = thread::reveal_top(
            f32::from(oben.top()),
            f32::from(above_top),
            f32::from(oben.top() + px(Row::THREAD_HOEHE) + karten_hoehe),
            unter,
            f32::from(sicht.top()),
            f32::from(sicht.size.height),
        );
        if let Some(ziel) = ziel {
            let versatz = f32::from(oben.top()) - ziel;
            self.list_state.scroll_to(ListOffset {
                item_ix: zeile,
                offset_in_item: px(versatz),
            });
        }
    }

    /// Theme übernehmen und an die Textfelder weitergeben (die halten eine Kopie).
    pub fn theme_setzen(&mut self, theme: Theme, cx: &mut Context<Self>) {
        self.theme = theme.clone();
        // Das Fenster hängt in `gpui_component::Root`; dessen Theme muss
        // mitziehen, sonst bleibt Hintergrund/Schrift beim alten Stand.
        crate::theme::an_gpui_component(&theme, cx);
        self.suchfeld.update(cx, |field, cx| {
            field.theme = theme;
            cx.notify();
        });
        cx.notify();
    }

    /// Breite, in der ein Mail-Körper gezeichnet wird.
    pub fn koerper_breite(&self) -> u32 {
        let platz = self.list_breite - 2.0 * (thread::KARTE_RAND + thread::KARTE_PAD);
        (platz.clamp(
            crate::html_view::MIN_KOERPER_BREITE as f32,
            crate::html_view::MAX_KOERPER_BREITE as f32,
        ))
        .round() as u32
    }

    // ------------------------------------------------------------ Suche

    pub fn suche_starten(&mut self, cx: &mut Context<Self>) {
        self.pending_focus = Some(Fokus::Suche);
        cx.notify();
    }

    pub fn suche_ausfuehren(&mut self, cx: &mut Context<Self>) {
        let query = self.suchfeld.read(cx).text().trim().to_string();
        if query.is_empty() {
            self.suche_beenden(cx);
            return;
        }
        self.suche = Some(query.clone());
        self.generation += 1;
        self.loading = true;
        self.in_flight += 1;
        self.expanded = None;
        self.threads.clear();
        self.rows.clear();
        self.next_cursor = None;
        self.list_state.reset(0);
        self.kern.request(Request::Search { generation: self.generation, query: query.clone() });
        self.status = format!("Suche: {query}").into();
        cx.notify();
    }

    pub fn suche_beenden(&mut self, cx: &mut Context<Self>) {
        self.suchfeld.update(cx, |field, cx| {
            field.text.clear();
            field.cursor = 0;
            cx.notify();
        });
        if self.suche.is_some() {
            self.suche = None;
            self.laden(cx);
        }
        self.pending_focus = Some(Fokus::Liste);
        cx.notify();
    }

    // ---------------------------------------------------------- Tastatur

    pub fn tasten(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        #[cfg(feature = "test-hooks")]
        eprintln!(
            "L2-TASTE key={} char={:?} shift={} ctrl={} alt={}",
            event.keystroke.key,
            event.keystroke.key_char,
            event.keystroke.modifiers.shift,
            event.keystroke.modifiers.control,
            event.keystroke.modifiers.alt
        );

        // Im Verfassen-Fenster: Strg+↵ sendet, Esc minimiert (Entwurf gesichert),
        // ↑↓ wählen einen Kontaktvorschlag.
        if self.compose_aktiv.is_some() {
            let key = event.keystroke.key.as_str();
            let ctrl = event.keystroke.modifiers.control;
            if ctrl && matches!(key, "enter" | "return") {
                self.senden(cx);
                return;
            }
            if key == "escape" {
                self.compose_minimieren(cx);
                return;
            }
            // Markierter Anhang (Tastaturweg): `Entf` oder `Backspace` löscht ihn.
            if let Some(index) = self.anhang_fokus {
                if crate::state::compose::entfernen_taste(key) {
                    self.anhang_entfernen(index, cx);
                    let laenge = self
                        .compose_aktiv
                        .and_then(|id| self.compose.iter().find(|compose| compose.id == id))
                        .map_or(0, |compose| compose.anhaenge.len());
                    self.pending_focus =
                        Some(match crate::state::compose::auswahl_nach_loeschen(index, laenge) {
                            Some(naechster) => Fokus::Anhaenge(naechster),
                            None => Fokus::Verfassen,
                        });
                    cx.stop_propagation();
                    return;
                }
            }
            if !self.vorschlaege.is_empty() && self.feld_an.read(cx).is_focused(window) {
                match key {
                    "down" => {
                        self.vorschlag_bewegen(1, cx);
                        return;
                    }
                    "up" => {
                        self.vorschlag_bewegen(-1, cx);
                        return;
                    }
                    "tab" | "enter" | "return" => {
                        let index = self.vorschlag_index;
                        self.vorschlag_nehmen(index, cx);
                        return;
                    }
                    _ => {}
                }
            }
        }

        // Ein offenes Overlay nimmt die Tasten zuerst; dahinter wirkt nichts.
        if self.bestaetigung.is_some() {
            self.bestaetigung_tasten(event, cx);
            return;
        }
        if self.auswahl.is_some() {
            self.auswahl_tasten(event, window, cx);
            return;
        }
        if self.kontextmenue.is_some() {
            self.kontextmenue_tasten(event, cx);
            return;
        }

        let textfeld = self.suchfeld.read(cx).is_focused(window)
            || self.datumfeld.read(cx).is_focused(window)
            || self.compose_felder_fokussiert(window, cx)
            || (self.compose_aktiv.is_some() && self.compose_fokus);
        // Enter im Suchfeld sucht; alles andere im Feld gehört dem Feld.
        let im_verfassen = self.compose_aktiv.is_some()
            && (self.compose_fokus || self.compose_felder_fokussiert(window, cx));
        if textfeld {
            match event.keystroke.key.as_str() {
                "enter" | "return" => {
                    // Im Verfassen ist ↵ ein Zeilenumbruch; gesendet wird mit
                    // `Strg+↵`, das der Editor selbst abfängt.
                    if im_verfassen {
                        return;
                    }
                    self.suche_ausfuehren(cx);
                    return;
                }
                "escape" => {
                    // `Esc` minimiert das Dock (und sichert den Entwurf).
                    if im_verfassen {
                        self.compose_minimieren(cx);
                        return;
                    }
                    self.suche_beenden(cx);
                    return;
                }
                _ => {}
            }
        }
        if self.compose_aktiv.is_some() && self.feld_an.read(cx).is_focused(window) {
            self.vorschlaege_anfragen(cx);
        }

        let ergebnis = keys::auswerten(
            event,
            Kontext { textfeld, g_prefix: self.gehezu_seit.is_some() },
        );
        match ergebnis {
            Ergebnis::Nichts => {}
            Ergebnis::GeheZuBeginn => {
                self.gehezu_seit = Some(Instant::now());
                self.hint = "Gehe zu: I Posteingang · S Markiert · D Entwürfe · T Gesendet · \
                             E Erledigt · H Später · # Papierkorb · ! Spam · A Alle"
                    .into();
                cx.notify();
            }
            Ergebnis::Aktion(action) => self.aktion(action, window, cx),
        }
    }

    /// Tasten im „Später/Verschieben/Label"-Overlay. Im Datumsfeld gehört die
    /// Eingabe dem Feld; nur `↵` und `Esc` wertet die Auswahl aus.
    fn auswahl_tasten(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let im_feld = self.datumfeld.read(cx).is_focused(window);
        let taste = event.keystroke.key.as_str();
        if im_feld {
            match taste {
                "enter" | "return" => self.auswahl_datum_uebernehmen(cx),
                "escape" => self.auswahl_schliessen(cx),
                _ => {}
            }
            return;
        }
        match taste {
            "escape" => self.auswahl_schliessen(cx),
            "up" | "k" => self.auswahl_bewegen(-1, cx),
            "down" | "j" => self.auswahl_bewegen(1, cx),
            "tab" => self.auswahl_eigenes_feld(cx),
            "enter" | "return" => {
                if let Some(index) = self.auswahl.as_ref().map(|auswahl| auswahl.index) {
                    self.auswahl_nehmen(index, cx);
                }
            }
            _ => {
                // Ziffer wählt die Zeile direkt.
                let mut zeichen = taste.chars();
                if let (Some(ziffer), None) = (zeichen.next(), zeichen.next()) {
                    if let Some(zahl) = ziffer.to_digit(10).filter(|zahl| *zahl > 0) {
                        let index = zahl as usize - 1;
                        if self.auswahl.as_ref().is_some_and(|auswahl| index < auswahl.zeilen())
                        {
                            self.auswahl_nehmen(index, cx);
                        }
                    }
                }
            }
        }
    }

    /// Tasten im Kontextmenü: wie ein Menü der Plattform.
    fn kontextmenue_tasten(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        match event.keystroke.key.as_str() {
            "escape" => self.kontextmenue_schliessen(cx),
            "up" | "k" => self.kontextmenue_bewegen(-1, cx),
            "down" | "j" => self.kontextmenue_bewegen(1, cx),
            "enter" | "return" => {
                if let Some(index) = self.kontextmenue.as_ref().map(|menue| menue.index) {
                    self.kontextmenue_nehmen(index, cx);
                }
            }
            _ => {}
        }
    }

    fn aktion(&mut self, action: Action, window: &mut Window, cx: &mut Context<Self>) {
        if action != Action::Schliessen {
            self.gehezu_seit = None;
        }
        match action {
            Action::Weiter => self.bewegen(1, cx),
            Action::Zurueck => self.bewegen(-1, cx),
            Action::SeiteWeiter => self.seitenweise(true),
            Action::SeiteZurueck => self.seitenweise(false),
            Action::Anfang => self.an_den_rand(true, cx),
            Action::Ende => self.an_den_rand(false, cx),
            Action::Oeffnen => self.oeffnen_oder_schliessen(cx),
            Action::Schliessen => {
                if self.auswahl.is_some() {
                    self.auswahl_schliessen(cx);
                } else if self.kontextmenue.is_some() {
                    self.kontextmenue_schliessen(cx);
                } else if self.hilfe {
                    self.hilfe = false;
                } else if self.suchfeld.read(cx).is_focused(window) {
                    self.suche_beenden(cx);
                } else if self.expanded.is_some() {
                    self.schliessen(cx);
                } else if self.suche.is_some() {
                    self.suche_beenden(cx);
                }
                cx.notify();
            }
            Action::NaechsterSplit => self.split_wechseln(1, cx),
            Action::VorigerSplit => self.split_wechseln(-1, cx),
            Action::Suche => self.suche_starten(cx),
            Action::Hilfe => {
                self.hilfe = !self.hilfe;
                cx.notify();
            }
            Action::Seitenleiste => {
                self.seitenleiste = !self.seitenleiste;
                cx.notify();
            }
            Action::GeheZu(view) => {
                self.hint = SharedString::default();
                self.gehe_zu(view, cx);
            }
            Action::Gelesen => {
                let ungelesen = self
                    .selected
                    .and_then(|id| self.thread(id).map(|thread| thread.unread_count > 0))
                    .unwrap_or(false);
                let art = if ungelesen { Aktionsart::Gelesen } else { Aktionsart::Ungelesen };
                self.aktion_auf_auswahl(art, cx);
            }
            Action::Stern => self.aktion_auf_auswahl(Aktionsart::Stern, cx),
            Action::Erledigt => self.aktion_auf_auswahl(Aktionsart::Erledigt, cx),
            Action::ZurueckInEingang => self.aktion_auf_auswahl(Aktionsart::Zurueck, cx),
            Action::Papierkorb => self.aktion_auf_auswahl(Aktionsart::Papierkorb, cx),
            Action::Spam => self.aktion_auf_auswahl(Aktionsart::Spam, cx),
            Action::Spaeter => self.aktion_auf_auswahl(Aktionsart::Spaeter, cx),
            Action::SpaeterAuswahl => self.spaeter_auswahl_oeffnen(cx),
            Action::Verschieben => self.verschieben_auswahl_oeffnen(cx),
            Action::Label => self.label_auswahl_oeffnen(cx),
            Action::Verfassen => self.verfassen(Modus::Neu, window, cx),
            Action::Antworten => self.verfassen(Modus::Antwort, window, cx),
            Action::AllenAntworten => self.verfassen(Modus::AllenAntworten, window, cx),
            Action::Weiterleiten => self.verfassen(Modus::Weiterleiten, window, cx),
            Action::Rueckgaengig => self.rueckgaengig(cx),
        }
    }

    /// Fokus aus einem Kürzel oder Hook auf das richtige Feld setzen.
    pub fn fokus_anwenden(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.pending_focus.take() {
            Some(Fokus::Suche) => {
                window.focus(&self.suchfeld.read(cx).focus_handle());
                cx.notify();
            }
            Some(Fokus::Liste) => {
                let focus = self.focus.clone();
                window.focus(&focus);
                cx.notify();
            }
            Some(Fokus::Datum) => {
                window.focus(&self.datumfeld.read(cx).focus_handle());
                cx.notify();
            }
            Some(Fokus::Verfassen) => {
                self.anhang_fokus = None;
                if let Some(editor) = self.editor.clone() {
                    editor.update(cx, |editor, cx| editor.focus(window, cx));
                }
                cx.notify();
            }
            Some(Fokus::Anhaenge(index)) => {
                // Der Anhang ist markiert, nicht das Feld: der Fokus geht an das
                // Wurzelelement, damit `Entf` nicht im Text landet.
                self.anhang_fokus = Some(index);
                let focus = self.focus.clone();
                window.focus(&focus);
                cx.notify();
            }
            None => {}
        }
    }

    /// `Tab` im Dock: vom Körper zu den Anhängen, dort weiter, am Ende zurück
    /// in den Körper (`⇧Tab` rückwärts). Ohne Anhänge bleibt `Tab` beim Feld
    /// (dort fügt der Editor einzug ein), deshalb meldet die Funktion `false`.
    pub fn verfassen_tab(&mut self, rueckwaerts: bool, cx: &mut Context<Self>) -> bool {
        let laenge = self
            .compose_aktiv
            .and_then(|id| self.compose.iter().find(|compose| compose.id == id))
            .map_or(0, |compose| compose.anhaenge.len());
        if laenge == 0 {
            return false;
        }
        let naechster = match (self.anhang_fokus, rueckwaerts) {
            (None, false) => Some(Fokus::Anhaenge(0)),
            (Some(index), false) if index + 1 < laenge => Some(Fokus::Anhaenge(index + 1)),
            (Some(_), false) => Some(Fokus::Verfassen),
            (Some(0), true) | (None, true) => Some(Fokus::Verfassen),
            (Some(index), true) => Some(Fokus::Anhaenge(index - 1)),
        };
        if let Some(fokus) = naechster {
            self.pending_focus = Some(fokus);
            cx.notify();
        }
        true
    }

    // ------------------------------------------------------------ Status

    pub fn status_text(&self) -> String {
        let mut teile = Vec::new();
        teile.push(self.theme.name.clone());
        if let Some(suche) = &self.suche {
            teile.push(format!("Suche „{suche}\" · {} Treffer", self.threads.len()));
        } else {
            let ungelesen = self.threads.iter().filter(|thread| thread.unread()).count();
            teile.push(format!("{} Unterhaltungen, {ungelesen} ungelesen", self.threads.len()));
        }
        if let Some(id) = self.selected {
            if let Some(zeile) = self.zeile_von(id) {
                teile.push(format!("Zeile {}", zeile + 1));
            }
        }
        herbste(&mut teile, &self.kern_status);
        if let Some(fehler) = &self.fehler {
            herbste(&mut teile, fehler);
        }
        teile.join("  ·  ")
    }

    // ------------------------------------------------------- Test-Hooks

    #[cfg(feature = "test-hooks")]
    fn hooks(&mut self, cx: &mut Context<Self>) {
        crate::hooks::poll(self, cx);
    }

    #[cfg(not(feature = "test-hooks"))]
    fn hooks(&mut self, _cx: &mut Context<Self>) {}

    /// Startet einen Frame-Messlauf: die Liste scrollt `schritte` Mal.
    #[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
    pub fn messlauf_starten(&mut self, name: String, schritte: usize, cx: &mut Context<Self>) {
        perf::reset_frames();
        self.messlauf = Some(Messlauf {
            schritte,
            rest: schritte,
            name,
            start: Some(Instant::now()),
        });
        self.status = "Messlauf läuft …".into();
        cx.notify();
    }

    /// Ein Schritt des Messlaufs, aus `tick` gerufen.
    pub fn messlauf_schritt(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(lauf) = self.messlauf.as_mut() else { return true };
        if lauf.rest == 0 {
            let stats = perf::frame_stats();
            eprintln!("L1-FRAMES lauf={} {}", lauf.name, stats.zeile());
            self.status = format!("{}: {}", lauf.name, stats.zeile()).into();
            self.messlauf = None;
            cx.notify();
            return true;
        }
        lauf.rest -= 1;
        let weiter = lauf.rest % 2 == 1;
        self.seitenweise(weiter);
        cx.notify();
        false
    }
}

/// Leere Teile weglassen, sonst anhängen.
fn herbste(teile: &mut Vec<String>, teil: &str) {
    let teil = teil.trim();
    if !teil.is_empty() {
        teile.push(teil.to_string());
    }
}


/// Was eine Taste auf der Auswahl auslöst (L2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Aktionsart {
    Gelesen,
    Ungelesen,
    Stern,
    Erledigt,
    Zurueck,
    Papierkorb,
    Spam,
    Spaeter,
}

impl AppState {
    /// Aktion auf die ausgewählte Mail: optimistisch in der Liste, Befehl an
    /// den Kern, Toast mit „Rückgängig", wo der Kern es kann (`undo_last`
    /// kennt archive, trash, snooze, spam und move — nicht unarchive/not_spam).
    pub fn aktion_auf_auswahl(&mut self, art: Aktionsart, cx: &mut Context<Self>) {
        let Some(id) = self.selected else {
            self.hinweis_keine_auswahl(cx);
            return;
        };
        let Some(thread) = self.thread(id).cloned() else { return };

        // Im Papierkorb löscht `#` endgültig — nur nach Rückfrage, ohne Undo.
        if art == Aktionsart::Papierkorb && self.view == MailView::Trash {
            self.bestaetigung = Some(Bestaetigung {
                text: "Endgültig löschen? Die Mail lässt sich danach nicht wiederherstellen.".into(),
                knopf: "Endgültig löschen".into(),
                loeschen: false,
                hinweis: "Tab wechselt · ↵ bestätigt die Auswahl · Esc bricht ab · kein Rückgängig"
                    .into(),
                ziel: BestaetigungZiel::EndgueltigLoeschen(id),
            });
            cx.notify();
            return;
        }

        let (kind, params, text, verschwindet, undo) = match art {
            Aktionsart::Gelesen => ("mark_read", None, "Gelesen", false, false),
            Aktionsart::Ungelesen => ("mark_unread", None, "Ungelesen", false, false),
            Aktionsart::Stern if thread.is_starred => {
                ("unstar", None, "Markierung entfernt", false, false)
            }
            Aktionsart::Stern => ("star", None, "Markiert", false, false),
            Aktionsart::Erledigt => ("archive", None, "Erledigt", true, true),
            Aktionsart::Zurueck => ("unarchive", None, "Zurück im Posteingang", true, false),
            Aktionsart::Papierkorb => ("trash", None, "In den Papierkorb", true, true),
            Aktionsart::Spam if self.view == MailView::Spam => {
                ("not_spam", None, "Kein Spam", true, false)
            }
            Aktionsart::Spam => ("spam", None, "Als Spam markiert", true, true),
            Aktionsart::Spaeter => (
                "snooze",
                morgen_acht_uhr_ms().map(|at| serde_json::json!({ "wakeAt": at })),
                "Zurückgestellt bis morgen, 8:00",
                true,
                true,
            ),
        };

        // Optimistisch: die Liste zeigt das Ergebnis sofort, der Kern bestätigt.
        if let Some(index) = self.threads.iter().position(|t| t.id == id) {
            match art {
                Aktionsart::Gelesen => self.threads[index].unread_count = 0,
                Aktionsart::Ungelesen => self.threads[index].unread_count = 1,
                Aktionsart::Stern => self.threads[index].is_starred = !thread.is_starred,
                _ => {}
            }
        }
        self.aktion_senden(id, kind, params, text.into(), verschwindet, undo, cx);
    }

    /// Schickt eine Aktion und zeigt den Toast dazu. `verschwindet` nimmt die
    /// Zeile optimistisch aus der Liste, `undo` gibt dem Toast „Rückgängig".
    fn aktion_senden(
        &mut self,
        id: i64,
        kind: &'static str,
        params: Option<serde_json::Value>,
        text: SharedString,
        verschwindet: bool,
        undo: bool,
        cx: &mut Context<Self>,
    ) {
        if verschwindet {
            self.zeile_entfernen(id, cx);
        }
        self.toast = Some(if undo {
            crate::ui::toast::Toast::mit_rueckgaengig(
                format!("{text} · 1 Mail"),
                crate::ui::toast::DAUER,
            )
        } else {
            crate::ui::toast::Toast::neu(text, Duration::from_secs(4))
        });
        self.in_flight += 1;
        self.kern.request(Request::Action {
            kind,
            thread_ids: vec![id],
            params,
        });
        cx.notify();
    }

    /// Zeile optimistisch aus der Liste nehmen (Erledigt, Papierkorb, Später …).
    fn zeile_entfernen(&mut self, id: i64, cx: &mut Context<Self>) {
        let Some(index) = self.threads.iter().position(|t| t.id == id) else {
            return;
        };
        self.threads.remove(index);
        let alt = self.rows.len();
        list::rows_bauen(self);
        let neu = self.rows.len();
        if alt == 0 || self.selected.is_none() {
            self.list_state.reset(neu);
        } else if neu != alt {
            self.list_state.splice(0..alt, neu);
        }
        self.selected = self
            .threads
            .get(index.min(self.threads.len().saturating_sub(1)))
            .map(|t| t.id);
        if self.expanded == Some(id) {
            self.schliessen(cx);
        }
    }

    fn hinweis_keine_auswahl(&mut self, cx: &mut Context<Self>) {
        self.toast = Some(crate::ui::toast::Toast::neu(
            "Keine Mail ausgewählt",
            Duration::from_secs(3),
        ));
        cx.notify();
    }

    /// „Rückgängig" im Toast: der Kern nimmt die letzte Aktion im 30-s-Fenster zurück.
    pub fn rueckgaengig(&mut self, cx: &mut Context<Self>) {
        self.toast = None;
        self.in_flight += 1;
        self.kern.request(Request::Undo);
        cx.notify();
    }

    // ------------------------------------------------------- Später-Auswahl

    /// `⇧H`: Vorschläge wie in der Mac-App und ein eigenes Datum.
    pub fn spaeter_auswahl_oeffnen(&mut self, cx: &mut Context<Self>) {
        if self.selected.is_none() {
            self.hinweis_keine_auswahl(cx);
            return;
        }
        let jetzt = chrono::Local::now().timestamp_millis();
        let eintraege = snooze::presets(jetzt)
            .into_iter()
            .map(|preset| Eintrag {
                key: preset.at,
                name: preset.name.into(),
                neben: snooze::zeit_text(preset.at, jetzt).into(),
                marke: false,
            })
            .collect();
        self.auswahl = Some(Auswahl {
            art: Auswahlart::Spaeter,
            titel: "Später".into(),
            eintraege,
            index: 0,
            eigenes: true,
            fehler: None,
        });
        self.datumfeld.update(cx, |feld, cx| {
            feld.text.clear();
            feld.cursor = 0;
            cx.notify();
        });
        self.kontextmenue = None;
        cx.notify();
    }

    /// „Später" auf einen festen Zeitpunkt (Millisekunden).
    pub fn snooze_bis(&mut self, at: i64, cx: &mut Context<Self>) {
        self.auswahl = None;
        let Some(id) = self.selected else { return };
        let text: SharedString = format!("Zurückgestellt bis {}", snooze::kurz(at)).into();
        self.aktion_senden(
            id,
            "snooze",
            Some(serde_json::json!({ "wakeAt": at })),
            text,
            true,
            true,
            cx,
        );
    }

    /// Zeile „Eigenes Datum": Fokus ins Feld darunter.
    pub fn auswahl_eigenes_feld(&mut self, cx: &mut Context<Self>) {
        if let Some(auswahl) = self.auswahl.as_mut() {
            auswahl.index = auswahl.eintraege.len();
            auswahl.fehler = None;
        }
        self.pending_focus = Some(Fokus::Datum);
        cx.notify();
    }

    /// `↵` im Feld „Eigenes Datum".
    pub fn auswahl_datum_uebernehmen(&mut self, cx: &mut Context<Self>) {
        let text = self.datumfeld.read(cx).text().to_string();
        let jetzt = chrono::Local::now().timestamp_millis();
        match snooze::parse(&text, jetzt) {
            Some(at) => self.snooze_bis(at, cx),
            None => {
                if let Some(auswahl) = self.auswahl.as_mut() {
                    auswahl.fehler = Some(
                        "Nicht verstanden — z. B. „morgen 9:00“ oder „24.11. 18:00“".into(),
                    );
                }
                cx.notify();
            }
        }
    }

    // ---------------------------------------------------- Verschieben/Labels

    /// `V`: Ordner holen und die Auswahl öffnen.
    pub fn verschieben_auswahl_oeffnen(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected else {
            self.hinweis_keine_auswahl(cx);
            return;
        };
        let account_id = self.thread(id).map(|thread| thread.account_id);
        self.kontextmenue = None;
        self.ordner_erwartet = Some(id);
        self.in_flight += 1;
        self.kern.request(Request::Folders { account_id });
        self.status = "Ordner werden geladen …".into();
        cx.notify();
    }

    /// Ordner sind da: die Auswahl öffnen.
    fn auswahl_fuer_ordner(&mut self, id: i64, cx: &mut Context<Self>) {
        if self.selected != Some(id) {
            return;
        }
        let mut folders: Vec<FolderInfo> =
            self.folders.iter().filter(|folder| folder.is_waehlbar()).cloned().collect();
        // Posteingang und Archiv zuerst, der Rest in der Reihenfolge des Kerns.
        // Die Rollen schreibt der Kern klein (`roles::INBOX` = "inbox").
        let rang = |folder: &FolderInfo| match folder.role.as_deref() {
            Some("inbox") => 0,
            Some("archive") => 1,
            _ => 2,
        };
        folders.sort_by_key(rang);
        let eintraege: Vec<Eintrag> = folders
            .into_iter()
            .map(|folder| Eintrag {
                key: folder.id,
                name: folder.display_name().into(),
                neben: SharedString::default(),
                marke: false,
            })
            .collect();
        if eintraege.is_empty() {
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Keine Ordner gefunden",
                Duration::from_secs(3),
            ));
            cx.notify();
            return;
        }
        self.status = "bereit".into();
        self.auswahl = Some(Auswahl {
            art: Auswahlart::Verschieben,
            titel: "Verschieben nach …".into(),
            eintraege,
            index: 0,
            eigenes: false,
            fehler: None,
        });
        cx.notify();
    }

    /// `L`: Labels des Kontos, gesetzte mit Haken.
    pub fn label_auswahl_oeffnen(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected else {
            self.hinweis_keine_auswahl(cx);
            return;
        };
        let Some(thread) = self.thread(id).cloned() else { return };
        let mut labels: Vec<&Label> = self.labels.iter().filter(|label| !label.is_auto).collect();
        labels.sort_by_key(|label| label.position);
        let eintraege: Vec<Eintrag> = labels
            .into_iter()
            .map(|label| Eintrag {
                key: label.id,
                name: label.name.clone().into(),
                neben: SharedString::default(),
                marke: thread.labels.contains(&label.id),
            })
            .collect();
        if eintraege.is_empty() {
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Keine Labels angelegt",
                Duration::from_secs(3),
            ));
            cx.notify();
            return;
        }
        self.kontextmenue = None;
        self.auswahl = Some(Auswahl {
            art: Auswahlart::Label,
            titel: "Label".into(),
            eintraege,
            index: 0,
            eigenes: false,
            fehler: None,
        });
        cx.notify();
    }

    fn label_umschalten(
        &mut self,
        label_id: i64,
        name: String,
        an: bool,
        cx: &mut Context<Self>,
    ) {
        self.auswahl = None;
        let Some(id) = self.selected else { return };
        if let Some(thread) = self.threads.iter_mut().find(|thread| thread.id == id) {
            if an && !thread.labels.contains(&label_id) {
                thread.labels.push(label_id);
            } else if !an {
                thread.labels.retain(|label| *label != label_id);
            }
        }
        let kind = if an { "add_label" } else { "remove_label" };
        let text: SharedString =
            format!("Label {name} {}", if an { "gesetzt" } else { "entfernt" }).into();
        self.aktion_senden(
            id,
            kind,
            Some(serde_json::json!({ "labelId": label_id })),
            text,
            false,
            false,
            cx,
        );
    }

    // ------------------------------------------------------------- Auswahl

    pub fn auswahl_bewegen(&mut self, delta: isize, cx: &mut Context<Self>) {
        let Some(auswahl) = self.auswahl.as_mut() else { return };
        let anzahl = auswahl.zeilen();
        if anzahl == 0 {
            return;
        }
        let index = auswahl.index as isize + delta;
        auswahl.index = index.rem_euclid(anzahl as isize) as usize;
        cx.notify();
    }

    /// `↵` oder Klick auf eine Zeile der Auswahl.
    pub fn auswahl_nehmen(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(auswahl) = self.auswahl.clone() else { return };
        match auswahl.art {
            Auswahlart::Spaeter => match auswahl.eintraege.get(index) {
                Some(eintrag) => self.snooze_bis(eintrag.key, cx),
                None => self.auswahl_eigenes_feld(cx),
            },
            Auswahlart::Verschieben => {
                let Some(eintrag) = auswahl.eintraege.get(index) else { return };
                let Some(id) = self.selected else { return };
                let (folder_id, name) = (eintrag.key, eintrag.name.to_string());
                self.auswahl = None;
                self.aktion_senden(
                    id,
                    "move",
                    Some(serde_json::json!({ "targetFolderId": folder_id })),
                    format!("Verschoben nach {name}").into(),
                    true,
                    true,
                    cx,
                );
            }
            Auswahlart::Senden => {
                let Some(eintrag) = auswahl.eintraege.get(index) else { return };
                let at = eintrag.key;
                self.auswahl = None;
                self.entwurf_speichern(SendeAbsicht::Um(at), cx);
            }
            Auswahlart::Label => {
                let Some(eintrag) = auswahl.eintraege.get(index) else { return };
                let (label_id, name, an) = (eintrag.key, eintrag.name.to_string(), !eintrag.marke);
                self.label_umschalten(label_id, name, an, cx);
            }
        }
    }

    pub fn auswahl_schliessen(&mut self, cx: &mut Context<Self>) {
        if self.auswahl.take().is_some() {
            self.pending_focus = Some(Fokus::Liste);
            cx.notify();
        }
    }

    // ---------------------------------------------------------- Kontextmenü

    /// Rechtsklick öffnet das Menü am Zeiger; es gilt für die Zeile darunter.
    pub fn kontextmenue_oeffnen(&mut self, id: i64, x: f32, y: f32, cx: &mut Context<Self>) {
        let Some(thread) = self.thread(id).cloned() else { return };
        self.selected = Some(id);
        self.auswahl = None;
        let mut eintraege: Vec<(thread::Menuebefehl, SharedString, &'static str)> = Vec::new();
        eintraege.push((
            thread::Menuebefehl::Oeffnen,
            if self.expanded == Some(id) { "Schließen" } else { "Öffnen" }.into(),
            "↵",
        ));
        eintraege.push((
            thread::Menuebefehl::Gelesen,
            if thread.unread() { "Als gelesen markieren" } else { "Als ungelesen markieren" }
                .into(),
            "U",
        ));
        eintraege.push((
            thread::Menuebefehl::Stern,
            if thread.is_starred { "Markierung entfernen" } else { "Markieren" }.into(),
            "S",
        ));
        if self.view == MailView::Done {
            eintraege.push((
                thread::Menuebefehl::Zurueck,
                "Zurück in den Posteingang".into(),
                "⇧E",
            ));
        } else {
            eintraege.push((thread::Menuebefehl::Erledigt, "Erledigt".into(), "E"));
        }
        eintraege.push((thread::Menuebefehl::Spaeter, "Später (morgen 8:00)".into(), "H"));
        eintraege.push((thread::Menuebefehl::SpaeterAuswahl, "Später …".into(), "⇧H"));
        eintraege.push((thread::Menuebefehl::Verschieben, "Verschieben …".into(), "V"));
        eintraege.push((thread::Menuebefehl::Label, "Label …".into(), "L"));
        eintraege.push((
            thread::Menuebefehl::Papierkorb,
            if self.view == MailView::Trash {
                "Endgültig löschen …"
            } else {
                "In den Papierkorb"
            }
            .into(),
            "#",
        ));
        eintraege.push((
            thread::Menuebefehl::Spam,
            if self.view == MailView::Spam { "Kein Spam" } else { "Als Spam markieren" }.into(),
            "!",
        ));
        self.kontextmenue = Some(thread::Kontextmenue {
            id,
            x,
            y,
            index: 0,
            eintraege,
        });
        cx.notify();
    }

    pub fn kontextmenue_bewegen(&mut self, delta: isize, cx: &mut Context<Self>) {
        let Some(menue) = self.kontextmenue.as_mut() else { return };
        if menue.eintraege.is_empty() {
            return;
        }
        let anzahl = menue.eintraege.len() as isize;
        menue.index = (menue.index as isize + delta).rem_euclid(anzahl) as usize;
        cx.notify();
    }

    pub fn kontextmenue_nehmen(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(menue) = self.kontextmenue.take() else { return };
        let Some((befehl, _, _)) = menue.eintraege.get(index).cloned() else { return };
        self.befehl_ausfuehren(menue.id, befehl, cx);
    }

    /// Einen Befehl auf einen Thread anwenden — aus dem Kontextmenü oder aus
    /// der Aktionsleiste; dieselben Wege wie die Tasten.
    pub fn befehl_ausfuehren(&mut self, id: i64, befehl: thread::Menuebefehl, cx: &mut Context<Self>) {
        self.selected = Some(id);
        match befehl {
            thread::Menuebefehl::Oeffnen => {
                if self.expanded == Some(id) {
                    self.schliessen(cx);
                } else {
                    self.oeffne(id, cx);
                }
            }
            thread::Menuebefehl::Gelesen => {
                let ungelesen = self
                    .thread(id)
                    .map(|thread| thread.unread_count > 0)
                    .unwrap_or(false);
                let art = if ungelesen { Aktionsart::Gelesen } else { Aktionsart::Ungelesen };
                self.aktion_auf_auswahl(art, cx);
            }
            thread::Menuebefehl::Stern => self.aktion_auf_auswahl(Aktionsart::Stern, cx),
            thread::Menuebefehl::Erledigt => self.aktion_auf_auswahl(Aktionsart::Erledigt, cx),
            thread::Menuebefehl::Zurueck => self.aktion_auf_auswahl(Aktionsart::Zurueck, cx),
            thread::Menuebefehl::Spaeter => self.aktion_auf_auswahl(Aktionsart::Spaeter, cx),
            thread::Menuebefehl::SpaeterAuswahl => self.spaeter_auswahl_oeffnen(cx),
            thread::Menuebefehl::Verschieben => self.verschieben_auswahl_oeffnen(cx),
            thread::Menuebefehl::Label => self.label_auswahl_oeffnen(cx),
            thread::Menuebefehl::Papierkorb => self.aktion_auf_auswahl(Aktionsart::Papierkorb, cx),
            thread::Menuebefehl::Spam => self.aktion_auf_auswahl(Aktionsart::Spam, cx),
        }
        cx.notify();
    }

    /// Hat eines der Verfassen-Felder den Tastaturfokus?
    fn compose_felder_fokussiert(&self, window: &Window, cx: &App) -> bool {
        self.feld_an.read(cx).is_focused(window)
            || self.feld_cc.read(cx).is_focused(window)
            || self.feld_bcc.read(cx).is_focused(window)
            || self.feld_betreff.read(cx).is_focused(window)
    }

    /// Inhalt der Felder und des Editors als Fingerabdruck fürs Autosave.
    fn compose_stand_lesen(&self, cx: &App) -> String {
        let text = self
            .editor
            .as_ref()
            .map(|editor| editor.read(cx).content(cx).text)
            .unwrap_or_default();
        format!(
            "{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}",
            self.feld_an.read(cx).text(),
            self.feld_cc.read(cx).text(),
            self.feld_bcc.read(cx).text(),
            self.feld_betreff.read(cx).text(),
            text
        )
    }

    /// Nach Tipppause speichern, ohne dass der Nutzer etwas tun muss.
    fn autosave_pruefen(&mut self, cx: &mut Context<Self>) {
        if self.compose_aktiv.is_none() || self.speichert.is_some() {
            return;
        }
        let stand = self.compose_stand_lesen(cx);
        if self.compose_stand.as_deref() != Some(stand.as_str()) {
            self.compose_stand = Some(stand);
            self.compose_stand_seit = Some(Instant::now());
            return;
        }
        let seit = self.compose_stand_seit;
        if seit.is_some() && crate::state::compose::autosave_faellig(true, seit, Instant::now()) {
            self.compose_stand_seit = None;
            self.entwurf_speichern(SendeAbsicht::Nichts, cx);
        }
    }

    // ------------------------------------------------------------- Verfassen

    /// `c` neu, `r` antworten, `a` allen antworten, `f` weiterleiten.
    pub fn verfassen(&mut self, modus: Modus, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(compose) = self.verfassen_auftrag(modus) {
            let id = compose.id;
            self.compose.retain(|vorhanden| vorhanden.id != id);
            self.compose.push(compose);
            self.compose_laden(id, window, cx);
            self.compose_fokus = true;
            cx.notify();
        }
    }

    /// Baut den Auftrag ohne Fenster — für Hooks und den Weg über `pending_dock`
    /// (die Antwort des Kerns kommt ohne `Window`, `set_content` braucht eines).
    pub fn verfassen_auftrag(&mut self, modus: Modus) -> Option<Compose> {
        let Some(konto) = self
            .account_id
            .or_else(|| self.threads.first().map(|thread| thread.account_id))
        else {
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Kein Konto geladen",
                Duration::from_secs(3),
            ));
            return None;
        };
        let id = self.naechste_compose_id;
        self.naechste_compose_id += 1;
        let mut compose = Compose::neu(id, modus, konto);
        compose.doc = Some(crate::editor::EditorDoc::default());

        if modus != Modus::Neu {
            let detail = self
                .expanded
                .and_then(|tid| self.details.get(&tid))
                .or_else(|| self.selected.and_then(|tid| self.details.get(&tid)))
                .cloned();
            let Some(detail) = detail else {
                self.toast = Some(crate::ui::toast::Toast::neu(
                    "Mail zum Antworten erst öffnen",
                    Duration::from_secs(3),
                ));
                return None;
            };
            compose.betreff = crate::state::compose::betreff(&detail.thread.subject, modus);
            if let Some(nachricht) = detail.messages.last() {
                let von = nachricht.from.display();
                let datum = crate::ui::list::datum_lang(nachricht.date);
                let original = nachricht.text_body.clone().unwrap_or_default();
                match modus {
                    Modus::Antwort | Modus::AllenAntworten => {
                        compose.an = nachricht.from.email.clone();
                        compose.antwort_auf = Some(detail.thread.id);
                        compose.doc = Some(crate::editor::EditorDoc::from_plain(
                            crate::state::compose::zitat(&original, &von, &datum),
                        ));
                        if modus == Modus::AllenAntworten {
                            let mich = self
                                .accounts
                                .iter()
                                .find(|account| account.id == konto)
                                .map(|account| account.email.to_lowercase())
                                .unwrap_or_default();
                            let mut cc: Vec<String> = Vec::new();
                            for adresse in nachricht.to.iter().chain(nachricht.cc.iter()) {
                                let mail = adresse.email.to_lowercase();
                                if mail == mich || mail == nachricht.from.email.to_lowercase() {
                                    continue;
                                }
                                if !cc.iter().any(|vorhanden| vorhanden == &adresse.email) {
                                    cc.push(adresse.email.clone());
                                }
                            }
                            compose.cc = cc.join(", ");
                        }
                    }
                    Modus::Weiterleiten => {
                        let konto_mail = self
                            .accounts
                            .iter()
                            .find(|account| account.id == konto)
                            .map(|account| account.email.clone())
                            .unwrap_or_default();
                        compose.doc = Some(crate::editor::EditorDoc::from_plain(
                            crate::state::compose::weiterleitung(
                                &original,
                                &von,
                                &konto_mail,
                                &datum,
                                &detail.thread.subject,
                            ),
                        ));
                    }
                    Modus::Neu => {}
                }
            }
        }

        Some(compose)
    }

    /// Fenster in die Felder und den Editor laden (auch beim Wechsel).
    fn compose_laden(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(compose) = self.compose.iter().find(|compose| compose.id == id).cloned() else {
            return;
        };
        let betreff = compose.betreff.clone();
        setze_feld(&self.feld_an, &compose.an, cx);
        setze_feld(&self.feld_cc, &compose.cc, cx);
        setze_feld(&self.feld_bcc, &compose.bcc, cx);
        setze_feld(&self.feld_betreff, &betreff, cx);
        self.cc_bcc = !compose.cc.trim().is_empty() || !compose.bcc.trim().is_empty();
        self.compose_aktiv = Some(id);
        self.compose_stand = None;
        self.compose_stand_seit = None;
        self.vorschlaege.clear();
        self.vorschlag_index = 0;

        let doc = compose.doc.clone().unwrap_or_default();
        let editor = self
            .editor
            .get_or_insert_with(|| cx.new(|cx| ComposeEditor::new(window, cx)))
            .clone();
        editor.update(cx, |editor, cx| editor.set_content(&doc, window, cx));
        // Der Körper nimmt die Tasten: ohne echten Fokus gingen Buchstaben in
        // die Einzeltasten-Kürzel der Liste statt in den Entwurf.
        self.compose_fokus = true;
        self.pending_focus = Some(Fokus::Verfassen);
        cx.notify();
    }

    /// Felder und Editor in den Zustand zurückschreiben (vor Wechsel/Schließen).
    fn compose_einlesen(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.compose_aktiv else { return };
        let an = self.feld_an.read(cx).text().to_string();
        let cc = self.feld_cc.read(cx).text().to_string();
        let bcc = self.feld_bcc.read(cx).text().to_string();
        let betreff = self.feld_betreff.read(cx).text().to_string();
        let doc = self.editor.as_ref().map(|editor| editor.read(cx).content(cx));
        if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
            compose.an = an;
            compose.cc = cc;
            compose.bcc = bcc;
            compose.betreff = betreff;
            if let Some(doc) = doc {
                compose.doc = Some(doc);
            }
        }
    }

    /// Anderes Fenster nach vorn holen.
    pub fn compose_wechseln(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        if self.compose_aktiv == Some(id) {
            return;
        }
        self.compose_einlesen(cx);
        if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
            compose.minimiert = false;
        }
        self.compose_laden(id, window, cx);
    }

    /// Minimieren (bleibt im Dock) — speichert vorher den Entwurf.
    pub fn compose_minimieren(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.compose_aktiv else { return };
        self.compose_einlesen(cx);
        self.compose_aktiv = None;
        self.compose_fokus = false;
        self.pending_focus = Some(Fokus::Liste);
        if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
            compose.minimiert = true;
        }
        self.entwurf_speichern_fuer(id, SendeAbsicht::Nichts, cx);
        cx.notify();
    }

    /// Schließen; mit `verwerfen` wird der Entwurf im Kern gelöscht.
    pub fn compose_schliessen(&mut self, verwerfen: bool, cx: &mut Context<Self>) {
        self.compose_einlesen(cx);
        let Some(id) = self.compose_aktiv.take() else { return };
        let Some(compose) = self.compose.iter().find(|compose| compose.id == id).cloned() else {
            return;
        };
        if verwerfen {
            if let Some(draft_id) = compose.draft_id {
                self.in_flight += 1;
                self.kern.request(Request::DeleteDraft { draft_id });
            }
            self.compose.retain(|vorhanden| vorhanden.id != id);
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Entwurf verworfen",
                Duration::from_secs(3),
            ));
        } else {
            self.entwurf_speichern_fuer(id, SendeAbsicht::Nichts, cx);
        }
        cx.notify();
    }

    /// Vorschläge zum An-Feld holen (ab zwei Zeichen).
    pub fn vorschlaege_anfragen(&mut self, cx: &mut Context<Self>) {
        if self.vorschlag_laeuft {
            return;
        }
        let an = self.feld_an.read(cx).text().to_string();
        let teil = an.rsplit(',').next().unwrap_or("").trim().to_string();
        if teil.chars().count() < 2 {
            self.vorschlaege.clear();
            cx.notify();
            return;
        }
        self.vorschlag_laeuft = true;
        self.in_flight += 1;
        self.kern.request(Request::SuggestContacts { prefix: teil });
        cx.notify();
    }

    /// Vorschlag übernehmen: ersetzt den angefangenen Teil des An-Felds.
    pub fn vorschlag_nehmen(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(vorschlag) = self.vorschlaege.get(index).cloned() else { return };
        let an = self.feld_an.read(cx).text().to_string();
        let mut teile: Vec<String> = an
            .split(',')
            .map(|teil| teil.trim().to_string())
            .filter(|teil| !teil.is_empty())
            .collect();
        if teile.is_empty() {
            teile.push(vorschlag.anzeige());
        } else if let Some(letzte) = teile.last_mut() {
            *letzte = vorschlag.anzeige();
        }
        let neu = format!("{}, ", teile.join(", "));
        setze_feld(&self.feld_an, &neu, cx);
        self.vorschlaege.clear();
        self.vorschlag_index = 0;
        cx.notify();
    }

    pub fn vorschlag_bewegen(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.vorschlaege.is_empty() {
            return;
        }
        let anzahl = self.vorschlaege.len() as isize;
        self.vorschlag_index = (self.vorschlag_index as isize + delta).rem_euclid(anzahl) as usize;
        cx.notify();
    }

    /// Entwurf speichern; `danach_senden` heißt: im Erfolgsfall gleich raus.
    fn entwurf_speichern(&mut self, absicht: SendeAbsicht, cx: &mut Context<Self>) {
        let Some(id) = self.compose_aktiv else { return };
        self.compose_einlesen(cx);
        self.entwurf_speichern_fuer(id, absicht, cx);
    }

    /// Wie [`AppState::entwurf_speichern`], aber für ein Fenster, das gerade
    /// nicht mehr aktiv ist (Minimieren, Schließen).
    fn entwurf_speichern_fuer(&mut self, id: u64, absicht: SendeAbsicht, _cx: &mut Context<Self>) {
        if self.speichert.is_some() {
            return;
        }
        let Some(compose) = self.compose.iter().find(|compose| compose.id == id).cloned() else {
            return;
        };
        let doc = compose.doc.clone().unwrap_or_default();
        let args = serde_json::json!({
            "draftId": compose.draft_id,
            "accountId": compose.konto,
            "to": adressen_json(&compose.an),
            "cc": adressen_json(&compose.cc),
            "bcc": adressen_json(&compose.bcc),
            "subject": compose.betreff,
            "bodyText": doc.to_plain(),
            "bodyHtml": doc.to_html(),
            "mode": compose.modus.kern_name(),
            "inReplyToMessageId": compose.antwort_auf,
            "attachments": compose.anhaenge.iter().map(|anhang| serde_json::json!({
                "filePath": anhang.pfad.to_string_lossy(),
                "filename": anhang.name,
            })).collect::<Vec<_>>(),
        });
        self.speichert = Some((id, absicht));
        self.in_flight += 1;
        self.kern.request(Request::SaveDraft { args });
    }

    /// Der Kern hat gespeichert.
    fn entwurf_gespeichert(&mut self, draft_id: i64, cx: &mut Context<Self>) {
        let Some((id, absicht)) = self.speichert.take() else { return };
        if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
            compose.draft_id = Some(draft_id);
        }
        match absicht {
            SendeAbsicht::Jetzt => return self.sende_einreihen(draft_id, None, cx),
            SendeAbsicht::Um(at) => return self.sende_einreihen(draft_id, Some(at), cx),
            SendeAbsicht::Nichts => {}
        }
        if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
            let laenge = compose.an.len() + compose.betreff.len() + compose.doc.as_ref().map_or(0, |doc| doc.text.len());
            eprintln!("L2-ENTWURF id={draft_id} fenster={id} zeichen={laenge}");
        }
        cx.notify();
    }

    /// `queue_send` mit oder ohne Zeitpunkt.
    fn sende_einreihen(&mut self, draft_id: i64, send_at: Option<i64>, cx: &mut Context<Self>) {
        self.send_absicht = Some(match send_at {
            Some(at) => SendeAbsicht::Um(at),
            None => SendeAbsicht::Jetzt,
        });
        self.in_flight += 1;
        self.kern.request(Request::QueueSend { draft_id, send_at });
        cx.notify();
    }

    /// Senden: erst den Entwurf sichern, dann einreihen. Prüft vorher die Adressen.
    pub fn senden(&mut self, cx: &mut Context<Self>) {
        self.compose_einlesen(cx);
        let Some(id) = self.compose_aktiv else { return };
        let Some(compose) = self.compose.iter().find(|compose| compose.id == id).cloned() else {
            return;
        };
        let schlecht = [&compose.an, &compose.cc, &compose.bcc]
            .iter()
            .flat_map(|feld| ungueltige(feld))
            .collect::<Vec<String>>();
        if schlecht.is_empty() && adressen_parsen(&compose.an).is_empty() {
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Kein Empfänger",
                Duration::from_secs(3),
            ));
            cx.notify();
            return;
        }
        if !schlecht.is_empty() {
            self.toast = Some(crate::ui::toast::Toast::neu(
                format!("Adresse nicht verstanden: {}", schlecht.join(", ")),
                Duration::from_secs(5),
            ));
            cx.notify();
            return;
        }
        if compose.doc.as_ref().map(|doc| doc.text.trim().is_empty()).unwrap_or(true) {
            self.toast = Some(crate::ui::toast::Toast::neu(
                "Nachricht ist leer",
                Duration::from_secs(3),
            ));
            cx.notify();
            return;
        }
        self.entwurf_speichern(SendeAbsicht::Jetzt, cx);
    }

    /// Datei-Dialog für Anhänge öffnen (Portal, auf der Kern-Runtime).
    pub fn anhaenge_waehlen(&mut self, cx: &mut Context<Self>) {
        if self.compose_aktiv.is_none() || self.anhaenge_laeuft {
            return;
        }
        self.anhaenge_laeuft = true;
        self.in_flight += 1;
        self.kern.request(Request::AnhaengeWaehlen);
        cx.notify();
    }

    /// Anhang ohne Portal anhängen (Messbuild/Hooks).
    #[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
    pub fn compose_anhang_setzen(
        &mut self,
        pfad: std::path::PathBuf,
        name: String,
        groesse: u64,
        mime: String,
        cx: &mut Context<Self>,
    ) {
        self.compose_einlesen(cx);
        if let Some(id) = self.compose_aktiv {
            if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
                compose.anhaenge.push(crate::state::compose::Anhang { pfad, name, groesse, mime });
                eprintln!("L2-ANHANG angehaengt n={}", compose.anhaenge.len());
            }
        }
        cx.notify();
    }

    /// Anhang wieder entfernen.
    pub fn anhang_entfernen(&mut self, index: usize, cx: &mut Context<Self>) {
        self.compose_einlesen(cx);
        if let Some(id) = self.compose_aktiv {
            if let Some(compose) = self.compose.iter_mut().find(|compose| compose.id == id) {
                if index < compose.anhaenge.len() {
                    compose.anhaenge.remove(index);
                }
            }
        }
        cx.notify();
    }

    /// „Später senden": dieselben Presets wie beim Snooze.
    pub fn spaeter_senden(&mut self, cx: &mut Context<Self>) {
        if self.compose_aktiv.is_none() {
            return;
        }
        let jetzt = chrono::Local::now().timestamp_millis();
        let eintraege = snooze::presets(jetzt)
            .into_iter()
            .map(|preset| Eintrag {
                key: preset.at,
                name: preset.name.into(),
                neben: snooze::zeit_text(preset.at, jetzt).into(),
                marke: false,
            })
            .collect();
        self.auswahl = Some(Auswahl {
            art: Auswahlart::Senden,
            titel: "Später senden".into(),
            eintraege,
            index: 0,
            eigenes: false,
            fehler: None,
        });
        cx.notify();
    }

    /// Senden eingereiht: Fenster zu, Toast mit Rückgängig.
    fn gesendet(&mut self, action_id: i64, dispatch_at: i64, cx: &mut Context<Self>) {
        self.compose_einlesen(cx);
        if let Some(id) = self.compose_aktiv.take() {
            if let Some(compose) = self.compose.iter().find(|compose| compose.id == id).cloned() {
                self.letzte_sendung = Some((action_id, compose));
            }
            self.compose.retain(|compose| compose.id != id);
        }
        let jetzt = chrono::Local::now().timestamp_millis();
        // „Später senden" erkennt man an der Absicht, nicht am Zeitfenster:
        // auch ein sofortiger Versand liegt einige Sekunden in der Zukunft
        // (`undo_send_seconds`), sonst gäbe es kein Rückgängig.
        let text = if matches!(self.send_absicht.take(), Some(SendeAbsicht::Um(_))) {
            format!(
                "Später senden eingereiht: {}",
                snooze::zeit_text(dispatch_at, jetzt)
            )
        } else {
            "Wird gesendet · 1 Nachricht".to_string()
        };
        // Das Rückgängig-Fenster ist das des Kerns (`undo_send_seconds`, hier
        // über `dispatch_at`): der Knopf bleibt so lange stehen wie die Chance.
        let dauer = std::time::Duration::from_millis(
            (dispatch_at - jetzt).clamp(5_000, 120_000) as u64,
        );
        self.toast = Some(crate::ui::toast::Toast::mit_senden(action_id, text, dauer));
        cx.notify();
    }

    /// Knopf im Toast: je nach Ziel zurücknehmen oder Senden abbrechen.
    pub fn toast_aktion(&mut self, cx: &mut Context<Self>) {
        let Some(toast) = self.toast.take() else { return };
        match toast.ziel {
            crate::ui::toast::ToastZiel::Undo => self.rueckgaengig(cx),
            crate::ui::toast::ToastZiel::SendCancel(action_id) => {
                self.in_flight += 1;
                self.kern.request(Request::CancelSend { action_id });
                cx.notify();
            }
        }
    }

    // ------------------------------------------------------------- Rückfrage

    /// Tasten in der Rückfrage: `Esc`/`↵` brechen ab, `Tab`/Pfeile wechseln,
    /// erst der gewechselte Knopf löst das Löschen aus.
    fn bestaetigung_tasten(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let gewaehlt = self.bestaetigung.as_ref().is_some_and(|frage| frage.loeschen);
        match dialog::taste(event.keystroke.key.as_str(), gewaehlt) {
            Antwort::Nichts => {}
            Antwort::Umschalten => {
                if let Some(frage) = self.bestaetigung.as_mut() {
                    frage.loeschen = !frage.loeschen;
                }
                cx.notify();
            }
            Antwort::Abbrechen => {
                self.bestaetigung = None;
                cx.notify();
            }
            Antwort::Loeschen => self.bestaetigung_bestaetigen(cx),
        }
    }

    /// Der gefährliche Knopf: ausführen und die Rückfrage schließen.
    pub fn bestaetigung_bestaetigen(&mut self, cx: &mut Context<Self>) {
        let Some(frage) = self.bestaetigung.take() else { return };
        match frage.ziel {
            BestaetigungZiel::AnhangOeffnen(pfad) => {
                if let Err(fehler) =
                    crate::core::host::oeffnen_mit(&crate::core::host::oeffner(), &pfad)
                {
                    self.toast = Some(crate::ui::toast::Toast::neu(
                        format!("Öffnen fehlgeschlagen: {fehler}"),
                        Duration::from_secs(5),
                    ));
                }
                cx.notify();
            }
            BestaetigungZiel::EndgueltigLoeschen(id) => {
                self.selected = Some(id);
                self.aktion_senden(
                    id,
                    "delete_permanently",
                    None,
                    "Endgültig gelöscht".into(),
                    true,
                    false,
                    cx,
                );
            }
        }
    }

    pub fn kontextmenue_schliessen(&mut self, cx: &mut Context<Self>) {
        if self.kontextmenue.take().is_some() {
            cx.notify();
        }
    }
}

/// Rückfrage vor dem Öffnen eines gefährdeten Anhangs. Vorgabe ist immer
/// „Abbrechen" (`loeschen: false`), wie beim endgültigen Löschen.
pub fn anhang_frage(text: String, pfad: String) -> Bestaetigung {
    Bestaetigung {
        text: text.into(),
        knopf: "Trotzdem öffnen".into(),
        loeschen: false,
        hinweis: "Tab wechselt · ↵ bestätigt die Auswahl · Esc bricht ab".into(),
        ziel: BestaetigungZiel::AnhangOeffnen(pfad),
    }
}

/// „Name <mail>" oder nur die Adresse — wie sie im Feld steht.
fn adresse_text(adresse: &crate::core::models::Address) -> String {
    match adresse.name.as_deref().map(str::trim).filter(|name| !name.is_empty()) {
        Some(name) => format!("{name} <{}>", adresse.email),
        None => adresse.email.clone(),
    }
}

/// Text in ein Feld setzen, Cursor ans Ende.
fn setze_feld(feld: &Entity<TextField>, text: &str, cx: &mut Context<AppState>) {
    let text = text.to_string();
    feld.update(cx, |feld, cx| {
        feld.cursor = text.encode_utf16().count();
        feld.text = text;
        cx.notify();
    });
}

/// Adressen eines Feldes als JSON für `save_draft`.
fn adressen_json(text: &str) -> Vec<serde_json::Value> {
    adressen_parsen(text)
        .into_iter()
        .map(|adresse| match adresse.name {
            Some(name) => serde_json::json!({ "name": name, "email": adresse.email }),
            None => serde_json::json!({ "name": null, "email": adresse.email }),
        })
        .collect()
}

/// Morgen 8:00 als Millisekunden (Vorgabe für „Später", wie auf dem Mac).
fn morgen_acht_uhr_ms() -> Option<i64> {
    use chrono::TimeZone as _;
    let morgen = chrono::Local::now().date_naive() + chrono::Duration::days(1);
    let zeit = morgen.and_hms_opt(8, 0, 0)?;
    chrono::Local.from_local_datetime(&zeit).single().map(|zeit| zeit.timestamp_millis())
}

impl Render for AppState {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = self.theme.clone();
        let breite = f32::from(window.viewport_size().width);
        let hoehe = f32::from(window.viewport_size().height);
        self.fenster_breite = breite;
        self.fenster_hoehe = hoehe;
        let seitenleiste = self.seitenleiste && breite >= 872.;
        let toast_inhalt = self
            .toast
            .as_ref()
            .map(|toast| (toast.text.clone(), toast.aktion.clone()));

        // Ein Entwurf kam ohne Fenster an (Entwürfe, abgebrochenes Senden):
        // hier ist das Fenster da, um Felder und Editor zu füllen.
        if let Some(compose) = self.pending_dock.take() {
            let id = compose.id;
            self.compose.retain(|vorhanden| vorhanden.id != id);
            self.compose.push(compose);
            self.compose_laden(id, window, cx);
        }

        // Beleg-Hook: Text in den Editor setzen (braucht das Fenster).
        if let Some(text) = self.pending_editor_text.take() {
            if let Some(editor) = self.editor.clone() {
                let doc = crate::editor::EditorDoc::from_plain(text);
                editor.update(cx, |editor, cx| editor.set_content(&doc, window, cx));
                if let Some(id) = self.compose_aktiv {
                    if let Some(compose) = self.compose.iter_mut().find(|c| c.id == id) {
                        compose.doc = Some(doc);
                    }
                }
            }
        }

        // Fokus aus einem Kürzel oder Hook anwenden (braucht das Fenster).
        self.fokus_anwenden(window, cx);

        // Fenstergröße aus einem Test-Hook (HiDPI-Gegenprobe, Messläufe).
        if let Some((w, h)) = self.pending_size.take() {
            window.resize(size(px(w), px(h)));
        }

        // Latenz „bis gezeichnet": erst im Frame-Callback messen, also nach
        // dem Frame, das die Karte malt (davor wäre die Zeichenzeit nicht drin).
        if let Some((_id, _name, seit)) = self.offen_marke.take() {
            window.on_next_frame(move |_window, _cx| {
                eprintln!(
                    "L1-MAIL-OEFFNEN ms={:.1}",
                    seit.elapsed().as_secs_f64() * 1000.0
                );
            });
        }
        // Kaltstart: der erste Frame, in dem Threads stehen.
        if !self.liste_gesehen && !self.rows.is_empty() && !self.loading {
            self.liste_gesehen = true;
            window.on_next_frame(|_window, _cx| {
                eprintln!("L1-LISTE-SICHTBAR ms={:.1}", perf::seit_start_ms());
            });
        }
        window.on_next_frame(|_window, _cx| perf::frame_mark());

        div()
            .id("root")
            .size_full()
            .relative()
            .flex()
            .flex_col()
            .bg(rgb(theme.bg()))
            .text_color(rgb(theme.ink1()))
            .font_family(theme.font())
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this: &mut AppState, event: &KeyDownEvent, window, cx| {
                this.tasten(event, window, cx);
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this: &mut AppState, _event: &MouseDownEvent, window, cx| {
                    let im_feld = this.suchfeld.read(cx).is_focused(window)
                        || this.datumfeld.read(cx).is_focused(window);
                    if this.kontextmenue.is_some() {
                        this.kontextmenue = None;
                        cx.notify();
                    }
                    this.compose_fokus = false;
                    if !im_feld {
                        let focus = this.focus.clone();
                        window.focus(&focus);
                    }
                }),
            )
            .child(crate::ui::toolbar::toolbar(self, window, cx))
            .child(
                div()
                    .flex_1()
                    .w_full()
                    .flex()
                    .flex_row()
                    .overflow_hidden()
                    .children(seitenleiste.then(|| crate::ui::sidebar::seitenleiste(self, window, cx)))
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .overflow_hidden()
                            .child(
                                div()
                                    .flex_1()
                                    .w_full()
                                    .overflow_hidden()
                                    .child(list::liste(self, window, cx)),
                            ),
                    ),
            )
            .child(crate::ui::toolbar::fusszeile(self, cx))
            .children(toast_inhalt.map(|(text, aktion)| {
                div()
                    .absolute()
                    .bottom(px(56.))
                    .left_0()
                    .right_0()
                    .flex()
                    .justify_center()
                    .child(crate::ui::toast::toast(text, aktion, &theme, cx))
            }))
            .children(self.hilfe.then(|| crate::ui::toolbar::hilfe_overlay(self, cx)))
            .children(self.auswahl.is_some().then(|| crate::ui::auswahl::overlay(self, cx)))
            .children(self.kontextmenue.is_some().then(|| thread::kontextmenue(self, cx)))
            .children(self.bestaetigung.is_some().then(|| dialog::dialog(self, cx)))
            .children((!self.compose.is_empty()).then(|| {
                crate::ui::compose_dock::dock(self, window, cx)
            }))
    }
}

/// Ordner mit Korpus-Mails für die Messung — nur im Messbuild. Im Release
/// bleibt `None`, damit dort keine `file://`-Basis gesetzt wird (AUDIT-L1 A1).
#[cfg(feature = "test-hooks")]
fn korpus_ordner() -> Option<PathBuf> {
    std::env::var("CORAX_KORPUS").ok().map(PathBuf::from)
}

#[cfg(not(feature = "test-hooks"))]
fn korpus_ordner() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::{anhang_frage, BestaetigungZiel};

    /// Die Anhang-Rückfrage steht auf „Abbrechen": ↵ ohne Umschalten öffnet nichts.
    #[test]
    fn anhang_frage_hat_abbrechen_als_vorgabe() {
        let frage = anhang_frage(
            "Trotzdem öffnen? .sh steckt als zweite Endung im Namen".into(),
            "/tmp/rechnung.sh.pdf".into(),
        );
        assert!(!frage.loeschen, "Vorgabe muss Abbrechen sein");
        assert_eq!(frage.knopf.as_ref(), "Trotzdem öffnen");
        assert_eq!(
            frage.ziel,
            BestaetigungZiel::AnhangOeffnen("/tmp/rechnung.sh.pdf".into())
        );
        // ↵ ohne Umschalten bricht ab (dieselbe Auswertung wie im Dialog).
        assert_eq!(
            crate::ui::dialog::taste("enter", frage.loeschen),
            crate::ui::dialog::Antwort::Abbrechen
        );
    }
}
