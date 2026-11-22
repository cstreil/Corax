# Corax — Google-Konto über OAuth einrichten

Stand 2026-11-21 · M3.4 (schlank) · Gilt für die macOS-App; die Anleitung selbst ist anbieterneutral.
Kern: `comail-core/src/oauth/flow.rs`, `providers.rs`; Oberfläche: `AccountsSettingsView` und `AccountSheet`.

Corax bringt **keine** eigene Google-Client-ID mit. Jede Installation legt sich ihre eigene
Google-Cloud-App an; das dauert etwa fünf Minuten und kostet nichts.

## 1. Projekt und Gmail-API

1. [Google Cloud Console](https://console.cloud.google.com/projectcreate) öffnen und ein Projekt anlegen (oder ein vorhandenes wählen).
2. Unter **APIs und Dienste → Bibliothek** die [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com) aktivieren.
3. Unter **OAuth-Zustimmungsbildschirm** (APIs und Dienste → OAuth-Zustimmungsbildschirm):
   - Nutzertyp **Extern**;
   - Veröffentlichungsstatus **Testing**;
   - unter **Testnutzer** die eigene Gmail-Adresse eintragen. Solange die App nicht geprüft ist, dürfen sich nur diese Adressen anmelden.

## 2. OAuth-Client

1. Unter **Anmeldedaten → Anmeldedaten erstellen → OAuth-Client-ID** den Anwendungstyp **Desktop-App** wählen.
2. Client-ID und Client-Secret kopieren.
3. In Corax unter **Einstellungen → Konten → Google (OAuth)** eintragen und **Speichern** klicken. Die Werte gelten sofort für die nächste Anmeldung, ohne Neustart.

Der Client ist ein öffentlicher Client: Der Kern schickt kein Secret mit, wenn keines eingetragen ist.
Googles „Desktop“-Secret gilt bei Google selbst nicht als vertraulich; es liegt deshalb in den
Einstellungen (Tabelle `settings`, Felder `google_client_id`/`google_client_secret`) und nicht im
Schlüsselbund. Wer will, kann die Client-ID stattdessen über `COMAIL_GOOGLE_CLIENT_ID` setzen; die
Umgebungsvariable sticht die Einstellung aus.

## 3. Anmelden

**Konto hinzufügen …** → **Mit Google anmelden**. Der Flow ist Authorization Code mit PKCE
(S256), der Rücksprung läuft über den Loopback-Server `http://localhost:{port}/`; der Kern
wartet bis zu fünf Minuten. Währenddessen steht im Blatt „Warte auf Browser …“ mit **Abbrechen**.

Angefragte Berechtigungen — genau diese vier, sonst nichts:

```
https://mail.google.com/
openid
email
profile
```

`https://mail.google.com/` ist die einzige Berechtigung, die Google für IMAP/SMTP per XOAUTH2
akzeptiert; `openid`/`email`/`profile` liefern die Adresse und den Absendernamen aus dem ID-Token.
Beim Anmelden setzt der Kern `access_type=offline&prompt=consent`, damit Google ein Refresh-Token
ausgibt. Weitere Berechtigungen (z. B. Kalender) werden erst bei Bedarf nachgefragt.

## 4. Die 7-Tage-Grenze im Modus „Testing“

Google lässt ausgestellte Refresh-Tokens im Modus **Testing** nach **sieben Tagen** ablaufen
(„Testing“-Apps bekommen nur kurzlebige Refresh-Tokens). Danach meldet der Kern das Konto als
`needs_reauth`; die Kontenseite zeigt „Abgemeldet – bitte neu verbinden“ und den Knopf
**Neu anmelden**. Ein Klick öffnet den Browser erneut und erneuert die Anmeldung.

Dauerhaft verschwindet die Grenze erst mit dem Veröffentlichen der Google-App — und dafür verlangt
Google für eingeschränkte Berechtigungen wie `https://mail.google.com/` ein
**Sicherheitsaudit** („verification“). Das ist der Grund, warum Corax beim Testmodus bleibt statt
eine eigene Client-ID mitzuliefern.

## 5. Alternative: IMAP mit App-Passwort

Ohne Google-Cloud-App geht Gmail auch als normales IMAP/SMTP-Konto:

- im Google-Konto die Bestätigung in zwei Schritten einschalten,
- unter <https://myaccount.google.com/apppasswords> ein App-Passwort erzeugen,
- in Corax **Konto hinzufügen** → IMAP-Server `imap.gmail.com`, Port `993`, SMTP `smtp.gmail.com`,
  Port `587`, Benutzer und Passwort = App-Passwort.

Das läuft ohne Browser und ohne 7-Tage-Grenze, verliert aber die OAuth-Token-Erneuerung und die
Konten-Einrichtung per Klick.

## 6. Wo die Fehler stehen

Der Kern antwortet auf Fehler mit `auth` und einem englischen Satz. Die Oberfläche übersetzt sie
(`CoraxKit/Support/OAuthErrorText.swift`) und zeigt nur deutschen Text — der Kern-Text bleibt im Log.
Protokolliert werden ausschließlich:

```
oauth start provider=gmail
oauth done ok=1 ms=8423
oauth done ok=0 ms=1502 reason=cancelled
oauth cancel
```

Kein Token, kein Code, kein Client-Secret und keine Mailadresse. Microsoft bleibt in M3 ausgeblendet
(kein Knopf, kein Aufruf); der Kern könnte es, die Oberfläche bietet es nicht an.
