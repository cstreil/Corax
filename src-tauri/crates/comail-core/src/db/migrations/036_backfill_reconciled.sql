-- A folder may only be called "done" once its UID list has been reconciled
-- against the server (fill_missing_uids). Older builds set backfill_done
-- before that check ran, and folders finished by them were never reconciled
-- at all, so they can be permanently short of mail. The flag lets the history
-- worker pick those folders up exactly once more.
ALTER TABLE folders ADD COLUMN backfill_reconciled INTEGER NOT NULL DEFAULT 0;
