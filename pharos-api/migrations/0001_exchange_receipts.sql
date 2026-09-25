CREATE TABLE IF NOT EXISTS exchange_receipts (
  idempotency_key TEXT PRIMARY KEY,
  receipt TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
