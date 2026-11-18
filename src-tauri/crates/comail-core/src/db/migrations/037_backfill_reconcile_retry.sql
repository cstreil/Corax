-- A reconcile that keeps failing (dead session, server rejecting UID SEARCH
-- ALL) must not reconnect and re-fetch on every sync tick. The timestamp holds
-- the folder back until it expires; a successful reconcile clears it.
ALTER TABLE folders ADD COLUMN backfill_reconcile_retry_at INTEGER;
