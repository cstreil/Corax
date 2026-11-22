//! The mockup mailbox as data.
//!
//! Transcribed from `Work/Tasks/2026-11-18-mail-app-mockup/mail-data.js`
//! (array `MAILS`) so the sandbox shows exactly what the design mockups show.
//! Times are relative to "now": the mockup groups are Heute / Gestern / Diese
//! Woche / Oktober, and mail clients derive those headers from the timestamp,
//! so each message carries its bucket instead of a fixed calendar date.

/// When a mail happened, expressed relative to the seeding run.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Slot {
    Today(u32, u32),
    Yesterday(u32, u32),
    DaysAgo(i64, u32, u32),
    /// Day of the previous month (the mockup's "Oktober" group).
    PreviousMonth(u32, u32, u32),
}

pub(crate) struct MockupAttachment {
    pub name: &'static str,
    pub kind: &'static str,
    /// Size as the mockup prints it; only metadata, the file is a placeholder.
    pub size: &'static str,
}

pub(crate) struct MockupMessage {
    /// Display name as the mail client shows it.
    pub from_name: &'static str,
    /// Written by the account owner (lives in Sent, counts as read).
    pub outgoing: bool,
    pub at: Slot,
    pub body: &'static str,
    pub attachments: &'static [MockupAttachment],
}

pub(crate) struct MockupThread {
    /// Stable suffix for Message-IDs and the placeholder file names.
    pub slug: &'static str,
    /// Mockup tab `wichtig` (true) or `news` (false).
    pub important: bool,
    pub from_name: &'static str,
    pub from_addr: &'static str,
    pub subject: &'static str,
    pub unread: bool,
    pub starred: bool,
    /// Mockup `tag`: [name, colour].
    pub tag: Option<(&'static str, &'static str)>,
    pub messages: &'static [MockupMessage],
}

/// The account the mockup mails are addressed to. `.invalid` never resolves
/// (RFC 2606), so the core's sync can only fail with a DNS/connection error.
pub(crate) const ACCOUNT_EMAIL: &str = "christian@sandbox.invalid";
pub(crate) const ACCOUNT_NAME: &str = "Christian";
pub(crate) const IMAP_HOST: &str = "imap.sandbox.invalid";
pub(crate) const SMTP_HOST: &str = "smtp.sandbox.invalid";

/// Split rule for the mockup's `news` tab, and the senders it matches.
pub(crate) const NEWS_SPLIT: &str = "Newsletter";
pub(crate) const NEWS_SENDERS: &[&str] =
    &["@1password.com", "@linkedin.com", "@mailer.netflix.com"];

const fn att(name: &'static str, kind: &'static str, size: &'static str) -> MockupAttachment {
    MockupAttachment { name, kind, size }
}

pub(crate) const THREADS: &[MockupThread] = &[
    MockupThread {
        slug: "jana",
        important: true,
        from_name: "Jana Peters",
        from_addr: "jana@studio-peters.de",
        subject: "Rebranding – Entwürfe Runde 3",
        unread: true,
        starred: true,
        tag: None,
        messages: &[
            MockupMessage {
                from_name: "Jana Peters",
                outgoing: false,
                at: Slot::DaysAgo(2, 16, 5),
                body: "<p>Hi Christian, kurze Frage vorab: dürfen wir beim Logo von der Wortmarke abweichen?</p>",
                attachments: &[],
            },
            MockupMessage {
                from_name: ACCOUNT_NAME,
                outgoing: true,
                at: Slot::DaysAgo(2, 18, 20),
                body: "<p>Ja, gern – solange der Vogel erkennbar bleibt.</p>",
                attachments: &[],
            },
            MockupMessage {
                from_name: "Jana Peters",
                outgoing: false,
                at: Slot::Today(10, 42),
                body: "<p>Hallo Christian,</p><p>anbei Runde 3. Wir haben die Wortmarke reduziert und den Vogel als eigenständiges Zeichen gezogen – funktioniert jetzt auch in 16 px.</p><p>Magst du bis Freitag Feedback geben? Dann kann Lea mit den App-Icons starten.</p><p>Liebe Grüße<br>Jana</p>",
                attachments: &[
                    att("Rebranding_Runde3.pdf", "application/pdf", "4,2 MB"),
                    att("Icon-Raster.png", "image/png", "820 KB"),
                ],
            },
        ],
    },
    MockupThread {
        slug: "db",
        important: true,
        from_name: "Deutsche Bahn",
        from_addr: "buchungsbestaetigung@bahn.de",
        subject: "Ihre Reisebestätigung Hamburg Hbf → Berlin Hbf",
        unread: true,
        starred: false,
        tag: Some(("Reise", "#2563eb")),
        messages: &[MockupMessage {
            from_name: "Deutsche Bahn",
            outgoing: false,
            at: Slot::Today(8, 12),
            body: "<p>Guten Tag Christian,</p><p>vielen Dank für Ihre Buchung. <b>Fr., 21. Nov., 07:24 ab Hamburg Hbf</b>, ICE 1703, Wagen 7, Platz 64 (Fenster).</p><p>Ihr Ticket finden Sie im Anhang und im DB Navigator.</p>",
            attachments: &[att("Ticket_ICE1703.pdf", "application/pdf", "210 KB")],
        }],
    },
    MockupThread {
        slug: "amp",
        important: true,
        from_name: "amp-werkstatt",
        from_addr: "info@amp-werkstatt.de",
        subject: "AW: Hiwatt",
        unread: false,
        starred: false,
        tag: None,
        messages: &[
            MockupMessage {
                from_name: ACCOUNT_NAME,
                outgoing: true,
                at: Slot::Yesterday(21, 10),
                body: "<p>Hallo, ich muss den Termin leider verschieben – Familie geht vor. Können Sie mir die Rechnung für das Gutachten noch einmal schicken?</p>",
                attachments: &[],
            },
            MockupMessage {
                from_name: "amp-werkstatt",
                outgoing: false,
                at: Slot::Today(7, 55),
                body: "<p>Hallo Christian,</p><p>das tut mir leid, und ich verstehe, dass die Familie immer vorgeht. Die Rechnung für das Gutachten habe ich noch einmal angehängt :)</p><p>Der Hiwatt steht bereit, sobald es dir passt.</p>",
                attachments: &[att("Gutachten_Hiwatt.pdf", "application/pdf", "1,1 MB")],
            },
        ],
    },
    MockupThread {
        slug: "cf",
        important: true,
        from_name: "Cloudflare",
        from_addr: "noreply@notify.cloudflare.com",
        subject: "[Action Required] Upgrade your Cloudflare Tunnel to 2026.10.2",
        unread: true,
        starred: false,
        tag: None,
        messages: &[MockupMessage {
            from_name: "Cloudflare",
            outgoing: false,
            at: Slot::Yesterday(16, 30),
            body: "<p>Hi cstreil,</p><p>one or more of your tunnels are running a <code>cloudflared</code> version that will stop being supported. Please upgrade to <b>2026.10.2 or later</b> before December 1.</p><p>Affected tunnel: <code>home-lab</code></p>",
            attachments: &[],
        }],
    },
    MockupThread {
        slug: "school",
        important: true,
        from_name: "Arzenbacher, Ulrike",
        from_addr: "ulrike.arzenbacher@bsfb.hamburg.de",
        subject: "Newsletter November ’26",
        unread: false,
        starred: false,
        tag: None,
        messages: &[MockupMessage {
            from_name: "Arzenbacher, Ulrike",
            outgoing: false,
            at: Slot::Yesterday(9, 19),
            body: "<p>Liebe Eltern,</p><p>mit unserem November-Newsletter möchten wir Sie über aktuelle Ereignisse, schöne Erlebnisse und wichtige Neuigkeiten aus unserem Schulleben informieren.</p><p>Viel Freude beim Lesen!</p><p>Mit freundlichen Grüßen<br><b>Ulrike Arzenbacher</b><br>Schulleitung · Schule Turmweg</p>",
            attachments: &[att(
                "Newsletter November 2026.pdf",
                "application/pdf",
                "1,0 MB",
            )],
        }],
    },
    MockupThread {
        slug: "guitar",
        important: true,
        from_name: "No.1 Guitar Center",
        from_addr: "service@no1guitarcenter.de",
        subject: "Rechnung 161497 (Duplikat)",
        unread: false,
        starred: false,
        tag: Some(("Rechnung", "#b45309")),
        messages: &[MockupMessage {
            from_name: "No.1 Guitar Center",
            outgoing: false,
            at: Slot::Yesterday(8, 2),
            body: "<p>Sehr geehrter Herr Streil,</p><p>anbei erhalten Sie im Anhang folgenden Beleg: Rechnung 161497 (Duplikat).</p><p>Mit freundlichen Grüßen<br>Ihr Service-Team</p>",
            attachments: &[att("Rechnung_161497.pdf", "application/pdf", "96 KB")],
        }],
    },
    MockupThread {
        slug: "1pw",
        important: false,
        from_name: "1Password",
        from_addr: "hello@1password.com",
        subject: "Create a recovery code now",
        unread: false,
        starred: false,
        tag: None,
        messages: &[MockupMessage {
            from_name: "1Password",
            outgoing: false,
            at: Slot::DaysAgo(2, 11, 0),
            body: "<p>Hi cstreil,</p><p>we know how important it is to always have access to your 1Password account. With recovery codes you can regain access even if you forget your account password.</p>",
            attachments: &[],
        }],
    },
    MockupThread {
        slug: "li",
        important: false,
        from_name: "LinkedIn Jobs",
        from_addr: "jobs-noreply@linkedin.com",
        subject: "Chief Marketing Officer (m/w/d) bei InkuPlay",
        unread: true,
        starred: false,
        tag: Some(("Social", "#16a34a")),
        messages: &[MockupMessage {
            from_name: "LinkedIn Jobs",
            outgoing: false,
            at: Slot::DaysAgo(3, 7, 30),
            body: "<p>Ihre Jobbenachrichtigung für Marketingleiter in Hamburg: <b>Chief Marketing Officer (m/w/d)</b> bei InkuPlay UG, ab 4.000 €.</p><p>3 weitere passende Stellen warten auf Sie.</p>",
            attachments: &[],
        }],
    },
    MockupThread {
        slug: "nf",
        important: false,
        from_name: "Netflix",
        from_addr: "info@mailer.netflix.com",
        subject: "Bitte überprüfen Sie Ihre Optionen",
        unread: false,
        starred: false,
        tag: None,
        messages: &[MockupMessage {
            from_name: "Netflix",
            outgoing: false,
            at: Slot::DaysAgo(4, 14, 12),
            body: "<p>Wir sind für Sie da, falls Sie Fragen haben. Ihre Möglichkeiten, um weiterzustreamen: Hallo, vielen Dank, dass Sie seit 2024 von uns …</p>",
            attachments: &[],
        }],
    },
    MockupThread {
        slug: "mara",
        important: true,
        from_name: "Mara Lindqvist",
        from_addr: "mara.l@posteo.de",
        subject: "Wochenende an der Ostsee?",
        unread: false,
        starred: false,
        tag: None,
        messages: &[
            MockupMessage {
                from_name: "Mara Lindqvist",
                outgoing: false,
                at: Slot::PreviousMonth(26, 18, 0),
                body: "<p>Wir haben das Haus in Hohwacht noch für das erste Dezemberwochenende – seid ihr dabei?</p>",
                attachments: &[],
            },
            MockupMessage {
                from_name: ACCOUNT_NAME,
                outgoing: true,
                at: Slot::PreviousMonth(27, 19, 30),
                body: "<p>Klingt großartig. Ich kläre das heute Abend.</p>",
                attachments: &[],
            },
            MockupMessage {
                from_name: "Mara Lindqvist",
                outgoing: false,
                at: Slot::PreviousMonth(28, 12, 10),
                body: "<p>Super! Ich schicke dir die Adresse und die Fotos vom Haus.</p><p>Bringt Gummistiefel mit 🙂</p>",
                attachments: &[att("Hohwacht_Haus.jpg", "image/jpeg", "2,8 MB")],
            },
        ],
    },
];
