-- Lead inbox: LeadGen OS pushes qualified leads, Contextward pulls and acks them.
-- Stores only the minimised leadgen.event.v1 fields Contextward needs. The payload
-- is set to NULL on ack; the row (id + hash, no PII) is kept for idempotency and
-- deleted 30 days after ack. Unacked rows are never aged out: the exporter only
-- re-sends changed leads, so deleting one would lose it for good. Withdrawn leads
-- are handled by retraction (0003).
CREATE TABLE IF NOT EXISTS lead_inbox (
  source_id TEXT PRIMARY KEY,
  content_hash TEXT NOT NULL,
  seq INTEGER NOT NULL UNIQUE,
  payload_json TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  acked_at TEXT
);
CREATE INDEX IF NOT EXISTS lead_inbox_pending ON lead_inbox (acked_at, seq);

-- Monotonic cursor source. A counter (not MAX(seq)) so deleting rows never reuses a cursor value.
CREATE TABLE IF NOT EXISTS lead_inbox_counter (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  value INTEGER NOT NULL
);
INSERT OR IGNORE INTO lead_inbox_counter (id, value) VALUES (1, 0);
