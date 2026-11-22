//! Tests für den Bildabruf — ausschließlich gegen einen lokalen Server im
//! Testprozess. Kein echter Netzzugriff.

#[path = "../src/html/mod.rs"]
mod html;

use std::net::SocketAddr;
use std::time::Duration;

use html::{FetchError, FetchLimits, Resources, fetch_image};

const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13];

fn antwort(status: u16, mime: &str, koerper: &[u8]) -> Vec<u8> {
    let mut out = format!(
        "HTTP/1.1 {status} X\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        koerper.len()
    )
    .into_bytes();
    out.extend_from_slice(koerper);
    out
}

fn weiterleitung(ziel: &str) -> Vec<u8> {
    format!("HTTP/1.1 302 Found\r\nLocation: {ziel}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        .into_bytes()
}

/// Mini-HTTP-Server auf 127.0.0.1 mit festen Pfaden.
async fn starte_server() -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("Testserver binden");
    let adresse = listener.local_addr().expect("Adresse");
    let griff = tokio::spawn(async move {
        loop {
            let Ok((mut strom, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut puffer = vec![0u8; 4096];
                let gelesen = strom.read(&mut puffer).await.unwrap_or(0);
                let anfrage = String::from_utf8_lossy(&puffer[..gelesen]).to_string();
                let pfad = anfrage
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .to_string();
                let basis = format!("http://127.0.0.1:{}", adresse.port());
                let antwort_bytes = match pfad.as_str() {
                    "/bild.png" => antwort(200, "image/png", PNG),
                    // Der Header sagt Bild, der Inhalt ist Text.
                    "/falsch.png" => antwort(200, "image/png", b"<html>nein</html>"),
                    "/kein-bildheader.png" => antwort(200, "text/plain", PNG),
                    "/fehler" => antwort(404, "text/plain", b""),
                    "/gross.png" => {
                        let mut gross = PNG.to_vec();
                        gross.extend(std::iter::repeat_n(0u8, 4096));
                        antwort(200, "image/png", &gross)
                    }
                    "/weiter.png" => weiterleitung(&format!("{basis}/bild.png")),
                    "/schleife" => weiterleitung(&format!("{basis}/schleife")),
                    "/langsam.png" => {
                        tokio::time::sleep(Duration::from_millis(900)).await;
                        antwort(200, "image/png", PNG)
                    }
                    _ => antwort(404, "text/plain", b""),
                };
                let _ = strom.write_all(&antwort_bytes).await;
                let _ = strom.shutdown().await;
            });
        }
    });
    (adresse, griff)
}

/// Grenzen für Tests: Loopback erlaubt, kurze Zeit.
fn testgrenzen() -> FetchLimits {
    FetchLimits {
        allow_private: true,
        timeout: Duration::from_secs(5),
        ..FetchLimits::default()
    }
}

#[tokio::test]
async fn loopback_wird_im_normalbetrieb_abgewiesen() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/bild.png", adresse.port());
    let fehler = fetch_image(&url, &FetchLimits::default()).await.unwrap_err();
    assert!(matches!(fehler, FetchError::PrivateAddress(_)), "{fehler:?}");
    griff.abort();
}

#[tokio::test]
async fn bild_wird_geholt_und_an_der_signatur_erkannt() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/bild.png", adresse.port());
    let (mime, bytes) = fetch_image(&url, &testgrenzen()).await.expect("Bild");
    assert_eq!(mime, "image/png");
    assert_eq!(bytes, PNG);
    griff.abort();
}

#[tokio::test]
async fn der_header_entscheidet_nicht() {
    let (adresse, griff) = starte_server().await;
    // Header sagt image/png, Inhalt ist HTML → abgelehnt.
    let falsch = format!("http://127.0.0.1:{}/falsch.png", adresse.port());
    assert_eq!(
        fetch_image(&falsch, &testgrenzen()).await.unwrap_err(),
        FetchError::UnsupportedImage
    );
    // Header sagt text/plain, Inhalt ist ein PNG → angenommen.
    let richtig = format!("http://127.0.0.1:{}/kein-bildheader.png", adresse.port());
    let (mime, _) = fetch_image(&richtig, &testgrenzen()).await.expect("PNG trotz Header");
    assert_eq!(mime, "image/png");
    griff.abort();
}

#[tokio::test]
async fn uebergroesse_bricht_ab() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/gross.png", adresse.port());
    let grenzen = FetchLimits {
        max_bytes: 64,
        ..testgrenzen()
    };
    let fehler = fetch_image(&url, &grenzen).await.unwrap_err();
    assert!(matches!(fehler, FetchError::TooLarge(64)), "{fehler:?}");
    griff.abort();
}

#[tokio::test]
async fn weiterleitung_auf_loopback_wird_abgewiesen() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/weiter.png", adresse.port());
    // Normalbetrieb: schon das erste Ziel ist Loopback.
    let fehler = fetch_image(&url, &FetchLimits::default()).await.unwrap_err();
    assert!(matches!(fehler, FetchError::PrivateAddress(_)), "{fehler:?}");
    // Mit Testschalter wird die Weiterleitung verfolgt und validiert.
    let (mime, bytes) = fetch_image(&url, &testgrenzen()).await.expect("gefolgt");
    assert_eq!(mime, "image/png");
    assert_eq!(bytes, PNG);
    griff.abort();
}

#[test]
fn https_auf_http_wird_abgewiesen() {
    // K4: eine verschlüsselte Adresse darf nicht auf unverschlüsseltes http
    // weiterleiten. (Ein echter https-Server im Testprozess wäre dafür nötig;
    // geprüft wird die Entscheidung selbst, die der Abruf je Sprung nutzt.)
    let von = reqwest::Url::parse("https://beispiel.test/bild.png").unwrap();
    assert!(matches!(
        html::weiterleitungsziel(&von, "http://beispiel.test/bild.png"),
        Err(FetchError::Downgrade(_))
    ));
    assert!(matches!(
        html::weiterleitungsziel(&von, "//beispiel.test/bild.png"),
        Ok(_)
    ));
    let von_http = reqwest::Url::parse("http://beispiel.test/bild.png").unwrap();
    assert!(html::weiterleitungsziel(&von_http, "http://beispiel.test/anders.png").is_ok());
}

#[tokio::test]
async fn zu_viele_weiterleitungen() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/schleife", adresse.port());
    let grenzen = FetchLimits {
        max_redirects: 1,
        ..testgrenzen()
    };
    assert_eq!(
        fetch_image(&url, &grenzen).await.unwrap_err(),
        FetchError::TooManyRedirects(1)
    );
    griff.abort();
}

#[tokio::test]
async fn zeitlimit_greift() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/langsam.png", adresse.port());
    let grenzen = FetchLimits {
        timeout: Duration::from_millis(150),
        ..testgrenzen()
    };
    assert_eq!(fetch_image(&url, &grenzen).await.unwrap_err(), FetchError::Timeout);
    griff.abort();
}

#[tokio::test]
async fn http_fehler_wird_gemeldet() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/fehler", adresse.port());
    assert_eq!(
        fetch_image(&url, &testgrenzen()).await.unwrap_err(),
        FetchError::Http(404)
    );
    griff.abort();
}

#[tokio::test]
async fn nur_http_und_https_ohne_zugangsdaten() {
    for (url, erwartet_schema) in [
        ("file:///etc/passwd", "file"),
        ("data:image/png;base64,AAAA", "data"),
        ("ftp://example.invalid/x.png", "ftp"),
    ] {
        match fetch_image(url, &FetchLimits::default()).await.unwrap_err() {
            FetchError::SchemeNotAllowed(schema) => assert_eq!(schema, erwartet_schema),
            anderes => panic!("{url}: {anderes:?}"),
        }
    }
    let mit_zugang = "http://nutzer:geheim@127.0.0.1/x.png";
    assert!(matches!(
        fetch_image(mit_zugang, &FetchLimits::default()).await.unwrap_err(),
        FetchError::InvalidUrl(_)
    ));
    assert!(matches!(
        fetch_image("nicht mal eine URL", &FetchLimits::default()).await.unwrap_err(),
        FetchError::InvalidUrl(_)
    ));
}

#[tokio::test]
async fn geholte_bilder_landen_in_den_ressourcen() {
    let (adresse, griff) = starte_server().await;
    let url = format!("http://127.0.0.1:{}/bild.png", adresse.port());
    let ressourcen = Resources::from_attachments(Vec::new());

    // Wie der Produktpfad (`core/host.rs`): einzeln holen und einlagern.
    let (mime, bytes) = fetch_image(&url, &testgrenzen()).await.expect("Bild");
    assert!(ressourcen.insert_remote(&url, &mime, bytes));
    let (mime, bytes) = ressourcen.resolve(&url).expect("eingetragen");
    assert_eq!(mime, "image/png");
    assert_eq!(&*bytes, PNG);

    // Ein Fehlschlag landet nicht im Speicher und stört den Rest nicht.
    let zweite = format!("http://127.0.0.1:{}/falsch.png", adresse.port());
    assert!(fetch_image(&zweite, &testgrenzen()).await.is_err());
    assert!(ressourcen.resolve(&zweite).is_none());
    griff.abort();
}
