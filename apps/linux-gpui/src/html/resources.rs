//! Bild-Ressourcen für den Blitz-Körper.
//!
//! Drei Quellen, in dieser Reihenfolge: `cid:` aus den Anhängen der Mail,
//! `data:` aus dem HTML selbst, `http(s):` ausschließlich aus einem Cache, den
//! die Oberfläche nach dem Nachladen füllt. Der Renderer bekommt Bytes oder
//! `None` — er sieht nie einen Netzpfad, und was nicht hier liegt, wird nicht
//! geladen.
//!
//! Anhänge und `data:`-Bilder gehören zur offenen Mail und bleiben immer
//! erreichbar. Der Remote-Cache hat dagegen einen Gesamtdeckel und verdrängt
//! die ältesten Bilder zuerst, damit langes Blättern nicht linear wächst.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, RwLock};

/// Eine aufgelöste Bild-Ressource: MIME-Typ und Bytes.
pub type Resolved = (String, Arc<[u8]>);

/// Standard-Obergrenze für ein einzelnes Bild (8 MiB).
///
/// Der Kern liefert `cid:`-Bilder als `data:`-URI; Base64 bläht ein Bild um
/// ein Drittel auf, ein 5-MB-Foto wäre also schon 6,7 MB HTML. Größere Bilder
/// bleiben draußen, statt den Speicher zu sprengen.
pub const DEFAULT_MAX_INLINE_BYTES: usize = 8 * 1024 * 1024;

/// Gesamtdeckel für nachgeladene Remote-Bilder (64 MiB).
///
/// Gilt für den Cache in Summe, nicht je Bild: Abo-Newsletter mit vielen
/// Mails sollen den Speicher nicht linear wachsen lassen. Anhänge und
/// `data:`-Bilder zählen nicht mit, sie gehören zur offenen Mail.
pub const DEFAULT_MAX_REMOTE_BYTES: usize = 64 * 1024 * 1024;

/// Remote-Cache in Einfüge-Reihenfolge: der älteste Eintrag fällt zuerst.
#[derive(Default)]
struct RemoteCache {
    bilder: HashMap<String, Resolved>,
    reihenfolge: VecDeque<String>,
    bytes: usize,
}

impl RemoteCache {
    fn get(&self, url: &str) -> Option<Resolved> {
        self.bilder
            .get(url)
            .map(|(mime, bytes)| (mime.clone(), Arc::clone(bytes)))
    }

    /// Trägt ein Bild ein und verdrängt danach die ältesten, bis der Deckel
    /// wieder passt. `false`, wenn schon das einzelne Bild zu groß ist.
    fn insert(
        &mut self,
        url: &str,
        mime: &str,
        bytes: Vec<u8>,
        max_bild: usize,
        max_gesamt: usize,
    ) -> bool {
        let groesse = bytes.len();
        if groesse > max_bild || groesse > max_gesamt {
            return false;
        }
        // Erneutes Nachladen derselben Adresse ersetzt den alten Stand; sonst
        // zählte der Deckel die Bytes doppelt.
        if let Some((_, alt)) = self.bilder.remove(url) {
            self.bytes = self.bytes.saturating_sub(alt.len());
            if let Some(stelle) = self.reihenfolge.iter().position(|eintrag| eintrag == url) {
                self.reihenfolge.remove(stelle);
            }
        }
        self.bytes += groesse;
        self.bilder
            .insert(url.to_string(), (mime.to_string(), Arc::from(bytes.into_boxed_slice())));
        self.reihenfolge.push_back(url.to_string());
        while self.bytes > max_gesamt {
            let Some(aeltestes) = self.reihenfolge.pop_front() else {
                break;
            };
            if let Some((_, bytes)) = self.bilder.remove(&aeltestes) {
                self.bytes = self.bytes.saturating_sub(bytes.len());
            }
        }
        true
    }
}

/// Bilder einer Mail: Anhänge, Inline-Daten und nachgeladene Remote-Bilder.
pub struct Resources {
    /// `cid` → Bild, Schlüssel normalisiert (klein, ohne `<...>`).
    attachments: HashMap<String, Resolved>,
    /// Nachgeladene Remote-Bilder, URL → Bytes, mit Gesamtdeckel.
    remote: RwLock<RemoteCache>,
    max_inline_bytes: usize,
    max_remote_bytes: usize,
}

impl Resources {
    /// Baut die Quellen aus den Anhängen: `(cid, mime, bytes)`.
    ///
    /// Der `cid` darf mit oder ohne `<...>` kommen; Groß-/Kleinschreibung und
    /// Prozent-Kodierung sind egal (siehe [`normalize_cid`]).
    pub fn from_attachments(parts: Vec<(String, String, Vec<u8>)>) -> Self {
        Self::with_limits(parts, DEFAULT_MAX_INLINE_BYTES)
    }

    /// Wie [`from_attachments`](Self::from_attachments), aber mit eigenem
    /// Einzelbild-Deckel. Der Gesamtdeckel bleibt bei 64 MiB.
    pub fn with_limits(parts: Vec<(String, String, Vec<u8>)>, max_inline_bytes: usize) -> Self {
        Self::with_caps(parts, max_inline_bytes, DEFAULT_MAX_REMOTE_BYTES)
    }

    /// Beide Deckel: je Bild und für den Remote-Cache in Summe.
    pub fn with_caps(
        parts: Vec<(String, String, Vec<u8>)>,
        max_inline_bytes: usize,
        max_remote_bytes: usize,
    ) -> Self {
        let mut attachments = HashMap::with_capacity(parts.len());
        for (cid, mime, bytes) in parts {
            let key = normalize_cid(&cid);
            if key.is_empty() {
                continue;
            }
            attachments
                .entry(key)
                .or_insert((mime, Arc::from(bytes.into_boxed_slice())));
        }
        Self {
            attachments,
            remote: RwLock::new(RemoteCache::default()),
            max_inline_bytes,
            max_remote_bytes,
        }
    }

    /// Trägt ein nachgeladenes Remote-Bild ein. `false`, wenn es den Deckel
    /// sprengt (dann bleibt es beim Platzhalter).
    ///
    /// Ist der Gesamtdeckel danach überschritten, fallen die ältesten Bilder
    /// raus; ein späteres [`resolve`](Self::resolve) liefert für sie `None`.
    pub fn insert_remote(&self, url: &str, mime: &str, bytes: Vec<u8>) -> bool {
        let Ok(mut cache) = self.remote.write() else {
            return false;
        };
        cache.insert(url, mime, bytes, self.max_inline_bytes, self.max_remote_bytes)
    }

    /// Löst eine URL des Renderers auf. `None` heißt: nicht laden.
    pub fn resolve(&self, url: &str) -> Option<Resolved> {
        let url = url.trim();
        if url.is_empty() {
            return None;
        }
        if let Some(rest) = strip_prefix_ignore_case(url, "cid:") {
            return self
                .attachments
                .get(&normalize_cid(rest))
                .map(|(mime, bytes)| (mime.clone(), Arc::clone(bytes)));
        }
        if strip_prefix_ignore_case(url, "data:").is_some() {
            return self.decode_data_uri(url);
        }
        if is_remote(url) {
            let cache = self.remote.read().ok()?;
            return cache.get(url);
        }
        // Relative Pfade und alles andere: Die echte App liefert Bilder als
        // `cid:`, ein Pfad ohne Basis würde aus dem Dateisystem lesen.
        None
    }

    /// `data:[<mime>][;base64],<daten>` → Bytes, mit Größenprüfung.
    fn decode_data_uri(&self, url: &str) -> Option<Resolved> {
        let rest = strip_prefix_ignore_case(url, "data:")?;
        let (meta, payload) = rest.split_once(',')?;
        let (mime, base64) = match meta.split_once(';') {
            Some((mime, param)) if param.eq_ignore_ascii_case("base64") => (mime, true),
            Some(_) => return None,
            None => (meta, false),
        };
        let mime = if mime.trim().is_empty() {
            "text/plain"
        } else {
            mime.trim()
        };
        // Nur Bilder: `data:` in einem <img> ist ein Bild, alles andere wäre
        // eine Text- oder Skriptladung durch die Hintertür.
        if !mime.starts_with("image/") {
            return None;
        }
        let bytes = if base64 {
            decode_base64(payload)?
        } else {
            percent_decode(payload)
        };
        if bytes.is_empty() || bytes.len() > self.max_inline_bytes {
            return None;
        }
        Some((mime.to_string(), Arc::from(bytes.into_boxed_slice())))
    }
}

/// Ist die URL extern? `//host/pfad` zählt als extern (schema-relativ).
pub fn is_remote(url: &str) -> bool {
    let url = url.trim();
    strip_prefix_ignore_case(url, "http://").is_some()
        || strip_prefix_ignore_case(url, "https://").is_some()
        || url.starts_with("//")
}

/// Normalisiert eine Content-ID: `cid:` weg, `<...>` weg, Prozent-Dekodierung
/// auf, Kleinschreibung, außen getrimmt.
pub fn normalize_cid(cid: &str) -> String {
    let raw = strip_prefix_ignore_case(cid.trim(), "cid:").unwrap_or(cid.trim());
    let raw = raw.trim().trim_start_matches('<').trim_end_matches('>');
    String::from_utf8_lossy(&percent_decode(raw))
        .trim()
        .to_ascii_lowercase()
}

fn strip_prefix_ignore_case<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    let head = value.get(..prefix.len())?;
    if head.eq_ignore_ascii_case(prefix) {
        Some(&value[prefix.len()..])
    } else {
        None
    }
}

/// `%XX`-Dekodierung; ungültige Folgen bleiben stehen.
pub fn percent_decode(input: &str) -> Vec<u8> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
                out.push(hi << 4 | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// Base64 (Standard-Alphabet), Leerraum wird übersprungen.
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    let mut buffer = 0u32;
    let mut bits = 0u8;
    for byte in input.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b' ' | b'\t' | b'\r' | b'\n' => continue,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cid_resolves_with_angle_brackets_and_case() {
        let res = Resources::from_attachments(vec![(
            "<Bild-1@Corax>".to_string(),
            "image/png".to_string(),
            vec![1, 2, 3],
        )]);
        assert_eq!(res.resolve("cid:bild-1@corax").map(|r| r.0), Some("image/png".into()));
        assert_eq!(res.resolve("CID:<Bild-1@Corax>").map(|r| r.1.len()), Some(3));
        assert!(res.resolve("cid:unbekannt").is_none());
    }

    #[test]
    fn data_uri_needs_image_mime_and_size() {
        let res = Resources::with_limits(Vec::new(), 4);
        // "AAEC" = drei Bytes
        assert_eq!(res.resolve("data:image/png;base64,AAEC").map(|r| r.1.len()), Some(3));
        assert!(res.resolve("data:text/html;base64,AAEC").is_none());
        assert!(res.resolve("data:image/png;base64,AAECAwQ=").is_none(), "zu groß");
    }

    #[test]
    fn remote_only_from_cache() {
        let res = Resources::from_attachments(Vec::new());
        assert!(res.resolve("https://example.invalid/pixel.gif").is_none());
        assert!(res.insert_remote("https://example.invalid/pixel.gif", "image/gif", vec![0, 1]));
        assert_eq!(
            res.resolve("https://example.invalid/pixel.gif").map(|r| r.0),
            Some("image/gif".into())
        );
        assert_eq!(
            res.resolve("https://example.invalid/pixel.gif").map(|r| r.1.len()),
            Some(2)
        );
    }

    #[test]
    fn remote_cache_verdraengt_die_aeltesten() {
        // 40 Bytes je Bild, 100 Bytes gesamt: das dritte Bild verdrängt das erste.
        let res = Resources::with_caps(Vec::new(), 1024, 100);
        for (name, fueller) in [("a", 1u8), ("b", 2), ("c", 3)] {
            let url = format!("https://cdn.example/{name}.png");
            assert!(res.insert_remote(&url, "image/png", vec![fueller; 40]), "{name}");
        }
        assert!(res.resolve("https://cdn.example/a.png").is_none(), "ältestes bleibt");
        assert!(res.resolve("https://cdn.example/b.png").is_some());
        assert!(res.resolve("https://cdn.example/c.png").is_some());
        // Dieselbe Adresse noch einmal: ersetzt, zählt nicht doppelt.
        assert!(res.insert_remote("https://cdn.example/b.png", "image/png", vec![2u8; 40]));
        assert!(res.resolve("https://cdn.example/b.png").is_some());
    }

    #[test]
    fn verdraengung_laesst_anhaenge_und_data_uri_in_ruhe() {
        let res = Resources::with_caps(
            vec![("logo@x".to_string(), "image/png".to_string(), vec![7u8; 40])],
            1024,
            100,
        );
        // "AAECAwQ=" sind fünf Bytes.
        let data = "data:image/png;base64,AAECAwQ=";
        assert!(res.resolve(data).is_some());
        for name in ["a", "b", "c"] {
            let url = format!("https://cdn.example/{name}.png");
            assert!(res.insert_remote(&url, "image/png", vec![name.as_bytes()[0]; 40]));
        }
        assert!(res.resolve("https://cdn.example/a.png").is_none(), "Remote verdrängt");
        // Anhang und data:-Bild gehören zur Mail und bleiben erreichbar.
        assert!(res.resolve("cid:logo@x").is_some());
        assert!(res.resolve(data).is_some());
    }

    #[test]
    fn einzelbild_ueber_dem_gesamtdeckel_wird_abgelehnt() {
        let res = Resources::with_caps(Vec::new(), 1024, 100);
        assert!(!res.insert_remote("https://cdn.example/gross.png", "image/png", vec![0u8; 101]));
        assert!(res.resolve("https://cdn.example/gross.png").is_none());
    }

    #[test]
    fn relative_paths_never_load() {
        let res = Resources::from_attachments(Vec::new());
        assert!(res.resolve("bilder/banner-hero.png").is_none());
        assert!(res.resolve("file:///etc/passwd").is_none());
    }

    #[test]
    fn base64_and_percent_decode() {
        assert_eq!(decode_base64("aGVsbG8=").as_deref(), Some(&b"hello"[..]));
        assert_eq!(percent_decode("a%20b"), b"a b".to_vec());
        assert_eq!(percent_decode("a%zzb"), b"a%zzb".to_vec());
    }
}
