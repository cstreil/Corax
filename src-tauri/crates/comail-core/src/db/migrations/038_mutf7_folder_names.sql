-- Mailbox names used to be stored exactly as the server puts them on the wire,
-- which for IMAP4rev1 means modified UTF-7 ("finanzen/anwa&Awg-lte"). The UI
-- showed those escapes verbatim. Names are decoded at the IMAP boundary from
-- now on; this backfills the rows written by older builds.
--
-- The rewrite itself is code (revision 38 below), because SQLite cannot decode
-- mUTF-7. Kept as a file so the revision stays in the numbered sequence.
SELECT 1;
