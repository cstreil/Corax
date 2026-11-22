//! Remote-Bilder für den Mail-Körper holen.
//!
//! Bewusst klein und streng: nur `http`/`https`, jede Adresse (auch jede
//! Weiterleitung) muss auf eine öffentliche IP zeigen, 10 s Zeit, 8 MiB
//! Größe, Abbruch beim Lesen. Gespeichert wird nur, was an der Signatur als
//! Bild erkennbar ist — dem `Content-Type` des Servers wird nicht geglaubt.
//!
//! Läuft auf der Tokio-Laufzeit des Hosts; das Modul baut keine eigene.

use std::error::Error;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use reqwest::Url;
use reqwest::header::LOCATION;

/// Obergrenze für ein Bild (8 MiB, wie `Resources::DEFAULT_MAX_INLINE_BYTES`).
pub const MAX_BYTES: usize = 8 * 1024 * 1024;
/// Zeitlimit für den ganzen Vorgang, Weiterleitungen eingeschlossen.
pub const TIMEOUT: Duration = Duration::from_secs(10);
/// Höchstens so viele Weiterleitungen.
pub const MAX_REDIRECTS: usize = 3;

const USER_AGENT: &str = "Corax/0.1 (Linux; Mail-Bildabruf)";

/// Grenzen eines Abrufs.
#[derive(Debug, Clone)]
pub struct FetchLimits {
    pub max_bytes: usize,
    pub timeout: Duration,
    pub max_redirects: usize,
    /// Nur für Tests: Loopback und private Adressen zulassen.
    pub allow_private: bool,
}

impl Default for FetchLimits {
    fn default() -> Self {
        Self {
            max_bytes: MAX_BYTES,
            timeout: TIMEOUT,
            max_redirects: MAX_REDIRECTS,
            allow_private: false,
        }
    }
}

/// Warum ein Bild nicht geholt wurde.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    InvalidUrl(String),
    SchemeNotAllowed(String),
    /// Ziel löst auf eine nicht-öffentliche Adresse auf.
    PrivateAddress(String),
    Resolve(String),
    InvalidRedirect,
    TooManyRedirects(usize),
    Timeout,
    TooLarge(usize),
    /// Signatur ist kein PNG, JPEG, GIF oder WebP.
    UnsupportedImage,
    Http(u16),
    Request(String),
}

impl fmt::Display for FetchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidUrl(url) => write!(f, "ungültige Adresse: {url}"),
            Self::SchemeNotAllowed(schema) => write!(f, "Schema nicht erlaubt: {schema}"),
            Self::PrivateAddress(ziel) => write!(f, "nicht-öffentliche Adresse: {ziel}"),
            Self::Resolve(fehler) => write!(f, "Name nicht auflösbar: {fehler}"),
            Self::InvalidRedirect => write!(f, "Weiterleitung ohne brauchbares Ziel"),
            Self::TooManyRedirects(grenze) => write!(f, "mehr als {grenze} Weiterleitungen"),
            Self::Timeout => write!(f, "Zeitlimit überschritten"),
            Self::TooLarge(grenze) => write!(f, "größer als {grenze} Bytes"),
            Self::UnsupportedImage => write!(f, "keine Bildsignatur"),
            Self::Http(status) => write!(f, "HTTP-Status {status}"),
            Self::Request(fehler) => write!(f, "Abruf fehlgeschlagen: {fehler}"),
        }
    }
}

impl Error for FetchError {}

/// Holt ein Bild und liefert `(mime, bytes)`.
///
/// Der MIME-Typ kommt aus der Signatur, nicht aus dem Header. Jede Weiterleitung
/// wird wie das ursprüngliche Ziel geprüft; der Client wird je Sprung auf die
/// aufgelöste IP festgelegt, damit ein zweiter DNS-Blick das Ziel nicht tauschen
/// kann (DNS-Rebinding).
pub async fn fetch_image(url: &str, limits: &FetchLimits) -> Result<(String, Vec<u8>), FetchError> {
    let deadline = tokio::time::Instant::now() + limits.timeout;
    let mut current = Url::parse(url).map_err(|_| FetchError::InvalidUrl(url.to_string()))?;
    let mut urspruenge = 0usize;

    loop {
        check_scheme(&current)?;
        let client = client_for(&current, limits, deadline).await?;

        let mut response = tokio::time::timeout_at(deadline, client.get(current.clone()).send())
            .await
            .map_err(|_| FetchError::Timeout)?
            .map_err(map_reqwest)?;

        let status = response.status();
        if status.is_redirection() {
            if urspruenge >= limits.max_redirects {
                return Err(FetchError::TooManyRedirects(limits.max_redirects));
            }
            let ziel = response
                .headers()
                .get(LOCATION)
                .and_then(|wert| wert.to_str().ok())
                .ok_or(FetchError::InvalidRedirect)?;
            current = current.join(ziel).map_err(|_| FetchError::InvalidRedirect)?;
            urspruenge += 1;
            continue;
        }
        if !status.is_success() {
            return Err(FetchError::Http(status.as_u16()));
        }

        let mut bytes = Vec::new();
        while let Some(stueck) = tokio::time::timeout_at(deadline, response.chunk())
            .await
            .map_err(|_| FetchError::Timeout)?
            .map_err(|fehler| FetchError::Request(fehler.to_string()))?
        {
            if bytes.len() + stueck.len() > limits.max_bytes {
                return Err(FetchError::TooLarge(limits.max_bytes));
            }
            bytes.extend_from_slice(&stueck);
        }

        let mime = sniff_image(&bytes).ok_or(FetchError::UnsupportedImage)?;
        return Ok((mime.to_string(), bytes));
    }
}

/// MIME-Typ aus der Dateisignatur.
pub fn sniff_image(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
        return Some("image/png");
    }
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

/// Feste Kopfzeilen: unkomprimiert, damit die Signatur im Rumpf steht und nicht
/// der gzip-Strom eines Servers.
fn kopfzeilen() -> reqwest::header::HeaderMap {
    let mut kopfzeilen = reqwest::header::HeaderMap::new();
    kopfzeilen.insert(
        reqwest::header::ACCEPT_ENCODING,
        reqwest::header::HeaderValue::from_static("identity"),
    );
    kopfzeilen
}

/// reqwest meldet sein eigenes Zeitlimit wie einen Netzfehler; für den Aufrufer
/// ist beides derselbe Fall.
fn map_reqwest(fehler: reqwest::Error) -> FetchError {
    if fehler.is_timeout() {
        FetchError::Timeout
    } else {
        FetchError::Request(fehler.to_string())
    }
}

fn check_scheme(url: &Url) -> Result<(), FetchError> {
    match url.scheme() {
        "http" | "https" => {}
        anderes => return Err(FetchError::SchemeNotAllowed(anderes.to_string())),
    }
    if !url.username().is_empty() || url.password().is_some() {
        // Zugangsdaten in der Adresse gehören nicht in ein Mail-HTML.
        return Err(FetchError::InvalidUrl(url.to_string()));
    }
    Ok(())
}

/// Baut einen Client, der genau diese URL (und keine andere Adresse derselben
/// Domain) erreicht. Die Namensauflösung läuft im selben Zeitbudget wie der
/// Abruf — ein hängender Resolver darf die Frist nicht überziehen.
async fn client_for(
    url: &Url,
    limits: &FetchLimits,
    deadline: tokio::time::Instant,
) -> Result<reqwest::Client, FetchError> {
    let host = url
        .host_str()
        .ok_or_else(|| FetchError::InvalidUrl(url.to_string()))?
        .to_string();
    let port = url.port_or_known_default().unwrap_or(443);

    let mut builder = reqwest::Client::builder()
        // Kein Proxy aus der Umgebung: sonst ginge die IP-Prüfung ins Leere.
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(limits.timeout)
        .user_agent(USER_AGENT)
        .default_headers(kopfzeilen());

    if let Ok(ip) = host.parse::<IpAddr>() {
        if !limits.allow_private && !is_public_ip(ip) {
            return Err(FetchError::PrivateAddress(ip.to_string()));
        }
    } else {
        let addrs: Vec<SocketAddr> = tokio::time::timeout_at(deadline, async {
            tokio::net::lookup_host((host.as_str(), port))
                .await
                .map(|adressen| adressen.collect::<Vec<_>>())
        })
        .await
        .map_err(|_| FetchError::Timeout)?
        .map_err(|fehler| FetchError::Resolve(fehler.to_string()))?;
        if addrs.is_empty() {
            return Err(FetchError::Resolve(format!("{host} ohne Adresse")));
        }
        let ziel = addrs
            .iter()
            .find(|adresse| limits.allow_private || is_public_ip(adresse.ip()))
            .ok_or_else(|| FetchError::PrivateAddress(host.clone()))?;
        builder = builder.resolve(&host, *ziel);
    }

    builder
        .build()
        .map_err(|fehler| FetchError::Request(fehler.to_string()))
}

/// Ist die Adresse öffentlich erreichbar? Alles, was im eigenen Netz oder im
/// Netz des Anbieters liegt, ist es nicht.
pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => {
            // `::ffff:a.b.c.d` ist IPv4 in IPv6-Schreibweise.
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_public_v4(v4);
            }
            is_public_v6(v6)
        }
    }
}

fn is_public_v6(v6: Ipv6Addr) -> bool {
    let s = v6.segments();
    // NAT64 und 6to4 tragen eine IPv4-Adresse in sich; die entscheidet, nicht
    // das IPv6-Präfix.
    let eingebettet = |hoch: u16, tief: u16| {
        Ipv4Addr::new((hoch >> 8) as u8, hoch as u8, (tief >> 8) as u8, tief as u8)
    };
    // 64:ff9b::/96 (RFC 6052) — nur mit öffentlicher IPv4 erreichbar.
    if s[0] == 0x0064 && s[1] == 0xff9b {
        if s[2] != 0 {
            // 64:ff9b:1::/48 ist der NAT64-Bereich für lokale Netze (RFC 8215).
            return false;
        }
        return is_public_v4(eingebettet(s[6], s[7]));
    }
    // 2002::/16 (6to4) — IPv4 steckt in den Segmenten 1 und 2.
    if s[0] == 0x2002 {
        return is_public_v4(eingebettet(s[1], s[2]));
    }
    // ::/96 — veraltete IPv4-kompatible Schreibweise `::a.b.c.d`.
    if s[..6].iter().all(|&teil| teil == 0) {
        return is_public_v4(eingebettet(s[6], s[7]));
    }
    !(v6.is_loopback()
        || v6.is_unspecified()
        || v6.is_multicast()
        // fc00::/7 – eindeutig lokal
        || (s[0] & 0xfe00) == 0xfc00
        // fe80::/10 – link-lokal
        || (s[0] & 0xffc0) == 0xfe80
        // 2001:db8::/32 – nur Dokumentation
        || (s[0] == 0x2001 && s[1] == 0x0db8))
}

fn is_public_v4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    let cgnat = o[0] == 100 && (64..128).contains(&o[1]);
    !(v4.is_unspecified()
        || v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_broadcast()
        || v4.is_multicast()
        || v4.is_documentation()
        // "dieses Netz" (0.0.0.0/8), Benchmark (198.18/15), reserviert (240/4),
        // CGNAT (100.64/10)
        || o[0] == 0
        || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
        || o[0] >= 240
        || cgnat)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oeffentliche_und_interne_adressen() {
        for oeffentlich in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2001:4860:4860::8888"] {
            assert!(is_public_ip(oeffentlich.parse().unwrap()), "{oeffentlich}");
        }
        for intern in [
            "127.0.0.1",
            "127.1.2.3",
            "10.1.2.3",
            "172.16.5.5",
            "192.168.1.1",
            "169.254.1.1",
            "100.64.0.1",
            "100.127.255.254",
            "0.0.0.0",
            "198.18.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "224.0.0.1",
            "::1",
            "::",
            "fe80::1",
            "fc00::1",
            "fd12:3456::1",
            "ff02::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
        ] {
            assert!(!is_public_ip(intern.parse().unwrap()), "{intern}");
        }
    }

    #[test]
    fn nat64_und_6to4_haengen_an_der_eingebetteten_ipv4() {
        for (adresse, oeffentlich) in [
            // NAT64 64:ff9b::/96
            ("64:ff9b::808:808", true),       // 8.8.8.8
            ("64:ff9b::7f00:1", false),       // 127.0.0.1
            ("64:ff9b::a00:1", false),        // 10.0.0.1
            ("64:ff9b::c0a8:101", false),     // 192.168.1.1
            ("64:ff9b:1::1", false),          // NAT64 für lokale Netze
            // 6to4 2002::/16
            ("2002:808:808::1", true),        // 8.8.8.8
            ("2002:7f00:1::1", false),        // 127.0.0.1
            ("2002:a00:1::1", false),         // 10.0.0.1
            ("2002:c0a8:101::1", false),      // 192.168.1.1
            // IPv4-kompatibel (::/96)
            ("::808:808", true),
            ("::7f00:1", false),
            // Dokumentationsbereich
            ("2001:db8::1", false),
            // Unverändert öffentlich
            ("2001:4860:4860::8888", true),
        ] {
            assert_eq!(
                is_public_ip(adresse.parse().unwrap()),
                oeffentlich,
                "{adresse}"
            );
        }
    }

    #[test]
    fn signatur_statt_header() {
        assert_eq!(sniff_image(&[0x89, b'P', b'N', b'G', 13, 10, 26, 10]), Some("image/png"));
        assert_eq!(sniff_image(&[0xff, 0xd8, 0xff, 0xe0]), Some("image/jpeg"));
        assert_eq!(sniff_image(b"GIF89a......"), Some("image/gif"));
        assert_eq!(sniff_image(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff_image(b"<html>nein</html>"), None);
        assert_eq!(sniff_image(&[]), None);
        assert_eq!(sniff_image(b"RIFF\0\0\0\0WAVEfmt "), None);
    }
}
