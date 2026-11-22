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
    Account, Label, ListThreadsArgs, MailView, SplitRule, ThreadDetail, ThreadSummary, UnreadCounts,
};
use crate::html::RemoteImages;
use crate::input::TextField;
use crate::keys::{self, Action, Ergebnis, Kontext};
use crate::perf;
use crate::theme::Theme;
use crate::ui::list::{self, Row};
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
#[derive(Debug, Default)]
pub struct Messlauf {
    pub schritte: usize,
    pub rest: usize,
    pub name: String,
    pub start: Option<Instant>,
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
    pub letzte_liste_ms: f64,

    // ---- Suche ----
    pub suche: Option<String>,
    pub suchfeld: Entity<TextField>,

    // ---- Oberfläche ----
    pub focus: FocusHandle,
    pub hilfe: bool,
    pub seitenleiste: bool,
    pub fenster_breite: f32,
    pub list_breite: f32,
    pub status: SharedString,
    pub hint: SharedString,
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
    pub hook_pos: u64,
    /// Fenstergröße aus einem Test-Hook, beim nächsten Zeichnen angewandt.
    pub pending_size: Option<(f32, f32)>,
}

impl AppState {
    pub fn new(ident: &str, cx: &mut Context<Self>) -> Self {
        let theme = Theme::load();
        let kern = MailCore::start(ident);
        let suchfeld = cx.new(|cx| TextField::new("Suche", false, "Suchen …", theme.clone(), cx));
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
            list_breite: 800.0,
            status: "bereit".into(),
            hint: SharedString::default(),
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

        // Dead Key, der kein Folgezeichen bekommen hat, nach kurzer Zeit einsetzen
        let dead = self.suchfeld.update(cx, |field, cx| field.flush_dead(cx));
        if dead {
            neu_zeichnen = true;
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
            Reply::Event(event) => self.kernereignis(event, cx),
            Reply::Status(text) => {
                self.kern_status = text.into();
                true
            }
            Reply::Error(text) => {
                self.in_flight = self.in_flight.saturating_sub(1);
                self.loading = false;
                eprintln!("L1-FEHLER {text}");
                self.fehler = Some(text.into());
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
        let textfeld = self.suchfeld.read(cx).is_focused(window);
        // Enter im Suchfeld sucht; alles andere im Feld gehört dem Feld.
        if textfeld {
            match event.keystroke.key.as_str() {
                "enter" | "return" => {
                    self.suche_ausfuehren(cx);
                    return;
                }
                "escape" => {
                    self.suche_beenden(cx);
                    return;
                }
                _ => {}
            }
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
                if self.hilfe {
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
            Action::Praefix(_) => {}
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
            None => {}
        }
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

impl Render for AppState {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = self.theme.clone();
        let breite = f32::from(window.viewport_size().width);
        self.fenster_breite = breite;
        let seitenleiste = self.seitenleiste && breite >= 872.;

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
                    let im_feld = this.suchfeld.read(cx).is_focused(window);
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
            .children(self.hilfe.then(|| crate::ui::toolbar::hilfe_overlay(self, cx)))
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
