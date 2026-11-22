//! Omarchy-Theme lesen und auf die Tokens der UI abbilden.
//!
//! Quelle ist der Zustand der laufenden Sitzung:
//!   ~/.local/state/omarchy/current/theme/colors.toml   (Farben)
//!   ~/.local/state/omarchy/current/theme.name          (Name)
//!   ~/.local/state/omarchy/current/theme/shell.toml    (Schrift, optional)
//!
//! Ein Theme-Wechsel ersetzt das Verzeichnis `current/theme`; die Datei ändert
//! ihre Kennung und ihr mtime, daran erkennen wir den Wechsel ohne Neustart.

use std::collections::HashMap;
use std::path::PathBuf;
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
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/home/cs".into()))
}

pub fn theme_dir() -> PathBuf {
    home().join(".local/state/omarchy/current/theme")
}

impl Theme {
    /// Theme aus `~/.config/omarchy/themes/<name>` (nur zum Ansehen, ohne den
    /// Desktop umzustellen).
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
        Theme::load_dir(&dir, &name)
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

        let font_family = std::fs::read_to_string(dir.join("shell.toml"))
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

        let stamp = std::fs::metadata(dir.join("colors.toml"))
            .ok()
            .and_then(|m| {
                let t = m.modified().ok()?;
                let secs = t.duration_since(SystemTime::UNIX_EPOCH).ok()?.as_secs();
                Some((secs, m.len()))
            });

        Theme {
            name: name.to_string(),
            mode: map.get("mode").cloned().unwrap_or_else(|| "dark".into()),
            colors: map,
            font_family,
            stamp,
        }
    }

    /// Hat sich das Theme seit dem letzten Laden geändert?
    pub fn changed(&self) -> bool {
        Theme::load().stamp != self.stamp
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
    pub fn selection_ink(&self) -> u32 {
        self.color("selection_foreground", self.ink1())
    }
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
