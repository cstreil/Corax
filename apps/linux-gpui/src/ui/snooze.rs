//! „Später": Presets wie die Mac-App (`Format.snoozePresets()`) und ein
//! eigenes Datum („morgen 9:00", „24.11. 18:00", „montag 8:00").
//!
//! Der Kern nimmt den Zeitpunkt als Millisekunden (`params.wakeAt`); hier
//! entsteht nur die Rechnung, ohne Fenster und damit testbar. Die Auswahl
//! selbst zeichnet [`crate::ui::auswahl`].

use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone, Timelike, Weekday};

/// Ein Vorschlag der Auswahl: Name links, Zeitpunkt in Millisekunden.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preset {
    /// Feste Kennung (wie die IDs der Mac-App).
    pub id: &'static str,
    pub name: &'static str,
    pub at: i64,
}

/// Presets wie `Format.snoozePresets()` der Mac-App: dieselben Namen und
/// Zeitpunkte (später heute +3 h, heute 19:00, morgen 9:00, Samstag 9:00,
/// Montag 9:00). Zwei Vorschläge mit demselben Zeitpunkt fallen zusammen;
/// zum Schluss wird aufsteigend sortiert, damit die Pfeiltasten der Zeit
/// folgen.
pub fn presets(jetzt: i64) -> Vec<Preset> {
    let Some(now) = Local.timestamp_millis_opt(jetzt).single() else {
        return Vec::new();
    };
    let mut out: Vec<Preset> = Vec::new();
    let mut add = |id: &'static str, name: &'static str, at: Option<DateTime<Local>>| {
        let Some(at) = at else { return };
        let ms = at.timestamp_millis();
        if out.iter().any(|preset| preset.at == ms) {
            return;
        }
        out.push(Preset { id, name, at: ms });
    };

    add("later", "Später heute", (now + chrono::Duration::hours(3)).with_second(0));
    let mut abend = zeit_am(now.date_naive(), 19, 0);
    if abend.map(|at| at.timestamp_millis() <= jetzt).unwrap_or(true) {
        abend = zeit_am(now.date_naive() + chrono::Duration::days(1), 19, 0);
    }
    add("tonight", "Heute Abend", abend);
    add("tomorrow", "Morgen", zeit_am(now.date_naive() + chrono::Duration::days(1), 9, 0));
    add("weekend", "Dieses Wochenende", naechster_wochentag(&now, Weekday::Sat, 9, 0));
    add("nextWeek", "Nächste Woche", naechster_wochentag(&now, Weekday::Mon, 9, 0));

    out.sort_by_key(|preset| preset.at);
    out
}

/// Zeit am gegebenen Tag. `.earliest()` fängt die doppelte Stunde der
/// Zeitumstellung ab; ein Tag ohne diese Uhrzeit (Umstellung nach vorn) fällt
/// auf 9:00 zurück, statt die Auswahl leer zu lassen.
fn zeit_am(tag: NaiveDate, stunde: u32, minute: u32) -> Option<DateTime<Local>> {
    if let Some(naiv) = tag.and_hms_opt(stunde, minute, 0) {
        if let Some(at) = Local.from_local_datetime(&naiv).earliest() {
            return Some(at);
        }
    }
    let naiv = tag.and_hms_opt(9, 0, 0)?;
    Local.from_local_datetime(&naiv).earliest()
}

/// Nächster passender Wochentag um `stunde:minute`; ist es heute und die Zeit
/// noch nicht vorbei, bleibt es bei heute (wie „Samstag 9:00" am Samstag früh).
fn naechster_wochentag(
    now: &DateTime<Local>,
    wochentag: Weekday,
    stunde: u32,
    minute: u32,
) -> Option<DateTime<Local>> {
    let heute = now.date_naive();
    let delta = (wochentag.num_days_from_monday() + 7 - heute.weekday().num_days_from_monday()) % 7;
    let mut tag = heute + chrono::Duration::days(i64::from(delta));
    let mut at = zeit_am(tag, stunde, minute)?;
    if at <= *now {
        tag += chrono::Duration::days(7);
        at = zeit_am(tag, stunde, minute)?;
    }
    Some(at)
}

/// Zeitpunkt für die Anzeige rechts am Eintrag: „Heute, 16:05", „Morgen, 9:00",
/// „Di., 9:00", sonst „24. Nov., 9:00" (mit Jahr, wenn es nicht das laufende ist).
pub fn zeit_text(at: i64, jetzt: i64) -> String {
    let Some(datum) = Local.timestamp_millis_opt(at).single() else {
        return String::new();
    };
    let heute = Local
        .timestamp_millis_opt(jetzt)
        .single()
        .map(|now| now.date_naive())
        .unwrap_or_else(|| Local::now().date_naive());
    let tag = datum.date_naive();
    let uhrzeit = datum.format("%H:%M").to_string();
    match (tag - heute).num_days() {
        0 => format!("Heute, {uhrzeit}"),
        1 => format!("Morgen, {uhrzeit}"),
        2..=6 => format!("{}, {uhrzeit}", wochentag_kurz(tag.weekday())),
        _ => {
            let monat = monat_kurz(datum.month());
            if tag.year() == heute.year() {
                format!("{}. {monat}, {uhrzeit}", tag.day())
            } else {
                format!("{}. {monat} {}, {uhrzeit}", tag.day(), tag.year())
            }
        }
    }
}

/// Kurzform des Zeitpunkts für den Toast: „morgen 8:00", „24.11. 18:00".
pub fn kurz(at: i64) -> String {
    let Some(datum) = Local.timestamp_millis_opt(at).single() else {
        return String::new();
    };
    let heute = Local::now().date_naive();
    let tag = datum.date_naive();
    let uhrzeit = datum.format("%H:%M").to_string();
    match (tag - heute).num_days() {
        0 => format!("heute {uhrzeit}"),
        1 => format!("morgen {uhrzeit}"),
        _ => format!("{}.{}. {uhrzeit}", tag.day(), datum.month()),
    }
}

fn wochentag_kurz(tag: Weekday) -> &'static str {
    match tag {
        Weekday::Mon => "Mo.",
        Weekday::Tue => "Di.",
        Weekday::Wed => "Mi.",
        Weekday::Thu => "Do.",
        Weekday::Fri => "Fr.",
        Weekday::Sat => "Sa.",
        Weekday::Sun => "So.",
    }
}

fn monat_kurz(monat: u32) -> &'static str {
    const NAMEN: [&str; 12] = [
        "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.",
        "Dez.",
    ];
    NAMEN.get((monat as usize).saturating_sub(1)).copied().unwrap_or("?")
}

/// Eigenes Datum aus der Eingabe: „heute", „morgen", „übermorgen", ein
/// Wochentag („mo", „montag") oder „24.11.", „24.11.26", „24.11.2026", jeweils
/// optional mit Uhrzeit („9:00", „9.30", „9h", „9 uhr"). Ohne Datum gilt heute,
/// ohne Uhrzeit 9:00. Ein Zeitpunkt in der Vergangenheit ist ungültig (`None`).
pub fn parse(text: &str, jetzt: i64) -> Option<i64> {
    let now = Local.timestamp_millis_opt(jetzt).single()?;
    let kleingeschrieben = text.to_lowercase().replace(',', " ");
    let worte: Vec<&str> = kleingeschrieben.split_whitespace().collect();
    if worte.is_empty() {
        return None;
    }

    let mut zeit: Option<(u32, u32)> = None;
    let mut tag: Option<NaiveDate> = None;
    let mut bezug = Bezug::Keiner;
    // „31.02." sieht aus wie ein Datum, ist aber keines: die Eingabe ist dann
    // ungültig und nicht bloß eine Uhrzeit.
    let mut datum_kaputt = false;

    for wort in &worte {
        if zeit.is_none() {
            if let Some(gefunden) = uhrzeit_lesen(wort) {
                zeit = Some(gefunden);
                continue;
            }
        }
        if tag.is_none() {
            match *wort {
                "heute" => {
                    tag = Some(now.date_naive());
                    bezug = Bezug::Relativ;
                }
                "morgen" => {
                    tag = Some(now.date_naive() + chrono::Duration::days(1));
                    bezug = Bezug::Relativ;
                }
                "übermorgen" | "uebermorgen" => {
                    tag = Some(now.date_naive() + chrono::Duration::days(2));
                    bezug = Bezug::Relativ;
                }
                _ => {
                    if let Some(wochentag) = wochentag_lesen(wort) {
                        let delta = (wochentag.num_days_from_monday() + 7
                            - now.date_naive().weekday().num_days_from_monday())
                            % 7;
                        tag = Some(now.date_naive() + chrono::Duration::days(i64::from(delta)));
                        bezug = Bezug::Wochentag;
                    } else if let Some((datum, ohne_jahr)) = datum_lesen(wort, now.year()) {
                        tag = Some(datum);
                        bezug = Bezug::Fest { jahr_fehlt: ohne_jahr };
                    } else if sieht_wie_datum_aus(wort) {
                        datum_kaputt = true;
                    }
                }
            }
        }
    }

    // Ohne jeden erkannten Bestandteil bleibt die Eingabe ungültig.
    if datum_kaputt || (zeit.is_none() && tag.is_none()) {
        return None;
    }

    let (stunde, minute) = zeit.unwrap_or((9, 0));
    let mut datum = tag.unwrap_or(now.date_naive());
    let mut at = zeit_am(datum, stunde, minute)?;

    if at.timestamp_millis() <= jetzt {
        match bezug {
            // „heute 18:00" um 19:00 ist vorbei — dann morgen.
            Bezug::Relativ => {
                datum += chrono::Duration::days(1);
                at = zeit_am(datum, stunde, minute)?;
            }
            // „montag 8:00" am Montagnachmittag ist der Montag drauf.
            Bezug::Wochentag => {
                datum += chrono::Duration::days(7);
                at = zeit_am(datum, stunde, minute)?;
            }
            // Nur eine Uhrzeit: morgen, wie beim Snooze üblich.
            Bezug::Keiner => {
                if zeit.is_some() {
                    datum += chrono::Duration::days(1);
                    at = zeit_am(datum, stunde, minute)?;
                }
            }
            // Ohne Jahr: das nächste Jahr. Mit Jahr: Vergangenheit, ungültig.
            Bezug::Fest { jahr_fehlt: true } => {
                at = zeit_am(datum.with_year(datum.year() + 1)?, stunde, minute)?;
            }
            Bezug::Fest { jahr_fehlt: false } => return None,
        }
    }
    Some(at.timestamp_millis())
}

/// Woher der Tag stammt — entscheidet, wohin ein vergangener Zeitpunkt rückt.
#[derive(Clone, Copy, Debug)]
enum Bezug {
    /// Nur eine Uhrzeit.
    Keiner,
    /// „heute", „morgen", „übermorgen".
    Relativ,
    Wochentag,
    /// Festes Datum, mit oder ohne Jahr.
    Fest { jahr_fehlt: bool },
}

/// Sieht das Wort wie ein festes Datum aus („31.02."), ist aber keines?
fn sieht_wie_datum_aus(wort: &str) -> bool {
    wort.starts_with(|c: char| c.is_ascii_digit()) && wort.contains('.')
}

/// Uhrzeit aus einem Wort: „9:00", „9.30", „9h", „9uhr", „9:00uhr".
fn uhrzeit_lesen(wort: &str) -> Option<(u32, u32)> {
    let wort = wort.trim_end_matches("uhr");
    let (stunde, minute) = if let Some((stunde, minute)) = wort.split_once(':') {
        (stunde, minute)
    } else if wort.ends_with('h') {
        (wort.trim_end_matches('h'), "")
    } else if let Some((stunde, minute)) = wort.split_once('.') {
        // „9.30" ist eine Uhrzeit, „24.11." nicht: die Stunde hat höchstens
        // zwei Ziffern, der Minuten-Teil ist eine zweistellige Zahl.
        if minute.len() == 2 && minute.chars().all(|c| c.is_ascii_digit()) {
            (stunde, minute)
        } else {
            return None;
        }
    } else {
        return None;
    };
    let stunde: u32 = stunde.parse().ok().filter(|stunde| *stunde < 24)?;
    let minute: u32 = if minute.is_empty() {
        0
    } else {
        minute.parse().ok().filter(|minute| *minute < 60)?
    };
    Some((stunde, minute))
}

/// Wochentag aus einem Wort: „mo", „montag", „sonnabend".
fn wochentag_lesen(wort: &str) -> Option<Weekday> {
    const NAMEN: [(&str, Weekday); 8] = [
        ("mo", Weekday::Mon),
        ("montag", Weekday::Mon),
        ("di", Weekday::Tue),
        ("dienstag", Weekday::Tue),
        ("mi", Weekday::Wed),
        ("mittwoch", Weekday::Wed),
        ("do", Weekday::Thu),
        ("donnerstag", Weekday::Thu),
    ];
    const REST: [(&str, Weekday); 7] = [
        ("fr", Weekday::Fri),
        ("freitag", Weekday::Fri),
        ("sa", Weekday::Sat),
        ("samstag", Weekday::Sat),
        ("sonnabend", Weekday::Sat),
        ("so", Weekday::Sun),
        ("sonntag", Weekday::Sun),
    ];
    NAMEN
        .iter()
        .chain(REST.iter())
        .find(|(name, _)| *name == wort)
        .map(|(_, wochentag)| *wochentag)
}

/// Festes Datum aus einem Wort: „24.11.", „24.11.26", „24.11.2026".
/// Rückgabe: Datum und ob das Jahr ergänzt werden musste.
fn datum_lesen(wort: &str, jahr: i32) -> Option<(NaiveDate, bool)> {
    let teile: Vec<&str> = wort.split('.').collect();
    let teile: Vec<&str> = teile.into_iter().filter(|teil| !teil.is_empty()).collect();
    if teile.len() < 2 || teile.len() > 3 {
        return None;
    }
    let tag: u32 = teile[0].parse().ok()?;
    let monat: u32 = teile[1].parse().ok()?;
    if !(1..=31).contains(&tag) || !(1..=12).contains(&monat) {
        return None;
    }
    let (jahr, fehlt) = match teile.get(2) {
        None => (jahr, true),
        Some(text) => {
            let wert: i32 = text.parse().ok()?;
            ((if wert < 100 { 2000 + wert } else { wert }), false)
        }
    };
    NaiveDate::from_ymd_opt(jahr, monat, tag).map(|datum| (datum, fehlt))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jetzt() -> i64 {
        Local
            .with_ymd_and_hms(2026, 11, 22, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis()
    }

    fn als_text(ms: i64) -> String {
        Local
            .timestamp_millis_opt(ms)
            .single()
            .map(|datum| datum.format("%Y-%m-%d %H:%M").to_string())
            .unwrap_or_default()
    }

    /// Mittwoch, 18.11.2026, 12:00 — an diesem Tag fallen keine Presets zusammen.
    fn mittwoch() -> i64 {
        Local
            .with_ymd_and_hms(2026, 11, 18, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis()
    }

    #[test]
    fn presets_wie_die_mac_app() {
        let liste = presets(mittwoch());
        let namen: Vec<&str> = liste.iter().map(|preset| preset.name).collect();
        assert_eq!(
            namen,
            vec![
                "Später heute",
                "Heute Abend",
                "Morgen",
                "Dieses Wochenende",
                "Nächste Woche"
            ]
        );
        assert_eq!(als_text(liste[0].at), "2026-11-18 15:00");
        assert_eq!(als_text(liste[1].at), "2026-11-18 19:00");
        assert_eq!(als_text(liste[2].at), "2026-11-19 09:00");
        // Mittwoch: Wochenende ist Samstag, nächste Woche Montag.
        assert_eq!(als_text(liste[3].at), "2026-11-21 09:00");
        assert_eq!(als_text(liste[4].at), "2026-11-23 09:00");
    }

    #[test]
    fn am_sonntag_fallen_morgen_und_naechste_woche_zusammen() {
        // 22.11.2026 ist ein Sonntag: „Morgen" und „Nächste Woche" sind beide
        // Montag 9:00 — wie in der Mac-App bleibt davon ein Eintrag.
        let liste = presets(jetzt());
        assert_eq!(liste.len(), 4, "{liste:?}");
        assert!(liste.iter().any(|preset| preset.id == "tomorrow"));
        assert!(!liste.iter().any(|preset| preset.id == "nextWeek"));
    }

    #[test]
    fn presets_sortiert_und_ohne_doppelte() {
        // 16:00: „Später heute" (19:00) fällt mit „Heute Abend" zusammen.
        let sechzehn = Local
            .with_ymd_and_hms(2026, 11, 18, 16, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let liste = presets(sechzehn);
        assert_eq!(liste.len(), 4, "{:?}", liste);
        assert!(liste.windows(2).all(|paar| paar[0].at < paar[1].at));
    }

    #[test]
    fn presets_am_abend() {
        // 21:00: heute Abend ist vorbei, alles rückt einen Tag.
        let abend = Local
            .with_ymd_and_hms(2026, 11, 18, 21, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let liste = presets(abend);
        // „Später heute" (+3 h) fällt auf den nächsten Tag — wie in der Mac-App.
        assert_eq!(als_text(liste[0].at), "2026-11-19 00:00");
        assert_eq!(als_text(liste[1].at), "2026-11-19 09:00");
    }

    #[test]
    fn eigenes_datum_mit_uhrzeit() {
        assert_eq!(als_text(parse("morgen 9:00", jetzt()).unwrap()), "2026-11-23 09:00");
        assert_eq!(als_text(parse("übermorgen 8:30", jetzt()).unwrap()), "2026-11-24 08:30");
        assert_eq!(als_text(parse("24.11. 18:00", jetzt()).unwrap()), "2026-11-24 18:00");
        assert_eq!(als_text(parse("24.11.26 18:00", jetzt()).unwrap()), "2026-11-24 18:00");
        assert_eq!(als_text(parse("24.11.2026 18h", jetzt()).unwrap()), "2026-11-24 18:00");
        assert_eq!(als_text(parse("1.12. 7.30", jetzt()).unwrap()), "2026-12-01 07:30");
    }

    #[test]
    fn eigenes_datum_ohne_uhrzeit_ist_neun() {
        assert_eq!(als_text(parse("morgen", jetzt()).unwrap()), "2026-11-23 09:00");
        assert_eq!(als_text(parse("25.11.", jetzt()).unwrap()), "2026-11-25 09:00");
    }

    #[test]
    fn uhrzeit_ohne_datum_ist_heute_oder_morgen() {
        assert_eq!(als_text(parse("18:00", jetzt()).unwrap()), "2026-11-22 18:00");
        // 11:00 ist vorbei — dann morgen, wie beim Snooze üblich.
        assert_eq!(als_text(parse("11:00", jetzt()).unwrap()), "2026-11-23 11:00");
    }

    #[test]
    fn wochentag_ist_der_naechste() {
        // Sonntag, 22.11.2026: Montag ist der 23.
        assert_eq!(als_text(parse("montag 8:00", jetzt()).unwrap()), "2026-11-23 08:00");
        // Sonntag selbst liegt eine Woche vor uns.
        assert_eq!(als_text(parse("so 8:00", jetzt()).unwrap()), "2026-11-29 08:00");
        // Samstag, 28.11., 9:00.
        assert_eq!(als_text(parse("sa 9:00", jetzt()).unwrap()), "2026-11-28 09:00");
    }

    #[test]
    fn unsinn_und_vergangenes_sind_ungueltig() {
        assert_eq!(parse("blödsinn", jetzt()), None);
        assert_eq!(parse("", jetzt()), None);
        assert_eq!(parse("1.1.2020 9:00", jetzt()), None);
        assert_eq!(parse("31.02. 9:00", jetzt()), None);
        assert_eq!(parse("25:00", jetzt()), None);
    }

    #[test]
    fn datum_ohne_jahr_rueckt_ins_naechste_jahr() {
        // 30.12. liegt 2026 vor uns (Dezember), 1.1. ist vorbei → 2027.
        assert_eq!(als_text(parse("1.1. 9:00", jetzt()).unwrap()), "2027-01-01 09:00");
    }

    #[test]
    fn anzeige_der_zeitpunkte() {
        assert_eq!(zeit_text(jetzt() + 3 * 3_600_000, jetzt()), "Heute, 15:00");
        let morgen = parse("morgen 9:00", jetzt()).unwrap();
        assert_eq!(zeit_text(morgen, jetzt()), "Morgen, 09:00");
        let samstag = parse("sa 9:00", jetzt()).unwrap();
        assert_eq!(zeit_text(samstag, jetzt()), "Sa., 09:00");
        assert_eq!(kurz(morgen), "morgen 09:00");
    }
}
