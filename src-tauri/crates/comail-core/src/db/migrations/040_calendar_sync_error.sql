-- Last failed push of one event, so the app can show "Nicht hochgeladen"
-- instead of failing silently. Cleared by the next successful PUT.
ALTER TABLE calendar_events ADD COLUMN sync_error TEXT;
