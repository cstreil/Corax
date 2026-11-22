//! Omarchy-Theme lesen und auf die Tokens der UI abbilden.
//!
//! Quelle ist der Zustand der laufenden Sitzung:
//!   ~/.local/state/omarchy/current/theme/colors.toml   (Farben)
//!   ~/.local/state/omarchy/current/theme.name          (Name)
//!   ~/.local/state/omarchy/current/theme/shell.toml    (Schrift, optional)
//!
//! Ein Theme-Wechsel ersetzt das Verzeichnis `current/theme`; die Datei ändert
//! ihre Kennung und ihr mtime, daran erkennen wir den Wechsel ohne Neustart.
//! Omarchy 4 schreibt `current` unter `~/.local/state`, Omarchy 3 unter
//! `~/.config`; gelesen wird zuerst der Zustands-Pfad.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::SystemTime;

#[derive(Clone, Debug, Default)]
pub struct Theme {
    pub name: String,
    pub mode: String,
    pub colors: HashMap<String, String>,
    pub font_family: Option<String>,
    pub stamp: Option<(u64, u64)>, // (mtime, len) von colors.toml
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

pub fn theme_dir() -> PathBuf {
    home().join(".local/state/omarchy/current/theme")
}

/// Fontconfig-Aliasse. Sie sind keine echten Familiennamen: fontique löst sie
/// auf den Fallback-Stapel auf, und dabei geht das Schriftgewicht verloren —
/// Fett bleibt dann in der ganzen App unsichtbar (Befund Coder 2, L2).
const SCHRIFT_ALIASSE: [&str; 7] = [
    "monospace",
    "mono",
    "sans-serif",
    "sans",
    "serif",
    "system-ui",
    "ui-monospace",
];

/// Kette ohne brauchbare Angabe in `shell.toml` (Entscheidung Architect, L2):
/// genommen wird die erste Familie, die fontconfig wirklich kennt.
pub const SCHRIFT_KETTE: [&str; 3] = ["Geist", "Noto Sans", "DejaVu Sans"];

/// Letzter Rückfall in [`Theme::font`], falls gar kein Kandidat vorhanden ist:
/// ein echter Familienname, kein Alias.
const SCHRIFT_RUECKFALL: &str = "DejaVu Sans";

/// Ist der Name ein fontconfig-Alias statt einer Familie?
pub fn ist_alias(name: &str) -> bool {
    SCHRIFT_ALIASSE.contains(&name.trim().to_lowercase().as_str())
}

/// Die Familien, die fontconfig kennt — einmal je Prozess gefragt (`fc-list`
/// braucht rund 11 ms) und danach aus dem Zwischenspeicher.
fn fontconfig_familien() -> Option<&'static HashSet<String>> {
    static FAMILIEN: OnceLock<Option<HashSet<String>>> = OnceLock::new();
    FAMILIEN
        .get_or_init(|| {
            let ausgabe = std::process::Command::new("fc-list")
                .args(["--format=%{family}\n"])
                .output()
                .ok()?;
            if !ausgabe.status.success() {
                return None;
            }
            let text = String::from_utf8_lossy(&ausgabe.stdout);
            let mut namen = HashSet::new();
            for zeile in text.lines() {
                for name in zeile.split(',') {
                    let name = name.trim();
                    if !name.is_empty() {
                        namen.insert(name.to_lowercase());
                    }
                }
            }
            Some(namen)
        })
        .as_ref()
}

/// Die Schriftfamilie wählen: was `shell.toml` nennt (sofern es kein Alias
/// ist), sonst die Kette [`SCHRIFT_KETTE`]. Ohne fontconfig bleibt es offen;
/// [`Theme::font`] setzt dann den Rückfall ein.
fn schrift_waehlen(aus_shell: Option<&str>) -> Option<String> {
    let mut kandidaten: Vec<&str> = Vec::with_capacity(4);
    if let Some(name) = aus_shell.map(str::trim).filter(|name| !name.is_empty()) {
        if !ist_alias(name) {
            kandidaten.push(name);
        }
    }
    for name in SCHRIFT_KETTE {
        if !kandidaten.iter().any(|vorhanden| vorhanden.eq_ignore_ascii_case(name)) {
            kandidaten.push(name);
        }
    }
    let bekannt = fontconfig_familien()?;
    kandidaten
        .into_iter()
        .find(|name| bekannt.contains(&name.to_lowercase()))
        .map(str::to_string)
}

impl Theme {
    /// Ein Rückfall-Thema, falls gar nichts lesbar ist (dunkel, wie Omarchy).
    pub fn fallback() -> Theme {
        Theme {
            name: "Omarchy".into(),
            mode: "dark".into(),
            colors: HashMap::new(),
            font_family: None,
            stamp: None,
        }
    }

    /// Theme aus `~/.config/omarchy/themes/<name>` (nur zum Ansehen, ohne den
    /// Desktop umzustellen). Nur der Test-Hook (`theme:`) ruft das.
    #[cfg_attr(not(feature = "test-hooks"), allow(dead_code))]
    pub fn load_named(name: &str) -> Theme {
        let dir = home().join(".config/omarchy/themes").join(name);
        Theme::load_dir(&dir, name)
    }

    pub fn load() -> Theme {
        let dir = theme_dir();
        let name = std::fs::read_to_string(dir.join("theme.name"))
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                std::fs::read_to_string(home().join(".local/state/omarchy/current/theme.name"))
                    .ok()
                    .map(|s| s.trim().to_string())
            })
            .unwrap_or_else(|| "?".into());
        let theme = Theme::load_dir(&dir, &name);
        if theme.colors.is_empty() {
            return Theme { name, ..Theme::fallback() };
        }
        theme
    }

    fn load_dir(dir: &std::path::Path, name: &str) -> Theme {
        let colors = std::fs::read_to_string(dir.join("colors.toml")).unwrap_or_default();

        let mut map = HashMap::new();
        for line in colors.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim().trim_matches('"');
            if !value.is_empty() {
                map.insert(key.trim().to_string(), value.to_string());
            }
        }

        let aus_shell = std::fs::read_to_string(dir.join("shell.toml"))
            .ok()
            .and_then(|shell| {
                let mut in_font = false;
                for line in shell.lines() {
                    let line = line.trim();
                    if line.starts_with('[') {
                        in_font = line == "[font]";
                        continue;
                    }
                    if in_font && (line.starts_with("family") || line.starts_with("name")) {
                        if let Some((_, value)) = line.split_once('=') {
                            return Some(value.trim().trim_matches('"').to_string());
                        }
                    }
                }
                None
            });

        let font_family = schrift_waehlen(aus_shell.as_deref());
        let stamp = stamp_of(dir);

        Theme {
            name: name.to_string(),
            mode: map.get("mode").cloned().unwrap_or_else(|| "dark".into()),
            colors: map,
            font_family,
            stamp,
        }
    }

    /// Nur die Kennung der Themadatei (mtime, Länge), ohne sie zu lesen. Damit
    /// kostet der Wechsel-Test alle 100 ms nur zwei `stat`.
    pub fn stamp_now(&self) -> Option<(u64, u64)> {
        stamp_of(&theme_dir())
    }

    /// Hat sich das Theme seit dem letzten Laden geändert?
    pub fn changed(&self) -> bool {
        self.stamp_now() != self.stamp
    }

    pub fn is_dark(&self) -> bool {
        self.mode != "light"
    }

    pub fn raw(&self, key: &str) -> Option<&str> {
        self.colors.get(key).map(String::as_str)
    }

    fn parse(value: &str) -> Option<u32> {
        let hex = value.trim_start_matches('#');
        if hex.len() == 6 {
            u32::from_str_radix(hex, 16).ok()
        } else {
            None
        }
    }

    /// Farbe zu einem Omarchy-Schlüssel, sonst der Rückfallwert.
    pub fn color(&self, key: &str, fallback: u32) -> u32 {
        self.raw(key).and_then(Theme::parse).unwrap_or(fallback)
    }

    // ---- abgeleitete Tokens (wie im Mock-up) ----
    pub fn bg(&self) -> u32 {
        self.color("background", if self.is_dark() { 0x101010 } else { 0xf4f4f4 })
    }
    pub fn surface(&self) -> u32 {
        if self.is_dark() {
            self.color("dark_background", self.bg())
        } else {
            self.color("lighter_background", self.bg())
        }
    }
    /// Etwas abgesetzte Fläche (Kopfzeile, Statuszeile, aufgeklappte Karte).
    pub fn raised(&self) -> u32 {
        if self.is_dark() {
            self.color("lighter_background", self.surface())
        } else {
            self.color("dark_background", self.surface())
        }
    }
    pub fn ink1(&self) -> u32 {
        self.color("foreground", if self.is_dark() { 0xececec } else { 0x101010 })
    }
    pub fn ink2(&self) -> u32 {
        if self.is_dark() {
            self.color("light_foreground", self.ink1())
        } else {
            self.color("dark_foreground", self.ink1())
        }
    }
    pub fn ink3(&self) -> u32 {
        self.color("muted", self.ink2())
    }
    /// Kräftigste Schrift (beste Kontrast): ungelesene Zeilen, Überschriften.
    pub fn ink_strong(&self) -> u32 {
        self.color("bright_foreground", self.ink1())
    }
    pub fn line(&self) -> u32 {
        // Haarlinie: Foreground zu 16 % über dem Hintergrund
        mix(self.ink1(), self.bg(), 0.16)
    }
    pub fn accent(&self) -> u32 {
        self.color("accent", 0x2f62ff)
    }
    pub fn selection(&self) -> u32 {
        self.color("selection", self.accent())
    }
    pub fn yellow(&self) -> u32 {
        self.color("yellow", 0xdf8e1d)
    }
    pub fn red(&self) -> u32 {
        self.color("red", 0xd20f39)
    }
    /// Die Schriftart: die erste vorhandene Familie aus `shell.toml` bzw. der
    /// Kette — nie ein fontconfig-Alias (sonst geht Fett verloren).
    pub fn font(&self) -> gpui::SharedString {
        match self.font_family.as_deref() {
            Some(name) if !ist_alias(name) => gpui::SharedString::from(name.to_string()),
            _ => gpui::SharedString::from(SCHRIFT_RUECKFALL),
        }
    }
}

/// Schriftfarbe auf `hintergrund`: dunkel auf heller Fläche, hell auf dunkler
/// (einfache Luminanz, kein Farbmanagement).
fn auf_farbe(hintergrund: u32) -> u32 {
    let kanal = |shift: u32| ((hintergrund >> shift) & 0xff) as f32 / 255.0;
    let helligkeit = 0.2126 * kanal(16) + 0.7152 * kanal(8) + 0.0722 * kanal(0);
    if helligkeit > 0.55 {
        0x101010
    } else {
        0xffffff
    }
}

/// gpui-components' eigenes Theme an Corax angleichen.
///
/// Zwei Gründe: `gpui_component::Root` muss die Fensterwurzel sein (das
/// Eingabefeld panikt sonst in `window.root::<Root>()`), und `Root` setzt
/// Hintergrund, Schrift und Textfarbe aus *diesem* Theme. Ohne Abgleich zeichnete
/// das Fenster in den Vorgabefarben und mit `.SystemUIFont` — einem
/// fontconfig-Alias, unter dem Fett nicht ankommt (Befund Coder 2, L2).
pub fn an_gpui_component(theme: &Theme, cx: &mut gpui::App) {
    use gpui::{rgb, rgba, Hsla};

    let zu = |wert: u32| -> Hsla { rgb(wert).into() };
    let auf_accent = auf_farbe(theme.accent());

    let gpui_theme = gpui_component::Theme::global_mut(cx);
    gpui_theme.mode = if theme.is_dark() {
        gpui_component::ThemeMode::Dark
    } else {
        gpui_component::ThemeMode::Light
    };
    gpui_theme.font_family = theme.font();
    gpui_theme.colors.background = zu(theme.bg());
    gpui_theme.colors.foreground = zu(theme.ink1());
    gpui_theme.colors.border = zu(theme.line());
    gpui_theme.colors.input = zu(theme.surface());
    gpui_theme.colors.muted = zu(theme.surface());
    gpui_theme.colors.muted_foreground = zu(theme.ink3());
    gpui_theme.colors.caret = zu(theme.accent());
    gpui_theme.colors.selection = rgba((theme.accent() << 8) | 0x50).into();
    gpui_theme.colors.accent = zu(theme.accent());
    gpui_theme.colors.accent_foreground = zu(auf_accent);
    gpui_theme.colors.primary = zu(theme.accent());
    gpui_theme.colors.primary_foreground = zu(auf_accent);
}

fn stamp_of(dir: &std::path::Path) -> Option<(u64, u64)> {
    std::fs::metadata(dir.join("colors.toml")).ok().and_then(|m| {
        let t = m.modified().ok()?;
        let secs = t.duration_since(SystemTime::UNIX_EPOCH).ok()?.as_secs();
        Some((secs, m.len()))
    })
}

/// `a` mit Anteil `t` über `b` mischen (t = 1 → a).
pub fn mix(a: u32, b: u32, t: f32) -> u32 {
    let ch = |shift: u32| {
        let x = ((a >> shift) & 0xff) as f32;
        let y = ((b >> shift) & 0xff) as f32;
        ((x * t + y * (1.0 - t)).round() as u32) & 0xff
    };
    (ch(16) << 16) | (ch(8) << 8) | ch(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliasse_werden_erkannt() {
        for name in ["monospace", "Monospace", "sans-serif", "system-ui", "ui-monospace"] {
            assert!(ist_alias(name), "{name}");
        }
        for name in ["Geist", "Noto Sans", "DejaVu Sans", "JetBrains Mono"] {
            assert!(!ist_alias(name), "{name}");
        }
    }

    #[test]
    fn font_ist_nie_ein_alias() {
        // Ohne Angabe: der Rückfall ist ein echter Familienname.
        let theme = Theme::fallback();
        assert_eq!(theme.font().as_ref(), SCHRIFT_RUECKFALL);
        assert!(!ist_alias(theme.font().as_ref()));

        // Ein Alias aus einer alten shell.toml darf nicht durchkommen.
        let theme = Theme { font_family: Some("monospace".into()), ..Theme::fallback() };
        assert!(!ist_alias(theme.font().as_ref()));

        // Eine echte Familie bleibt erhalten.
        let theme = Theme { font_family: Some("Geist".into()), ..Theme::fallback() };
        assert_eq!(theme.font().as_ref(), "Geist");
    }

    #[test]
    fn kette_beginnt_mit_geist() {
        assert_eq!(SCHRIFT_KETTE, ["Geist", "Noto Sans", "DejaVu Sans"]);
        // Ohne fontconfig (z. B. auf dem Mac im Test) bleibt die Wahl offen;
        // mit fontconfig kommt nur eine echte Familie zurück.
        assert!(schrift_waehlen(Some("monospace")).is_none_or(|name| !ist_alias(&name)));
    }
}
