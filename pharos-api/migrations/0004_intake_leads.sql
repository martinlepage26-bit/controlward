-- Public intake (KAIROS signups, site forms). One row per submitted lead.
-- The lead is also copied into lead_inbox as source_id 'intake:<id>' so the
-- native Contextward app pulls it with the LeadGen leads. No auto-reply exists.
CREATE TABLE IF NOT EXISTS intake_leads (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  source TEXT NOT NULL,
  route TEXT NOT NULL,
  project_id TEXT NOT NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  company TEXT,
  note TEXT,
  test INTEGER NOT NULL DEFAULT 0,
  ip_hash TEXT,
  status TEXT NOT NULL DEFAULT 'new',
  pc_item_id TEXT,
  pc_status INTEGER
);
CREATE INDEX IF NOT EXISTS intake_leads_ip ON intake_leads (ip_hash, created_at);
CREATE INDEX IF NOT EXISTS intake_leads_route ON intake_leads (route, created_at);
