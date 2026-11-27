-- D1 schema for wa-gateway. Apply once: npx wrangler d1 execute weone-wa-gateway --remote --file=schema.sql
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  body TEXT NOT NULL,                  -- Meta's delivery, byte for byte (the signature covers it)
  sig TEXT NOT NULL,                   -- X-Hub-Signature-256, passed on unchanged
  received_at INTEGER NOT NULL,
  done TEXT NOT NULL DEFAULT '[]',     -- which targets already answered 200
  done_at INTEGER, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER, last_error TEXT);
CREATE INDEX IF NOT EXISTS events_todo ON events (done_at, next_at);
