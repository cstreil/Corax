//! Desktop colours for the Linux builds.
//!
//! On Linux the app can take its palette from the desktop instead of picking
//! Glas or Graphit: Plasma keeps every role in `~/.config/kdeglobals`, Omarchy
//! keeps one `colors.toml` per theme. Everything is derived from a handful of
//! roles so both sources map onto the same token set.
//!
//! macOS returns `None`; there the theme setting keeps meaning light/dark.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Serialize;

/// The subset of tokens the frontend overrides. Colours are `#rrggbb`.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SystemColors {
    /// Where the colours came from: `kde` or `omarchy`.
    pub source: String,
    /// `dark` or `light`, decided by the background's luminance.
    pub mode: String,
    pub bg0: String,
    pub bg1: String,
    pub bg2: String,
    pub bg3: String,
    pub bg4: String,
    pub ink: String,
    pub ink_muted: String,
    pub ink_faint: String,
    pub accent: String,
    pub on_accent: String,
    pub hairline: String,
}

/// Read the desktop palette, or `None` when there is none to read.
pub fn detect() -> Option<SystemColors> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    // Omarchy first, not Plasma: Omarchy writes its own `kdeglobals` for the
    // Qt apps it ships, so that file exists on an Omarchy box too — but it
    // spends `[Colors:Selection] BackgroundNormal` on the selection tone and
    // leaves the theme's accent in `DecorationFocus`, which would hand the app
    // a grey accent. `kdeglobals` is only authoritative on a real Plasma
    // session, and there is no Omarchy state directory to find first.
    omarchy().or_else(plasma)
}

fn config_home() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME") {
        let path = PathBuf::from(dir);
        if path.is_absolute() {
            return Some(path);
        }
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config"))
}

/// Plasma: `kdeglobals` carries the applied colour scheme's roles.
fn plasma() -> Option<SystemColors> {
    let path = config_home()?.join("kdeglobals");
    let text = std::fs::read_to_string(&path).ok()?;
    let sections = parse_ini(&text);

    let get = |section: &str, key: &str| -> Option<Rgb> {
        sections
            .get(section)
            .and_then(|s| s.get(key))
            .and_then(|v| Rgb::parse(v))
    };

    let view_bg = get("Colors:View", "BackgroundNormal")?;
    let window_bg = get("Colors:Window", "BackgroundNormal").unwrap_or(view_bg);
    let button_bg = get("Colors:Button", "BackgroundNormal").unwrap_or(window_bg);
    let ink = get("Colors:View", "ForegroundNormal")?;
    let ink_inactive = get("Colors:View", "ForegroundInactive").unwrap_or(ink);
    let accent = get("Colors:Selection", "BackgroundNormal")?;
    let on_accent = get("Colors:Selection", "ForegroundNormal").unwrap_or(ink);

    Some(build(
        "kde",
        view_bg,
        window_bg,
        button_bg,
        ink,
        ink_inactive,
        accent,
        on_accent,
    ))
}

/// Omarchy: the applied theme is staged complete under its `current` state
/// directory, so `colors.toml` is read from there.
fn omarchy() -> Option<SystemColors> {
    let path = omarchy_colors_path()?;
    let text = std::fs::read_to_string(&path).ok()?;
    omarchy_from_colors_toml(&text)
}

/// Where the active Omarchy theme keeps its `colors.toml`.
///
/// Omarchy 4 stages the applied theme at
/// `$HOME/.local/state/omarchy/current/theme`; Omarchy 3 kept it under
/// `~/.config/omarchy/current`. Omarchy writes `$HOME/.local/state` literally,
/// whatever `XDG_STATE_HOME` says, so that path is built from `HOME` alone.
fn omarchy_colors_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    omarchy_candidates(&home, config_home().as_deref())
        .into_iter()
        .find(|path| path.is_file())
}

fn omarchy_candidates(home: &std::path::Path, config: Option<&std::path::Path>) -> Vec<PathBuf> {
    let mut paths = vec![
        home.join(".local/state/omarchy/current/theme/colors.toml"),
        home.join(".config/omarchy/current/theme/colors.toml"),
        home.join(".config/omarchy/current/colors.toml"),
    ];
    if let Some(config) = config {
        paths.push(config.join("omarchy/current/theme/colors.toml"));
        paths.push(config.join("omarchy/current/colors.toml"));
    }
    paths
}

fn omarchy_from_colors_toml(text: &str) -> Option<SystemColors> {
    let values = parse_flat_toml(text);

    let background = values.get("background").and_then(|v| Rgb::parse(v))?;
    let ink = values.get("foreground").and_then(|v| Rgb::parse(v))?;
    let accent = values
        .get("accent")
        .and_then(|v| Rgb::parse(v))
        .unwrap_or(ink);
    let muted = values
        .get("muted")
        .and_then(|v| Rgb::parse(v))
        .unwrap_or_else(|| ink.mix(background, 0.45));
    let lighter = values
        .get("lighter_background")
        .and_then(|v| Rgb::parse(v))
        .unwrap_or_else(|| background.mix(ink, 0.06));
    let on_accent = values
        .get("selection_foreground")
        .and_then(|v| Rgb::parse(v))
        .unwrap_or_else(|| {
            if accent.luminance() > 0.55 {
                Rgb(0, 0, 0)
            } else {
                Rgb(255, 255, 255)
            }
        });

    // `mode` states the theme's intent; the background luminance is only the
    // fallback for themes that leave it out.
    let dark = match values.get("mode").map(|v| v.trim().trim_matches('"')) {
        Some("light") => false,
        Some("dark") => true,
        _ => background.luminance() < 0.45,
    };
    let (bg0, bg1) = sort_by_luminance(background, lighter, dark);
    Some(build(
        "omarchy",
        bg0,
        bg1,
        bg1.mix(ink, if dark { 0.06 } else { 0.04 }),
        ink,
        muted,
        accent,
        on_accent,
    ))
}

/// Assemble the token set from the roles every desktop provides.
fn build(
    source: &str,
    view_bg: Rgb,
    window_bg: Rgb,
    button_bg: Rgb,
    ink: Rgb,
    ink_inactive: Rgb,
    accent: Rgb,
    on_accent: Rgb,
) -> SystemColors {
    let dark = view_bg.luminance() < 0.45;
    // bg0 is the canvas, bg1 the surface that sits on it: the surface is always
    // the lighter one in dark mode and the lighter one in light mode too, so
    // both distros' role naming collapses into a luminance sort.
    let (bg0, bg1) = sort_by_luminance(view_bg, window_bg, dark);
    // Elevated surfaces step away from the canvas in the direction the theme
    // itself goes: lighter on dark themes, darker on light ones.
    let step = |from: Rgb, amount: f32| {
        if dark {
            from.mix(Rgb(255, 255, 255), amount)
        } else {
            from.mix(Rgb(0, 0, 0), amount)
        }
    };
    // bg2 is the next step up from the surface: on a dark theme that is the
    // lighter of the two, on a light theme the darker one. Taking the button
    // tone unconditionally would collapse hover into the card itself.
    let bg2 = {
        let (darker, lighter) = sort_by_luminance(button_bg, bg1, dark);
        if dark { lighter } else { darker }
    };
    let bg3 = step(bg2, 0.06);
    let bg4 = step(bg2, 0.12);

    SystemColors {
        source: source.to_string(),
        mode: if dark { "dark" } else { "light" }.to_string(),
        bg0: bg0.hex(),
        bg1: bg1.hex(),
        bg2: bg2.hex(),
        bg3: bg3.hex(),
        bg4: bg4.hex(),
        ink: ink.hex(),
        ink_muted: ink_inactive.hex(),
        ink_faint: ink.mix(bg0, 0.45).hex(),
        accent: accent.hex(),
        on_accent: on_accent.hex(),
        hairline: bg1.mix(ink, 0.14).hex(),
    }
}

/// `bg0` is the darker, `bg1` the lighter of the two.
fn sort_by_luminance(a: Rgb, b: Rgb, _dark: bool) -> (Rgb, Rgb) {
    if a.luminance() <= b.luminance() {
        (a, b)
    } else {
        (b, a)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb(u8, u8, u8);

impl Rgb {
    fn parse(raw: &str) -> Option<Rgb> {
        let raw = raw.trim().trim_matches('"').trim();
        if let Some(hex) = raw.strip_prefix('#') {
            let hex = hex.trim();
            return match hex.len() {
                6 => Some(Rgb(
                    u8::from_str_radix(&hex[0..2], 16).ok()?,
                    u8::from_str_radix(&hex[2..4], 16).ok()?,
                    u8::from_str_radix(&hex[4..6], 16).ok()?,
                )),
                3 => {
                    let d = |c: &str| u8::from_str_radix(c, 16).ok().map(|v| v * 17);
                    Some(Rgb(d(&hex[0..1])?, d(&hex[1..2])?, d(&hex[2..3])?))
                }
                _ => None,
            };
        }
        // KDE writes colours as comma separated decimal triples.
        let parts: Vec<&str> = raw.split(',').map(str::trim).collect();
        if parts.len() == 3 {
            return Some(Rgb(
                parts[0].parse().ok()?,
                parts[1].parse().ok()?,
                parts[2].parse().ok()?,
            ));
        }
        None
    }

    fn hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.0, self.1, self.2)
    }

    /// Linear mix towards `other`; `amount` is the share of `other`.
    fn mix(self, other: Rgb, amount: f32) -> Rgb {
        let amount = amount.clamp(0.0, 1.0);
        let blend = |a: u8, b: u8| -> u8 {
            let a = a as f32;
            let b = b as f32;
            (a + (b - a) * amount).round().clamp(0.0, 255.0) as u8
        };
        Rgb(
            blend(self.0, other.0),
            blend(self.1, other.1),
            blend(self.2, other.2),
        )
    }

    /// Rec. 601 luma, good enough to sort colours and decide light vs dark.
    fn luminance(self) -> f32 {
        (0.299 * self.0 as f32 + 0.587 * self.1 as f32 + 0.114 * self.2 as f32) / 255.0
    }
}

type Ini = HashMap<String, HashMap<String, String>>;

fn parse_ini(text: &str) -> Ini {
    let mut out: Ini = HashMap::new();
    let mut section = String::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = name.trim().to_string();
            out.entry(section.clone()).or_default();
        } else if let Some((key, value)) = line.split_once('=') {
            out.entry(section.clone())
                .or_default()
                .insert(key.trim().to_string(), value.trim().to_string());
        }
    }
    out
}

/// Flat `key = "value"` files, all a theme's `colors.toml` needs here.
fn parse_flat_toml(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    // TOML never returns to the root table, so everything after the first
    // `[table]` header is irrelevant here.
    let mut in_table = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            in_table = true;
            continue;
        }
        if in_table {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            if !key.is_empty() && !key.contains('.') {
                out.insert(key.to_string(), value.trim().to_string());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Luminance of a `#rrggbb` token, so tests compare brightness and not
    /// the lexical order of strings.
    fn luma(hex: &str) -> f32 {
        Rgb::parse(hex).expect("token is a colour").luminance()
    }

    #[test]
    fn parses_kde_and_hex_colours() {
        assert_eq!(Rgb::parse("20,22,24"), Some(Rgb(20, 22, 24)));
        assert_eq!(Rgb::parse("#141618"), Some(Rgb(20, 22, 24)));
        assert_eq!(Rgb::parse("\"#1a2b3c\""), Some(Rgb(26, 43, 60)));
        assert_eq!(Rgb::parse("nope"), None);
    }

    #[test]
    fn dark_plasma_roles_become_the_dark_token_set() {
        let c = build(
            "kde",
            Rgb(20, 22, 24), // view
            Rgb(32, 35, 38), // window
            Rgb(41, 44, 48), // button
            Rgb(252, 252, 252),
            Rgb(161, 169, 177),
            Rgb(61, 174, 233),
            Rgb(252, 252, 252),
        );
        assert_eq!(c.mode, "dark");
        assert_eq!(c.bg0, "#141618");
        assert_eq!(c.bg1, "#202326");
        assert_eq!(c.accent, "#3daee9");
        // #202326 (window) is the surface and the button tone #292c30 the step
        // above it: hover and menus must not collapse into the card.
        assert_eq!(c.bg2, "#292c30", "bg2 should take the button tone");
        assert!(
            luma(&c.bg2) > luma(&c.bg1),
            "bg2 must stand off the surface"
        );
        assert!(luma(&c.bg3) > luma(&c.bg2), "bg3 must be lighter than bg2");
    }

    #[test]
    fn light_roles_put_the_canvas_below_the_surface() {
        let c = build(
            "kde",
            Rgb(252, 252, 252), // view (white)
            Rgb(239, 240, 241), // window (grey)
            Rgb(227, 229, 231),
            Rgb(35, 38, 41),
            Rgb(127, 140, 141),
            Rgb(61, 174, 233),
            Rgb(252, 252, 252),
        );
        assert_eq!(c.mode, "light");
        assert_eq!(c.bg0, "#eff0f1");
        assert_eq!(c.bg1, "#fcfcfc");
        assert!(
            luma(&c.bg3) < luma(&c.bg2),
            "on a light theme bg3 must be darker than bg2"
        );
        assert!(
            luma(&c.bg2) < luma(&c.bg1),
            "on a light theme the step above the surface is darker"
        );
    }

    #[test]
    fn ini_parser_keeps_sections_apart() {
        let ini = parse_ini(
            "[Colors:View]\nBackgroundNormal=1,2,3\n[Colors:Window]\nBackgroundNormal=4,5,6\n",
        );
        assert_eq!(ini["Colors:View"]["BackgroundNormal"], "1,2,3");
        assert_eq!(ini["Colors:Window"]["BackgroundNormal"], "4,5,6");
    }

    #[test]
    fn flat_toml_ignores_nested_keys() {
        let values = parse_flat_toml(
            "mode = \"dark\"\naccent = \"#ff8d52\"\n[extra]\naccent = \"#000000\"\n",
        );
        assert_eq!(
            values.get("accent").map(String::as_str),
            Some("\"#ff8d52\"")
        );
        assert_eq!(values.len(), 2);
    }

    /// `matte-black`, the theme installed on the Omarchy test machine. Copied
    /// verbatim from `~/.local/state/omarchy/current/theme/colors.toml`.
    const MATTE_BLACK: &str = r##"
mode = "dark"

accent = "#e68e0d"
selection = "#2a2a2a"
muted = "#333333"

background = "#121212"
dark_background = "#0d0d0d"
darker_background = "#090909"
lighter_background = "#1e1e1e"

foreground = "#bebebe"
dark_foreground = "#555555"
light_foreground = "#8a8a8d"
bright_foreground = "#bebebe"

red = "#D35F5F"
yellow = "#b91c1c"
orange = "#c63d3d"
green = "#FFC107"
cyan = "#bebebe"
blue = "#e68e0d"
magenta = "#D35F5F"
brown = "#631e1e"

bright_red = "#B91C1C"
bright_yellow = "#b90a0a"
bright_green = "#FFC107"
bright_cyan = "#eaeaea"
bright_blue = "#f59e0b"
bright_magenta = "#B91C1C"
"##;

    #[test]
    fn real_omarchy_theme_maps_to_the_dark_token_set() {
        let c = omarchy_from_colors_toml(MATTE_BLACK).expect("the real theme parses");
        assert_eq!(c.source, "omarchy");
        assert_eq!(c.mode, "dark");
        // The theme's own roles, not a luminance guess.
        assert_eq!(c.bg0, "#121212");
        assert_eq!(c.bg1, "#1e1e1e");
        assert_eq!(c.ink, "#bebebe");
        // The accent is the theme's orange, never the `selection` grey.
        assert_eq!(c.accent, "#e68e0d");
        assert_eq!(c.on_accent, "#000000", "black text on the orange accent");
        assert!(
            luma(&c.bg2) > luma(&c.bg1),
            "bg2 must stand off the surface"
        );
        assert!(luma(&c.bg3) > luma(&c.bg2));
        assert!(
            luma(&c.hairline) > luma(&c.bg1),
            "the hairline separates on a dark theme"
        );
    }

    #[test]
    fn omarchy_mode_wins_over_a_dark_background() {
        // A light theme can still carry a dark `background` in its palette;
        // the stated mode decides, not the luminance.
        let c = omarchy_from_colors_toml(
            "mode = \"light\"\nbackground = \"#f7f7f7\"\nforeground = \"#202020\"\n",
        )
        .expect("parses");
        assert_eq!(c.mode, "light");
        assert!(luma(&c.bg3) < luma(&c.bg2), "light theme steps downwards");
    }

    #[test]
    fn omarchy_state_dir_wins_over_the_old_config_path() {
        let root = std::env::temp_dir().join(format!(
            "rabe-system-theme-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let state = root.join(".local/state/omarchy/current/theme");
        let legacy = root.join(".config/omarchy/current");
        std::fs::create_dir_all(&state).expect("temp state dir");
        std::fs::create_dir_all(&legacy).expect("temp legacy dir");
        std::fs::write(
            state.join("colors.toml"),
            "mode = \"dark\"\nbackground = \"#121212\"\nforeground = \"#bebebe\"\n",
        )
        .expect("write state theme");
        std::fs::write(
            legacy.join("colors.toml"),
            "mode = \"light\"\nbackground = \"#ffffff\"\nforeground = \"#000000\"\n",
        )
        .expect("write legacy theme");

        let path = omarchy_candidates(&root, None)
            .into_iter()
            .find(|path| path.is_file())
            .expect("a theme is found");
        assert_eq!(path, state.join("colors.toml"), "Omarchy 4 outranks 3");

        let text = std::fs::read_to_string(&path).expect("read theme");
        let c = omarchy_from_colors_toml(&text).expect("parses");
        assert_eq!(c.bg0, "#121212");

        std::fs::remove_dir_all(&root).expect("clean up");
    }
}
